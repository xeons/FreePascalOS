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
  What scripts need from the rest of the engine that the bindings do not
  do themselves: the event loop (timers, tasks), fetching scripts,
  navigation and session history, user prompts, the viewport, cookies.
  The loader and event loop subclass TScriptEnvironment and hand it to
  the script context (TScriptContext.Create).

  Nothing here pretends: a hook the environment does not implement
  raises EScriptEnvironmentUnsupported, which scripts see as a
  NotSupportedError DOMException, and the timers exist on the window
  only when SupportsTimers says so.

  Calls back into the script context (Web.Script.Context):
    FireTimer(TimerId)            when a timer is due (as a task); the
                                  context runs its handler, then the
                                  microtask checkpoint
    ExecuteClassicScript(...)     a fetched script, to run now
    ScriptFetchFailed(Element)    a script that could not be fetched
    PerformMicrotaskCheckpoint    after each task the loop runs
    Parser.Resume                 after a parser-blocking script ran
}
unit Web.ScriptEnvironment;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Dom;

type
  EScriptEnvironmentUnsupported = class(Exception);

  { How a classic script waits (the HTML Standard's script preparation):
    ParserBlocking stops the parser until it ran (the context's parser
    host has paused it); Deferred runs after parsing, in order; InOrder
    is a script-inserted one with async=false; Async runs when it is
    there. }
  TScriptFetchMode = (ScriptFetchParserBlocking, ScriptFetchDeferred, ScriptFetchInOrder, ScriptFetchAsync);

  TScriptEnvironment = class
  public
    { Timers: StartTimer asks for Context.FireTimer(TimerId) after
      Milliseconds (again every Milliseconds when Repeating, until
      StopTimer). Context is the TScriptContext. }
    function SupportsTimers: Boolean; virtual;
    procedure StartTimer(Context: TObject; TimerId: Integer; Milliseconds: Integer; Repeating: Boolean); virtual;
    procedure StopTimer(Context: TObject; TimerId: Integer); virtual;

    { An external classic script to fetch (Url is absolute); when it is
      there the environment calls Context.ExecuteClassicScript (after
      the parser-blocking or deferred ordering the mode says), or
      Context.ScriptFetchFailed. }
    procedure FetchClassicScript(Context: TObject; Element: TElement; const Url, Charset: string;
      Mode: TScriptFetchMode); virtual;

    { Location and history. }
    function LocationHref(Context: TObject): string; virtual;
    procedure Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean); virtual;
    procedure Reload(Context: TObject); virtual;
    function HistoryLength(Context: TObject): Integer; virtual;
    procedure HistoryGo(Context: TObject; Delta: Integer); virtual;
    { pushState/replaceState: the URL (absolute) becomes the document's;
      the state stays with the context. }
    procedure HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean); virtual;

    { User prompts. }
    procedure Alert(Context: TObject; const Message: string); virtual;
    function Confirm(Context: TObject; const Message: string): Boolean; virtual;
    function Prompt(Context: TObject; const Message, Default: string; out Answer: string): Boolean; virtual;

    { The viewport, in CSS pixels, and the device pixel ratio. }
    function ViewportWidth: Integer; virtual;
    function ViewportHeight: Integer; virtual;
    function DevicePixelRatio: Double; virtual;

    { document.cookie for the document's URL. }
    function GetCookies(Context: TObject; const Url: string): string; virtual;
    procedure SetCookie(Context: TObject; const Url, Cookie: string); virtual;

    function UserAgent: string; virtual;
    function Language: string; virtual;
  end;

procedure RaiseUnsupported(const What: string);

implementation

procedure RaiseUnsupported(const What: string);
begin
  raise EScriptEnvironmentUnsupported.Create(What + ' is not available here');
end;

function TScriptEnvironment.SupportsTimers: Boolean;
begin
  Result := False;
end;

procedure TScriptEnvironment.StartTimer(Context: TObject; TimerId: Integer; Milliseconds: Integer;
  Repeating: Boolean);
begin
  RaiseUnsupported('timers');
end;

procedure TScriptEnvironment.StopTimer(Context: TObject; TimerId: Integer);
begin
end;

procedure TScriptEnvironment.FetchClassicScript(Context: TObject; Element: TElement; const Url, Charset: string;
  Mode: TScriptFetchMode);
begin
  RaiseUnsupported('fetching scripts');
end;

function TScriptEnvironment.LocationHref(Context: TObject): string;
begin
  Result := '';
end;

procedure TScriptEnvironment.Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean);
begin
  RaiseUnsupported('navigation');
end;

procedure TScriptEnvironment.Reload(Context: TObject);
begin
  RaiseUnsupported('navigation');
end;

function TScriptEnvironment.HistoryLength(Context: TObject): Integer;
begin
  Result := 1;
end;

procedure TScriptEnvironment.HistoryGo(Context: TObject; Delta: Integer);
begin
  RaiseUnsupported('session history');
end;

procedure TScriptEnvironment.HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean);
begin
  RaiseUnsupported('session history');
end;

procedure TScriptEnvironment.Alert(Context: TObject; const Message: string);
begin
end;

function TScriptEnvironment.Confirm(Context: TObject; const Message: string): Boolean;
begin
  Result := False;
end;

function TScriptEnvironment.Prompt(Context: TObject; const Message, Default: string; out Answer: string): Boolean;
begin
  Answer := '';
  Result := False;
end;

function TScriptEnvironment.ViewportWidth: Integer;
begin
  Result := 0;
end;

function TScriptEnvironment.ViewportHeight: Integer;
begin
  Result := 0;
end;

function TScriptEnvironment.DevicePixelRatio: Double;
begin
  Result := 1;
end;

function TScriptEnvironment.GetCookies(Context: TObject; const Url: string): string;
begin
  Result := '';
end;

procedure TScriptEnvironment.SetCookie(Context: TObject; const Url, Cookie: string);
begin
end;

function TScriptEnvironment.UserAgent: string;
begin
  Result := 'Mozilla/5.0 (FreePascalOS) libweb';
end;

function TScriptEnvironment.Language: string;
begin
  Result := 'en-US';
end;

end.
