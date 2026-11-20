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

procedure RunScriptingTests;
begin
  CheckScriptedPage;
end;

end.
