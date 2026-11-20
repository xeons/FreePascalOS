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
  Web.Dom,
  Web.EventLoop,
  Web.ScriptEnvironment,
  Js.Engine,
  Web.Script.Context,
  Web.Loading.Scripts,
  Web.Navigation.Navigables;

type
  TScriptAlertEvent = procedure(const Message: string) of object;
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
    function FindTimer(Context: TObject; TimerId: Integer): Integer;
    procedure TraverseTask;
    procedure ReloadTask;
  public
    constructor Create(Executor: TPageScriptExecutor);
    destructor Destroy; override;
    { The timers of a context that stopped. }
    procedure ForgetContext(Context: TObject);
    procedure ForgetTimers;
    procedure TimerDue(Context: TObject; TimerId, Milliseconds: Integer; Repeating: Boolean);
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
    function Confirm(Context: TObject; const Message: string): Boolean; override;
    function Prompt(Context: TObject; const Message, Default: string; out Answer: string): Boolean; override;
    function ViewportWidth: Integer; override;
    function ViewportHeight: Integer; override;
    function DevicePixelRatio: Double; override;
    function GetCookies(Context: TObject; const Url: string): string; override;
    procedure SetCookie(Context: TObject; const Url, Cookie: string); override;
    function UserAgent: string; override;
    function Language: string; override;
    property UserAgentText: string read FUserAgent write FUserAgent;
  end;

  { A context's module graph: specifiers resolved against the
    importing module's URL, module sources fetched through the loader
    (CORS, UTF-8). }
  TContextModules = class
  private
    FContext: TScriptContext;
    FLoader: TObject;
    FInlineCount: Integer;
    function Resolve(const Specifier, ReferrerKey: string; out Key: string): Boolean;
    procedure Fetch(Request: TJsModuleFetch);
    procedure FetchDone(const Source: string; Success: Boolean; Data: TObject);
  public
    Stopped: Boolean;
    constructor Create(Context: TScriptContext; Loader: TObject);
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
    FOnConfirm: TScriptConfirmEvent;
    FOnPrompt: TScriptPromptEvent;
    FOnConsoleMessage: TScriptConsoleEvent;
    function IndexOfLoader(Loader: TObject): Integer;
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
    procedure DocumentStopped(Loader: TObject); override;
    procedure DocumentFreed(Loader: TObject); override;
    { The live context of Document, nil if none. }
    function ContextOf(Document: TDocument): TScriptContext;
    function IsLiveContext(Context: TObject): Boolean;
    property Navigable: TNavigable read FNavigable;
    property Environment: TPageScriptEnvironment read FEnvironment;
    property OnAlert: TScriptAlertEvent read FOnAlert write FOnAlert;
    property OnConfirm: TScriptConfirmEvent read FOnConfirm write FOnConfirm;
    property OnPrompt: TScriptPromptEvent read FOnPrompt write FOnPrompt;
    property OnConsoleMessage: TScriptConsoleEvent read FOnConsoleMessage write FOnConsoleMessage;
  end;

const
  DefaultScriptUserAgent = 'Mozilla/5.0 (FreePascalOS) libweb/1.0';

implementation

uses
  Web.Profiling,
  DateUtils,
  Url.Records,
  Url.Parser,
  Url.Origins,
  Http.Cookies,
  Web.EventLoop.Tasks,
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
end;

destructor TPageScriptEnvironment.Destroy;
begin
  ForgetTimers;
  FTimers.Free;
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
  Jar: TCookieJar;
begin
  Result := '';
  Jar := FExecutor.FNavigable.Fetcher.Network.Client.Cookies;
  if (Jar = nil) or not ParseUrl(Url, Target) then
    Exit;
  if (Target.Scheme <> 'http') and (Target.Scheme <> 'https') then
    Exit;
  Result := Jar.DocumentCookie(Target, ScriptCookieContext(Target), UnixTimeNow);
end;

procedure TPageScriptEnvironment.SetCookie(Context: TObject; const Url, Cookie: string);
var
  Target: TUrlRecord;
  Jar: TCookieJar;
begin
  Jar := FExecutor.FNavigable.Fetcher.Network.Client.Cookies;
  if (Jar = nil) or not ParseUrl(Url, Target) then
    Exit;
  if (Target.Scheme <> 'http') and (Target.Scheme <> 'https') then
    Exit;
  Jar.SetDocumentCookie(Target, Cookie, ScriptCookieContext(Target), UnixTimeNow);
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
end;

function TContextModules.Resolve(const Specifier, ReferrerKey: string; out Key: string): Boolean;
var
  Base, Target: TUrlRecord;
begin
  Key := '';
  { Bare specifiers need an import map (not read yet). }
  if not ((Copy(Specifier, 1, 1) = '/') or (Copy(Specifier, 1, 2) = './') or (Copy(Specifier, 1, 3) = '../')) then
  begin
    Result := ParseUrl(Specifier, Target);
    if Result then
      Key := SerializeUrl(Target);
    Exit;
  end;
  if (ReferrerKey = '') or not ParseUrl(ReferrerKey, Base) then
    Base := TDocumentLoader(FLoader).BaseUrl;
  Result := ParseUrl(Specifier, Base, Target);
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
  EnterPhase(PhaseScript);
  try
    SetPhaseDetail(Key);
    try
      FContext.Engine.EvaluateModule(Source, Key);
    except
      on Error: EJsError do
        FContext.Console('error', 'Uncaught ' + Error.Message);
    end;
    FContext.PerformMicrotaskCheckpoint;
  finally
    LeavePhase;
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
    FContexts[Index].Context.Free;
  end;
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
begin
  for Index := 0 to High(FContexts) do
    if (FContexts[Index].Context = Context) and not FContexts[Index].Stopped then
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
  Context: TScriptContext;
begin
  if IndexOfLoader(Loader) >= 0 then
    Exit;
  DocumentLoader := TDocumentLoader(Loader);
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

procedure TPageScriptExecutor.DocumentStopped(Loader: TObject);
var
  Index: Integer;
begin
  Index := IndexOfLoader(Loader);
  if (Index < 0) or FContexts[Index].Stopped then
    Exit;
  FContexts[Index].Stopped := True;
  FContexts[Index].Modules.Stopped := True;
  FContexts[Index].Context.AttachParser(nil);
  FEnvironment.ForgetContext(FContexts[Index].Context);
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
