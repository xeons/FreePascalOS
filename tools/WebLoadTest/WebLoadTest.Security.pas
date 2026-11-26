{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  WebSockets and Content Security Policy in loaded pages, against the
  in-process site and its WebSocket servers:

  - WebSocket: the constructor's checks (scheme, fragment, subprotocols),
    send() while connecting, close()'s code and reason checks, an echo
    with a subprotocol and permessage-deflate, text and binary
    (arraybuffer and blob) messages with their origin, bufferedAmount
    going back to 0, the clean close handshake, the server closing,
    a refused handshake and a mixed-content ws: from an https page
    failing (error, then close 1006), the handshake's Origin;
  - CSP from the response: nonces for inline and external scripts,
    'self' and a cross-origin script refused, a refused style block,
    an event handler allowed by 'unsafe-hashes' with its hash, eval and
    Function refused with EvalError, connect-src refusing fetch() and a
    WebSocket, report-only reporting without blocking,
    securitypolicyviolation events, reports to report-uri;
  - 'strict-dynamic': a script inserted by a nonced one runs, a
    parser-inserted one without the nonce does not;
  - html5test's CSP 1.0 case: a frame whose meta policy refuses eval;
  - WebAssembly: script-src without 'unsafe-eval' or 'wasm-unsafe-eval'
    refuses compiling (CompileError, a "wasm-eval" violation), while
    validate still answers; 'wasm-unsafe-eval' allows it but not eval.
}
unit WebLoadTest.Security;

{$mode objfpc}
{$H+}

interface

procedure RunSecurityTests;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Navigation.Navigables,
  Web.Script.PageScripting,
  WebLoadTest.Server;

type
  TSecurityRun = class
  public
    Environment: TTestEnvironment;
    Sink: TNullResourceSink;
    Navigable: TNavigable;
    Executor: TPageScriptExecutor;
    Console: string;
    constructor Create;
    destructor Destroy; override;
    procedure ConsoleMessage(const Level, Text: string);
    function Done: Boolean;
    function Output: string;
  end;

constructor TSecurityRun.Create;
begin
  inherited Create;
  Environment := TTestEnvironment.Create;
  Sink := TNullResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @ConsoleMessage;
  Navigable.Executor := Executor;
end;

destructor TSecurityRun.Destroy;
begin
  Navigable.Free;
  Executor.Free;
  { Dropped connections are freed on threads of their own. }
  Environment.RunFor(100);
  Sink.Free;
  Environment.Free;
  inherited Destroy;
end;

procedure TSecurityRun.ConsoleMessage(const Level, Text: string);
begin
  Console := Console + Level + ': ' + Text + LineEnding;
end;

function TSecurityRun.Output: string;
var
  Element: TElement;
begin
  Result := '';
  if Navigable.ActiveDocument = nil then
    Exit;
  Element := Navigable.ActiveDocument.GetElementById('out');
  if Element <> nil then
    Result := Element.TextContent;
end;

function TSecurityRun.Done: Boolean;
begin
  Result := Pos('done', Output) > 0;
end;

procedure CheckWebSocketApi;
var
  Run: TSecurityRun;
  Text: string;
begin
  Run := TSecurityRun.Create;
  try
    Run.Environment.Site.AddRoute('ws.test/page.html', 200, 'Content-Type: text/html',
      '<!DOCTYPE html><p id="out">x</p><script>var log = [];' +
      'function attempt(name, f) { try { f(); log.push(name + " ok"); } catch (e) { log.push(name + " " + e.name); } }' +
      'attempt("ftp", function () { new WebSocket("ftp://wsecho.test/"); });' +
      'attempt("fragment", function () { new WebSocket("wss://wsecho.test/#x"); });' +
      'attempt("duplicate", function () { new WebSocket("wss://wsecho.test/", ["a", "a"]); });' +
      'attempt("token", function () { new WebSocket("wss://wsecho.test/", "a b"); });' +
      'log.push("constants " + WebSocket.CONNECTING + WebSocket.OPEN + WebSocket.CLOSING + WebSocket.CLOSED +' +
      ' ("binaryType" in WebSocket.prototype));' +
      'var event = new CloseEvent("close", { wasClean: true, code: 4000, reason: "r" });' +
      'log.push("closeevent " + event.wasClean + " " + event.code + " " + event.reason);' +
      'var ws = new WebSocket("https://wsecho.test/echo?q=1", ["chat", "other"]);' +
      'log.push("new " + ws.readyState + " " + ws.url + " " + ws.binaryType + " " + ws.bufferedAmount);' +
      'attempt("early send", function () { ws.send("x"); });' +
      'attempt("code", function () { ws.close(1001); });' +
      'attempt("reason", function () { ws.close(1000, "x".repeat(124)); });' +
      'var count = 0;' +
      'ws.onopen = function () { log.push("open " + ws.readyState + " " + ws.protocol + " " + ws.extensions);' +
      ' ws.send("hello"); ws.binaryType = "arraybuffer"; ws.send(new Uint8Array([1, 2, 3]));' +
      ' ws.send(new Blob(["blob!"])); log.push("buffered " + ws.bufferedAmount); };' +
      'ws.onmessage = function (e) { count++;' +
      ' if (typeof e.data === "string") log.push("text " + e.data + " " + e.origin);' +
      ' else log.push("binary " + e.data.byteLength + " " + (e.data instanceof ArrayBuffer));' +
      ' if (count === 3) { ws.close(1000, "bye"); log.push("closing " + ws.readyState); } };' +
      'ws.onerror = function () { log.push("error?"); };' +
      'ws.onclose = function (e) { log.push("close " + e.wasClean + " " + e.code + " " + e.reason + " " +' +
      ' ws.readyState + " " + ws.bufferedAmount); serverCloses(); };' +
      'function serverCloses() { var s = new WebSocket("wss://wsclose.test/");' +
      ' s.onclose = function (e) { log.push("server " + e.wasClean + " " + e.code + " " + e.reason); refused(); }; }' +
      'function refused() { var r = new WebSocket("wss://wsrefuse.test/");' +
      ' r.onerror = function () { log.push("refused error " + r.readyState); };' +
      ' r.onclose = function (e) { log.push("refused " + e.wasClean + " " + e.code); mixed(); }; }' +
      'function mixed() { var m = new WebSocket("ws://wsecho.test/");' +
      ' m.onerror = function () { log.push("mixed error"); };' +
      ' m.onclose = function (e) { log.push("mixed " + e.code);' +
      ' document.getElementById("out").textContent = log.join("|") + "|done"; }; }' +
      '</script>');
    Run.Navigable.NavigateTo('https://ws.test/page.html');
    Check(Run.Environment.RunUntil(@Run.Done, 10000), 'websocket: the page finished (' + Run.Output + ' ' +
      Trim(Run.Console) + ')');
    Text := Run.Output;
    Check(Pos('ftp SyntaxError|fragment SyntaxError|duplicate SyntaxError|token SyntaxError|constants 0123true|' +
      'closeevent true 4000 r|new 0 wss://wsecho.test/echo?q=1 blob 0|early send InvalidStateError|' +
      'code InvalidAccessError|reason SyntaxError|', Text) = 1, 'websocket: the constructor''s and methods'' checks (' +
      Text + ')');
    Check(Pos('|open 1 chat permessage-deflate|buffered 13|text hello wss://wsecho.test|binary 3 true|' +
      'binary 5 true|closing 2|close true 1000 bye 3 0|', Text) > 0,
      'websocket: echo with deflate, buffered amount, the close handshake (' + Text + ')');
    Check(Pos('|server true 4001 done|', Text) > 0, 'websocket: the server closing');
    Check(Pos('|refused error 3|refused false 1006|', Text) > 0, 'websocket: a refused handshake fails');
    Check(Pos('|mixed error|mixed 1006|done', Text) > 0, 'websocket: ws: from an https page is mixed content');
    Check(Pos('text:hello,binary:3,binary:5,close:1000:bye', Run.Environment.Site.SocketLog) > 0,
      'websocket: what the server saw (' + Run.Environment.Site.SocketLog + ')');
    Check(Pos('Origin: https://ws.test'#13#10, Run.Environment.Site.SocketHeads) > 0,
      'websocket: the handshake carries the page''s origin');
    Check(Pos('Sec-WebSocket-Protocol: chat, other'#13#10, Run.Environment.Site.SocketHeads) > 0,
      'websocket: the subprotocols offered');
    Check(Pos('ws://wsecho.test', Run.Environment.Site.LogText) = 0, 'websocket: the mixed-content one never went');
  finally
    Run.Free;
  end;
end;

procedure CheckPolicies;
var
  Run: TSecurityRun;
  Text: string;
begin
  Run := TSecurityRun.Create;
  try
    Run.Environment.Site.AddRoute('csp.test/page.html', 200, 'Content-Type: text/html|' +
      'Content-Security-Policy: script-src ''self'' ''nonce-abc'' ''unsafe-hashes'' ' +
      '''sha256-z/st8V5b9yNQ/bscveqKFdJ1EuyZCL2Nih9dKDaFAvc=''; style-src ''self''; connect-src ''self''; ' +
      'report-uri /report|Content-Security-Policy-Report-Only: img-src ''none''; report-uri /report-only',
      '<!DOCTYPE html><p id="out">x</p><script nonce="abc">var log = [], violations = [];' +
      'document.addEventListener("securitypolicyviolation", function (e) { violations.push(e.effectiveDirective +' +
      ' " " + e.blockedURI + " " + e.disposition + " " + (e instanceof SecurityPolicyViolationEvent)); });' +
      '</script><script>log.push("no nonce ran");</script><script nonce="wrong">log.push("wrong nonce ran");</script>' +
      '<script src="/ok.js"></script><script src="https://other.test/x.js"></script>' +
      '<style>#out { color: red }</style><button id="b" onclick="log.push(''handler'')">b</button>' +
      '<button id="c" onclick="log.push(''other handler'')">c</button><img src="/pic.png">' +
      '<script nonce="abc">' +
      'try { eval("1"); log.push("eval ran"); } catch (e) { log.push("eval " + e.name); }' +
      'try { new Function("return 1"); log.push("function ran"); } catch (e) { log.push("function " + e.name); }' +
      'log.push("sheet " + (document.querySelector("style").sheet === null));' +
      'var ws = new WebSocket("wss://wsecho.test/"); ws.onclose = function (e) { log.push("socket " + e.code); };' +
      'fetch("https://other.test/data").then(function () { log.push("fetch ok"); },' +
      ' function () { log.push("fetch blocked"); });' +
      'fetch("/same").then(function (r) { log.push("same " + r.status); });' +
      'window.onload = function () { setTimeout(function () { document.getElementById("b").click();' +
      ' document.getElementById("c").click(); setTimeout(function () {' +
      ' document.getElementById("out").textContent = log.join("|") + "||" + violations.sort().join("|") +' +
      ' "|done"; }, 200); }, 50); };</script>');
    Run.Environment.Site.AddRoute('csp.test/ok.js', 200, 'Content-Type: text/javascript', 'log.push("ok.js");');
    Run.Environment.Site.AddRoute('other.test/x.js', 200, 'Content-Type: text/javascript', 'log.push("x.js");');
    Run.Environment.Site.AddRoute('other.test/data', 200, 'Content-Type: text/plain|Access-Control-Allow-Origin: *', 'd');
    Run.Environment.Site.AddRoute('csp.test/same', 200, 'Content-Type: text/plain', 's');
    Run.Environment.Site.AddRoute('csp.test/pic.png', 404, 'Content-Type: text/plain', '');
    Run.Environment.Site.AddRoute('csp.test/report', 204, '', '');
    Run.Environment.Site.AddRoute('csp.test/report-only', 204, '', '');
    Run.Navigable.NavigateTo('https://csp.test/page.html');
    Check(Run.Environment.RunUntil(@Run.Done, 10000), 'csp: the page finished (' + Run.Output + ')');
    Text := Run.Output;
    Check(Pos('no nonce ran', Text) + Pos('wrong nonce ran', Text) + Pos('|x.js', Text) = 0,
      'csp: inline scripts without the nonce and a script of another origin do not run (' + Text + ')');
    Check(Pos('ok.js|eval EvalError|function EvalError|sheet true|', Text) = 1,
      'csp: ''self'', eval and Function refused, the style block refused (' + Text + ')');
    Check((Pos('|handler', Text) > 0) and (Pos('other handler', Text) = 0),
      'csp: the handler with the hash ran, the other did not');
    Check((Pos('fetch blocked', Text) > 0) and (Pos('same 200', Text) > 0) and (Pos('socket 1006', Text) > 0),
      'csp: connect-src refuses another origin''s fetch and the WebSocket, not its own (' + Text + ')');
    Check(Pos('script-src-elem inline enforce true', Text) > 0, 'csp: an inline script''s violation event');
    Check(Pos('script-src-elem https://other.test/x.js enforce true', Text) > 0,
      'csp: a script URL''s violation event');
    Check(Pos('script-src eval enforce true', Text) > 0, 'csp: eval''s violation event');
    Check(Pos('style-src-elem inline enforce true', Text) > 0, 'csp: the style block''s violation event');
    Check(Pos('script-src-attr inline enforce true', Text) > 0, 'csp: the handler''s violation event');
    Check(Pos('connect-src https://other.test/data enforce true', Text) > 0, 'csp: fetch''s violation event');
    Check(Pos('connect-src wss://wsecho.test/ enforce true', Text) > 0, 'csp: the WebSocket''s violation event');
    Check(Pos('img-src https://csp.test/pic.png report true', Text) > 0,
      'csp: report-only reports the image (' + Text + ')');
    Check(Run.Environment.Site.RequestCount('GET https://csp.test/pic.png') = 1, 'csp: report-only does not block');
    Check(Run.Environment.Site.RequestCount('GET https://other.test/x.js') = 0, 'csp: the refused script never went');
    Check(Run.Environment.Site.RequestCount('POST https://csp.test/report') >= 6, 'csp: reports to report-uri (' +
      IntToStr(Run.Environment.Site.RequestCount('POST https://csp.test/report')) + ')');
    Check(Pos('application/csp-report', LowerCase(Run.Environment.Site.LastHead('POST https://csp.test/report'))) > 0,
      'csp: a report''s type');
    Check(Run.Environment.Site.RequestCount('POST https://csp.test/report-only') >= 1,
      'csp: the report-only policy''s reports (the image and the favicon)');
  finally
    Run.Free;
  end;
end;

procedure CheckStrictDynamic;
var
  Run: TSecurityRun;
  Text: string;
begin
  Run := TSecurityRun.Create;
  try
    Run.Environment.Site.AddRoute('sd.test/page.html', 200, 'Content-Type: text/html|' +
      'Content-Security-Policy: script-src ''nonce-n'' ''strict-dynamic'' https://sd.test',
      '<!DOCTYPE html><p id="out">x</p><script nonce="n">var log = [];' +
      'var s = document.createElement("script"); s.src = "/dyn.js"; document.head.appendChild(s);</script>' +
      '<script src="/parser.js"></script><script nonce="n" src="/nonced.js"></script>' +
      '<script nonce="n">window.onload = function () { setTimeout(function () {' +
      ' document.getElementById("out").textContent = log.sort().join("|") + "|done"; }, 50); };</script>');
    Run.Environment.Site.AddRoute('sd.test/dyn.js', 200, 'Content-Type: text/javascript', 'log.push("dyn");');
    Run.Environment.Site.AddRoute('sd.test/parser.js', 200, 'Content-Type: text/javascript', 'log.push("parser");');
    Run.Environment.Site.AddRoute('sd.test/nonced.js', 200, 'Content-Type: text/javascript', 'log.push("nonced");');
    Run.Navigable.NavigateTo('https://sd.test/page.html');
    Check(Run.Environment.RunUntil(@Run.Done, 10000), 'csp strict-dynamic: the page finished');
    Text := Run.Output;
    Check(Text = 'dyn|nonced|done', 'csp strict-dynamic: trust passes to inserted scripts, not to parser-inserted ' +
      'ones (' + Text + ')');
  finally
    Run.Free;
  end;
end;

procedure CheckMetaPolicyInFrame;
var
  Run: TSecurityRun;
  Text: string;
begin
  Run := TSecurityRun.Create;
  try
    Run.Environment.Site.AddRoute('h5.test/page.html', 200, 'Content-Type: text/html',
      '<!DOCTYPE html><p id="out">x</p><script>var log = [];' +
      'try { eval("1"); log.push("parent eval"); } catch (e) { log.push("parent " + e.name); }' +
      'window.addEventListener("message", function (e) { log.push(e.data);' +
      ' document.getElementById("out").textContent = log.join("|") + "|done"; });</script>' +
      '<iframe src="/csp.html"></iframe>');
    Run.Environment.Site.AddRoute('h5.test/csp.html', 200, 'Content-Type: text/html',
      '<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="script-src ''unsafe-inline''">' +
      '</head><body><script>var passed = false; try { eval("true"); } catch (e) { passed = true; }' +
      'window.top.postMessage("csp10:" + (passed ? "passed" : "failed"), "*");</script></body></html>');
    Run.Navigable.NavigateTo('https://h5.test/page.html');
    Check(Run.Environment.RunUntil(@Run.Done, 10000), 'csp meta: the page finished');
    Text := Run.Output;
    Check(Text = 'parent eval|csp10:passed|done', 'csp meta: html5test''s CSP 1.0 frame (' + Text + ')');
  finally
    Run.Free;
  end;
end;

{ The policy's answer to WebAssembly in a page: what the page logged. }
function WasmUnderPolicy(const Policy: string): string;
const
  { (module) }
  EmptyModule = 'new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])';
var
  Run: TSecurityRun;
begin
  Run := TSecurityRun.Create;
  try
    Run.Environment.Site.AddRoute('wasm.test/page.html', 200, 'Content-Type: text/html|' +
      'Content-Security-Policy: ' + Policy,
      '<!DOCTYPE html><p id="out">x</p><script>var log = [];' +
      'document.addEventListener("securitypolicyviolation", function (e) {' +
      ' log.push("violation " + e.effectiveDirective + " " + e.blockedURI); });' +
      'log.push("validate " + WebAssembly.validate(' + EmptyModule + '));' +
      'try { new WebAssembly.Module(' + EmptyModule + '); log.push("module made"); }' +
      ' catch (e) { log.push("module " + e.name); }' +
      'try { eval("1"); log.push("eval ran"); } catch (e) { log.push("eval " + e.name); }' +
      'WebAssembly.compile(' + EmptyModule + ').then(function () { log.push("compiled"); },' +
      ' function (e) { log.push("compile " + e.name); }).then(function () { setTimeout(function () {' +
      ' document.getElementById("out").textContent = log.join("|") + "|done"; }, 50); });</script>');
    Run.Navigable.NavigateTo('https://wasm.test/page.html');
    Check(Run.Environment.RunUntil(@Run.Done, 10000), 'csp wasm: the page finished (' + Policy + ')');
    Result := Run.Output;
  finally
    Run.Free;
  end;
end;

procedure CheckWasmPolicy;
var
  Text: string;
begin
  Text := WasmUnderPolicy('script-src ''unsafe-inline''');
  Check((Pos('validate true|module CompileError|eval EvalError|', Text) = 1) and (Pos('compile CompileError', Text) > 0),
    'csp wasm: compiling refused without ''wasm-unsafe-eval'' (' + Text + ')');
  Check(Pos('violation script-src wasm-eval', Text) > 0, 'csp wasm: the violation event (' + Text + ')');
  Text := WasmUnderPolicy('script-src ''unsafe-inline'' ''wasm-unsafe-eval''');
  Check((Pos('validate true|module made|eval EvalError|', Text) = 1) and (Pos('compiled', Text) > 0) and
    (Pos('violation script-src wasm-eval', Text) = 0), 'csp wasm: ''wasm-unsafe-eval'' allows compiling (' + Text + ')');
  Text := WasmUnderPolicy('script-src ''unsafe-inline'' ''unsafe-eval''');
  Check(Pos('validate true|module made|eval ran|compiled|', Text) = 1,
    'csp wasm: ''unsafe-eval'' allows compiling (' + Text + ')');
end;

procedure RunSecurityTests;
begin
  CheckWebSocketApi;
  CheckPolicies;
  CheckStrictDynamic;
  CheckMetaPolicyInFrame;
  CheckWasmPolicy;
end;

end.
