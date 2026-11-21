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
  Child navigables (iframes) through a real loader and the in-process
  site: a same-origin frame loads (its load event, the parent's load
  waiting for it, contentDocument, frames[0], the frame's own location
  and viewport), a cross-origin frame's document and properties are
  out of reach while postMessage goes both ways with the right origin
  and source, X-Frame-Options and frame-ancestors keep a page out of a
  frame, a sandbox without allow-scripts runs no script, srcdoc, named
  targets, and a frame's navigation after the load joins the top-level
  history (Back traverses the frame). The frame policy rules are also
  checked on their own.
}
unit WebLoadTest.Frames;

{$mode objfpc}
{$H+}

interface

procedure RunFrameTests;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Url.Records,
  Url.Parser,
  Url.Origins,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.ResourceSink,
  Web.Navigation.Navigables,
  Web.Navigation.FramePolicy,
  Web.Script.PageScripting,
  WebLoadTest.Server;

type
  TFrameConditions = class
  public
    Navigable: TNavigable;
    Console: string;
    procedure ConsoleMessage(const Level, Text: string);
    function OutputDone: Boolean;
    function FrameAtTall: Boolean;
    function FrameBack: Boolean;
  end;

procedure TFrameConditions.ConsoleMessage(const Level, Text: string);
begin
  Console := Console + Level + ': ' + Text + LineEnding;
end;

function OutputText(Navigable: TNavigable): string;
var
  Output: TElement;
begin
  Result := '';
  if Navigable.ActiveDocument = nil then
    Exit;
  Output := Navigable.ActiveDocument.GetElementById('out');
  if Output <> nil then
    Result := Output.TextContent;
end;

function TFrameConditions.OutputDone: Boolean;
begin
  Result := Pos('done', OutputText(Navigable)) > 0;
end;

function ChildUrl(Navigable: TNavigable; Index: Integer): string;
begin
  if Index < Navigable.ChildCount then
    Result := Navigable.Child(Index).CurrentUrlText
  else
    Result := '';
end;

function TFrameConditions.FrameAtTall: Boolean;
begin
  Result := (Pos('tall.html', ChildUrl(Navigable, 0)) > 0) and (Navigable.Child(0).State = LoadingComplete);
end;

function TFrameConditions.FrameBack: Boolean;
begin
  Result := (Pos('child.html', ChildUrl(Navigable, 0)) > 0) and (Navigable.Child(0).State = LoadingComplete);
end;

function ChildText(Navigable: TNavigable; Index: Integer): string;
begin
  Result := '';
  if (Index < Navigable.ChildCount) and (Navigable.Child(Index).ActiveDocument <> nil) and
     (Navigable.Child(Index).ActiveDocument.Body <> nil) then
    Result := Navigable.Child(Index).ActiveDocument.Body.TextContent;
end;

procedure AddRoutes(Site: TTestSite);
begin
  Site.AddRoute('p.test/page.html', 200, 'Content-Type: text/html',
    '<!DOCTYPE html><title>Top</title><p id="out">x</p>' +
    '<iframe id="a" src="child.html" name="kid"></iframe>' +
    '<iframe id="c" src="https://q.test/other.html"></iframe>' +
    '<iframe id="deny" src="https://q.test/deny.html"></iframe>' +
    '<iframe id="fa" src="https://q.test/ancestors.html"></iframe>' +
    '<iframe id="sb" sandbox src="sandboxed.html"></iframe>' +
    '<iframe id="sd" srcdoc="<p>from srcdoc</p>"></iframe>' +
    '<script>var parts = []; var aLoaded = false;' +
    'document.getElementById("a").onload = function () { aLoaded = true; };' +
    'window.addEventListener("message", function (e) { parts.push("msg " + e.data + " " + e.origin + " " +' +
    ' (e.source === document.getElementById("c").contentWindow)); finish(); });' +
    'window.onload = function () { var a = document.getElementById("a"); var c = document.getElementById("c");' +
    ' parts.push("aLoaded " + aLoaded + " " + a.contentDocument.title + " " + (frames[0] === a.contentWindow) +' +
    ' " " + frames.length);' +
    ' parts.push("cdoc " + c.contentDocument);' +
    ' try { c.contentWindow.document; parts.push("cross readable"); } catch (e) { parts.push("cross " + e.name); }' +
    ' parts.push("sandboxed " + (window.sandboxRan === true));' +
    ' c.contentWindow.postMessage("ping", "https://q.test"); };' +
    'function finish() { document.getElementById("out").textContent = parts.join("|") + "|done"; }</script>');
  Site.AddRoute('p.test/child.html', 200, 'Content-Type: text/html',
    '<!DOCTYPE html><title>Child</title><a id="l" href="tall.html">t</a>' +
    '<script>parent.childSaw = location.href + " " + innerWidth + " " + (frameElement.id);</script>');
  Site.AddRoute('p.test/tall.html', 200, 'Content-Type: text/html', '<!DOCTYPE html><title>Tall</title><p>tall</p>');
  Site.AddRoute('p.test/sandboxed.html', 200, 'Content-Type: text/html',
    '<!DOCTYPE html><p>sb</p><script>parent.sandboxRan = true;</script>');
  Site.AddRoute('q.test/other.html', 200, 'Content-Type: text/html',
    '<!DOCTYPE html><p>other</p><script>window.addEventListener("message", function (e) {' +
    ' var blocked; try { parent.document; blocked = "no"; } catch (x) { blocked = x.name; }' +
    ' e.source.postMessage("pong " + e.data + " " + blocked, e.origin); });</script>');
  Site.AddRoute('q.test/deny.html', 200, 'Content-Type: text/html|X-Frame-Options: DENY', '<p>secret</p>');
  Site.AddRoute('q.test/ancestors.html', 200,
    'Content-Type: text/html|Content-Security-Policy: frame-ancestors https://elsewhere.test', '<p>secret</p>');
end;

procedure CheckFramedPage;
var
  Environment: TTestEnvironment;
  Conditions: TFrameConditions;
  Sink: TNullResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Text: string;
  Entries: Integer;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TFrameConditions.Create;
  Sink := TNullResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  try
    AddRoutes(Environment.Site);
    Navigable.NavigateTo('https://p.test/page.html');
    Check(Environment.RunUntil(@Conditions.OutputDone), 'frames: the page finished (' + Trim(Conditions.Console) +
      ')');
    Text := OutputText(Navigable);
    Check(Text = 'aLoaded true Child true 5|cdoc null|cross SecurityError|sandboxed false|' +
      'msg pong ping SecurityError https://q.test true|done',
      'frames: load events, contentDocument, frames[], cross-origin limits, postMessage, sandbox (' + Text + ')');
    Check(Navigable.ChildCount = 6, 'frames: a child navigable per iframe');
    Check(Pos('refuses', ChildText(Navigable, 2)) > 0, 'frames: X-Frame-Options DENY keeps the page out');
    Check(Pos('refuses', ChildText(Navigable, 3)) > 0, 'frames: frame-ancestors keeps the page out');
    Check(Pos('from srcdoc', ChildText(Navigable, 5)) > 0, 'frames: srcdoc');
    Check(Navigable.FindByName('kid') = Navigable.Child(0), 'frames: a frame by its name');
    Check(Navigable.Child(0).ChooseNavigable('_top') = Navigable, 'frames: _top from a frame');
    Check(Executor.ContextOf(Navigable.ActiveDocument).Engine.Evaluate('childSaw', 'test') <> 0,
      'frames: the frame''s script ran');
    Entries := Navigable.History.Count;
    Executor.ContextOf(Navigable.Child(0).ActiveDocument).Engine.Evaluate('location.href = "tall.html"', 'test');
    Check(Environment.RunUntil(@Conditions.FrameAtTall), 'frames: a frame navigates itself (' + ChildUrl(Navigable, 0) + ' ' + Trim(Conditions.Console) + ')');
    Check(Navigable.History.Count = Entries + 1, 'frames: the frame''s navigation joins the top-level history');
    Navigable.Back;
    Check(Environment.RunUntil(@Conditions.FrameBack), 'frames: Back traverses the frame');
    Check(Pos('page.html', Navigable.CurrentUrlText) > 0, 'frames: the top-level document stays');
    Executor.ContextOf(Navigable.ActiveDocument).Engine.Evaluate('document.getElementById("a").remove()', 'test');
    Check(Navigable.ChildCount = 5, 'frames: removing the element drops its navigable');
  finally
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

function Origin(const Text: string): TUrlOrigin;
var
  Url: TUrlRecord;
begin
  ParseUrl(Text, Url);
  Result := OriginOfUrl(Url);
end;

procedure CheckFramePolicy;
var
  Url: TUrlRecord;
  Ancestors: TOriginArray;
  Allowances: TFrameAllowances;
begin
  ParseUrl('https://a.test/x', Url);
  Ancestors := nil;
  SetLength(Ancestors, 1);
  Ancestors[0] := Origin('https://a.test/');
  Check(MayBeFramed(Url, '', '', Ancestors), 'frame policy: no rules');
  Check(not MayBeFramed(Url, '', 'DENY', Ancestors), 'frame policy: DENY');
  Check(MayBeFramed(Url, '', 'sameorigin', Ancestors), 'frame policy: SAMEORIGIN, same origin');
  Ancestors[0] := Origin('https://b.test/');
  Check(not MayBeFramed(Url, '', 'SAMEORIGIN', Ancestors), 'frame policy: SAMEORIGIN, another origin');
  Check(MayBeFramed(Url, '', 'DENY, SAMEORIGIN', Ancestors), 'frame policy: conflicting values are invalid');
  Check(MayBeFramed(Url, 'frame-ancestors https://*.test', 'DENY', Ancestors),
    'frame policy: frame-ancestors decides over X-Frame-Options');
  Check(not MayBeFramed(Url, 'frame-ancestors ''self''', '', Ancestors), 'frame policy: frame-ancestors self');
  Check(not MayBeFramed(Url, 'frame-ancestors ''none''', '', Ancestors), 'frame policy: frame-ancestors none');
  Check(MayBeFramed(Url, 'frame-ancestors https:', '', Ancestors), 'frame policy: a scheme source');
  Check(MayBeFramed(Url, 'default-src ''self''', 'SAMEORIGIN', Ancestors) = False,
    'frame policy: other directives leave X-Frame-Options');
  Allowances := ParseSandboxAllowances('allow-scripts  ALLOW-FORMS bogus');
  Check(Allowances = [AllowScripts, AllowForms], 'frame policy: sandbox tokens');
end;

procedure RunFrameTests;
begin
  CheckFramePolicy;
  CheckFramedPage;
end;

end.
