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
  Scripting for a page: the loader's script executor
  (Web.Loading.Scripts) and the bindings' environment
  (Web.ScriptEnvironment) over a navigable and its event loop.

    Executor := TPageScriptExecutor.Create(Page.Navigable);
    Page.Navigable.Executor := Executor;   // scripting on from the next document

  - Each document a loader starts gets a TScriptContext (its global and
    DOM wrappers) whose window is the loader's TWebWindow, so the
    loader's events (DOMContentLoaded, load, pageshow) and the script's
    listeners and handlers meet; it goes with the loader. document.
    readyState is the document's.
  - The loader prepares, fetches and orders script elements (parser-
    blocking, deferred, async, script-inserted in order) and hands each
    to ExecuteScript, which runs it in the document's context
    (document.currentScript, errors to the console, the microtask
    checkpoint); the context does not prepare scripts itself. While a
    parser-inserted script runs, document.write goes to the loader's
    parser.
  - After every task of the loop the contexts' microtasks run.
  - The environment: timers as the loop's delayed tasks (grouped by
    context, so they stop with its document); location, navigation and
    history through the navigable (pushState and replaceState change
    the entry's URL); prompts through events the web view answers; the
    viewport and pixel ratio from the resource sink's media environment;
    document.cookie through the network context's jar (HttpOnly
    cookies neither read nor written); the user agent and language.
}
unit Web.Script.PageScripting;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Css.MediaQueries,
  Web.Dom,
  Web.EventLoop,
  Web.Storage,
  Web.ScriptEnvironment,
  Web.Script.PageFetch,
  Web.Script.PageSockets,
  Web.Script.Layout,
  Web.Script.ImportMaps,
  Js.Engine,
  Web.Bindings.Context,
  Web.Script.Context,
  Web.Loading.Scripts,
  Web.Navigation.Navigables;

type
  TScriptAlertEvent = procedure(const Message: string) of object;
  { window.open (Url absolute): True when the host opened something. }
  TScriptOpenWindowEvent = function(const Url, Target, Features: string): Boolean of object;
  TScriptConfirmEvent = function(const Message: string): Boolean of object;
  TScriptPromptEvent = function(const Message, Default: string; out Answer: string): Boolean of object;
  TScriptConsoleEvent = procedure(const Level, Text: string) of object;

  TPageScriptExecutor = class;

  TPageScriptEnvironment = class(TScriptEnvironment)
  private
    FExecutor: TPageScriptExecutor;
    FTimers: TList;
    FPendingTraversal: Integer;
    FUserAgent: string;
    FLocalStorage: TWebStorageRegistry;
    FOwnsLocalStorage: Boolean;
    FSessionStorage: TWebStorageRegistry;
    FSaveScheduled: Boolean;
    FSaveTask: QWord;
    FFetches: TScriptFetches;
    FSockets: TScriptWebSockets;
    FScreenWidth: Integer;
    FScreenHeight: Integer;
    function FindTimer(Context: TObject; TimerId: Integer): Integer;
    function LoaderOf(Context: TObject): TObject;
    procedure SetLocalStorage(Value: TWebStorageRegistry);
    procedure TraverseTask;
    procedure ReloadTask;
  public
    constructor Create(Executor: TPageScriptExecutor);
    destructor Destroy; override;
    { The timers of a context that stopped. }
    procedure ForgetContext(Context: TObject);
    procedure ForgetTimers;
    procedure TimerDue(Context: TObject; TimerId, Milliseconds: Integer; Repeating: Boolean);
    function ManagesFrames: Boolean; override;
    function SupportsTimers: Boolean; override;
    procedure StartTimer(Context: TObject; TimerId: Integer; Milliseconds: Integer; Repeating: Boolean); override;
    procedure StopTimer(Context: TObject; TimerId: Integer); override;
    function LocationHref(Context: TObject): string; override;
    procedure Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean); override;
    procedure Reload(Context: TObject); override;
    function HistoryLength(Context: TObject): Integer; override;
    procedure HistoryGo(Context: TObject; Delta: Integer); override;
    procedure HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean); override;
    procedure Alert(Context: TObject; const Message: string); override;
    function OpenWindow(Context: TObject; const Url, Target, Features: string): Boolean; override;
    function Confirm(Context: TObject; const Message: string): Boolean; override;
    function Prompt(Context: TObject; const Message, Default: string; out Answer: string): Boolean; override;
    function ViewportWidth: Integer; override;
    function ViewportHeight: Integer; override;
    function DevicePixelRatio: Double; override;
    function GetCookies(Context: TObject; const Url: string): string; override;
    procedure SetCookie(Context: TObject; const Url, Cookie: string); override;
    function UserAgent: string; override;
    function Language: string; override;
    function NavigationTiming(Context: TObject): TScriptNavigationTiming; override;
    function StorageArea(Context: TObject; Session: Boolean): TWebStorageArea; override;
    procedure StorageChanged(Context: TObject; Area: TWebStorageArea); override;
    function MediaEnvironment: TCssMediaEnvironment; override;
    function ScreenWidth: Integer; override;
    function ScreenHeight: Integer; override;
    function RequestAnimationFrame(Context: TObject): Boolean; override;
    procedure SendBeacon(Context: TObject; const Url: string; const Body: TBytes; const ContentType: string); override;
    function StartFetch(Context: TObject; const Request: TScriptFetchRequest; Sink: TScriptFetchSink): TObject;
      override;
    procedure CancelFetch(Context: TObject; Handle: TObject); override;
    function SupportsWebSockets: Boolean; override;
    function OpenWebSocket(Context: TObject; const Url: string; const Protocols: TStringArray;
      Sink: TScriptWebSocketSink): TObject; override;
    procedure SendWebSocket(Context: TObject; Handle: TObject; IsText: Boolean; const Data: TBytes); override;
    procedure CloseWebSocket(Context: TObject; Handle: TObject; Code: Word; const Reason: string); override;
    procedure ForgetWebSocket(Context: TObject; Handle: TObject); override;
    { Writes the local storage that changed. }
    procedure SaveStorage;
    property UserAgentText: string read FUserAgent write FUserAgent;
    { Where localStorage lives (the host's, shared by its pages; the page
      keeps one in memory when none is set). }
    property LocalStorage: TWebStorageRegistry read FLocalStorage write SetLocalStorage;
    { The screen in CSS pixels (0: the viewport's size). }
    property ScreenWidthValue: Integer read FScreenWidth write FScreenWidth;
    property ScreenHeightValue: Integer read FScreenHeight write FScreenHeight;
  end;

  { A context's module graph: specifiers resolved against the
    importing module's URL, module sources fetched through the loader
    (CORS, UTF-8). }
  TContextModules = class
  private
    FContext: TScriptContext;
    FLoader: TObject;
    FInlineCount: Integer;
    FImportMap: TImportMap;
    function Resolve(const Specifier, ReferrerKey: string; out Key: string): Boolean;
    procedure Fetch(Request: TJsModuleFetch);
    procedure FetchDone(const Source: string; Success: Boolean; Data: TObject);
  public
    Stopped: Boolean;
    constructor Create(Context: TScriptContext; Loader: TObject);
    destructor Destroy; override;
    { Merges an import map's JSON into the document's. }
    procedure AddImportMap(const Source: string);
    { Runs a module script (Url '' for an inline one). }
    procedure Run(const Source, Url: string);
  end;

  TPageContextRecord = record
    Loader: TObject;
    Context: TScriptContext;
    Modules: TContextModules;
    Stopped: Boolean;
  end;

  TPageScriptExecutor = class(TScriptExecutor)
  private
    FNavigable: TNavigable;
    FLoop: TEventLoop;
    FEnvironment: TPageScriptEnvironment;
    FContexts: array of TPageContextRecord;
    FOnAlert: TScriptAlertEvent;
    FOnOpenWindow: TScriptOpenWindowEvent;
    FOnConfirm: TScriptConfirmEvent;
    FOnPrompt: TScriptPromptEvent;
    FOnConsoleMessage: TScriptConsoleEvent;
    function IndexOfLoader(Loader: TObject): Integer;
    { Drops the records of the frames' windows inside Context (they go
      with it). }
    procedure ForgetFramesOf(Context: TBindingContext);
    procedure MicrotaskCheckpoint(Sender: TObject);
    procedure ConsoleMessage(const Level, Text: string);
  public
    constructor Create(Navigable: TNavigable);
    destructor Destroy; override;
    { The page (and its loop) is about to go: tasks and the loop's hook
      are dropped; contexts still go with their loaders. }
    procedure Shutdown;
    function SupportsModules: Boolean; override;
    procedure ExecuteScript(Script: TPendingScript); override;
    procedure DocumentStarted(Loader: TObject); override;
    procedure DocumentTimed(Loader: TObject); override;
    procedure DocumentStopped(Loader: TObject); override;
    procedure DocumentFreed(Loader: TObject); override;
    { The live context of Document, nil if none. }
    function ContextOf(Document: TDocument): TScriptContext;
    function IsLiveContext(Context: TObject): Boolean;
    property Navigable: TNavigable read FNavigable;
    property Environment: TPageScriptEnvironment read FEnvironment;
    property OnAlert: TScriptAlertEvent read FOnAlert write FOnAlert;
    property OnOpenWindow: TScriptOpenWindowEvent read FOnOpenWindow write FOnOpenWindow;
    property OnConfirm: TScriptConfirmEvent read FOnConfirm write FOnConfirm;
    property OnPrompt: TScriptPromptEvent read FOnPrompt write FOnPrompt;
    property OnConsoleMessage: TScriptConsoleEvent read FOnConsoleMessage write FOnConsoleMessage;
  end;

const
{$ifdef CPUAARCH64}
  DefaultScriptUserAgent = 'Mozilla/5.0 (X11; FreePascalOS aarch64) AppleWebKit/537.36 (KHTML, like Gecko) libweb/1.0 ' +
    'Safari/537.36';
{$else}
  DefaultScriptUserAgent = 'Mozilla/5.0 (X11; FreePascalOS x86_64) AppleWebKit/537.36 (KHTML, like Gecko) libweb/1.0 ' +
    'Safari/537.36';
{$endif}

implementation

uses
  Web.Profiling,
  DateUtils,
  Js.Values,
  Web.EventLoop.AnimationFrames,
  Web.Navigation.Windows,
  Web.Script.Frames,
  Web.Script.FrameNavigables,
  Web.Bindings.CrossOrigin,
  Url.Records,
  Url.Parser,
  Url.Origins,
  Http.Cookies,
  Web.EventLoop.Tasks,
  Web.Origins,
  Web.Loading.Documents;

type
  TScriptTimerRecord = class
  public
    Context: TObject;
    TimerId: Integer;
    Handle: QWord;
  end;

  TScriptTimerTask = class(TWebTask)
  public
    Environment: TPageScriptEnvironment;
    Context: TObject;
    TimerId: Integer;
    Milliseconds: Integer;
    Repeating: Boolean;
    procedure Run; override;
  end;

procedure TScriptTimerTask.Run;
begin
  Environment.TimerDue(Context, TimerId, Milliseconds, Repeating);
end;

function UnixTimeNow: Int64;
begin
  Result := DateTimeToUnix(LocalTimeToUniversal(Now));
end;

{ ---- the environment ---- }

constructor TPageScriptEnvironment.Create(Executor: TPageScriptExecutor);
begin
  inherited Create;
  FExecutor := Executor;
  FTimers := TList.Create;
  FUserAgent := DefaultScriptUserAgent;
  FSessionStorage := TWebStorageRegistry.Create('');
  FFetches := TScriptFetches.Create;
end;

destructor TPageScriptEnvironment.Destroy;
begin
  ForgetTimers;
  FTimers.Free;
  FFetches.Free;
  FSockets.Free;
  SaveStorage;
  if FOwnsLocalStorage then
    FLocalStorage.Free;
  FSessionStorage.Free;
  inherited Destroy;
end;

function TPageScriptEnvironment.FindTimer(Context: TObject; TimerId: Integer): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FTimers.Count - 1 do
    if (TScriptTimerRecord(FTimers[Index]).Context = Context) and (TScriptTimerRecord(FTimers[Index]).TimerId = TimerId) then
      Exit(Index);
  Result := -1;
end;

procedure TPageScriptEnvironment.ForgetContext(Context: TObject);
var
  Index: Integer;
begin
  for Index := FTimers.Count - 1 downto 0 do
    if TScriptTimerRecord(FTimers[Index]).Context = Context then
    begin
      TScriptTimerRecord(FTimers[Index]).Free;
      FTimers.Delete(Index);
    end;
  if FExecutor.FLoop <> nil then
    FExecutor.FLoop.DiscardTasks(Context);
end;

procedure TPageScriptEnvironment.ForgetTimers;
var
  Index: Integer;
begin
  for Index := 0 to FTimers.Count - 1 do
  begin
    if FExecutor.FLoop <> nil then
      FExecutor.FLoop.CancelScheduledTask(TScriptTimerRecord(FTimers[Index]).Handle);
    TScriptTimerRecord(FTimers[Index]).Free;
  end;
  FTimers.Clear;
  if FExecutor.FLoop <> nil then
    FExecutor.FLoop.DiscardTasks(Self);
end;

function TPageScriptEnvironment.ManagesFrames: Boolean;
begin
  Result := True;
end;

function TPageScriptEnvironment.SupportsTimers: Boolean;
begin
  Result := True;
end;

procedure TPageScriptEnvironment.StartTimer(Context: TObject; TimerId: Integer; Milliseconds: Integer; Repeating: Boolean);
var
  Task: TScriptTimerTask;
  Timer: TScriptTimerRecord;
  Index: Integer;
begin
  Index := FindTimer(Context, TimerId);
  if Index >= 0 then
    StopTimer(Context, TimerId);
  if not FExecutor.IsLiveContext(Context) or (FExecutor.FLoop = nil) then
    Exit;
  Task := TScriptTimerTask.Create;
  Task.Environment := Self;
  Task.Context := Context;
  Task.TimerId := TimerId;
  Task.Milliseconds := Milliseconds;
  Task.Repeating := Repeating;
  Task.Source := TaskSourceTimer;
  Task.Group := Context;
  Timer := TScriptTimerRecord.Create;
  Timer.Context := Context;
  Timer.TimerId := TimerId;
  Timer.Handle := FExecutor.FLoop.ScheduleTask(Task, Milliseconds);
  FTimers.Add(Timer);
end;

procedure TPageScriptEnvironment.StopTimer(Context: TObject; TimerId: Integer);
var
  Index: Integer;
begin
  Index := FindTimer(Context, TimerId);
  if Index < 0 then
    Exit;
  if FExecutor.FLoop <> nil then
    FExecutor.FLoop.CancelScheduledTask(TScriptTimerRecord(FTimers[Index]).Handle);
  TScriptTimerRecord(FTimers[Index]).Free;
  FTimers.Delete(Index);
end;

procedure TPageScriptEnvironment.TimerDue(Context: TObject; TimerId, Milliseconds: Integer; Repeating: Boolean);
var
  Index: Integer;
begin
  Index := FindTimer(Context, TimerId);
  if Index < 0 then
    Exit;
  TScriptTimerRecord(FTimers[Index]).Free;
  FTimers.Delete(Index);
  if not FExecutor.IsLiveContext(Context) then
    Exit;
  { An interval comes again (the handler may clear it). }
  if Repeating then
    StartTimer(Context, TimerId, Milliseconds, True);
  TScriptContext(Context).FireTimer(TimerId);
end;

function TPageScriptEnvironment.LocationHref(Context: TObject): string;
begin
  Result := FExecutor.FNavigable.CurrentUrlText;
end;

procedure TPageScriptEnvironment.Navigate(Context: TObject; const Url: string; ReplaceEntry: Boolean);
var
  Target: TUrlRecord;
  Options: TNavigateOptions;
begin
  if not ParseUrl(Url, Target) or (Target.Scheme = 'javascript') then
    Exit;
  Options := DefaultNavigateOptions;
  Options.Replace := ReplaceEntry;
  Options.Source := FExecutor.FNavigable.Loader;
  FExecutor.FNavigable.Navigate(Target, Options);
end;

procedure TPageScriptEnvironment.ReloadTask;
begin
  FExecutor.FNavigable.Reload;
end;

procedure TPageScriptEnvironment.Reload(Context: TObject);
begin
  if FExecutor.FLoop <> nil then
    FExecutor.FLoop.QueueMethod(@ReloadTask, TaskSourceNavigation, Self);
end;

function TPageScriptEnvironment.HistoryLength(Context: TObject): Integer;
begin
  Result := FExecutor.FNavigable.History.Count;
end;

procedure TPageScriptEnvironment.TraverseTask;
var
  Delta: Integer;
begin
  Delta := FPendingTraversal;
  FPendingTraversal := 0;
  if Delta = 0 then
    FExecutor.FNavigable.Reload
  else
    FExecutor.FNavigable.Traverse(Delta);
end;

procedure TPageScriptEnvironment.HistoryGo(Context: TObject; Delta: Integer);
begin
  FPendingTraversal := Delta;
  if FExecutor.FLoop <> nil then
    FExecutor.FLoop.QueueMethod(@TraverseTask, TaskSourceHistoryTraversal, Self);
end;

procedure TPageScriptEnvironment.HistoryChangeUrl(Context: TObject; const Url: string; ReplaceEntry: Boolean);
var
  Target: TUrlRecord;
begin
  if ParseUrl(Url, Target) then
    FExecutor.FNavigable.ChangeUrlFromScript(Target, ReplaceEntry);
end;

function TPageScriptEnvironment.OpenWindow(Context: TObject; const Url, Target, Features: string): Boolean;
begin
  Result := Assigned(FExecutor.FOnOpenWindow) and FExecutor.FOnOpenWindow(Url, Target, Features);
end;

procedure TPageScriptEnvironment.Alert(Context: TObject; const Message: string);
begin
  if Assigned(FExecutor.FOnAlert) then
    FExecutor.FOnAlert(Message);
end;

function TPageScriptEnvironment.Confirm(Context: TObject; const Message: string): Boolean;
begin
  Result := Assigned(FExecutor.FOnConfirm) and FExecutor.FOnConfirm(Message);
end;

function TPageScriptEnvironment.Prompt(Context: TObject; const Message, Default: string; out Answer: string): Boolean;
begin
  Answer := '';
  Result := Assigned(FExecutor.FOnPrompt) and FExecutor.FOnPrompt(Message, Default, Answer);
end;

function TPageScriptEnvironment.ViewportWidth: Integer;
begin
  Result := Round(FExecutor.FNavigable.Sink.MediaEnvironment.Width);
end;

function TPageScriptEnvironment.ViewportHeight: Integer;
begin
  Result := Round(FExecutor.FNavigable.Sink.MediaEnvironment.Height);
end;

function TPageScriptEnvironment.DevicePixelRatio: Double;
begin
  Result := FExecutor.FNavigable.Sink.MediaEnvironment.Resolution;
  if Result <= 0 then
    Result := 1;
end;

function ScriptCookieContext(constref Url: TUrlRecord): TCookieRequestContext;
begin
  Result := Default(TCookieRequestContext);
  Result.IsSecure := (Url.Scheme = 'https') or (Url.Scheme = 'wss');
  Result.SameSite := True;
  Result.SafeMethod := True;
  Result.HttpApi := False;
end;

function TPageScriptEnvironment.GetCookies(Context: TObject; const Url: string): string;
var
  Target: TUrlRecord;
begin
  Result := '';
  if not ParseUrl(Url, Target) then
    Exit;
  if (Target.Scheme <> 'http') and (Target.Scheme <> 'https') then
    Exit;
  Result := FExecutor.FNavigable.Fetcher.Network.DocumentCookie(Target, ScriptCookieContext(Target).IsSecure);
end;

procedure TPageScriptEnvironment.SetCookie(Context: TObject; const Url, Cookie: string);
var
  Target: TUrlRecord;
begin
  if not ParseUrl(Url, Target) then
    Exit;
  if (Target.Scheme <> 'http') and (Target.Scheme <> 'https') then
    Exit;
  FExecutor.FNavigable.Fetcher.Network.SetDocumentCookie(Target, Cookie, ScriptCookieContext(Target).IsSecure);
end;

function TPageScriptEnvironment.UserAgent: string;
begin
  Result := FUserAgent;
end;

function TPageScriptEnvironment.Language: string;
var
  Text: string;
  Stop: Integer;
begin
  Text := FExecutor.FNavigable.Fetcher.Network.AcceptLanguage;
  Stop := Pos(',', Text);
  if Stop > 0 then
    Text := Copy(Text, 1, Stop - 1);
  Stop := Pos(';', Text);
  if Stop > 0 then
    Text := Copy(Text, 1, Stop - 1);
  Result := Trim(Text);
  if Result = '' then
    Result := 'en-US';
end;

{$I Web.Script.PageServices.inc}

{ ---- modules ---- }

type
  TModuleFetchRequest = class
  public
    Request: TJsModuleFetch;
  end;

constructor TContextModules.Create(Context: TScriptContext; Loader: TObject);
begin
  inherited Create;
  FContext := Context;
  FLoader := Loader;
  FContext.Engine.ModuleResolver := @Resolve;
  FContext.Engine.ModuleFetcher := @Fetch;
  FImportMap := TImportMap.Create;
end;

destructor TContextModules.Destroy;
begin
  FImportMap.Free;
  inherited Destroy;
end;

const
  { The map's entries as text: scope (empty for "imports"), key and
    value (#2 when not a string), separated by #1, entries by #3; "!"
    and the message when it is not JSON. }
  FlattenImportMapSource =
    '(function (text) { var map; try { map = JSON.parse(text); } catch (e) { return "!" + e.message; }' +
    ' var out = [], own = Object.prototype.hasOwnProperty;' +
    ' function add(scope, table) { if (table === null || typeof table !== "object") return;' +
    '  for (var key in table) if (own.call(table, key))' +
    '   out.push(scope + "" + key + "" + (typeof table[key] === "string" ? table[key] : "")); }' +
    ' if (map === null || typeof map !== "object") return "!the import map is not an object";' +
    ' add("", map.imports);' +
    ' if (map.scopes !== null && typeof map.scopes === "object")' +
    '  for (var scope in map.scopes) if (own.call(map.scopes, scope)) add(scope, map.scopes[scope]);' +
    ' return out.join(""); })';

procedure TContextModules.AddImportMap(const Source: string);
var
  Flatten, Value: TJsValue;
  Text: string;
  Entries, Parts: TStringArray;
  Index: Integer;
  Base: TUrlRecord;
begin
  Base := TDocumentLoader(FLoader).BaseUrl;
  try
    Flatten := FContext.Engine.EvaluateBuiltin(FlattenImportMapSource, 'importmap');
    Value := FContext.Engine.Call(Flatten, JsUndefined, [FContext.Engine.NewString(Source)]);
    Text := FContext.Engine.ToText(Value);
  except
    on Error: EJsError do
    begin
      FContext.Console('error', 'Uncaught ' + Error.Message);
      Exit;
    end;
  end;
  if Copy(Text, 1, 1) = '!' then
  begin
    FContext.Console('error', 'Uncaught SyntaxError: import map: ' + Copy(Text, 2, MaxInt));
    Exit;
  end;
  if Text = '' then
    Exit;
  Entries := Text.Split([#3]);
  for Index := 0 to High(Entries) do
  begin
    Parts := Entries[Index].Split([#1]);
    if Length(Parts) = 3 then
      FImportMap.AddEntry(Parts[0], Parts[1], Parts[2], Parts[2] <> #2, Base);
  end;
end;

function TContextModules.Resolve(const Specifier, ReferrerKey: string; out Key: string): Boolean;
var
  Base, Target: TUrlRecord;
  Referrer: string;
begin
  Key := '';
  if (ReferrerKey = '') or not ParseUrl(ReferrerKey, Base) then
    Base := TDocumentLoader(FLoader).BaseUrl;
  if not FImportMap.IsEmpty then
  begin
    { An inline module is the document's for the map's scopes. }
    Referrer := ReferrerKey;
    if Pos('#module', Referrer) > 0 then
      Referrer := Copy(Referrer, 1, Pos('#module', Referrer) - 1);
    if Referrer = '' then
      Referrer := SerializeUrl(TDocumentLoader(FLoader).BaseUrl);
    Result := FImportMap.Resolve(Specifier, Referrer, Base, Key) = ImportResolved;
    Exit;
  end;
  { Without an import map a bare specifier resolves only as a URL. }
  Result := ParseUrlLike(Specifier, Base, Target);
  if Result then
    Key := SerializeUrl(Target);
end;

procedure TContextModules.Fetch(Request: TJsModuleFetch);
var
  Target: TUrlRecord;
  Pending: TModuleFetchRequest;
begin
  if Stopped or not ParseUrl(Request.Key, Target) then
  begin
    Request.Fail('cannot load ' + Request.Key);
    Exit;
  end;
  Pending := TModuleFetchRequest.Create;
  Pending.Request := Request;
  TDocumentLoader(FLoader).Scripts.FetchScript(Target, True, @FetchDone, Pending);
end;

procedure TContextModules.FetchDone(const Source: string; Success: Boolean; Data: TObject);
var
  Request: TJsModuleFetch;
begin
  Request := TModuleFetchRequest(Data).Request;
  Data.Free;
  if Success and not Stopped then
    Request.Succeed(Source)
  else
    Request.Fail('cannot load ' + Request.Key);
  if not Stopped then
    FContext.PerformMicrotaskCheckpoint;
end;

procedure TContextModules.Run(const Source, Url: string);
var
  Key: string;
begin
  Key := Url;
  if Key = '' then
  begin
    Inc(FInlineCount);
    Key := TDocumentLoader(FLoader).Document.Url + '#module' + IntToStr(FInlineCount);
  end;
  { EnterScript arms the slow script watchdog; LeaveScript runs the
    microtask checkpoint. }
  FContext.EnterScript;
  try
    SetPhaseDetail(Key);
    try
      FContext.Engine.EvaluateModule(Source, Key);
    except
      on Error: EJsError do
        FContext.Console('error', 'Uncaught ' + Error.Message);
    end;
  finally
    FContext.LeaveScript;
  end;
end;

{ ---- the executor ---- }

constructor TPageScriptExecutor.Create(Navigable: TNavigable);
begin
  inherited Create;
  FNavigable := Navigable;
  FLoop := Navigable.Loop;
  FEnvironment := TPageScriptEnvironment.Create(Self);
  FLoop.OnMicrotaskCheckpoint := @MicrotaskCheckpoint;
end;

destructor TPageScriptExecutor.Destroy;
var
  Index: Integer;
begin
  Shutdown;
  for Index := 0 to High(FContexts) do
  begin
    FEnvironment.ForgetContext(FContexts[Index].Context);
    FContexts[Index].Modules.Free;
  end;
  { Top-level contexts free their frames' windows. }
  for Index := 0 to High(FContexts) do
    if FContexts[Index].Context.ParentContext = nil then
      FContexts[Index].Context.Free;
  FContexts := nil;
  FEnvironment.Free;
  inherited Destroy;
end;

procedure TPageScriptExecutor.Shutdown;
var
  Index: Integer;
begin
  if FLoop = nil then
    Exit;
  for Index := 0 to High(FContexts) do
    FEnvironment.ForgetContext(FContexts[Index].Context);
  FEnvironment.ForgetTimers;
  if TMethod(FLoop.OnMicrotaskCheckpoint).Data = Pointer(Self) then
    FLoop.OnMicrotaskCheckpoint := nil;
  FLoop := nil;
end;

function TPageScriptExecutor.SupportsModules: Boolean;
begin
  Result := True;
end;

function TPageScriptExecutor.IndexOfLoader(Loader: TObject): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FContexts) do
    if FContexts[Index].Loader = Loader then
      Exit(Index);
  Result := -1;
end;

function TPageScriptExecutor.IsLiveContext(Context: TObject): Boolean;
var
  Index: Integer;
  Top: TObject;
begin
  Top := Context;
  for Index := 0 to High(FContexts) do
    if FContexts[Index].Context = Context then
      Exit(not FContexts[Index].Stopped);
  { A frame's window lives while it is open and its page does. }
  if (Context is TBindingContext) and not TBindingContext(Context).Closed then
    Top := TBindingContext(Context).TopContext;
  if Top = Context then
    Exit(False);
  for Index := 0 to High(FContexts) do
    if (FContexts[Index].Context = Top) and not FContexts[Index].Stopped then
      Exit(True);
  Result := False;
end;

function TPageScriptExecutor.ContextOf(Document: TDocument): TScriptContext;
var
  Index: Integer;
begin
  for Index := 0 to High(FContexts) do
    if (FContexts[Index].Context.Document = Document) and not FContexts[Index].Stopped then
      Exit(FContexts[Index].Context);
  Result := nil;
end;

procedure TPageScriptExecutor.ConsoleMessage(const Level, Text: string);
begin
  if Assigned(FOnConsoleMessage) then
    FOnConsoleMessage(Level, Text);
end;

procedure TPageScriptExecutor.DocumentStarted(Loader: TObject);
var
  DocumentLoader: TDocumentLoader;
  Context, ParentContext: TScriptContext;
  Child: TNavigable;
  FrameEnvironment: TNavigableFrameEnvironment;
begin
  if IndexOfLoader(Loader) >= 0 then
    Exit;
  DocumentLoader := TDocumentLoader(Loader);
  Child := nil;
  if (DocumentLoader.Window <> nil) and (DocumentLoader.Window.Navigable is TNavigable) and
     (TNavigable(DocumentLoader.Window.Navigable).Parent <> nil) then
    Child := TNavigable(DocumentLoader.Window.Navigable);
  if Child <> nil then
  begin
    { A frame's document: a realm in its parent's engine (objects pass
      between them), with the child navigable's window. }
    ParentContext := ContextOf(Child.Container.NodeDocument);
    FrameEnvironment := TNavigableFrameEnvironment.Create(FEnvironment, ParentContext, Child, DocumentLoader.Document);
    if ParentContext <> nil then
      Context := TScriptContext.CreateFrame(DocumentLoader.Document, FrameEnvironment, ParentContext, Child.Container,
        DocumentLoader.Window)
    else
      Context := TScriptContext.Create(DocumentLoader.Document, FrameEnvironment, DocumentLoader.Window);
    Context.OwnsEnvironment := True;
    if Child.FrameName <> '' then
      Context.SetSingleton(SingletonWindowName, Context.TextValue(Child.FrameName));
    if ParentContext <> nil then
      UpdateFrameIndices(ParentContext);
  end
  else
    Context := TScriptContext.Create(DocumentLoader.Document, FEnvironment, DocumentLoader.Window);
  Context.PreparesScripts := False;
  Context.ReadyStateFromDocument := True;
  Context.OnConsoleMessage := @ConsoleMessage;
  SetLength(FContexts, Length(FContexts) + 1);
  FContexts[High(FContexts)].Loader := Loader;
  FContexts[High(FContexts)].Context := Context;
  FContexts[High(FContexts)].Modules := TContextModules.Create(Context, Loader);
  FContexts[High(FContexts)].Stopped := False;
end;

procedure TPageScriptExecutor.DocumentTimed(Loader: TObject);
var
  Index: Integer;
begin
  Index := IndexOfLoader(Loader);
  if Index >= 0 then
    FContexts[Index].Context.SetTimeOrigin(TDocumentLoader(Loader).Times.NavigationStart);
end;

procedure TPageScriptExecutor.DocumentStopped(Loader: TObject);
var
  Index: Integer;
begin
  Index := IndexOfLoader(Loader);
  if (Index < 0) or FContexts[Index].Stopped then
    Exit;
  FEnvironment.FFetches.CancelLoader(TDocumentLoader(Loader));
  if FEnvironment.FSockets <> nil then
    FEnvironment.FSockets.CancelLoader(TDocumentLoader(Loader));
  FContexts[Index].Stopped := True;
  FContexts[Index].Modules.Stopped := True;
  FContexts[Index].Context.AttachParser(nil);
  FEnvironment.ForgetContext(FContexts[Index].Context);
  { A frame's window closes when its document is left (contentWindow is
      the next document's). }
  if FContexts[Index].Context.Environment is TNavigableFrameEnvironment then
    TNavigableFrameEnvironment(FContexts[Index].Context.Environment).Disconnect;
  if FContexts[Index].Context.ParentContext <> nil then
  begin
    FContexts[Index].Context.Close;
    UpdateFrameIndices(FContexts[Index].Context.ParentContext);
  end;
end;

procedure TPageScriptExecutor.ForgetFramesOf(Context: TBindingContext);
var
  Index: Integer;
  Walk: TBindingContext;
  Inside: Boolean;
begin
  Index := High(FContexts);
  while Index >= 0 do
  begin
    Walk := FContexts[Index].Context.ParentContext;
    Inside := False;
    while Walk <> nil do
    begin
      if Walk = Context then
      begin
        Inside := True;
        Break;
      end;
      Walk := Walk.ParentContext;
    end;
    if Inside then
    begin
      FEnvironment.ForgetContext(FContexts[Index].Context);
      FContexts[Index].Modules.Free;
      FContexts[Index] := FContexts[High(FContexts)];
      SetLength(FContexts, Length(FContexts) - 1);
      if Index > High(FContexts) then
        Index := High(FContexts);
      Continue;
    end;
    Dec(Index);
  end;
end;

procedure TPageScriptExecutor.DocumentFreed(Loader: TObject);
var
  Index: Integer;
  Context: TScriptContext;
begin
  Index := IndexOfLoader(Loader);
  if Index < 0 then
    Exit;
  Context := FContexts[Index].Context;
  FContexts[Index].Modules.Free;
  FContexts[Index] := FContexts[High(FContexts)];
  SetLength(FContexts, Length(FContexts) - 1);
  FEnvironment.ForgetContext(Context);
  { The frames' windows inside go with this context (their parent frees
    them, after its engine). }
  ForgetFramesOf(Context);
  if Context.ParentContext <> nil then
  begin
    { The loader's window goes now; the window lives on (its parent
      frees it). }
    Context.DetachWindow;
    Context.Close;
  end
  else
    Context.Free;
end;

procedure TPageScriptExecutor.ExecuteScript(Script: TPendingScript);
var
  Modules: TContextModules;
  Index: Integer;
  Context: TScriptContext;
  DocumentLoader: TDocumentLoader;
  Url: string;
begin
  Context := nil;
  DocumentLoader := nil;
  Modules := nil;
  for Index := 0 to High(FContexts) do
    if (FContexts[Index].Context.Document = Script.Element.NodeDocument) and not FContexts[Index].Stopped then
    begin
      Context := FContexts[Index].Context;
      DocumentLoader := TDocumentLoader(FContexts[Index].Loader);
      Modules := FContexts[Index].Modules;
    end;
  if Context = nil then
    Exit;
  if Script.External then
    Url := SerializeUrl(Script.Url)
  else
    Url := '';
  if Script.Kind = ScriptModule then
  begin
    Modules.Run(Script.Source, Url);
    Exit;
  end;
  if Script.Kind = ScriptImportMap then
  begin
    Modules.AddImportMap(Script.Source);
    Exit;
  end;
  if Script.Kind <> ScriptClassic then
    Exit;
  if not DocumentLoader.ParsingDone then
    Context.AttachParser(DocumentLoader.Parser);
  try
    Context.ExecuteClassicScript(Script.Source, Url, Script.Element, False);
  finally
    Context.AttachParser(nil);
  end;
end;

procedure TPageScriptExecutor.MicrotaskCheckpoint(Sender: TObject);
var
  Index: Integer;
begin
  for Index := 0 to High(FContexts) do
    if not FContexts[Index].Stopped then
      FContexts[Index].Context.PerformMicrotaskCheckpoint;
end;

end.
