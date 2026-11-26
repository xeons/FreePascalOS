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
  Scripts in a loaded page (Web.Script.PageScripting): inline, external
  and deferred scripts run in the standard's order, document.write
  writes at the parser's insertion point, DOMContentLoaded and the
  window's load reach the page's listeners and handlers, setTimeout
  runs on the loop, document.cookie reads and writes the network's jar
  without the HttpOnly cookie, readyState and location are the
  loader's, an onclick attribute handles a click, pushState changes the
  location and adds a history entry, and alert reaches the embedder.
  Images made by script outside the document (new Image()) load and
  fire load or error at listeners set after src, even when nothing
  refers to them any more and the collectors run while they load.
}
unit WebLoadTest.Scripting;

{$mode objfpc}
{$H+}

interface

procedure RunScriptingTests;

implementation

uses
  Classes,
  SysUtils,
  SyncObjs,
  TestChecks,
  Image.Model,
  Image.Codecs,
  Image.Files,
  Http.Cookies,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Navigation.Navigables,
  Web.Navigation.Events,
  Web.Script.PageScripting,
  Web.Script.Context,
  WebView.MouseEvents,
  WebView.FieldEditing,
  WebView.ClipboardEvents,
  Web.Dom.FormControls,
  WebView.KeyNames,
  WebBrowse.Input,
  WebLoadTest.Server;

type
  TScriptConditions = class
  public
    Navigable: TNavigable;
    Alerts: string;
    Console: string;
    function TimerRan: Boolean;
    procedure Alert(const Message: string);
    procedure ConsoleMessage(const Level, Text: string);
  end;

function TScriptConditions.TimerRan: Boolean;
var
  Output: TElement;
begin
  Result := False;
  if (Navigable.ActiveDocument = nil) then
    Exit;
  Output := Navigable.ActiveDocument.GetElementById('out');
  Result := (Output <> nil) and (Pos('timer', Output.TextContent) > 0);
end;

procedure TScriptConditions.Alert(const Message: string);
begin
  Alerts := Alerts + Message + ';';
end;

procedure TScriptConditions.ConsoleMessage(const Level, Text: string);
begin
  Console := Console + Level + ': ' + Text + LineEnding;
end;

procedure CheckScriptedPage;
var
  Environment: TTestEnvironment;
  Conditions: TScriptConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Jar: TCookieJar;
  Document: TDocument;
  Output, Button: TElement;
  Text: string;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TScriptConditions.Create;
  Sink := TNullResourceSink.Create;
  Jar := TCookieJar.Create;
  Environment.Client.Cookies := Jar;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnAlert := @Conditions.Alert;
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  try
    Environment.Site.AddRoute('s.test/page.html', 200, 'Content-Type: text/html|Set-Cookie: h=2; HttpOnly',
      '<!DOCTYPE html><html><head><script>var order = []; order.push("inline1"); document.cookie = "a=1";</script>' +
      '<script src="ext.js"></script><script defer src="def.js"></script></head><body><p id="out">x</p>' +
      '<button id="b" onclick="this.textContent = ''clicked''; alert(''hi'')">b</button>' +
      '<script>order.push("inline2"); document.write("<span id=written>w</span>");</script>' +
      '<script>document.addEventListener("DOMContentLoaded", function () { order.push("dcl"); });' +
      'window.onload = function () { order.push("load"); setTimeout(function () { order.push("timer");' +
      ' document.getElementById("out").textContent = order.join(",") + ";" + document.cookie + ";" +' +
      ' document.readyState + ";" + location.href; }, 10); };</script></body></html>');
    Environment.Site.AddRoute('s.test/ext.js', 200, 'Content-Type: text/javascript', 'order.push("ext");');
    Environment.Site.AddRoute('s.test/def.js', 200, 'Content-Type: text/javascript', 'order.push("defer");');
    Navigable.NavigateTo('https://s.test/page.html');
    Check(Environment.RunUntil(@Conditions.TimerRan), 'scripts: the page''s timer ran');
    Document := Navigable.ActiveDocument;
    Output := Document.GetElementById('out');
    if Output <> nil then
      Text := Output.TextContent
    else
      Text := '';
    Check(Text = 'inline1,ext,inline2,defer,dcl,load,timer;a=1;complete;https://s.test/page.html',
      'scripts: order, cookie (no HttpOnly), readyState and location (' + Text + ')');
    Check(Document.GetElementById('written') <> nil, 'scripts: document.write at the insertion point');
    Button := Document.GetElementById('b');
    FireEvent(Button, 'click', True, True);
    Check((Button.TextContent = 'clicked') and (Conditions.Alerts = 'hi;'),
      'scripts: an onclick attribute handles a click, alert reaches the embedder');
    Executor.ContextOf(Document).Engine.Evaluate('history.pushState(null, "", "/next.html")', 'test');
    Check((Navigable.CurrentUrlText = 'https://s.test/next.html') and (Navigable.History.Count = 2),
      'scripts: pushState changes the location and adds an entry (' + Navigable.CurrentUrlText + ')');
    Check(Pos('error', Conditions.Console) = 0, 'scripts: no errors on the console (' + Trim(Conditions.Console) + ')');
  finally
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Environment.Client.Cookies := nil;
    Jar.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

function OutputHas(Navigable: TNavigable; const Marker: string): Boolean;
var
  Output: TElement;
begin
  Result := False;
  if Navigable.ActiveDocument = nil then
    Exit;
  Output := Navigable.ActiveDocument.GetElementById('out');
  Result := (Output <> nil) and (Pos(Marker, Output.TextContent) > 0);
end;

type
  TFetchConditions = class(TScriptConditions)
  public
    function Done: Boolean;
  end;

function TFetchConditions.Done: Boolean;
begin
  Result := OutputHas(Navigable, 'done');
end;

{ fetch(), XMLHttpRequest, CORS for script, navigation timing and
  localStorage through a real loader and the in-process server. }
procedure CheckScriptFetches;
var
  Environment: TTestEnvironment;
  Conditions: TFetchConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Jar: TCookieJar;
  Text: string;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TFetchConditions.Create;
  Sink := TNullResourceSink.Create;
  Jar := TCookieJar.Create;
  Environment.Client.Cookies := Jar;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  try
    Environment.Site.AddRoute('f.test/page.html', 200, 'Content-Type: text/html|Set-Cookie: c=1',
      '<!DOCTYPE html><p id="out">x</p><script>var parts = [];' +
      'fetch("/data.json").then(function (r) { parts.push(r.status + " " + r.headers.get("x-custom") + " " +' +
      ' r.headers.get("set-cookie")); return r.json(); }).then(function (v) { parts.push("json " + v.n);' +
      ' return fetch("https://other.test/cors.txt"); }).then(function (r) { parts.push("cors " + r.type + " " +' +
      ' r.headers.get("x-hidden")); return r.text(); }).then(function (t) { parts.push(t);' +
      ' return fetch("https://other.test/closed.txt").catch(function (e) { parts.push("blocked " + e.name); }); })' +
      '.then(function () { var x = new XMLHttpRequest(); x.open("POST", "/echo"); x.onload = function () {' +
      ' parts.push("xhr " + x.status + " " + x.responseText); var t = performance.timing;' +
      ' parts.push("timing " + (t.responseStart >= t.navigationStart) + " " +' +
      ' (performance.getEntriesByType("navigation")[0].responseStart >= 0));' +
      ' localStorage.setItem("k", "v"); parts.push("storage " + localStorage.getItem("k"));' +
      ' document.getElementById("out").textContent = parts.join("|") + "|done"; };' +
      ' x.send("hello"); });</script>');
    Environment.Site.AddRoute('f.test/data.json', 200, 'Content-Type: application/json|X-Custom: yes|Set-Cookie: d=2',
      '{"n":5}');
    Environment.Site.AddRoute('other.test/cors.txt', 200,
      'Content-Type: text/plain|Access-Control-Allow-Origin: https://f.test|X-Hidden: 1', 'cross');
    Environment.Site.AddRoute('other.test/closed.txt', 200, 'Content-Type: text/plain', 'closed');
    Environment.Site.AddRoute('f.test/echo', 200, 'Content-Type: text/plain', 'echoed');
    Navigable.NavigateTo('https://f.test/page.html');
    Check(Environment.RunUntil(@Conditions.Done), 'script fetches: the chain finished (' +
      Trim(Conditions.Console) + ')');
    if Navigable.ActiveDocument.GetElementById('out') <> nil then
      Text := Navigable.ActiveDocument.GetElementById('out').TextContent
    else
      Text := '';
    Check(Text = '200 yes null|json 5|cors cors null|cross|blocked TypeError|xhr 200 echoed|timing true true|' +
      'storage v|done', 'script fetches: statuses, filtered headers, CORS, XHR, timing, storage (' + Text + ')');
  finally
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Environment.Client.Cookies := nil;
    Jar.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

{ Import maps: a bare specifier, a prefix ("pkg/"), a scope that maps
  the same specifier differently for the modules under it, and a
  specifier mapped to null (blocked). }
procedure CheckImportMaps;
var
  Environment: TTestEnvironment;
  Conditions: TScriptConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Output: TElement;
  Text: string;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TScriptConditions.Create;
  Sink := TNullResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  try
    Environment.Site.AddRoute('m.test/page.html', 200, 'Content-Type: text/html',
      '<!DOCTYPE html><script type="importmap">{"imports": {"lib": "/js/lib.js", "pkg/": "/js/pkg/",' +
      ' "gone": null}, "scopes": {"/js/pkg/": {"lib": "/js/other.js"}}}</script>' +
      '<p id="out">x</p><script type="module">import { v } from "lib"; import { w } from "pkg/a.js";' +
      ' import("gone").catch(function (e) { document.getElementById("out").textContent = v + w + " " + e.name +' +
      ' " timer"; });</script>');
    Environment.Site.AddRoute('m.test/js/lib.js', 200, 'Content-Type: text/javascript', 'export const v = "lib";');
    Environment.Site.AddRoute('m.test/js/other.js', 200, 'Content-Type: text/javascript', 'export const o = "+other";');
    Environment.Site.AddRoute('m.test/js/pkg/a.js', 200, 'Content-Type: text/javascript',
      'import { o } from "lib"; export const w = "+a" + o;');
    Navigable.NavigateTo('https://m.test/page.html');
    Check(Environment.RunUntil(@Conditions.TimerRan), 'import maps: the module ran');
    Output := Navigable.ActiveDocument.GetElementById('out');
    Text := '';
    if Output <> nil then
      Text := Output.TextContent;
    Check(Text = 'lib+a+other TypeError timer', 'import maps: bare, prefix, scoped and blocked specifiers (' +
      Text + ')');
  finally
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

type
  TImageConditions = class(TScriptConditions)
  public
    function Started: Boolean;
    function Done: Boolean;
  end;

function TImageConditions.Started: Boolean;
begin
  Result := OutputHas(Navigable, 'started');
end;

function TImageConditions.Done: Boolean;
begin
  Result := OutputHas(Navigable, 'done');
end;

function SmallPng: string;
var
  Image: TImage;
  Bytes: TBytes;
begin
  Image := TImage.Create(3, 2);
  try
    Image.Fill($FF808080);
    Bytes := EncodeImage(Image, ImageFormatPng);
  finally
    Image.Free;
  end;
  SetString(Result, PChar(@Bytes[0]), Length(Bytes));
end;

{ new Image() and createElement('img') outside the document: the fetch
  waits behind a gate while both collectors run, with no reference to
  the elements left in script; the events still reach the handlers. }
procedure CheckDetachedImages;
var
  Environment: TTestEnvironment;
  Conditions: TImageConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Route: TTestRoute;
  Text: string;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TImageConditions.Create;
  Sink := TNullResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  try
    Environment.Site.AddRoute('i.test/page.html', 200, 'Content-Type: text/html',
      '<!DOCTYPE html><p id="out">x</p><script>var seen = [];' +
      'function note(t) { seen.push(t); if (seen.length == 4) document.getElementById("out").textContent =' +
      ' seen.sort().join(",") + " done"; }' +
      'var image = new Image(); image.src = "slow.png"; var before = image.complete + " " + image.naturalWidth;' +
      ' image.onload = function () { note("load " + before + " " + this.complete + " " + this.naturalWidth + "x" +' +
      ' this.naturalHeight + " " + this.width + "x" + this.height + " " + this.currentSrc); };' +
      ' image.onerror = function () { note("error slow"); };' +
      'image = document.createElement("img"); image.src = "data:image/heic;base64,AAAA";' +
      ' image.addEventListener("error", function () { note("error data"); });' +
      'image = new Image(); image.src = "missing.png"; image.onerror = function () { note("error missing"); };' +
      'image = null; var empty = new Image(); note("empty " + empty.complete + " " + empty.naturalWidth);' +
      'document.getElementById("out").textContent = "started";</script>');
    Route := Environment.Site.AddRoute('i.test/slow.png', 200, 'Content-Type: image/png', SmallPng);
    Route.HeadGate := TEvent.Create(nil, True, False, '');
    Navigable.NavigateTo('https://i.test/page.html');
    Check(Environment.RunUntil(@Conditions.Started), 'detached images: the script ran');
    Executor.ContextOf(Navigable.ActiveDocument).Engine.CollectGarbage;
    Web.Dom.CollectGarbage;
    Executor.ContextOf(Navigable.ActiveDocument).Engine.CollectGarbage;
    Route.HeadGate.SetEvent;
    Check(Environment.RunUntil(@Conditions.Done), 'detached images: every event came (' +
      Trim(Conditions.Console) + ')');
    Text := Navigable.ActiveDocument.GetElementById('out').TextContent;
    Check(Text = 'empty true 0,error data,error missing,load false 0 true 3x2 3x2 https://i.test/slow.png done',
      'detached images: load and error at the handlers, the natural size, complete and currentSrc (' + Text + ')');
    Check(Navigable.Loader.Images.PendingCount = 0, 'detached images: nothing left loading');
  finally
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

{ EventSource against the in-process server: a stream in pieces (CRLF,
  CR and LF line ends, a comment, a named event, multi-line data, an
  id, retry), the reconnection after the server closes sending
  Last-Event-ID, a response of the wrong type failing for good, and
  close(). }
procedure CheckEventSource;
var
  Environment: TTestEnvironment;
  Conditions: TFetchConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Route: TTestRoute;
  Text: string;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TFetchConditions.Create;
  Sink := TNullResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  try
    Environment.Site.AddRoute('e.test/page.html', 200, 'Content-Type: text/html',
      '<!DOCTYPE html><p id="out">x</p><script>var log = [], ones = 0;' +
      'var source = new EventSource("/events");' +
      'log.push(source.readyState + " " + source.url);' +
      'source.onopen = function () { log.push("open " + source.readyState); };' +
      'source.onmessage = function (e) { log.push("message " + JSON.stringify(e.data) + " " + e.lastEventId + " " +' +
      ' e.origin); if (e.data === "one" && ++ones === 2) { source.close(); log.push("closed " + source.readyState);' +
      ' var bad = new EventSource("/plain"); bad.onerror = function () { log.push("bad " + bad.readyState);' +
      ' document.getElementById("out").textContent = log.join("|") + "|done"; }; } };' +
      'source.addEventListener("tick", function (e) { log.push("tick " + e.data); });' +
      'source.onerror = function () { log.push("error " + source.readyState); };</script>');
    Route := Environment.Site.AddRoute('e.test/events', 200, 'Content-Type: text/event-stream; charset=utf-8',
      #$EF#$BB#$BF': a comment'#13#10'retry: 50'#13#10'data: one'#13#10#13#10 +
      'event: tick'#13'data: a'#13'data: b'#13#13 + 'id: 7'#10'data:  spaced'#10#10 + 'data'#10#10 +
      'data: no end');
    Route.Pieces := 7;
    Environment.Site.AddRoute('e.test/plain', 200, 'Content-Type: text/plain', 'data: x'#10#10);
    Navigable.NavigateTo('https://e.test/page.html');
    Check(Environment.RunUntil(@Conditions.Done), 'event source: the events came (' + Trim(Conditions.Console) + ')');
    Text := '';
    if Navigable.ActiveDocument.GetElementById('out') <> nil then
      Text := Navigable.ActiveDocument.GetElementById('out').TextContent;
    Check(Text = '0 https://e.test/events|open 1|message "one"  https://e.test|tick a'#10'b|' +
      'message " spaced" 7 https://e.test|message "" 7 https://e.test|error 0|open 1|message "one" 7 https://e.test|' +
      'closed 2|bad 2|done',
      'event source: fields, line ends, reconnection, close and a wrong type (' + Text + ')');
    Check(Pos('last-event-id: 7', LowerCase(Environment.Site.LastHead('e.test/events'))) > 0,
      'event source: the reconnection sends Last-Event-ID');
  finally
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

procedure SendMouse(Document: TDocument; const Id, EventType: string; Buttons: Word);
var
  Init: TMouseEventInit;
begin
  Init := Default(TMouseEventInit);
  Init.Buttons := Buttons;
  DispatchMouseEvent(Document.GetElementById(Id), EventType, Init);
end;

{ Pointer events before the mouse events the web view sends: the mouse
  as pointer 1, a capture set in pointerdown taking the move and the up
  (gotpointercapture, lostpointercapture after the up), a cancelled
  pointerdown keeping mousedown, mousemove and mouseup back until the
  pointer is up, PointerEvent made by script, the capture's errors. }
procedure CheckPointerEvents;
var
  Environment: TTestEnvironment;
  Conditions: TScriptConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Document: TDocument;
  Context: TScriptContext;
  Text: string;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TScriptConditions.Create;
  Sink := TNullResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  try
    Environment.Site.AddRoute('p.test/page.html', 200, 'Content-Type: text/html',
      '<!DOCTYPE html><div id=b>b</div><div id=c>c</div><p id="out">x</p><script>var log = [];' +
      '["pointerdown", "mousedown", "pointerup", "mouseup", "pointermove", "mousemove", "gotpointercapture",' +
      ' "lostpointercapture"].forEach(function (t) { document.addEventListener(t, function (e) {' +
      ' log.push(t + ":" + e.target.id + (e instanceof PointerEvent ? ":" + e.pointerType + e.pointerId +' +
      ' e.isPrimary + e.button : "")); }, true); });' +
      'var b = document.getElementById("b"), c = document.getElementById("c");' +
      'b.addEventListener("pointerdown", function (e) { b.setPointerCapture(e.pointerId);' +
      ' log.push("has " + b.hasPointerCapture(1)); });' +
      'c.addEventListener("pointerdown", function (e) { e.preventDefault(); });' +
      'document.getElementById("out").textContent = "timer";</script>');
    Navigable.NavigateTo('https://p.test/page.html');
    Check(Environment.RunUntil(@Conditions.TimerRan), 'pointer events: the page ran');
    Document := Navigable.ActiveDocument;
    Context := Executor.ContextOf(Document);
    SendMouse(Document, 'b', 'mousedown', 1);
    SendMouse(Document, 'c', 'mousemove', 1);
    SendMouse(Document, 'c', 'mouseup', 0);
    Text := Context.Engine.ToText(Context.Engine.Evaluate('log.join(" ")'));
    Check(Text = 'pointerdown:b:mouse1true0 has true mousedown:b gotpointercapture:b:mouse1true-1 ' +
      'pointermove:b:mouse1true-1 mousemove:b pointerup:b:mouse1true0 mouseup:b lostpointercapture:b:mouse1true-1',
      'pointer events: pointer before mouse events, a capture taking the move and the up (' + Text + ')');
    Context.Engine.Evaluate('log = [];');
    SendMouse(Document, 'c', 'mousedown', 1);
    SendMouse(Document, 'c', 'mousemove', 1);
    SendMouse(Document, 'c', 'mouseup', 0);
    SendMouse(Document, 'c', 'mousemove', 0);
    Text := Context.Engine.ToText(Context.Engine.Evaluate('log.join(" ")'));
    Check(Text = 'pointerdown:c:mouse1true0 pointermove:c:mouse1true-1 pointerup:c:mouse1true0 ' +
      'pointermove:c:mouse1true-1 mousemove:c',
      'pointer events: a cancelled pointerdown holds the mouse events back until the up (' + Text + ')');
    Text := Context.Engine.ToText(Context.Engine.Evaluate('(function () { var e = new PointerEvent("pointerdown",' +
      ' { pointerId: 5, pointerType: "pen", isPrimary: true, pressure: 0.25, width: 3, clientX: 4, bubbles: true });' +
      ' var r = [e.pointerId, e.pointerType, e.isPrimary, e.pressure, e.width, e.height, e.clientX,' +
      ' e instanceof MouseEvent, e.getCoalescedEvents().length, e.isTrusted];' +
      ' try { b.setPointerCapture(7); } catch (x) { r.push(x.name); }' +
      ' try { document.createElement("i").setPointerCapture(1); } catch (x) { r.push(x.name); }' +
      ' r.push(b.hasPointerCapture(1)); b.setPointerCapture(1); r.push(b.hasPointerCapture(1));' +
      ' return r.join(); })()'));
    Check(Text = '5,pen,true,0.25,3,1,4,true,0,false,NotFoundError,InvalidStateError,false,false',
      'pointer events: PointerEvent made by script, capture errors, no capture without a button held (' + Text + ')');
  finally
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

type
  TTestClipboard = class
  public
    Text: string;
    function Read: string;
    procedure Write(const Value: string);
  end;

function TTestClipboard.Read: string;
begin
  Result := Text;
end;

procedure TTestClipboard.Write(const Value: string);
begin
  Text := Value;
end;

{ copy, cut and paste events before the field editor's own and the
  page's copy: a listener reading the pasted text, cancelling a paste,
  replacing what is copied, a cancelled cut that cuts nothing. }
procedure CheckClipboardEvents;
var
  Environment: TTestEnvironment;
  Conditions: TScriptConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Document: TDocument;
  Context: TScriptContext;
  Editor: TTextFieldEditor;
  Clipboard: TTestClipboard;
  Field: TElement;
  Text: string;
  Outcome: TClipboardOutcome;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TScriptConditions.Create;
  Sink := TNullResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  Editor := TTextFieldEditor.Create;
  Clipboard := TTestClipboard.Create;
  Editor.OnReadClipboard := @Clipboard.Read;
  Editor.OnWriteClipboard := @Clipboard.Write;
  try
    Environment.Site.AddRoute('c.test/page.html', 200, 'Content-Type: text/html',
      '<!DOCTYPE html><input id=f value="hello world"><p id="out">x</p><script>var log = [], mode = "";' +
      'var f = document.getElementById("f");' +
      '["copy", "cut", "paste"].forEach(function (t) { document.addEventListener(t, function (e) {' +
      ' log.push(t + ":" + e.target.id + ":" + e.isTrusted + ":" + (e instanceof ClipboardEvent) + ":" +' +
      ' e.clipboardData.types.join("+") + ":" + e.clipboardData.getData("text"));' +
      ' if (mode === "replace" && t !== "paste") { e.clipboardData.setData("text/plain", "replaced"); e.preventDefault(); }' +
      ' if (mode === "block") e.preventDefault(); }); });' +
      'document.getElementById("out").textContent = "timer";</script>');
    Navigable.NavigateTo('https://c.test/page.html');
    Check(Environment.RunUntil(@Conditions.TimerRan), 'clipboard events: the page ran');
    Document := Navigable.ActiveDocument;
    Context := Executor.ContextOf(Document);
    Field := Document.GetElementById('f');
    Clipboard.Text := ' pasted';
    Editor.Perform(Field, FieldValueEnd, '', []);
    Editor.Perform(Field, FieldPaste, '', []);
    Context.Engine.Evaluate('mode = "block";');
    Editor.Perform(Field, FieldPaste, '', []);
    Context.Engine.Evaluate('mode = "replace"; f.setSelectionRange(0, 5);');
    Editor.Perform(Field, FieldCopy, '', []);
    Text := Clipboard.Text;
    Editor.Perform(Field, FieldCut, '', []);
    Context.Engine.Evaluate('mode = ""; f.blur();');
    Outcome := FireCopyEvent(ClipboardEventTarget(Document), 'copy');
    Check(Outcome.Proceed and (TextControlValue(Field) = 'hello world pasted') and (Text = 'replaced'),
      'clipboard events: a paste goes in, a cancelled one does not, a cancelled copy or cut puts the page''s text (' +
      TextControlValue(Field) + ', ' + Text + ')');
    Text := Context.Engine.ToText(Context.Engine.Evaluate('log.join(" ")'));
    Check(Text = 'paste:f:true:true:text/plain: pasted paste:f:true:true:text/plain: pasted copy:f:true:true:: ' +
      'cut:f:true:true:: copy::true:true::',
      'clipboard events: trusted ClipboardEvents with the pasted text at the field, then the body (' + Text + ')');
    Text := Context.Engine.ToText(Context.Engine.Evaluate('(function () { var d = new DataTransfer();' +
      ' d.setData("Text", "a"); d.setData("text/html", "<b>b</b>"); d.setData("text/plain", "c");' +
      ' d.setData("URL", "# comment\nhttps://x.test/\nhttps://y.test/");' +
      ' var e = new ClipboardEvent("copy", { clipboardData: d, bubbles: true });' +
      ' var r = [d.types.join("+"), d.getData("text"), d.getData("url"), e.clipboardData === d,' +
      ' new ClipboardEvent("paste").clipboardData, e.isTrusted];' +
      ' d.clearData("text/html"); r.push(d.types.join("+")); d.clearData(); r.push(d.types.length);' +
      ' d.dropEffect = "bogus"; r.push(d.dropEffect); d.effectAllowed = "copyMove"; r.push(d.effectAllowed);' +
      ' return r.join(); })()'));
    Check(Text = 'text/html+text/plain+text/uri-list,c,https://x.test/,true,,false,text/plain+text/uri-list,0,none,' +
      'copyMove', 'clipboard events: DataTransfer and ClipboardEvent made by script (' + Text + ')');
  finally
    Editor.Free;
    Clipboard.Free;
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

{ Access keys: accessKeyLabel ("Alt+Shift+" and the first one-letter or
  one-digit token), and Alt+Shift with the key clicking the element as
  the web view does (webbrowse's TPageInput). }
procedure CheckAccessKeys;
var
  Environment: TTestEnvironment;
  Conditions: TScriptConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Document: TDocument;
  Context: TScriptContext;
  Input: TPageInput;
  Text: string;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TScriptConditions.Create;
  Sink := TNullResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  Input := TPageInput.Create(Navigable);
  try
    Environment.Site.AddRoute('k.test/page.html', 200, 'Content-Type: text/html',
      '<!DOCTYPE html><button id=a accesskey="k">a</button><button id=b accesskey="ab 7 c">b</button>' +
      '<div id=c accesskey="">c</div><p id="out">x</p><script>var log = [];' +
      'document.addEventListener("click", function (e) { log.push("click " + e.target.id); });' +
      'document.getElementById("out").textContent = "timer";</script>');
    Navigable.NavigateTo('https://k.test/page.html');
    Check(Environment.RunUntil(@Conditions.TimerRan), 'access keys: the page ran');
    Document := Navigable.ActiveDocument;
    Context := Executor.ContextOf(Document);
    Input.PressKey(Document, ScanCodeOfKeyCode('KeyK'), Ord('K'), $05);
    Input.PressKey(Document, ScanCodeOfKeyCode('Digit7'), Ord('&'), $05);
    Input.PressKey(Document, ScanCodeOfKeyCode('KeyQ'), Ord('Q'), $05);
    Text := Context.Engine.ToText(Context.Engine.Evaluate('[document.getElementById("a").accessKeyLabel,' +
      ' document.getElementById("b").accessKeyLabel, document.getElementById("c").accessKeyLabel,' +
      ' log.join(" "), document.activeElement.id].join("|")'));
    Check(Text = 'Alt+Shift+K|Alt+Shift+7||click a click b|b',
      'access keys: the label and Alt+Shift activating the element (' + Text + ')');
  finally
    Input.Free;
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

procedure RunScriptingTests;
begin
  CheckAccessKeys;
  CheckClipboardEvents;
  CheckPointerEvents;
  CheckEventSource;
  CheckDetachedImages;
  CheckScriptedPage;
  CheckScriptFetches;
  CheckImportMaps;
end;

end.
