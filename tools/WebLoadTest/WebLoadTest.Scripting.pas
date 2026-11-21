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
  TestChecks,
  Http.Cookies,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Navigation.Navigables,
  Web.Navigation.Events,
  Web.Script.PageScripting,
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

procedure RunScriptingTests;
begin
  CheckScriptedPage;
  CheckScriptFetches;
  CheckImportMaps;
end;

end.
