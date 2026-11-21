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
  Css.MediaQueries,
  Web.Dom,
  Web.Storage;

type
  EScriptEnvironmentUnsupported = class(Exception);

  { How a classic script waits (the HTML Standard's script preparation):
    ParserBlocking stops the parser until it ran (the context's parser
    host has paused it); Deferred runs after parsing, in order; InOrder
    is a script-inserted one with async=false; Async runs when it is
    there. }
  TScriptFetchMode = (ScriptFetchParserBlocking, ScriptFetchDeferred, ScriptFetchInOrder, ScriptFetchAsync);

  { Navigation Timing's moments of the current document, as
    GetTickCount64 milliseconds (0: not yet, or unknown). }
  TScriptNavigationTiming = record
    { 'navigate', 'reload' or 'back_forward'. }
    Kind: string;
    RedirectCount: Integer;
    NavigationStart, FetchStart, RequestStart, ResponseStart, ResponseEnd: QWord;
    DomInteractive, DomContentLoadedEventStart, DomContentLoadedEventEnd, DomComplete: QWord;
    LoadEventStart, LoadEventEnd: QWord;
    { 'http/1.1', 'h2', 'h3' or ''. }
    NextHopProtocol: string;
    TransferSize, EncodedBodySize, DecodedBodySize: Int64;
    ResponseStatus: Integer;
  end;

  TScriptFetchHeader = record
    Name: string;
    Value: string;
  end;
  TScriptFetchHeaders = array of TScriptFetchHeader;

  { A fetch() or XMLHttpRequest request (Fetch Standard 5.4: the
    enumerations as their IDL strings). }
  TScriptFetchRequest = record
    Method: string;
    Url: string;
    Headers: TScriptFetchHeaders;
    Body: TBytes;
    HasBody: Boolean;
    { 'same-origin', 'no-cors' or 'cors'. }
    Mode: string;
    { 'omit', 'same-origin' or 'include'. }
    Credentials: string;
    Cache: string;
    { 'follow', 'error' or 'manual'. }
    Redirect: string;
    { 'about:client', 'no-referrer' or a URL. }
    Referrer: string;
    ReferrerPolicy: string;
    Priority: string;
    Destination: string;
    Integrity: string;
    Keepalive: Boolean;
  end;

  { Where a script fetch's results go, on the page thread and never from
    inside StartFetch: ResponseArrived once (unless the fetch fails
    first), DataArrived per piece of the body, then Finished once. }
  TScriptFetchSink = class
  public
    { ResponseType: 'basic', 'cors' or 'opaque' (status 0 and no
      headers then); Headers are the ones script may read. }
    procedure ResponseArrived(Status: Integer; const StatusText, Url, ResponseType: string; Redirected: Boolean;
      const Headers: TScriptFetchHeaders); virtual; abstract;
    procedure DataArrived(Data: Pointer; Count: PtrUInt); virtual; abstract;
    procedure Finished(Success: Boolean; const ErrorText: string); virtual; abstract;
  end;

  { What script asks of the layout (CSSOM View, getComputedStyle), in
    CSS pixels; whoever lays the document out answers (the web view),
    bringing its layout up to date first. Positions are in the
    document's coordinates (the initial containing block's origin). }
  TScriptLayout = class
  public
    { The border box of Element (the union of its fragments); False when
      it has no box. }
    function BorderBox(Element: TElement; out X, Y, Width, Height: Double): Boolean; virtual; abstract;
    { The border widths (clientLeft, clientTop), the padding box's size
      less scroll bars (clientWidth, clientHeight), the scrollable
      overflow's size and the scroll offset. }
    function ScrollGeometry(Element: TElement; out ClientLeft, ClientTop, ClientWidth, ClientHeight, ScrollWidth,
      ScrollHeight, ScrollLeft, ScrollTop: Double): Boolean; virtual; abstract;
    { Element nil: the viewport. }
    procedure ScrollTo(Element: TElement; Left, Top: Double); virtual; abstract;
    procedure ViewportScroll(out Left, Top: Double); virtual; abstract;
    { The topmost element at a point of the viewport, nil if none. }
    function ElementAtPoint(X, Y: Double): TElement; virtual; abstract;
    { The computed value of a property ('' when the element is not
      rendered and has no style). }
    function ComputedValue(Element: TElement; const PropertyName: string): string; virtual; abstract;
  end;

  TScriptEnvironment = class
  public
    { The layout's answers (nil: elements have no boxes). }
    Layout: TScriptLayout;
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

    { performance.timing and the navigation entry (all zero: unknown). }
    function NavigationTiming(Context: TObject): TScriptNavigationTiming; virtual;
    { Web Storage: the context's local or session storage area for its
      origin, nil when it has none (storage is then a SecurityError).
      StorageChanged follows a change (a local area is saved soon). }
    function StorageArea(Context: TObject; Session: Boolean): TWebStorageArea; virtual;
    procedure StorageChanged(Context: TObject; Area: TWebStorageArea); virtual;
    { What media queries see (matchMedia); by default a screen of the
      viewport's size. }
    function MediaEnvironment: TCssMediaEnvironment; virtual;
    { The screen in CSS pixels (by default the viewport). }
    function ScreenWidth: Integer; virtual;
    function ScreenHeight: Integer; virtual;
    { requestAnimationFrame: True when the environment will call
      Context.RunAnimationFrames at its next rendering opportunity; False
      lets the window use a 16 ms timer. }
    function RequestAnimationFrame(Context: TObject): Boolean; virtual;
    { navigator.sendBeacon: a POST that outlives the page (Body may be
      empty, ContentType '' for none). }
    procedure SendBeacon(Context: TObject; const Url: string; const Body: TBytes; const ContentType: string); virtual;
    { fetch() and XMLHttpRequest: starts Request for the context's
      document and returns a handle for CancelFetch, or nil when the
      environment cannot fetch (the script sees a network error). }
    function StartFetch(Context: TObject; const Request: TScriptFetchRequest; Sink: TScriptFetchSink): TObject; virtual;
    { No more calls to the sink of Handle. }
    procedure CancelFetch(Context: TObject; Handle: TObject); virtual;
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

function TScriptEnvironment.NavigationTiming(Context: TObject): TScriptNavigationTiming;
begin
  Result := Default(TScriptNavigationTiming);
  Result.Kind := 'navigate';
end;

function TScriptEnvironment.StorageArea(Context: TObject; Session: Boolean): TWebStorageArea;
begin
  Result := nil;
end;

procedure TScriptEnvironment.StorageChanged(Context: TObject; Area: TWebStorageArea);
begin
end;

function TScriptEnvironment.MediaEnvironment: TCssMediaEnvironment;
begin
  Result := DefaultMediaEnvironment;
  if ViewportWidth > 0 then
  begin
    Result.Width := ViewportWidth;
    Result.Height := ViewportHeight;
  end;
  Result.Resolution := DevicePixelRatio;
end;

function TScriptEnvironment.ScreenWidth: Integer;
begin
  Result := ViewportWidth;
end;

function TScriptEnvironment.ScreenHeight: Integer;
begin
  Result := ViewportHeight;
end;

function TScriptEnvironment.RequestAnimationFrame(Context: TObject): Boolean;
begin
  Result := False;
end;

procedure TScriptEnvironment.SendBeacon(Context: TObject; const Url: string; const Body: TBytes;
  const ContentType: string);
begin
end;

function TScriptEnvironment.StartFetch(Context: TObject; const Request: TScriptFetchRequest;
  Sink: TScriptFetchSink): TObject;
begin
  Result := nil;
end;

procedure TScriptEnvironment.CancelFetch(Context: TObject; Handle: TObject);
begin
end;

end.
