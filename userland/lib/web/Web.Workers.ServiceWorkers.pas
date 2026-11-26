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
  Service workers' behaviour (Service Workers, sections 3 and 4.2 to
  4.4 of the algorithms): the job queue (Register, Update, Unregister,
  run one at a time), Install, Try Activate and Activate, Clear
  Registration, skipWaiting and clients.claim, running a worker in a
  worker agent of its own (Web.Workers.Agents) when it has events to
  handle and ending it when it has been idle IdleTimeout, and Handle
  Fetch as the fetch layer's ServiceWorkerFetchHook.

  Everything the worker's script and the pages see goes through
  Web.Script.NativeServiceWorkers (the natives, the updates pushed to
  the windows and to the workers' scopes, the calls into an agent). The
  records are Web.Workers.ServiceWorkerModel's.

  An update job checks the script in a new agent: the agent fetches it
  (Service-Worker: script, the cache bypassed unless updateViaCache is
  'all'), the job compares it with the newest worker's, and only a
  changed script is evaluated and installed. A navigation in a
  registration's scope that last checked more than a day ago starts a
  soft update.
}
unit Web.Workers.ServiceWorkers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.Bindings.Context,
  Web.Fetch.Responses,
  Web.Fetch.NetworkContexts,
  Web.Script.MessageLinks,
  Web.Workers.ServiceWorkerModel;

const
  { A worker with nothing to do is ended after this long. }
  IdleTimeout = 30000;
  { A registration is checked for an update at most once a day by
    navigations. }
  SoftUpdateInterval = 1.0;

type
  TFetchAnswerKind = (FetchAnswerFallback, FetchAnswerResponse, FetchAnswerError);

  { A fetch event's request as the worker's script gets it. }
  TFetchEventRequest = class
  public
    Method: string;
    Url: string;
    HeaderNames: TStringArray;
    HeaderValues: TStringArray;
    Mode: string;
    Credentials: string;
    Cache: string;
    Redirect: string;
    Destination: string;
    Referrer: string;
    ReferrerPolicy: string;
    Integrity: string;
    Body: TBytes;
    HasBody: Boolean;
    ClientId: string;
    ResultingClientId: string;
    IsReload: Boolean;
    PreloadEnabled: Boolean;
    PreloadHeader: string;
  end;

{ Jobs, for the natives (RequestId: the promise to settle in Client; 0
  for none). }
procedure ScheduleRegister(Client: TBindingContext; RequestId: Integer; const Origin, Scope, ScriptUrl,
  UpdateViaCache: string; Network: TNetworkContext; const UserAgent: string);
procedure ScheduleUpdate(Client: TBindingContext; RequestId: Integer; Registration: TServiceWorkerRegistration;
  Network: TNetworkContext; const UserAgent: string);
procedure ScheduleUnregister(Client: TBindingContext; RequestId: Integer; Registration: TServiceWorkerRegistration);

{ What a worker's agent reports. }
function WorkerOfAgentContext(Context: TBindingContext): TServiceWorkerRecord;
procedure WorkerScriptFetched(Worker: TServiceWorkerRecord; Ok: Boolean; const Text, MimeEssence, AllowedScope,
  ErrorText, CspEnforced, CspReportOnly: string);
procedure WorkerEvaluated(Worker: TServiceWorkerRecord; Failed: Boolean; const ErrorText: string;
  HandlesFetch: Boolean; const ImportUrls, ImportSources: TStringArray);
procedure WorkerEventDone(Worker: TServiceWorkerRecord; EventId: Integer; Success: Boolean);
{ Response: taken (nil unless FetchAnswerResponse). }
procedure WorkerFetchAnswered(Worker: TServiceWorkerRecord; FetchId: Integer; Kind: TFetchAnswerKind;
  Response: TFetchResponse; const Body: string);
procedure WorkerSkipWaiting(Worker: TServiceWorkerRecord);
{ False when the worker is not the active one of its registration. }
function WorkerClaim(Worker: TServiceWorkerRecord): Boolean;

{ A message for Worker from a window or another worker's scope. }
procedure PostMessageToWorker(Worker: TServiceWorkerRecord; Sender: TBindingContext; const Text: string;
  const Ids: TLinkIds);

{ Clients }
{ A window's context starts (or a frame's): it becomes a client. }
procedure ClientStarted(Context: TBindingContext);
{ The worker controlling a client's document (nil if none). }
function ControllerOf(Context: TBindingContext): TServiceWorkerRecord;
{ Whether a worker's registration is the one a client uses. }
function ClientUsesRegistration(Client: TServiceWorkerClient; Registration: TServiceWorkerRegistration): Boolean;
{ The contexts that hear an origin's updates: its clients and the scopes
  of its running workers. }
function ContextsOfOrigin(const Origin: string): TList;

{ The workers running (tests). }
function RunningWorkerCount: Integer;

var
  { The storage service a worker gets when no page of its origin has one
    of the host's (a navigation's worker started before any page;
    nil: one of the agent's own). The browser and its content processes
    set their shared service. }
  DefaultStorageBackend: TObject;
{ Ends every worker and forgets every registration (tests). }
procedure ResetServiceWorkers;

implementation

uses
  DateUtils,
  Url.Records,
  Url.Parser,
  Url.Origins,
  Http.HeaderFields,
  Web.EventLoop,
  Web.EventLoop.Tasks,
  Web.Fetch.Requests,
  Web.Fetch.Fetcher,
  Web.Fetch.MimeTypes,
  Web.Fetch.ServiceWorkerHook,
  Web.Fetch.ReferrerPolicy,
  Web.Fetch.ContentSecurityPolicy,
  Web.Loading.Contexts,
  Web.Script.ContextTasks,
  Web.Script.NativeServiceWorkers,
  Web.Script.PageScripting,
  Web.Workers.Agents;

type
  TJobKind = (JobRegister, JobUpdate, JobUnregister);

  TServiceWorkerJob = class
  public
    Kind: TJobKind;
    Origin: string;
    Scope: string;
    ScriptUrl: string;
    UpdateViaCache: string;
    Client: TBindingContext;
    RequestId: Integer;
    Network: TNetworkContext;
    UserAgent: string;
    Registration: TServiceWorkerRegistration;
    Worker: TServiceWorkerRecord;
  end;

  TPendingEventKind = (PendingInstall, PendingActivate, PendingFetch, PendingMessage);

  TPendingEvent = class
  public
    Kind: TPendingEventKind;
    Id: Integer;
    Fetch: TFetchEventRequest;
    MessageText: string;
    MessageIds: TLinkIds;
    SourceClientId: string;
    SourceWorkerId: QWord;
    destructor Destroy; override;
  end;

  { A worker that has an agent. }
  TRunningWorker = class
  public
    Worker: TServiceWorkerRecord;
    Agent: TWorkerAgent;
    Network: TNetworkContext;
    { The script ran (the events may go to it). }
    Ready: Boolean;
    Failed: Boolean;
    Pending: TList;
    InFlight: Integer;
    IdleCheck: QWord;
    constructor Create;
    destructor Destroy; override;
    procedure AgentRetired(Agent_: TWorkerAgent);
    procedure IdleTimerFired;
  end;

  { A fetch a worker was asked to answer. }
  TPendingFetch = class
  public
    Id: Integer;
    Fetcher: TFetcher;
    Loop: TEventLoop;
    JobId: QWord;
    WorkerId: QWord;
    Mode: TFetchMode;
    Redirect: TFetchRedirect;
    IsNavigation: Boolean;
  end;

  TFetchCompletion = class
  public
    Fetcher: TFetcher;
    JobId: QWord;
    Kind: TFetchAnswerKind;
    Response: TFetchResponse;
    Body: string;
    Reason: string;
    destructor Destroy; override;
  end;

  TFetchCompleter = class
  public
    procedure Run(Data: TObject);
  end;

  TServiceWorkerHook = class(TServiceWorkerFetchHook)
  public
    function Intercept(Fetcher: TObject; Loop: TEventLoop; JobId: QWord; Request: TFetchRequest;
      const Referrer: string): Boolean; override;
    procedure FetcherGone(Fetcher: TObject); override;
  end;

  { Who waits for an install or activate event. }
  TEventWaiter = class
  public
    EventId: Integer;
    Worker: TServiceWorkerRecord;
    Kind: TPendingEventKind;
    Job: TServiceWorkerJob;
  end;

var
  Jobs: TList;
  CurrentJob: TServiceWorkerJob;
  RunningWorkers: TList;
  PendingFetches: TList;
  Waiters: TList;
  Completer: TFetchCompleter;
  Hook: TServiceWorkerHook;
  NextEventId: Integer = 0;
  LastUserAgent: string;

{ ---- small helpers ---- }

destructor TPendingEvent.Destroy;
begin
  Fetch.Free;
  inherited Destroy;
end;

destructor TFetchCompletion.Destroy;
begin
  Response.Free;
  inherited Destroy;
end;

constructor TRunningWorker.Create;
begin
  inherited Create;
  Pending := TList.Create;
end;

destructor TRunningWorker.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to Pending.Count - 1 do
    TPendingEvent(Pending[Index]).Free;
  Pending.Free;
  inherited Destroy;
end;

function RunningOf(Worker: TServiceWorkerRecord): TRunningWorker;
begin
  if (Worker = nil) or (Worker.Running = nil) or (RunningWorkers.IndexOf(Worker.Running) < 0) then
    Exit(nil);
  Result := TRunningWorker(Worker.Running);
end;

function RunningWorkerCount: Integer;
begin
  Result := RunningWorkers.Count;
end;

function OriginOfUrlText(const Url: string): string;
var
  Parsed: TUrlRecord;
  Origin: TUrlOrigin;
begin
  if not ParseUrl(Url, Parsed) then
    Exit('null');
  Origin := OriginOfUrl(Parsed);
  if Origin.Opaque then
    Result := 'null'
  else
    Result := SerializeOrigin(Origin);
end;

function PathOfUrl(const Url: string): string;
var
  Parsed: TUrlRecord;
begin
  if not ParseUrl(Url, Parsed) then
    Exit('');
  Result := SerializePath(Parsed);
end;

{ ---- clients ---- }

function ClientFetchClient(Client: TServiceWorkerClient): TFetchClient;
begin
  Result := ContextFetchClient(Client.Context);
end;

function ControllerIdOf(Client: TServiceWorkerClient): QWord;
var
  FetchClient: TFetchClient;
begin
  FetchClient := ClientFetchClient(Client);
  if FetchClient = nil then
    Exit(0);
  Result := FetchClient.ControllerId;
end;

function ControllerOf(Context: TBindingContext): TServiceWorkerRecord;
var
  FetchClient: TFetchClient;
begin
  Result := nil;
  FetchClient := ContextFetchClient(Context);
  if (FetchClient <> nil) and (FetchClient.ControllerId <> 0) then
    Result := WorkerById(FetchClient.ControllerId);
  if (Result <> nil) and (Result.State = WorkerRedundant) then
    Result := nil;
end;

function ClientUsesRegistration(Client: TServiceWorkerClient; Registration: TServiceWorkerRegistration): Boolean;
var
  Worker: TServiceWorkerRecord;
begin
  Worker := WorkerById(ControllerIdOf(Client));
  Result := (Worker <> nil) and (Worker.Registration = Registration);
end;

function AnyClientUses(Registration: TServiceWorkerRegistration): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to ClientCount - 1 do
    if ClientUsesRegistration(ClientAt(Index), Registration) then
      Exit(True);
  Result := False;
end;

procedure ClientStarted(Context: TBindingContext);
var
  FetchClient: TFetchClient;
  Id, FrameType: string;
begin
  if (ClientByContext(Context) <> nil) or (Context.Environment = nil) or Context.Environment.IsWorkerAgent then
    Exit;
  FetchClient := ContextFetchClient(Context);
  if FetchClient = nil then
    Exit;
  Id := FetchClient.ServiceWorkerClientId;
  { A script-made frame shares its parent's loader: an id of its own. }
  if (Id = '') or (ClientById(Id) <> nil) then
    Id := NewClientId;
  if FetchClient.ServiceWorkerClientId = '' then
    FetchClient.ServiceWorkerClientId := Id;
  if Context.ParentContext <> nil then
    FrameType := 'nested'
  else
    FrameType := 'top-level';
  AddClient(Context, Id, ContextOriginText(Context), FrameType);
end;

function ContextsOfOrigin(const Origin: string): TList;
var
  Index: Integer;
  Running: TRunningWorker;
  Context: TBindingContext;
begin
  Result := TList.Create;
  for Index := 0 to ClientCount - 1 do
    if (ClientAt(Index).Origin = Origin) and ContextIsLive(ClientAt(Index).Context) then
      Result.Add(ClientAt(Index).Context);
  for Index := 0 to RunningWorkers.Count - 1 do
  begin
    Running := TRunningWorker(RunningWorkers[Index]);
    if (Running.Worker.Registration.StorageKey <> Origin) or Running.Agent.Retired then
      Continue;
    Context := Running.Agent.Context;
    if Context <> nil then
      Result.Add(Context);
  end;
end;

{ ---- running workers ---- }

procedure StopWorker(Worker: TServiceWorkerRecord); forward;
procedure FlushEvents(Running: TRunningWorker); forward;
procedure AnswerFetchLocally(Pending: TPendingFetch; Kind: TFetchAnswerKind; Response: TFetchResponse;
  const Body, Reason: string); forward;
function TakePendingFetch(FetchId: Integer): TPendingFetch; forward;

procedure TRunningWorker.AgentRetired(Agent_: TWorkerAgent);
var
  Index: Integer;
  Event: TPendingEvent;
  Pending_: TPendingFetch;
begin
  { However the agent went, the worker is not running now: fetches that
    waited go to the network. }
  RunningWorkers.Remove(Self);
  if Worker.Running = Self then
  begin
    Worker.Running := nil;
    Worker.Agent := nil;
  end;
  for Index := 0 to Pending.Count - 1 do
  begin
    Event := TPendingEvent(Pending[Index]);
    if Event.Kind = PendingFetch then
    begin
      Pending_ := TakePendingFetch(Event.Id);
      if Pending_ <> nil then
        AnswerFetchLocally(Pending_, FetchAnswerFallback, nil, '', '');
    end;
  end;
  for Index := PendingFetches.Count - 1 downto 0 do
    if (Index < PendingFetches.Count) and (TPendingFetch(PendingFetches[Index]).WorkerId = Worker.Id) then
    begin
      Pending_ := TPendingFetch(PendingFetches[Index]);
      PendingFetches.Delete(Index);
      AnswerFetchLocally(Pending_, FetchAnswerFallback, nil, '', '');
    end;
  Free;
end;

procedure TRunningWorker.IdleTimerFired;
begin
  IdleCheck := 0;
  if (RunningWorkers.IndexOf(Self) < 0) or (InFlight > 0) or (Pending.Count > 0) then
    Exit;
  StopWorker(Worker);
end;

procedure ScheduleIdleCheck(Running: TRunningWorker);
begin
  if (Running.InFlight > 0) or (Running.Pending.Count > 0) or Running.Agent.Retired then
    Exit;
  if Running.IdleCheck <> 0 then
    Running.Agent.Loop.CancelScheduledTask(Running.IdleCheck);
  Running.IdleCheck := Running.Agent.Loop.ScheduleTask(TMethodTask.Create(@Running.IdleTimerFired), IdleTimeout);
end;

procedure StopWorker(Worker: TServiceWorkerRecord);
var
  Running: TRunningWorker;
begin
  Running := RunningOf(Worker);
  if Running = nil then
    Exit;
  { Retiring tells AgentRetired, which frees the running record. }
  Running.Agent.Retire;
end;

{ The storage service of the origin's pages (their environment's shared
  one), so the worker sees the caches they see; nil if none has one. }
function StorageBackendFor(Worker: TServiceWorkerRecord): TObject;
var
  Index: Integer;
  Client: TServiceWorkerClient;
begin
  for Index := 0 to ClientCount - 1 do
  begin
    Client := ClientAt(Index);
    if (Client.Origin = Worker.Registration.StorageKey) and ContextIsLive(Client.Context) and
       (Client.Context.Environment <> nil) and (Client.Context.Environment.SharedStorageBackend <> nil) then
      Exit(Client.Context.Environment.SharedStorageBackend);
  end;
  Result := DefaultStorageBackend;
end;

{ The worker's Content Security Policy (its script response's) on its
  agent's fetch client: what the worker fetches is checked against it
  (connect-src for fetch(), script-src for importScripts...). }
procedure ApplyWorkerPolicies(Worker: TServiceWorkerRecord);
var
  Agent: TWorkerAgent;
  Client: TFetchClient;
begin
  Agent := TWorkerAgent(Worker.Agent);
  if (Agent = nil) or (Agent.Context = nil) then
    Exit;
  Client := ContextFetchClient(Agent.Context);
  if Client = nil then
    Exit;
  Client.Csp.Clear;
  if Worker.CspEnforced <> '' then
    Client.Csp.AddFromField(Worker.CspEnforced, CspEnforce);
  if Worker.CspReportOnly <> '' then
    Client.Csp.AddFromField(Worker.CspReportOnly, CspReport);
end;

{ "Run Service Worker": an agent for Worker; its script runs from what
  was stored unless the update check runs it (FetchFirst). }
function StartWorker(Worker: TServiceWorkerRecord; Network: TNetworkContext; FetchFirst: Boolean): TRunningWorker;
var
  Url: TUrlRecord;
begin
  Result := RunningOf(Worker);
  if Result <> nil then
    Exit;
  if (Network = nil) or not ParseUrl(Worker.ScriptUrl, Url) then
    Exit(nil);
  Result := TRunningWorker.Create;
  Result.Worker := Worker;
  Result.Network := Network;
  Result.Agent := TWorkerAgent.Create(Network, Url, LastUserAgent, StorageBackendFor(Worker));
  Result.Agent.OnRetired := @Result.AgentRetired;
  Worker.Agent := Result.Agent;
  Worker.Running := Result;
  RunningWorkers.Add(Result);
  if Result.Agent.Context = nil then
  begin
    Result.Agent.Retire;
    Exit(nil);
  end;
  SendAgentStart(Worker);
  ApplyWorkerPolicies(Worker);
  if FetchFirst then
    SendAgentFetchScript(Worker, Worker.Registration.UpdateViaCache = 'all')
  else
    SendAgentRun(Worker);
end;

{ The network a worker runs on when nothing else says: its running
  agent's, else any of the clients of its origin's. }
function NetworkFor(Worker: TServiceWorkerRecord): TNetworkContext;
var
  Index: Integer;
  Loader: TObject;
  Client: TServiceWorkerClient;
begin
  if RunningOf(Worker) <> nil then
    Exit(RunningOf(Worker).Network);
  for Index := 0 to ClientCount - 1 do
  begin
    Client := ClientAt(Index);
    if (Client.Origin <> Worker.Registration.StorageKey) or not ContextIsLive(Client.Context) then
      Continue;
    Loader := Client.Context.Environment.LoadingContextOf(Client.Context);
    if Loader is TLoadingContext then
      Exit(TLoadingContext(Loader).Fetcher.Network);
  end;
  Result := nil;
end;

procedure QueueEvent(Worker: TServiceWorkerRecord; Event: TPendingEvent; Network: TNetworkContext);
var
  Running: TRunningWorker;
begin
  if Network = nil then
    Network := NetworkFor(Worker);
  Running := StartWorker(Worker, Network, False);
  if Running = nil then
  begin
    if Event.Kind = PendingFetch then
      AnswerFetchLocally(TakePendingFetch(Event.Id), FetchAnswerFallback, nil, '', '');
    Event.Free;
    Exit;
  end;
  if Running.IdleCheck <> 0 then
  begin
    Running.Agent.Loop.CancelScheduledTask(Running.IdleCheck);
    Running.IdleCheck := 0;
  end;
  Running.Pending.Add(Event);
  FlushEvents(Running);
end;

procedure FlushEvents(Running: TRunningWorker);
var
  Event: TPendingEvent;
  Index: Integer;
begin
  if not Running.Ready then
    Exit;
  Index := 0;
  while Index < Running.Pending.Count do
  begin
    Event := TPendingEvent(Running.Pending[Index]);
    { Fetches wait for an activating worker to be activated. }
    if (Event.Kind = PendingFetch) and (Running.Worker.State = WorkerActivating) then
    begin
      Inc(Index);
      Continue;
    end;
    Running.Pending.Delete(Index);
    if Running.Failed then
    begin
      if Event.Kind = PendingFetch then
        AnswerFetchLocally(TakePendingFetch(Event.Id), FetchAnswerFallback, nil, '', '');
      if Event.Kind in [PendingInstall, PendingActivate] then
        WorkerEventDone(Running.Worker, Event.Id, False);
      Event.Free;
      Continue;
    end;
    Inc(Running.InFlight);
    case Event.Kind of
      PendingInstall: SendAgentEvent(Running.Worker, Event.Id, 'install');
      PendingActivate: SendAgentEvent(Running.Worker, Event.Id, 'activate');
      PendingFetch: SendAgentFetch(Running.Worker, Event.Id, Event.Fetch);
      PendingMessage: SendAgentMessage(Running.Worker, Event.Id, Event.MessageText, Event.MessageIds,
        Event.SourceClientId, Event.SourceWorkerId);
    end;
    Event.Fetch := nil;
    Event.Free;
  end;
end;

function WorkerOfAgentContext(Context: TBindingContext): TServiceWorkerRecord;
var
  Index: Integer;
  Running: TRunningWorker;
begin
  for Index := 0 to RunningWorkers.Count - 1 do
  begin
    Running := TRunningWorker(RunningWorkers[Index]);
    if not Running.Agent.Retired and (Running.Agent.Context = Context) then
      Exit(Running.Worker);
  end;
  Result := nil;
end;

{ An event the script finished with (events, fetches, messages). }
procedure EventFinished(Worker: TServiceWorkerRecord);
var
  Running: TRunningWorker;
begin
  Running := RunningOf(Worker);
  if Running = nil then
    Exit;
  if Running.InFlight > 0 then
    Dec(Running.InFlight);
  ScheduleIdleCheck(Running);
end;

{ ---- the job queue ---- }

procedure RunNextJob; forward;
procedure UpdateJob(Job: TServiceWorkerJob); forward;
procedure TryActivate(Registration: TServiceWorkerRegistration); forward;
procedure ClearRegistration(Registration: TServiceWorkerRegistration); forward;

procedure FinishJob(Job: TServiceWorkerJob);
begin
  if CurrentJob = Job then
    CurrentJob := nil;
  Jobs.Remove(Job);
  Job.Free;
  RunNextJob;
end;

procedure ResolveJob(Job: TServiceWorkerJob; Registration: TServiceWorkerRegistration);
begin
  if (Job.RequestId <> 0) and ContextIsLive(Job.Client) then
    ReplyWithRegistration(Job.Client, Job.RequestId, Registration);
  Job.RequestId := 0;
end;

procedure RejectJob(Job: TServiceWorkerJob; const ErrorName, Message: string);
begin
  if (Job.RequestId <> 0) and ContextIsLive(Job.Client) then
    ReplyWithError(Job.Client, Job.RequestId, ErrorName, Message);
  Job.RequestId := 0;
end;

procedure ScheduleJob(Job: TServiceWorkerJob);
begin
  if Job.Network <> nil then
    LastUserAgent := Job.UserAgent;
  Jobs.Add(Job);
  if CurrentJob = nil then
    RunNextJob;
end;

procedure ScheduleRegister(Client: TBindingContext; RequestId: Integer; const Origin, Scope, ScriptUrl,
  UpdateViaCache: string; Network: TNetworkContext; const UserAgent: string);
var
  Job: TServiceWorkerJob;
begin
  Job := TServiceWorkerJob.Create;
  Job.Kind := JobRegister;
  Job.Client := Client;
  Job.RequestId := RequestId;
  Job.Origin := Origin;
  Job.Scope := Scope;
  Job.ScriptUrl := ScriptUrl;
  Job.UpdateViaCache := UpdateViaCache;
  Job.Network := Network;
  Job.UserAgent := UserAgent;
  ScheduleJob(Job);
end;

procedure ScheduleUpdate(Client: TBindingContext; RequestId: Integer; Registration: TServiceWorkerRegistration;
  Network: TNetworkContext; const UserAgent: string);
var
  Job: TServiceWorkerJob;
  Newest: TServiceWorkerRecord;
begin
  Newest := Registration.Newest;
  Job := TServiceWorkerJob.Create;
  Job.Kind := JobUpdate;
  Job.Client := Client;
  Job.RequestId := RequestId;
  Job.Origin := Registration.StorageKey;
  Job.Scope := Registration.Scope;
  if Newest <> nil then
    Job.ScriptUrl := Newest.ScriptUrl;
  Job.UpdateViaCache := Registration.UpdateViaCache;
  Job.Network := Network;
  Job.UserAgent := UserAgent;
  ScheduleJob(Job);
end;

procedure ScheduleUnregister(Client: TBindingContext; RequestId: Integer; Registration: TServiceWorkerRegistration);
var
  Job: TServiceWorkerJob;
begin
  Job := TServiceWorkerJob.Create;
  Job.Kind := JobUnregister;
  Job.Client := Client;
  Job.RequestId := RequestId;
  Job.Origin := Registration.StorageKey;
  Job.Scope := Registration.Scope;
  ScheduleJob(Job);
end;

procedure RegisterJob(Job: TServiceWorkerJob);
var
  Registration: TServiceWorkerRegistration;
  Newest: TServiceWorkerRecord;
begin
  Registration := RegistrationForScope(Job.Origin, Job.Scope);
  if Registration <> nil then
  begin
    Newest := Registration.Newest;
    if (Newest <> nil) and (Newest.ScriptUrl = Job.ScriptUrl) and (Registration.UpdateViaCache = Job.UpdateViaCache) then
    begin
      ResolveJob(Job, Registration);
      FinishJob(Job);
      Exit;
    end;
    Registration.UpdateViaCache := Job.UpdateViaCache;
  end
  else
    Registration := NewRegistration(Job.Origin, Job.Scope, Job.UpdateViaCache);
  Job.Registration := Registration;
  UpdateJob(Job);
end;

procedure UnregisterJob(Job: TServiceWorkerJob);
var
  Registration: TServiceWorkerRegistration;
begin
  Registration := RegistrationForScope(Job.Origin, Job.Scope);
  if Registration = nil then
  begin
    if (Job.RequestId <> 0) and ContextIsLive(Job.Client) then
      ReplyWithBoolean(Job.Client, Job.RequestId, False);
    FinishJob(Job);
    Exit;
  end;
  Registration.Uninstalling := True;
  SaveRegistrations(Registration.StorageKey);
  if (Job.RequestId <> 0) and ContextIsLive(Job.Client) then
    ReplyWithBoolean(Job.Client, Job.RequestId, True);
  if not AnyClientUses(Registration) then
    ClearRegistration(Registration);
  FinishJob(Job);
end;

procedure UpdateJob(Job: TServiceWorkerJob);
var
  Registration: TServiceWorkerRegistration;
  Newest, Worker: TServiceWorkerRecord;
begin
  Registration := Job.Registration;
  if Registration = nil then
    Registration := RegistrationForScope(Job.Origin, Job.Scope);
  if (Registration = nil) or Registration.Uninstalling then
  begin
    RejectJob(Job, 'TypeError', 'The service worker registration is gone.');
    FinishJob(Job);
    Exit;
  end;
  Job.Registration := Registration;
  Newest := Registration.Newest;
  if (Job.Kind = JobUpdate) and ((Newest = nil) or (Newest.ScriptUrl <> Job.ScriptUrl)) then
  begin
    RejectJob(Job, 'TypeError', 'The service worker script changed.');
    FinishJob(Job);
    Exit;
  end;
  Worker := NewWorker(Registration, Job.ScriptUrl);
  Job.Worker := Worker;
  if StartWorker(Worker, Job.Network, True) = nil then
  begin
    ForgetWorker(Worker);
    Job.Worker := nil;
    RejectJob(Job, 'TypeError', 'The service worker could not be started.');
    if Registration.Newest = nil then
      RemoveRegistration(Registration);
    FinishJob(Job);
  end;
end;

procedure RunNextJob;
var
  Job: TServiceWorkerJob;
begin
  if (CurrentJob <> nil) or (Jobs.Count = 0) then
    Exit;
  Job := TServiceWorkerJob(Jobs[0]);
  CurrentJob := Job;
  if (Job.Client <> nil) and not ContextIsLive(Job.Client) then
    Job.Client := nil;
  case Job.Kind of
    JobRegister: RegisterJob(Job);
    JobUpdate: UpdateJob(Job);
    JobUnregister: UnregisterJob(Job);
  end;
end;

function JobOfWorker(Worker: TServiceWorkerRecord): TServiceWorkerJob;
begin
  if (CurrentJob <> nil) and (CurrentJob.Worker = Worker) then
    Result := CurrentJob
  else
    Result := nil;
end;

{ A job's new worker that will not be installed. }
procedure DropJobWorker(Job: TServiceWorkerJob);
var
  Worker: TServiceWorkerRecord;
  Registration: TServiceWorkerRegistration;
begin
  Worker := Job.Worker;
  Registration := Job.Registration;
  Job.Worker := nil;
  if Worker <> nil then
  begin
    StopWorker(Worker);
    ForgetWorker(Worker);
  end;
  if (Registration <> nil) and (Registration.Newest = nil) then
    RemoveRegistration(Registration);
end;

function ScopeAllowed(const Scope, ScriptUrl, AllowedScope: string): Boolean;
var
  MaxScope: string;
  Parsed, Base: TUrlRecord;
begin
  if AllowedScope <> '' then
  begin
    if not ParseUrl(ScriptUrl, Base) or not ParseUrl(AllowedScope, Base, Parsed) then
      Exit(False);
    MaxScope := SerializePath(Parsed);
  end
  else
    MaxScope := PathOfUrl(DirectoryOf(ScriptUrl));
  Result := Copy(PathOfUrl(Scope), 1, Length(MaxScope)) = MaxScope;
end;

procedure WorkerScriptFetched(Worker: TServiceWorkerRecord; Ok: Boolean; const Text, MimeEssence, AllowedScope,
  ErrorText, CspEnforced, CspReportOnly: string);
var
  Job: TServiceWorkerJob;
  Registration: TServiceWorkerRegistration;
  Newest: TServiceWorkerRecord;
begin
  Job := JobOfWorker(Worker);
  if Job = nil then
    Exit;
  Registration := Job.Registration;
  if not Ok then
  begin
    RejectJob(Job, 'TypeError', 'Failed to register a ServiceWorker: ' + ErrorText);
    DropJobWorker(Job);
    FinishJob(Job);
    Exit;
  end;
  if not IsJavaScriptMimeType(MimeEssence) then
  begin
    RejectJob(Job, 'SecurityError', 'Failed to register a ServiceWorker: The script has an unsupported MIME type (''' +
      MimeEssence + ''').');
    DropJobWorker(Job);
    FinishJob(Job);
    Exit;
  end;
  if not ScopeAllowed(Registration.Scope, Worker.ScriptUrl, AllowedScope) then
  begin
    RejectJob(Job, 'SecurityError', 'Failed to register a ServiceWorker: The path of the provided scope (''' +
      Registration.Scope + ''') is not under the max scope allowed. Adjust the scope, move the Service Worker ' +
      'script, or use the Service-Worker-Allowed HTTP header to allow the scope.');
    DropJobWorker(Job);
    FinishJob(Job);
    Exit;
  end;
  Registration.LastUpdateCheck := Now;
  Newest := Registration.Newest;
  if (Newest <> nil) and (Newest <> Worker) and (Newest.ScriptUrl = Worker.ScriptUrl) and (Newest.Source = Text) then
  begin
    ResolveJob(Job, Registration);
    DropJobWorker(Job);
    SaveRegistrations(Registration.StorageKey);
    FinishJob(Job);
    Exit;
  end;
  Worker.Source := Text;
  Worker.CspEnforced := CspEnforced;
  Worker.CspReportOnly := CspReportOnly;
  ApplyWorkerPolicies(Worker);
  SendAgentRun(Worker);
end;

procedure Install(Job: TServiceWorkerJob); forward;

procedure WorkerEvaluated(Worker: TServiceWorkerRecord; Failed: Boolean; const ErrorText: string;
  HandlesFetch: Boolean; const ImportUrls, ImportSources: TStringArray);
var
  Job: TServiceWorkerJob;
  Running: TRunningWorker;
begin
  Running := RunningOf(Worker);
  Job := JobOfWorker(Worker);
  if (Job <> nil) and (Worker.State = WorkerParsed) then
  begin
    if Failed then
    begin
      RejectJob(Job, 'TypeError', 'Failed to register a ServiceWorker: ' + ErrorText);
      DropJobWorker(Job);
      FinishJob(Job);
      Exit;
    end;
    Worker.HandlesFetch := HandlesFetch;
    Worker.ImportUrls := Copy(ImportUrls);
    Worker.ImportSources := Copy(ImportSources);
    if Running <> nil then
      Running.Ready := True;
    Install(Job);
    Exit;
  end;
  { A worker started again for its events. }
  if Running = nil then
    Exit;
  Running.Ready := True;
  Running.Failed := Failed;
  FlushEvents(Running);
  ScheduleIdleCheck(Running);
end;

{ ---- install and activate ---- }

function NewEventId: Integer;
begin
  Inc(NextEventId);
  Result := NextEventId;
end;

procedure DispatchLifecycleEvent(Worker: TServiceWorkerRecord; Kind: TPendingEventKind; Job: TServiceWorkerJob);
var
  Waiter: TEventWaiter;
  Event: TPendingEvent;
begin
  Waiter := TEventWaiter.Create;
  Waiter.EventId := NewEventId;
  Waiter.Worker := Worker;
  Waiter.Kind := Kind;
  Waiter.Job := Job;
  Waiters.Add(Waiter);
  Event := TPendingEvent.Create;
  Event.Kind := Kind;
  Event.Id := Waiter.EventId;
  if Job <> nil then
    QueueEvent(Worker, Event, Job.Network)
  else
    QueueEvent(Worker, Event, nil);
end;

procedure SetWorkerState(Worker: TServiceWorkerRecord; State: TServiceWorkerState);
begin
  Worker.State := State;
  PushWorkerState(Worker);
end;

procedure Install(Job: TServiceWorkerJob);
var
  Registration: TServiceWorkerRegistration;
  Worker: TServiceWorkerRecord;
begin
  Registration := Job.Registration;
  Worker := Job.Worker;
  Registration.Installing := Worker;
  Worker.State := WorkerInstalling;
  PushRegistration(Registration);
  PushWorkerState(Worker);
  ResolveJob(Job, Registration);
  PushUpdateFound(Registration);
  DispatchLifecycleEvent(Worker, PendingInstall, Job);
end;

procedure InstallFinished(Job: TServiceWorkerJob; Worker: TServiceWorkerRecord; Success: Boolean);
var
  Registration: TServiceWorkerRegistration;
  Previous: TServiceWorkerRecord;
begin
  Registration := Worker.Registration;
  if not Success or (Registration.Installing <> Worker) then
  begin
    if Registration.Installing = Worker then
      Registration.Installing := nil;
    SetWorkerState(Worker, WorkerRedundant);
    PushRegistration(Registration);
    StopWorker(Worker);
    Job.Worker := nil;
    if Registration.Newest = nil then
      RemoveRegistration(Registration);
    FinishJob(Job);
    Exit;
  end;
  Previous := Registration.Waiting;
  if Previous <> nil then
  begin
    Registration.Waiting := nil;
    StopWorker(Previous);
    SetWorkerState(Previous, WorkerRedundant);
  end;
  Registration.Waiting := Worker;
  Registration.Installing := nil;
  PushRegistration(Registration);
  SetWorkerState(Worker, WorkerInstalled);
  SaveRegistrations(Registration.StorageKey);
  Job.Worker := nil;
  FinishJob(Job);
  TryActivate(Registration);
end;

procedure Activate(Registration: TServiceWorkerRegistration);
var
  Previous, Worker: TServiceWorkerRecord;
  Index: Integer;
  Client: TServiceWorkerClient;
  FetchClient: TFetchClient;
begin
  Worker := Registration.Waiting;
  if Worker = nil then
    Exit;
  Previous := Registration.Active;
  if Previous <> nil then
  begin
    StopWorker(Previous);
    SetWorkerState(Previous, WorkerRedundant);
  end;
  Registration.Active := Worker;
  Registration.Waiting := nil;
  Worker.State := WorkerActivating;
  PushRegistration(Registration);
  PushWorkerState(Worker);
  { The clients using the registration now use its new active worker. }
  for Index := 0 to ClientCount - 1 do
  begin
    Client := ClientAt(Index);
    if (Previous <> nil) and (ControllerIdOf(Client) = Previous.Id) then
    begin
      FetchClient := ClientFetchClient(Client);
      FetchClient.ControllerId := Worker.Id;
      PushController(Client, Worker);
    end;
  end;
  SaveRegistrations(Registration.StorageKey);
  DispatchLifecycleEvent(Worker, PendingActivate, nil);
end;

procedure ActivateFinished(Worker: TServiceWorkerRecord);
var
  Running: TRunningWorker;
begin
  if (Worker.Registration.Active <> Worker) or (Worker.State <> WorkerActivating) then
    Exit;
  SetWorkerState(Worker, WorkerActivated);
  Running := RunningOf(Worker);
  if Running <> nil then
    FlushEvents(Running);
end;

procedure TryActivate(Registration: TServiceWorkerRegistration);
var
  Waiting, Active: TServiceWorkerRecord;
begin
  Waiting := Registration.Waiting;
  if Waiting = nil then
    Exit;
  Active := Registration.Active;
  if (Active <> nil) and (Active.State = WorkerActivating) then
    Exit;
  if (Active = nil) or Waiting.SkipWaitingFlag or not AnyClientUses(Registration) then
    Activate(Registration);
end;

procedure ClearRegistration(Registration: TServiceWorkerRegistration);
var
  Worker: TServiceWorkerRecord;
begin
  Worker := Registration.Installing;
  if Worker <> nil then
  begin
    StopWorker(Worker);
    SetWorkerState(Worker, WorkerRedundant);
  end;
  Worker := Registration.Waiting;
  if Worker <> nil then
  begin
    StopWorker(Worker);
    SetWorkerState(Worker, WorkerRedundant);
  end;
  Worker := Registration.Active;
  if Worker <> nil then
  begin
    StopWorker(Worker);
    SetWorkerState(Worker, WorkerRedundant);
  end;
  Registration.Installing := nil;
  Registration.Waiting := nil;
  Registration.Active := nil;
  PushRegistration(Registration);
  if (CurrentJob <> nil) and (CurrentJob.Registration = Registration) then
    CurrentJob.Registration := nil;
  RemoveRegistration(Registration);
end;

procedure WorkerEventDone(Worker: TServiceWorkerRecord; EventId: Integer; Success: Boolean);
var
  Index: Integer;
  Waiter: TEventWaiter;
begin
  EventFinished(Worker);
  for Index := 0 to Waiters.Count - 1 do
  begin
    Waiter := TEventWaiter(Waiters[Index]);
    if Waiter.EventId <> EventId then
      Continue;
    Waiters.Delete(Index);
    try
      if Waiter.Kind = PendingInstall then
      begin
        if (CurrentJob <> nil) and (CurrentJob = Waiter.Job) then
          InstallFinished(Waiter.Job, Waiter.Worker, Success);
      end
      else if Waiter.Kind = PendingActivate then
        ActivateFinished(Waiter.Worker);
    finally
      Waiter.Free;
    end;
    Exit;
  end;
end;

procedure WorkerSkipWaiting(Worker: TServiceWorkerRecord);
begin
  Worker.SkipWaitingFlag := True;
  if (Worker.State = WorkerInstalled) and (Worker.Registration.Waiting = Worker) then
    TryActivate(Worker.Registration);
end;

function WorkerClaim(Worker: TServiceWorkerRecord): Boolean;
var
  Index: Integer;
  Client: TServiceWorkerClient;
  FetchClient: TFetchClient;
  Registration: TServiceWorkerRegistration;
begin
  Result := (Worker.Registration.Active = Worker) and (Worker.State in [WorkerActivating, WorkerActivated]);
  if not Result then
    Exit;
  for Index := 0 to ClientCount - 1 do
  begin
    Client := ClientAt(Index);
    if (Client.Origin <> Worker.Registration.StorageKey) or not ContextIsLive(Client.Context) then
      Continue;
    Registration := MatchRegistration(Client.Origin, ContextUrlText(Client.Context));
    if Registration <> Worker.Registration then
      Continue;
    FetchClient := ClientFetchClient(Client);
    if (FetchClient = nil) or (FetchClient.ControllerId = Worker.Id) then
      Continue;
    FetchClient.ControllerId := Worker.Id;
    PushController(Client, Worker);
  end;
end;

{ ---- messages ---- }

procedure PostMessageToWorker(Worker: TServiceWorkerRecord; Sender: TBindingContext; const Text: string;
  const Ids: TLinkIds);
var
  Event: TPendingEvent;
  Client: TServiceWorkerClient;
  SenderWorker: TServiceWorkerRecord;
  Network: TNetworkContext;
  Loader: TObject;
  Index: Integer;
begin
  if (Worker = nil) or (Worker.State in [WorkerParsed, WorkerRedundant]) then
  begin
    for Index := 0 to High(Ids) do
      CloseMessageLink(Ids[Index]);
    Exit;
  end;
  Event := TPendingEvent.Create;
  Event.Kind := PendingMessage;
  Event.Id := NewEventId;
  Event.MessageText := Text;
  Event.MessageIds := Copy(Ids);
  Client := ClientByContext(Sender);
  Network := nil;
  if Client <> nil then
  begin
    Event.SourceClientId := Client.Id;
    Loader := Sender.Environment.LoadingContextOf(Sender);
    if Loader is TLoadingContext then
      Network := TLoadingContext(Loader).Fetcher.Network;
  end
  else
  begin
    SenderWorker := WorkerOfAgentContext(Sender);
    if SenderWorker <> nil then
    begin
      Event.SourceWorkerId := SenderWorker.Id;
      Network := RunningOf(SenderWorker).Network;
    end;
  end;
  QueueEvent(Worker, Event, Network);
end;

{ ---- fetches ---- }

function TakePendingFetch(FetchId: Integer): TPendingFetch;
var
  Index: Integer;
begin
  for Index := 0 to PendingFetches.Count - 1 do
    if TPendingFetch(PendingFetches[Index]).Id = FetchId then
    begin
      Result := TPendingFetch(PendingFetches[Index]);
      PendingFetches.Delete(Index);
      Exit;
    end;
  Result := nil;
end;

procedure TFetchCompleter.Run(Data: TObject);
var
  Completion: TFetchCompletion;
  Response: TFetchResponse;
begin
  Completion := TFetchCompletion(Data);
  case Completion.Kind of
    FetchAnswerFallback: Completion.Fetcher.ContinueWithoutServiceWorker(Completion.JobId);
    FetchAnswerError: Completion.Fetcher.FailFromServiceWorker(Completion.JobId, Completion.Reason);
    FetchAnswerResponse:
      begin
        Response := Completion.Response;
        Completion.Response := nil;
        Completion.Fetcher.RespondFromServiceWorker(Completion.JobId, Response, Completion.Body);
      end;
  end;
end;

{ The answer goes back to the fetcher in a task of its loop (dropped with
  the fetcher's tasks if it goes first). }
procedure AnswerFetchLocally(Pending: TPendingFetch; Kind: TFetchAnswerKind; Response: TFetchResponse;
  const Body, Reason: string);
var
  Completion: TFetchCompletion;
begin
  if Pending = nil then
  begin
    Response.Free;
    Exit;
  end;
  Completion := TFetchCompletion.Create;
  Completion.Fetcher := Pending.Fetcher;
  Completion.JobId := Pending.JobId;
  Completion.Kind := Kind;
  Completion.Response := Response;
  Completion.Body := Body;
  Completion.Reason := Reason;
  Pending.Loop.PostMethod(@Completer.Run, Completion, TaskSourceNetworking, Pending.Fetcher);
  Pending.Free;
end;

{ Handle Fetch's checks of the worker's response against the request. }
function ResponseRefused(Pending: TPendingFetch; Response: TFetchResponse; out Reason: string): Boolean;
begin
  Reason := '';
  if Response.ResponseType = ResponseTypeError then
    Reason := 'the service worker answered with a network error'
  else if (Pending.Mode = FetchModeSameOrigin) and (Response.ResponseType = ResponseTypeCors) then
    Reason := 'a same-origin request got a cors response from the service worker'
  else if (Pending.Mode <> FetchModeNoCors) and (Response.ResponseType = ResponseTypeOpaque) then
    Reason := 'an opaque response from the service worker for a request that is not no-cors'
  else if (Pending.Redirect <> FetchRedirectManual) and (Response.ResponseType = ResponseTypeOpaqueRedirect) then
    Reason := 'an opaque redirect from the service worker'
  else if Pending.IsNavigation and (Response.ResponseType <> ResponseTypeBasic) and
     (Response.ResponseType <> ResponseTypeDefault) then
    Reason := 'a navigation got a response from another origin from the service worker';
  Result := Reason <> '';
end;

procedure WorkerFetchAnswered(Worker: TServiceWorkerRecord; FetchId: Integer; Kind: TFetchAnswerKind;
  Response: TFetchResponse; const Body: string);
var
  Pending: TPendingFetch;
  Reason: string;
begin
  EventFinished(Worker);
  Pending := TakePendingFetch(FetchId);
  if Pending = nil then
  begin
    Response.Free;
    Exit;
  end;
  if (Kind = FetchAnswerResponse) and ResponseRefused(Pending, Response, Reason) then
  begin
    Response.Free;
    AnswerFetchLocally(Pending, FetchAnswerError, nil, '', Reason);
    Exit;
  end;
  if Kind = FetchAnswerError then
    Reason := 'the service worker''s respondWith was rejected';
  AnswerFetchLocally(Pending, Kind, Response, Body, Reason);
end;

function ModeName(Mode: TFetchMode): string;
const
  Names: array[TFetchMode] of string = ('navigate', 'same-origin', 'no-cors', 'cors');
begin
  Result := Names[Mode];
end;

function CredentialsName(Credentials: TFetchCredentials): string;
const
  Names: array[TFetchCredentials] of string = ('omit', 'same-origin', 'include');
begin
  Result := Names[Credentials];
end;

function CacheName(Mode: TFetchCacheMode): string;
const
  Names: array[TFetchCacheMode] of string = ('default', 'no-store', 'reload', 'no-cache', 'force-cache',
    'only-if-cached');
begin
  Result := Names[Mode];
end;

function RedirectName(Redirect: TFetchRedirect): string;
const
  Names: array[TFetchRedirect] of string = ('follow', 'error', 'manual');
begin
  Result := Names[Redirect];
end;

function EventRequestOf(Request: TFetchRequest; const Referrer: string): TFetchEventRequest;
var
  Index, Count: Integer;
begin
  Result := TFetchEventRequest.Create;
  Result.Method := Request.Method;
  Result.Url := SerializeUrl(Request.CurrentUrl);
  Count := Request.Headers.Count;
  SetLength(Result.HeaderNames, Count);
  SetLength(Result.HeaderValues, Count);
  for Index := 0 to Count - 1 do
  begin
    Result.HeaderNames[Index] := Request.Headers[Index].Name;
    Result.HeaderValues[Index] := Request.Headers[Index].Value;
  end;
  if (Request.Headers.Value('accept') = '') then
  begin
    SetLength(Result.HeaderNames, Count + 1);
    SetLength(Result.HeaderValues, Count + 1);
    Result.HeaderNames[Count] := 'accept';
    Result.HeaderValues[Count] := AcceptForDestination(Request.Destination);
  end;
  Result.Mode := ModeName(Request.Mode);
  Result.Credentials := CredentialsName(Request.Credentials);
  Result.Cache := CacheName(Request.CacheMode);
  Result.Redirect := RedirectName(Request.Redirect);
  Result.Destination := DestinationName(Request.Destination);
  if Referrer <> '' then
    Result.Referrer := Referrer
  else if Request.ReferrerKind = ReferrerNone then
    Result.Referrer := ''
  else
    Result.Referrer := 'about:client';
  Result.Integrity := Request.Integrity;
  Result.Body := Request.Body;
  Result.HasBody := Request.HasBody;
  if Request.Client <> nil then
    Result.ClientId := Request.Client.ServiceWorkerClientId;
end;

function TServiceWorkerHook.Intercept(Fetcher: TObject; Loop: TEventLoop; JobId: QWord; Request: TFetchRequest;
  const Referrer: string): Boolean;
var
  Registration: TServiceWorkerRegistration;
  Worker: TServiceWorkerRecord;
  IsNavigation: Boolean;
  Url: string;
  Pending: TPendingFetch;
  Event: TPendingEvent;
begin
  Result := False;
  IsNavigation := (Request.Mode = FetchModeNavigate) and
    (Request.Destination in [DestinationDocument, DestinationIframe, DestinationFrame]);
  Url := SerializeUrl(Request.CurrentUrl);
  if IsNavigation then
  begin
    { A secure context only: an http: page outside localhost is never
      controlled. }
    if not UrlIsPotentiallyTrustworthy(Request.CurrentUrl) then
      Exit;
    Registration := MatchRegistration(OriginOfUrlText(Url), Url);
    if (Registration = nil) or (Registration.Active = nil) then
      Exit;
    Worker := Registration.Active;
    Request.ServiceWorkerControllerId := Worker.Id;
    if DaysBetween(Now, Registration.LastUpdateCheck) >= SoftUpdateInterval then
    begin
      Registration.LastUpdateCheck := Now;
      ScheduleUpdate(nil, 0, Registration, TFetcher(Fetcher).Network, LastUserAgent);
    end;
  end
  else
  begin
    if (Request.Client = nil) or (Request.Client.ControllerId = 0) then
      Exit;
    Worker := WorkerById(Request.Client.ControllerId);
    if (Worker = nil) or not (Worker.State in [WorkerActivating, WorkerActivated]) then
      Exit;
  end;
  if not Worker.HandlesFetch then
    Exit;
  Pending := TPendingFetch.Create;
  Pending.Id := NewEventId;
  Pending.Fetcher := TFetcher(Fetcher);
  Pending.Loop := Loop;
  Pending.JobId := JobId;
  Pending.WorkerId := Worker.Id;
  Pending.Mode := Request.Mode;
  Pending.Redirect := Request.Redirect;
  Pending.IsNavigation := IsNavigation;
  PendingFetches.Add(Pending);
  Event := TPendingEvent.Create;
  Event.Kind := PendingFetch;
  Event.Id := Pending.Id;
  Event.Fetch := EventRequestOf(Request, Referrer);
  if IsNavigation then
  begin
    Event.Fetch.ResultingClientId := Request.ReservedClientId;
    Event.Fetch.PreloadEnabled := Worker.Registration.NavigationPreloadEnabled;
    Event.Fetch.PreloadHeader := Worker.Registration.NavigationPreloadHeader;
  end;
  Event.Fetch.IsReload := Request.CacheMode = FetchCacheNoCache;
  QueueEvent(Worker, Event, TFetcher(Fetcher).Network);
  Result := True;
end;

procedure TServiceWorkerHook.FetcherGone(Fetcher: TObject);
var
  Index: Integer;
begin
  for Index := PendingFetches.Count - 1 downto 0 do
    if TPendingFetch(PendingFetches[Index]).Fetcher = Fetcher then
    begin
      TPendingFetch(PendingFetches[Index]).Free;
      PendingFetches.Delete(Index);
    end;
end;

{ ---- what goes ---- }

procedure ContextEnded(Context: TBindingContext);
var
  Client: TServiceWorkerClient;
  Worker: TServiceWorkerRecord;
  Registration: TServiceWorkerRegistration;
begin
  Client := ClientByContext(Context);
  if Client = nil then
    Exit;
  Worker := WorkerById(ControllerIdOf(Client));
  RemoveClient(Client);
  if Worker = nil then
    Exit;
  Registration := Worker.Registration;
  if Registration.Uninstalling and not AnyClientUses(Registration) then
    ClearRegistration(Registration)
  else
    TryActivate(Registration);
end;

procedure NetworkGone(Network: TNetworkContext);
var
  Index: Integer;
begin
  for Index := Jobs.Count - 1 downto 0 do
    if TServiceWorkerJob(Jobs[Index]).Network = Network then
      TServiceWorkerJob(Jobs[Index]).Network := nil;
end;

procedure ResetServiceWorkers;
var
  Index: Integer;
begin
  while RunningWorkers.Count > 0 do
    TRunningWorker(RunningWorkers[0]).Agent.Free;
  for Index := 0 to Jobs.Count - 1 do
    TServiceWorkerJob(Jobs[Index]).Free;
  Jobs.Clear;
  CurrentJob := nil;
  for Index := 0 to PendingFetches.Count - 1 do
    TPendingFetch(PendingFetches[Index]).Free;
  PendingFetches.Clear;
  for Index := 0 to Waiters.Count - 1 do
    TEventWaiter(Waiters[Index]).Free;
  Waiters.Clear;
  ForgetAllRegistrations;
end;

initialization
  Jobs := TList.Create;
  RunningWorkers := TList.Create;
  PendingFetches := TList.Create;
  Waiters := TList.Create;
  Completer := TFetchCompleter.Create;
  Hook := TServiceWorkerHook.Create;
  ServiceWorkerFetchHook := Hook;
  AddContextEndHook(@ContextEnded);
  AfterNetworkGone := @NetworkGone;
  PageContextStartedHook := @ClientStarted;
finalization
  PageContextStartedHook := nil;
  ServiceWorkerFetchHook := nil;
  AfterNetworkGone := nil;
  ResetServiceWorkers;
  FreeAndNil(Jobs);
  FreeAndNil(RunningWorkers);
  FreeAndNil(PendingFetches);
  FreeAndNil(Waiters);
  FreeAndNil(Completer);
  FreeAndNil(Hook);
end.
