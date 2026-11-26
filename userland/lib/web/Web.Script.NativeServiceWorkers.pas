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
  The natives of service workers: what the windows' ServiceWorkerContainer
  (platform/68-service-workers.js) and a worker's scope
  (platform/69-service-worker-scope.js) call, the updates pushed to
  them, and the calls into a worker's agent. The behaviour is
  Web.Workers.ServiceWorkers'.

  A worker is [id, script URL, state] in script, a registration [id,
  scope, updateViaCache, installing, waiting, active, navigation preload
  enabled, its header value], a client [id, URL, 'window', frame type,
  focused, visibility state].

  In a window (or a worker's scope, for its registration):
    swClientStarted()               [client id, controller]: the window
                                    is a client now
    swController()                  the controller or null
    swRegister(script, scope, updateViaCache, type)
                                    a request id; checks throw
    swGetRegistration(url)          the registration for a URL or undefined
    swGetRegistrations()            the origin's registrations
    swUpdate(id), swUnregister(id)  request ids
    swPostMessage(workerId, text, linkIds)
    swPreload(id, operation, value) navigation preload: 'enable',
                                    'disable', 'header', 'state'
  Replies come as natives.onServiceWorkerReply(request, ok, value), where
  value is a registration, a boolean, or [error name, message] when not
  ok; updates as natives.onServiceWorkerUpdate(kind, ...): 'registration'
  (registration), 'state' (worker), 'updatefound' (registration id),
  'controller' (worker), 'message' (worker, text, link ids).

  In a worker's agent:
    swScriptFetched(ok, text, mime essence, Service-Worker-Allowed, error)
    swEvaluated(failed, error, handles fetch, import URLs, import sources)
    swEventDone(eventId, ok)
    swFetchRespond(fetchId, 'fallback' | 'error' | 'response', [type, url,
                   status, statusText, headers], body)
    swSkipWaiting(), swClaim()
    swClients(includeUncontrolled, type), swClient(id)
    swClientPost(clientId, text, linkIds)
    swClientNavigate(clientId, url)
  and the agent hears onServiceWorkerStart(workerId, script URL,
  registration, state), onServiceWorkerFetchScript(useCache),
  onServiceWorkerRun(source, import URLs, import sources),
  onServiceWorkerEvent(eventId, type), onServiceWorkerFetch(fetchId,
  request, clientId, resultingClientId, preload header or null, reload)
  and onServiceWorkerMessage(eventId, text, linkIds, ['client', client]
  or ['worker', worker]).
}
unit Web.Script.NativeServiceWorkers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Objects,
  Web.Bindings.Context,
  Web.Script.MessageLinks,
  Web.Workers.ServiceWorkerModel,
  Web.Workers.ServiceWorkers;

procedure DefineServiceWorkerNatives(Context: TBindingContext; Natives: TJsObject);

{ Settling a request's promise. }
procedure ReplyWithRegistration(Context: TBindingContext; RequestId: Integer;
  Registration: TServiceWorkerRegistration);
procedure ReplyWithBoolean(Context: TBindingContext; RequestId: Integer; Value: Boolean);
procedure ReplyWithError(Context: TBindingContext; RequestId: Integer; const ErrorName, Message: string);

{ Updates for every context of the registration's origin (one client's
  for the controller). }
procedure PushRegistration(Registration: TServiceWorkerRegistration);
procedure PushWorkerState(Worker: TServiceWorkerRecord);
procedure PushUpdateFound(Registration: TServiceWorkerRegistration);
procedure PushController(Client: TServiceWorkerClient; Worker: TServiceWorkerRecord);

{ Calls into a worker's agent (in tasks of its loop). }
procedure SendAgentStart(Worker: TServiceWorkerRecord);
procedure SendAgentFetchScript(Worker: TServiceWorkerRecord; UseCache: Boolean);
procedure SendAgentRun(Worker: TServiceWorkerRecord);
procedure SendAgentEvent(Worker: TServiceWorkerRecord; EventId: Integer; const EventType: string);
{ Takes Request. }
procedure SendAgentFetch(Worker: TServiceWorkerRecord; FetchId: Integer; Request: TFetchEventRequest);
procedure SendAgentMessage(Worker: TServiceWorkerRecord; EventId: Integer; const Text: string; const Ids: TLinkIds;
  const SourceClientId: string; SourceWorkerId: QWord);

implementation

uses
  Classes,
  Js.Values,
  Js.Functions,
  Js.Engine,
  Url.Records,
  Url.Parser,
  Url.Origins,
  Web.Fetch.Responses,
  Web.Fetch.MimeTypes,
  Web.Fetch.NetworkContexts,
  Web.Loading.Contexts,
  Web.Script.ContextTasks,
  Web.Workers.Agents;

type
  TWorkerSnapshot = record
    Id: QWord;
    Url: string;
    State: string;
  end;

  TRegistrationSnapshot = record
    Id: QWord;
    Scope: string;
    UpdateViaCache: string;
    Installing: TWorkerSnapshot;
    Waiting: TWorkerSnapshot;
    Active: TWorkerSnapshot;
    PreloadEnabled: Boolean;
    PreloadHeader: string;
  end;

  TReplyKind = (ReplyRegistration, ReplyBoolean, ReplyError, ReplyUndefined);

  TReplyTask = class
  public
    RequestId: Integer;
    Kind: TReplyKind;
    Registration: TRegistrationSnapshot;
    Value: Boolean;
    ErrorName: string;
    Message: string;
  end;

  TPushKind = (PushRegistrationKind, PushStateKind, PushUpdateFoundKind, PushControllerKind, PushMessageKind);

  TPushTask = class
  public
    Kind: TPushKind;
    Registration: TRegistrationSnapshot;
    Worker: TWorkerSnapshot;
    Text: string;
    Ids: TLinkIds;
  end;

  TAgentCallKind = (AgentStart, AgentFetchScript, AgentRun, AgentEvent, AgentFetch, AgentMessage);

  TAgentCallTask = class
  public
    Kind: TAgentCallKind;
    WorkerId: QWord;
    ScriptUrl: string;
    Registration: TRegistrationSnapshot;
    State: string;
    UseCache: Boolean;
    Source: string;
    ImportUrls: TStringArray;
    ImportSources: TStringArray;
    EventId: Integer;
    EventType: string;
    Request: TFetchEventRequest;
    Text: string;
    Ids: TLinkIds;
    SourceClientId: string;
    SourceWorker: TWorkerSnapshot;
    destructor Destroy; override;
  end;

var
  NextRequestId: Integer = 0;

destructor TAgentCallTask.Destroy;
begin
  Request.Free;
  inherited Destroy;
end;

{ ---- snapshots and their values ---- }

function SnapshotOf(Worker: TServiceWorkerRecord): TWorkerSnapshot;
begin
  Result := Default(TWorkerSnapshot);
  if Worker = nil then
    Exit;
  Result.Id := Worker.Id;
  Result.Url := Worker.ScriptUrl;
  Result.State := StateName(Worker.State);
end;

function RegistrationSnapshotOf(Registration: TServiceWorkerRegistration): TRegistrationSnapshot;
begin
  Result := Default(TRegistrationSnapshot);
  Result.Id := Registration.Id;
  Result.Scope := Registration.Scope;
  Result.UpdateViaCache := Registration.UpdateViaCache;
  Result.Installing := SnapshotOf(Registration.Installing);
  Result.Waiting := SnapshotOf(Registration.Waiting);
  Result.Active := SnapshotOf(Registration.Active);
  Result.PreloadEnabled := Registration.NavigationPreloadEnabled;
  Result.PreloadHeader := Registration.NavigationPreloadHeader;
end;

function WorkerValue(Context: TBindingContext; constref Snapshot: TWorkerSnapshot): TJsValue;
begin
  if Snapshot.Id = 0 then
    Exit(JsNull);
  Result := Context.NewArray([JsNumber(Snapshot.Id), Context.TextValue(Snapshot.Url), Context.TextValue(Snapshot.State)]);
end;

function RegistrationValue(Context: TBindingContext; constref Snapshot: TRegistrationSnapshot): TJsValue;
begin
  Result := Context.NewArray([JsNumber(Snapshot.Id), Context.TextValue(Snapshot.Scope),
    Context.TextValue(Snapshot.UpdateViaCache), WorkerValue(Context, Snapshot.Installing),
    WorkerValue(Context, Snapshot.Waiting), WorkerValue(Context, Snapshot.Active), JsBoolean(Snapshot.PreloadEnabled),
    Context.TextValue(Snapshot.PreloadHeader)]);
end;

function LiveRegistrationValue(Context: TBindingContext; Registration: TServiceWorkerRegistration): TJsValue;
var
  Snapshot: TRegistrationSnapshot;
begin
  Snapshot := RegistrationSnapshotOf(Registration);
  Result := RegistrationValue(Context, Snapshot);
end;

function LiveWorkerValue(Context: TBindingContext; Worker: TServiceWorkerRecord): TJsValue;
var
  Snapshot: TWorkerSnapshot;
begin
  Snapshot := SnapshotOf(Worker);
  Result := WorkerValue(Context, Snapshot);
end;

function IdsValue(Context: TBindingContext; const Ids: TLinkIds): TJsValue;
var
  Values: array of TJsValue;
  Index: Integer;
begin
  Values := nil;
  SetLength(Values, Length(Ids));
  for Index := 0 to High(Ids) do
    Values[Index] := JsNumber(Ids[Index]);
  Result := Context.NewArray(Values);
end;

function ClientValue(Context: TBindingContext; Client: TServiceWorkerClient): TJsValue;
begin
  Result := Context.NewArray([Context.TextValue(Client.Id), Context.TextValue(ContextUrlText(Client.Context)),
    Context.TextValue('window'), Context.TextValue(Client.FrameType), JsBoolean(False), Context.TextValue('visible')]);
end;

{ ---- replies ---- }

procedure ReplyTaskRun(Context: TBindingContext; Data: TObject);
var
  Task: TReplyTask;
  Value: TJsValue;
  Ok: Boolean;
begin
  Task := TReplyTask(Data);
  Ok := True;
  case Task.Kind of
    ReplyRegistration: Value := RegistrationValue(Context, Task.Registration);
    ReplyBoolean: Value := JsBoolean(Task.Value);
    ReplyError:
      begin
        Ok := False;
        Value := Context.NewArray([Context.TextValue(Task.ErrorName), Context.TextValue(Task.Message)]);
      end;
  else
    Value := JsUndefined;
  end;
  Context.CallPlatform('onServiceWorkerReply', [JsInteger(Task.RequestId), JsBoolean(Ok), Value]);
end;

procedure ReplyWithRegistration(Context: TBindingContext; RequestId: Integer;
  Registration: TServiceWorkerRegistration);
var
  Task: TReplyTask;
begin
  Task := TReplyTask.Create;
  Task.RequestId := RequestId;
  Task.Kind := ReplyRegistration;
  Task.Registration := RegistrationSnapshotOf(Registration);
  PostToContext(Context, @ReplyTaskRun, Task);
end;

procedure ReplyWithBoolean(Context: TBindingContext; RequestId: Integer; Value: Boolean);
var
  Task: TReplyTask;
begin
  Task := TReplyTask.Create;
  Task.RequestId := RequestId;
  Task.Kind := ReplyBoolean;
  Task.Value := Value;
  PostToContext(Context, @ReplyTaskRun, Task);
end;

procedure ReplyWithError(Context: TBindingContext; RequestId: Integer; const ErrorName, Message: string);
var
  Task: TReplyTask;
begin
  Task := TReplyTask.Create;
  Task.RequestId := RequestId;
  Task.Kind := ReplyError;
  Task.ErrorName := ErrorName;
  Task.Message := Message;
  PostToContext(Context, @ReplyTaskRun, Task);
end;

{ ---- pushes ---- }

procedure PushTaskRun(Context: TBindingContext; Data: TObject);
var
  Task: TPushTask;
begin
  Task := TPushTask(Data);
  case Task.Kind of
    PushRegistrationKind:
      Context.CallPlatform('onServiceWorkerUpdate', [Context.TextValue('registration'),
        RegistrationValue(Context, Task.Registration)]);
    PushStateKind:
      Context.CallPlatform('onServiceWorkerUpdate', [Context.TextValue('state'), WorkerValue(Context, Task.Worker)]);
    PushUpdateFoundKind:
      Context.CallPlatform('onServiceWorkerUpdate', [Context.TextValue('updatefound'),
        JsNumber(Task.Registration.Id)]);
    PushControllerKind:
      Context.CallPlatform('onServiceWorkerUpdate', [Context.TextValue('controller'),
        WorkerValue(Context, Task.Worker)]);
    PushMessageKind:
      Context.CallPlatform('onServiceWorkerUpdate', [Context.TextValue('message'), WorkerValue(Context, Task.Worker),
        Context.TextValue(Task.Text), IdsValue(Context, Task.Ids)]);
  end;
end;

procedure PushToOrigin(const Origin: string; Kind: TPushKind; constref Registration: TRegistrationSnapshot;
  constref Worker: TWorkerSnapshot);
var
  Contexts: TList;
  Index: Integer;
  Task: TPushTask;
begin
  Contexts := ContextsOfOrigin(Origin);
  try
    for Index := 0 to Contexts.Count - 1 do
    begin
      Task := TPushTask.Create;
      Task.Kind := Kind;
      Task.Registration := Registration;
      Task.Worker := Worker;
      PostToContext(TBindingContext(Contexts[Index]), @PushTaskRun, Task);
    end;
  finally
    Contexts.Free;
  end;
end;

procedure PushRegistration(Registration: TServiceWorkerRegistration);
begin
  PushToOrigin(Registration.StorageKey, PushRegistrationKind, RegistrationSnapshotOf(Registration),
    Default(TWorkerSnapshot));
end;

procedure PushWorkerState(Worker: TServiceWorkerRecord);
begin
  PushToOrigin(Worker.Registration.StorageKey, PushStateKind, Default(TRegistrationSnapshot), SnapshotOf(Worker));
end;

procedure PushUpdateFound(Registration: TServiceWorkerRegistration);
begin
  PushToOrigin(Registration.StorageKey, PushUpdateFoundKind, RegistrationSnapshotOf(Registration),
    Default(TWorkerSnapshot));
end;

procedure PushController(Client: TServiceWorkerClient; Worker: TServiceWorkerRecord);
var
  Task: TPushTask;
begin
  Task := TPushTask.Create;
  Task.Kind := PushControllerKind;
  Task.Worker := SnapshotOf(Worker);
  PostToContext(Client.Context, @PushTaskRun, Task);
end;

{ ---- calls into an agent ---- }

function FetchRequestValue(Context: TBindingContext; Request: TFetchEventRequest): TJsValue;
var
  Engine: TJsEngine;
  Headers: array of TJsValue;
  Index: Integer;
begin
  Engine := Context.Engine;
  Result := JsObjectValue(Engine.NewObject);
  Engine.SetProperty(Result, 'method', Context.TextValue(Request.Method));
  Engine.SetProperty(Result, 'url', Context.TextValue(Request.Url));
  Headers := nil;
  SetLength(Headers, Length(Request.HeaderNames));
  for Index := 0 to High(Request.HeaderNames) do
    Headers[Index] := Context.NewArray([Context.TextValue(Request.HeaderNames[Index]),
      Context.TextValue(Request.HeaderValues[Index])]);
  Engine.SetProperty(Result, 'headerList', Context.NewArray(Headers));
  Engine.SetProperty(Result, 'mode', Context.TextValue(Request.Mode));
  Engine.SetProperty(Result, 'credentials', Context.TextValue(Request.Credentials));
  Engine.SetProperty(Result, 'cache', Context.TextValue(Request.Cache));
  Engine.SetProperty(Result, 'redirect', Context.TextValue(Request.Redirect));
  Engine.SetProperty(Result, 'destination', Context.TextValue(Request.Destination));
  Engine.SetProperty(Result, 'referrer', Context.TextValue(Request.Referrer));
  Engine.SetProperty(Result, 'referrerPolicy', Context.TextValue(Request.ReferrerPolicy));
  Engine.SetProperty(Result, 'integrity', Context.TextValue(Request.Integrity));
  if Request.HasBody and (Length(Request.Body) > 0) then
    Engine.SetProperty(Result, 'bytes', Engine.NewUint8Array(@Request.Body[0], Length(Request.Body)))
  else if Request.HasBody then
    Engine.SetProperty(Result, 'bytes', Engine.NewUint8Array(nil, 0))
  else
    Engine.SetProperty(Result, 'bytes', JsNull);
end;

function StringsValue(Context: TBindingContext; const Items: TStringArray): TJsValue;
begin
  Result := Context.StringArray(Items);
end;

procedure AgentCallRun(Context: TBindingContext; Data: TObject);
var
  Task: TAgentCallTask;
  Source: TJsValue;
  Client: TServiceWorkerClient;
  Preload: TJsValue;
begin
  Task := TAgentCallTask(Data);
  case Task.Kind of
    AgentStart:
      Context.CallPlatform('onServiceWorkerStart', [JsNumber(Task.WorkerId), Context.TextValue(Task.ScriptUrl),
        RegistrationValue(Context, Task.Registration), Context.TextValue(Task.State)]);
    AgentFetchScript:
      Context.CallPlatform('onServiceWorkerFetchScript', [JsBoolean(Task.UseCache)]);
    AgentRun:
      Context.CallPlatform('onServiceWorkerRun', [Context.TextValue(Task.Source), StringsValue(Context, Task.ImportUrls),
        StringsValue(Context, Task.ImportSources)]);
    AgentEvent:
      Context.CallPlatform('onServiceWorkerEvent', [JsInteger(Task.EventId), Context.TextValue(Task.EventType)]);
    AgentFetch:
      begin
        if Task.Request.PreloadEnabled then
          Preload := Context.TextValue(Task.Request.PreloadHeader)
        else
          Preload := JsNull;
        Context.CallPlatform('onServiceWorkerFetch', [JsInteger(Task.EventId), FetchRequestValue(Context, Task.Request),
          Context.TextValue(Task.Request.ClientId), Context.TextValue(Task.Request.ResultingClientId), Preload,
          JsBoolean(Task.Request.IsReload)]);
      end;
    AgentMessage:
      begin
        Client := ClientById(Task.SourceClientId);
        if (Task.SourceClientId <> '') and (Client <> nil) and ContextIsLive(Client.Context) then
          Source := Context.NewArray([Context.TextValue('client'), ClientValue(Context, Client)])
        else if Task.SourceWorker.Id <> 0 then
          Source := Context.NewArray([Context.TextValue('worker'), WorkerValue(Context, Task.SourceWorker)])
        else
          Source := JsNull;
        Context.CallPlatform('onServiceWorkerMessage', [JsInteger(Task.EventId), Context.TextValue(Task.Text),
          IdsValue(Context, Task.Ids), Source]);
      end;
  end;
end;

function NewAgentCall(Worker: TServiceWorkerRecord; Kind: TAgentCallKind): TAgentCallTask;
begin
  Result := TAgentCallTask.Create;
  Result.Kind := Kind;
  Result.WorkerId := Worker.Id;
end;

procedure SendToAgent(Worker: TServiceWorkerRecord; Task: TAgentCallTask);
var
  Agent: TWorkerAgent;
begin
  Agent := TWorkerAgent(Worker.Agent);
  if (Agent = nil) or Agent.Retired or (Agent.Context = nil) then
  begin
    Task.Free;
    Exit;
  end;
  PostToContext(Agent.Context, @AgentCallRun, Task);
end;

procedure SendAgentStart(Worker: TServiceWorkerRecord);
var
  Task: TAgentCallTask;
begin
  Task := NewAgentCall(Worker, AgentStart);
  Task.ScriptUrl := Worker.ScriptUrl;
  Task.Registration := RegistrationSnapshotOf(Worker.Registration);
  Task.State := StateName(Worker.State);
  SendToAgent(Worker, Task);
end;

procedure SendAgentFetchScript(Worker: TServiceWorkerRecord; UseCache: Boolean);
var
  Task: TAgentCallTask;
begin
  Task := NewAgentCall(Worker, AgentFetchScript);
  Task.UseCache := UseCache;
  SendToAgent(Worker, Task);
end;

procedure SendAgentRun(Worker: TServiceWorkerRecord);
var
  Task: TAgentCallTask;
begin
  Task := NewAgentCall(Worker, AgentRun);
  Task.Source := Worker.Source;
  Task.ImportUrls := Copy(Worker.ImportUrls);
  Task.ImportSources := Copy(Worker.ImportSources);
  SendToAgent(Worker, Task);
end;

procedure SendAgentEvent(Worker: TServiceWorkerRecord; EventId: Integer; const EventType: string);
var
  Task: TAgentCallTask;
begin
  Task := NewAgentCall(Worker, AgentEvent);
  Task.EventId := EventId;
  Task.EventType := EventType;
  SendToAgent(Worker, Task);
end;

procedure SendAgentFetch(Worker: TServiceWorkerRecord; FetchId: Integer; Request: TFetchEventRequest);
var
  Task: TAgentCallTask;
begin
  Task := NewAgentCall(Worker, AgentFetch);
  Task.EventId := FetchId;
  Task.Request := Request;
  SendToAgent(Worker, Task);
end;

procedure SendAgentMessage(Worker: TServiceWorkerRecord; EventId: Integer; const Text: string; const Ids: TLinkIds;
  const SourceClientId: string; SourceWorkerId: QWord);
var
  Task: TAgentCallTask;
begin
  Task := NewAgentCall(Worker, AgentMessage);
  Task.EventId := EventId;
  Task.Text := Text;
  Task.Ids := Copy(Ids);
  Task.SourceClientId := SourceClientId;
  Task.SourceWorker := SnapshotOf(WorkerById(SourceWorkerId));
  SendToAgent(Worker, Task);
end;

{ ---- argument helpers ---- }

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

function TextArg(Context: TBindingContext; Args: PJsValueArray; Count, Index: Integer): string;
begin
  Result := Context.Engine.ToText(Arg(Args, Count, Index));
end;

function NumberArg(Context: TBindingContext; Args: PJsValueArray; Count, Index: Integer): Double;
begin
  Result := Context.Engine.ToNumber(Arg(Args, Count, Index));
end;

function TruthArg(Args: PJsValueArray; Count, Index: Integer): Boolean;
var
  Value: TJsValue;
begin
  Value := Arg(Args, Count, Index);
  Result := JsIsBoolean(Value) and (Value = JsBoolean(True));
end;

function ListLength(Context: TBindingContext; Value: TJsValue): Integer;
begin
  if not JsIsObject(Value) then
    Exit(0);
  Result := Trunc(Context.Engine.ToNumber(Context.Engine.GetProperty(Value, 'length')));
end;

function ListItem(Context: TBindingContext; Value: TJsValue; Index: Integer): TJsValue;
begin
  Result := Context.Engine.GetProperty(Value, IntToStr(Index));
end;

function TextList(Context: TBindingContext; Value: TJsValue): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, ListLength(Context, Value));
  for Index := 0 to High(Result) do
    Result[Index] := Context.Engine.ToText(ListItem(Context, Value, Index));
end;

function IdList(Context: TBindingContext; Value: TJsValue): TLinkIds;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, ListLength(Context, Value));
  for Index := 0 to High(Result) do
    Result[Index] := Context.Engine.ToNumber(ListItem(Context, Value, Index));
end;

function NetworkOf(Context: TBindingContext): TNetworkContext;
var
  Loader: TObject;
begin
  Result := nil;
  if Context.Environment = nil then
    Exit;
  Loader := Context.Environment.LoadingContextOf(Context);
  if Loader is TLoadingContext then
    Result := TLoadingContext(Loader).Fetcher.Network;
end;

function NewRequestId: Integer;
begin
  Inc(NextRequestId);
  Result := NextRequestId;
end;

{ The path of a URL has an escaped slash or backslash. }
function HasEscapedSlash(constref Url: TUrlRecord): Boolean;
var
  Path: string;
begin
  Path := LowerCase(SerializePath(Url));
  Result := (Pos('%2f', Path) > 0) or (Pos('%5c', Path) > 0);
end;

function OriginText(constref Url: TUrlRecord): string;
var
  Origin: TUrlOrigin;
begin
  Origin := OriginOfUrl(Url);
  if Origin.Opaque then
    Result := 'null'
  else
    Result := SerializeOrigin(Origin);
end;

{ ---- the natives of windows ---- }

function NativeClientStarted(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Client: TServiceWorkerClient;
begin
  ClientStarted(Context);
  Client := ClientByContext(Context);
  if Client = nil then
    Exit(JsNull);
  Result := Context.NewArray([Context.TextValue(Client.Id), LiveWorkerValue(Context, ControllerOf(Context))]);
end;

function NativeController(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
begin
  Result := LiveWorkerValue(Context, ControllerOf(Context));
end;

function NativeRegister(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  ScriptUrl, Scope: TUrlRecord;
  Origin, UpdateViaCache: string;
  RequestId: Integer;
begin
  if not ParseUrl(TextArg(Context, Args, ArgCount, 0), ScriptUrl) then
    Exit(Context.ThrowFromException(Exception.Create('Failed to register a ServiceWorker: Invalid script URL.')));
  if (ScriptUrl.Scheme <> 'http') and (ScriptUrl.Scheme <> 'https') then
    Exit(Context.ThrowDomException('SecurityError', 'Failed to register a ServiceWorker: The URL protocol of the ' +
      'script (''' + SerializeUrl(ScriptUrl) + ''') is not supported.'));
  if HasEscapedSlash(ScriptUrl) then
    Exit(Context.ThrowDomException('SecurityError', 'Failed to register a ServiceWorker: The script URL may not ' +
      'contain an escaped slash or backslash.'));
  if JsIsNullish(Arg(Args, ArgCount, 1)) then
  begin
    if not ParseUrl('./', ScriptUrl, Scope) then
      Exit(Context.ThrowDomException('SecurityError', 'Failed to register a ServiceWorker: Invalid scope.'));
  end
  else if not ParseUrl(TextArg(Context, Args, ArgCount, 1), Scope) then
    Exit(Context.ThrowDomException('SecurityError', 'Failed to register a ServiceWorker: Invalid scope.'));
  Scope.Fragment := '';
  Scope.HasFragment := False;
  if (Scope.Scheme <> 'http') and (Scope.Scheme <> 'https') then
    Exit(Context.ThrowDomException('SecurityError', 'Failed to register a ServiceWorker: The URL protocol of the ' +
      'scope (''' + SerializeUrl(Scope) + ''') is not supported.'));
  if HasEscapedSlash(Scope) then
    Exit(Context.ThrowDomException('SecurityError', 'Failed to register a ServiceWorker: The scope may not ' +
      'contain an escaped slash or backslash.'));
  Origin := ContextOriginText(Context);
  if (OriginText(ScriptUrl) <> Origin) or (OriginText(Scope) <> Origin) then
    Exit(Context.ThrowDomException('SecurityError', 'Failed to register a ServiceWorker: The origin of the ' +
      'provided scriptURL or scope does not match the current origin.'));
  if TextArg(Context, Args, ArgCount, 3) = 'module' then
    Exit(Context.ThrowDomException('NotSupportedError', 'Failed to register a ServiceWorker: module service ' +
      'workers are not supported.'));
  UpdateViaCache := TextArg(Context, Args, ArgCount, 2);
  if (UpdateViaCache <> 'all') and (UpdateViaCache <> 'none') then
    UpdateViaCache := 'imports';
  RequestId := NewRequestId;
  ScheduleRegister(Context, RequestId, Origin, SerializeUrl(Scope), SerializeUrl(ScriptUrl), UpdateViaCache,
    NetworkOf(Context), Context.Environment.UserAgent);
  Result := JsInteger(RequestId);
end;

function NativeGetRegistration(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Url: TUrlRecord;
  Registration: TServiceWorkerRegistration;
begin
  if not ParseUrl(TextArg(Context, Args, ArgCount, 0), Url) then
    Exit(JsUndefined);
  if OriginText(Url) <> ContextOriginText(Context) then
    Exit(Context.ThrowDomException('SecurityError', 'Failed to get a ServiceWorkerRegistration: The origin of the ' +
      'provided documentURL does not match the current origin.'));
  Registration := MatchRegistration(ContextOriginText(Context), SerializeUrl(Url));
  if Registration = nil then
    Exit(JsUndefined);
  Result := LiveRegistrationValue(Context, Registration);
end;

function NativeGetRegistrations(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  List: TList;
  Values: array of TJsValue;
  Index: Integer;
begin
  List := RegistrationsOf(ContextOriginText(Context));
  try
    Values := nil;
    SetLength(Values, List.Count);
    for Index := 0 to List.Count - 1 do
      Values[Index] := LiveRegistrationValue(Context, TServiceWorkerRegistration(List[Index]));
    Result := Context.NewArray(Values);
  finally
    List.Free;
  end;
end;

function RegistrationArg(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TServiceWorkerRegistration;
begin
  Result := RegistrationById(Trunc(NumberArg(Context, Args, ArgCount, 0)));
  if (Result <> nil) and (Result.StorageKey <> ContextOriginText(Context)) then
    Result := nil;
end;

function NativeUpdate(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Registration: TServiceWorkerRegistration;
  RequestId: Integer;
begin
  Registration := RegistrationArg(Context, Args, ArgCount);
  if (Registration = nil) or Registration.Uninstalling or (Registration.Newest = nil) then
    Exit(Context.ThrowDomException('InvalidStateError', 'Failed to update a ServiceWorker: The registration has no ' +
      'worker.'));
  RequestId := NewRequestId;
  ScheduleUpdate(Context, RequestId, Registration, NetworkOf(Context), Context.Environment.UserAgent);
  Result := JsInteger(RequestId);
end;

function NativeUnregister(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Registration: TServiceWorkerRegistration;
  RequestId: Integer;
begin
  RequestId := NewRequestId;
  Registration := RegistrationArg(Context, Args, ArgCount);
  if (Registration = nil) or Registration.Uninstalling then
    ReplyWithBoolean(Context, RequestId, False)
  else
    ScheduleUnregister(Context, RequestId, Registration);
  Result := JsInteger(RequestId);
end;

function NativePostMessage(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
begin
  Worker := WorkerById(Trunc(NumberArg(Context, Args, ArgCount, 0)));
  if (Worker <> nil) and (Worker.Registration.StorageKey <> ContextOriginText(Context)) then
    Worker := nil;
  PostMessageToWorker(Worker, Context, TextArg(Context, Args, ArgCount, 1), IdList(Context, Arg(Args, ArgCount, 2)));
  Result := JsUndefined;
end;

function NativePreload(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Registration: TServiceWorkerRegistration;
  Operation: string;
begin
  Registration := RegistrationArg(Context, Args, ArgCount);
  if Registration = nil then
    Exit(Context.ThrowDomException('InvalidStateError', 'The registration is gone.'));
  Operation := TextArg(Context, Args, ArgCount, 1);
  if ((Operation = 'enable') or (Operation = 'disable')) and (Registration.Active = nil) then
    Exit(Context.ThrowDomException('InvalidStateError', 'The registration has no active worker.'));
  if Operation = 'enable' then
    Registration.NavigationPreloadEnabled := True
  else if Operation = 'disable' then
    Registration.NavigationPreloadEnabled := False
  else if Operation = 'header' then
    Registration.NavigationPreloadHeader := TextArg(Context, Args, ArgCount, 2);
  if Operation <> 'state' then
    SaveRegistrations(Registration.StorageKey);
  Result := Context.NewArray([JsBoolean(Registration.NavigationPreloadEnabled),
    Context.TextValue(Registration.NavigationPreloadHeader)]);
end;

{ ---- the natives of a worker's agent ---- }

function AgentWorker(Context: TBindingContext; out Worker: TServiceWorkerRecord): Boolean;
begin
  Worker := WorkerOfAgentContext(Context);
  Result := Worker <> nil;
end;

function NativeScriptFetched(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
begin
  Result := JsUndefined;
  if AgentWorker(Context, Worker) then
    WorkerScriptFetched(Worker, TruthArg(Args, ArgCount, 0), TextArg(Context, Args, ArgCount, 1),
      TextArg(Context, Args, ArgCount, 2), TextArg(Context, Args, ArgCount, 3), TextArg(Context, Args, ArgCount, 4));
end;

function NativeEvaluated(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
begin
  Result := JsUndefined;
  if AgentWorker(Context, Worker) then
    WorkerEvaluated(Worker, TruthArg(Args, ArgCount, 0), TextArg(Context, Args, ArgCount, 1),
      TruthArg(Args, ArgCount, 2), TextList(Context, Arg(Args, ArgCount, 3)), TextList(Context, Arg(Args, ArgCount, 4)));
end;

function NativeEventDone(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
begin
  Result := JsUndefined;
  if AgentWorker(Context, Worker) then
    WorkerEventDone(Worker, Trunc(NumberArg(Context, Args, ArgCount, 0)), TruthArg(Args, ArgCount, 1));
end;

function ResponseTypeOf(const Name: string): TFetchResponseType;
begin
  if Name = 'cors' then
    Result := ResponseTypeCors
  else if Name = 'opaque' then
    Result := ResponseTypeOpaque
  else if Name = 'opaqueredirect' then
    Result := ResponseTypeOpaqueRedirect
  else if Name = 'error' then
    Result := ResponseTypeError
  else
    Result := ResponseTypeBasic;
end;

function NativeFetchRespond(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
  Kind: string;
  Record_, Headers, Pair: TJsValue;
  Response: TFetchResponse;
  Index: Integer;
  Data: PByte;
  Count: SizeInt;
  Body, ContentType: string;
  FetchId: Integer;
begin
  Result := JsUndefined;
  if not AgentWorker(Context, Worker) then
    Exit;
  FetchId := Trunc(NumberArg(Context, Args, ArgCount, 0));
  Kind := TextArg(Context, Args, ArgCount, 1);
  if Kind = 'fallback' then
  begin
    WorkerFetchAnswered(Worker, FetchId, FetchAnswerFallback, nil, '');
    Exit;
  end;
  if Kind <> 'response' then
  begin
    WorkerFetchAnswered(Worker, FetchId, FetchAnswerError, nil, '');
    Exit;
  end;
  Record_ := Arg(Args, ArgCount, 2);
  Response := TFetchResponse.Create;
  Response.ResponseType := ResponseTypeOf(Context.Engine.ToText(ListItem(Context, Record_, 0)));
  Response.Status := Trunc(Context.Engine.ToNumber(ListItem(Context, Record_, 2)));
  Response.StatusText := Context.Engine.ToText(ListItem(Context, Record_, 3));
  { An opaque response's status is not known here: the page reads it
    as 0 anyway, the engine's consumers as a success. }
  if Response.ResponseType = ResponseTypeOpaque then
    Response.Status := 200;
  Headers := ListItem(Context, Record_, 4);
  ContentType := '';
  for Index := 0 to ListLength(Context, Headers) - 1 do
  begin
    Pair := ListItem(Context, Headers, Index);
    Response.Headers.Add(Context.Engine.ToText(ListItem(Context, Pair, 0)), Context.Engine.ToText(ListItem(Context, Pair, 1)));
    if LowerCase(Context.Engine.ToText(ListItem(Context, Pair, 0))) = 'content-type' then
      ContentType := Context.Engine.ToText(ListItem(Context, Pair, 1));
  end;
  if ContentType <> '' then
    Response.MimeType := ParseMimeType(ContentType);
  Response.Protocol := 'service-worker';
  Body := '';
  if Context.Engine.BufferSourceData(Arg(Args, ArgCount, 3), Data, Count) and (Count > 0) then
    SetString(Body, PChar(Data), Count);
  WorkerFetchAnswered(Worker, FetchId, FetchAnswerResponse, Response, Body);
end;

function NativeSkipWaiting(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
begin
  Result := JsUndefined;
  if AgentWorker(Context, Worker) then
    WorkerSkipWaiting(Worker);
end;

function NativeClaim(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
begin
  Result := JsBoolean(AgentWorker(Context, Worker) and WorkerClaim(Worker));
end;

function NativeClients(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
  IncludeUncontrolled: Boolean;
  Kind: string;
  Values: array of TJsValue;
  Index: Integer;
  Client: TServiceWorkerClient;
  Controller: TServiceWorkerRecord;
begin
  Values := nil;
  if AgentWorker(Context, Worker) then
  begin
    IncludeUncontrolled := TruthArg(Args, ArgCount, 0);
    Kind := TextArg(Context, Args, ArgCount, 1);
    { Windows only: dedicated and shared workers are not clients here. }
    if (Kind = 'window') or (Kind = 'all') then
      for Index := 0 to ClientCount - 1 do
      begin
        Client := ClientAt(Index);
        if (Client.Origin <> Worker.Registration.StorageKey) or not ContextIsLive(Client.Context) then
          Continue;
        Controller := ControllerOf(Client.Context);
        if not IncludeUncontrolled and (Controller <> Worker) then
          Continue;
        SetLength(Values, Length(Values) + 1);
        Values[High(Values)] := ClientValue(Context, Client);
      end;
  end;
  Result := Context.NewArray(Values);
end;

function NativeClient(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
  Client: TServiceWorkerClient;
begin
  Result := JsNull;
  if not AgentWorker(Context, Worker) then
    Exit;
  Client := ClientById(TextArg(Context, Args, ArgCount, 0));
  if (Client <> nil) and (Client.Origin = Worker.Registration.StorageKey) and ContextIsLive(Client.Context) then
    Result := ClientValue(Context, Client);
end;

function NativeClientPost(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
  Client: TServiceWorkerClient;
  Task: TPushTask;
  Ids: TLinkIds;
  Index: Integer;
begin
  Result := JsUndefined;
  Ids := IdList(Context, Arg(Args, ArgCount, 2));
  Client := ClientById(TextArg(Context, Args, ArgCount, 0));
  if not AgentWorker(Context, Worker) or (Client = nil) or (Client.Origin <> Worker.Registration.StorageKey) or
     not ContextIsLive(Client.Context) then
  begin
    for Index := 0 to High(Ids) do
      CloseMessageLink(Ids[Index]);
    Exit;
  end;
  Task := TPushTask.Create;
  Task.Kind := PushMessageKind;
  Task.Worker := SnapshotOf(Worker);
  Task.Text := TextArg(Context, Args, ArgCount, 1);
  Task.Ids := Ids;
  PostToContext(Client.Context, @PushTaskRun, Task);
end;

function NativeClientNavigate(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;
var
  Worker: TServiceWorkerRecord;
  Client: TServiceWorkerClient;
begin
  Result := JsBoolean(False);
  if not AgentWorker(Context, Worker) then
    Exit;
  Client := ClientById(TextArg(Context, Args, ArgCount, 0));
  { Only a client this worker controls may be navigated. }
  if (Client = nil) or (ControllerOf(Client.Context) <> Worker) or (Client.Context.Environment = nil) then
    Exit;
  Client.Context.Environment.Navigate(Client.Context, TextArg(Context, Args, ArgCount, 1), False);
  Result := JsBoolean(True);
end;

type
  TServiceWorkerNative = function(Context: TBindingContext; Args: PJsValueArray; ArgCount: Integer): TJsValue;

const
  NativeCount = 19;
  NativeNames: array[0..NativeCount - 1] of string = ('swClientStarted', 'swController', 'swRegister',
    'swGetRegistration', 'swGetRegistrations', 'swUpdate', 'swUnregister', 'swPostMessage', 'swPreload',
    'swScriptFetched', 'swEvaluated', 'swEventDone', 'swFetchRespond', 'swSkipWaiting', 'swClaim', 'swClients',
    'swClient', 'swClientPost', 'swClientNavigate');
  NativeRoutines: array[0..NativeCount - 1] of TServiceWorkerNative = (@NativeClientStarted, @NativeController,
    @NativeRegister, @NativeGetRegistration, @NativeGetRegistrations, @NativeUpdate, @NativeUnregister,
    @NativePostMessage, @NativePreload, @NativeScriptFetched, @NativeEvaluated, @NativeEventDone, @NativeFetchRespond,
    @NativeSkipWaiting, @NativeClaim, @NativeClients, @NativeClient, @NativeClientPost, @NativeClientNavigate);

function NativeEntry(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
begin
  Context := ContextOfRealm(R);
  try
    { A window becomes a client the first time it is looked at here (its
      platform scripts run before its loader knows it). }
    ClientStarted(Context);
    Result := NativeRoutines[Callee.Magic](Context, Args, ArgCount);
  except
    on Error: Exception do
      Result := Context.ThrowFromException(Error);
  end;
end;

procedure DefineServiceWorkerNatives(Context: TBindingContext; Natives: TJsObject);
var
  Index: Integer;
begin
  for Index := 0 to High(NativeRoutines) do
    Context.Engine.DefineFunction(Natives, NativeNames[Index], @NativeEntry, 0, Index);
end;

end.
