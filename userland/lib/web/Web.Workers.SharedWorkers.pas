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
  The process's shared workers (HTML Standard 10.2.6, "run a worker"
  for SharedWorker): one per origin, script URL and name, in a worker
  agent of its own (Web.Workers.Agents). The natives of
  platform/66-shared-workers.js:

  in a page:
    natives.sharedWorkerConnect(url, name, linkId, source)
        connects the link end to the worker (started first if there is
        none); source: the script's text (a blob: URL's) or null to
        fetch it. The connection's id, 0 when no worker can be started.
  in the worker's agent:
    natives.sharedWorkerFailed(message)  the script could not be
        fetched or parsed: error at every connection's SharedWorker
        (natives.onSharedWorkerError(connection, message)); the worker
        goes
    natives.sharedWorkerClose()          close(): the worker goes, the
        next connection starts another

  The agent hears natives.onSharedWorkerStart(url, name, source) and
  natives.onSharedWorkerConnect(linkId) in tasks of its loop. A worker
  goes when the last document that connected to it goes.
}
unit Web.Workers.SharedWorkers;

{$mode objfpc}
{$H+}

interface

uses
  Js.Objects,
  Web.Bindings.Context;

procedure DefineSharedWorkerNatives(Context: TBindingContext; Natives: TJsObject);

{ The shared workers running (tests). }
function SharedWorkerCount: Integer;

implementation

uses
  SysUtils,
  Classes,
  Js.Values,
  Js.Functions,
  Js.Engine,
  Url.Records,
  Url.Parser,
  Web.Loading.Contexts,
  Web.Script.ContextTasks,
  Web.Script.MessageLinks,
  Web.Workers.Agents;

type
  TSharedWorkerConnection = class
  public
    Id: Integer;
    Context: TBindingContext;
  end;

  TSharedWorkerRecord = class
  private
    procedure AgentRetired(Agent: TWorkerAgent);
  public
    Origin: string;
    Url: string;
    Name: string;
    Agent: TWorkerAgent;
    Connections: TList;
    constructor Create;
    destructor Destroy; override;
  end;

  TAgentCall = class
  public
    Kind: Integer;
    Url: string;
    Name: string;
    Source: string;
    HasSource: Boolean;
    LinkId: Double;
  end;

  TErrorCall = class
  public
    Connection: Integer;
    Message: string;
  end;

const
  CallStart = 0;
  CallConnect = 1;

var
  Workers: TList;
  NextConnectionId: Integer = 0;

constructor TSharedWorkerRecord.Create;
begin
  inherited Create;
  Connections := TList.Create;
end;

destructor TSharedWorkerRecord.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to Connections.Count - 1 do
    TSharedWorkerConnection(Connections[Index]).Free;
  Connections.Free;
  inherited Destroy;
end;

{ The record is dropped when its agent goes, however it goes. }
procedure TSharedWorkerRecord.AgentRetired(Agent: TWorkerAgent);
begin
  Self.Agent := nil;
  Workers.Remove(Self);
  Free;
end;

function SharedWorkerCount: Integer;
begin
  Result := Workers.Count;
end;

function Arg(Args: PJsValueArray; Count, Index: Integer): TJsValue; inline;
begin
  if Index < Count then
    Result := Args^[Index]
  else
    Result := JsUndefined;
end;

procedure AgentCallTask(Context: TBindingContext; Data: TObject);
var
  Call: TAgentCall;
  Source: TJsValue;
begin
  Call := TAgentCall(Data);
  if Call.Kind = CallStart then
  begin
    if Call.HasSource then
      Source := Context.TextValue(Call.Source)
    else
      Source := JsNull;
    Context.CallPlatform('onSharedWorkerStart', [Context.TextValue(Call.Url), Context.TextValue(Call.Name), Source]);
  end
  else
    Context.CallPlatform('onSharedWorkerConnect', [JsNumber(Call.LinkId)]);
end;

procedure ErrorTask(Context: TBindingContext; Data: TObject);
begin
  Context.CallPlatform('onSharedWorkerError', [JsInteger(TErrorCall(Data).Connection),
    Context.TextValue(TErrorCall(Data).Message)]);
end;

function FindWorker(const Origin, Url, Name: string): TSharedWorkerRecord;
var
  Index: Integer;
  Worker: TSharedWorkerRecord;
begin
  for Index := 0 to Workers.Count - 1 do
  begin
    Worker := TSharedWorkerRecord(Workers[Index]);
    if (Worker.Origin = Origin) and (Worker.Url = Url) and (Worker.Name = Name) and (Worker.Agent <> nil) and
       not Worker.Agent.Retired then
      Exit(Worker);
  end;
  Result := nil;
end;

function WorkerOfAgentContext(Context: TBindingContext): TSharedWorkerRecord;
var
  Index: Integer;
  Worker: TSharedWorkerRecord;
begin
  for Index := 0 to Workers.Count - 1 do
  begin
    Worker := TSharedWorkerRecord(Workers[Index]);
    if (Worker.Agent <> nil) and (Worker.Agent.Context = Context) then
      Exit(Worker);
  end;
  Result := nil;
end;

function NativeSharedWorkerConnect(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Loader: TObject;
  Url: TUrlRecord;
  UrlText, Name, Origin: string;
  Worker: TSharedWorkerRecord;
  Connection: TSharedWorkerConnection;
  Call: TAgentCall;
  SourceValue: TJsValue;
begin
  Context := ContextOfRealm(R);
  Result := JsInteger(0);
  UrlText := Context.Engine.ToText(Arg(Args, ArgCount, 0));
  Name := Context.Engine.ToText(Arg(Args, ArgCount, 1));
  Loader := nil;
  if Context.Environment <> nil then
    Loader := Context.Environment.LoadingContextOf(Context);
  if not (Loader is TLoadingContext) or not ParseUrl(UrlText, Url) then
  begin
    CloseMessageLink(Context.Engine.ToNumber(Arg(Args, ArgCount, 2)));
    Exit;
  end;
  Origin := ContextOriginText(Context);
  Worker := FindWorker(Origin, UrlText, Name);
  if Worker = nil then
  begin
    Worker := TSharedWorkerRecord.Create;
    Worker.Origin := Origin;
    Worker.Url := UrlText;
    Worker.Name := Name;
    Worker.Agent := TWorkerAgent.Create(TLoadingContext(Loader).Fetcher.Network, Url, Context.Environment.UserAgent,
      Context.Environment.SharedStorageBackend);
    Worker.Agent.OnRetired := @Worker.AgentRetired;
    Workers.Add(Worker);
    Call := TAgentCall.Create;
    Call.Kind := CallStart;
    Call.Url := UrlText;
    Call.Name := Name;
    SourceValue := Arg(Args, ArgCount, 3);
    Call.HasSource := JsIsString(SourceValue);
    if Call.HasSource then
      Call.Source := Context.Engine.ToText(SourceValue);
    if (Worker.Agent.Context = nil) or not PostToContext(Worker.Agent.Context, @AgentCallTask, Call) then
    begin
      Worker.Agent.Retire;
      CloseMessageLink(Context.Engine.ToNumber(Arg(Args, ArgCount, 2)));
      Exit;
    end;
  end;
  Inc(NextConnectionId);
  Connection := TSharedWorkerConnection.Create;
  Connection.Id := NextConnectionId;
  Connection.Context := Context;
  KnowContext(Context);
  Worker.Connections.Add(Connection);
  Call := TAgentCall.Create;
  Call.Kind := CallConnect;
  Call.LinkId := Context.Engine.ToNumber(Arg(Args, ArgCount, 2));
  PostToContext(Worker.Agent.Context, @AgentCallTask, Call);
  Result := JsInteger(Connection.Id);
end;

function NativeSharedWorkerFailed(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Context: TBindingContext;
  Worker: TSharedWorkerRecord;
  Connection: TSharedWorkerConnection;
  Call: TErrorCall;
  Index: Integer;
begin
  Context := ContextOfRealm(R);
  Result := JsUndefined;
  Worker := WorkerOfAgentContext(Context);
  if Worker = nil then
    Exit;
  for Index := 0 to Worker.Connections.Count - 1 do
  begin
    Connection := TSharedWorkerConnection(Worker.Connections[Index]);
    Call := TErrorCall.Create;
    Call.Connection := Connection.Id;
    Call.Message := Context.Engine.ToText(Arg(Args, ArgCount, 0));
    PostToContext(Connection.Context, @ErrorTask, Call);
  end;
  Worker.Agent.Retire;
end;

function NativeSharedWorkerClose(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Worker: TSharedWorkerRecord;
begin
  Result := JsUndefined;
  Worker := WorkerOfAgentContext(ContextOfRealm(R));
  if Worker <> nil then
    Worker.Agent.Retire;
end;

procedure ContextEnded(Context: TBindingContext);
var
  WorkerIndex, Index: Integer;
  Worker: TSharedWorkerRecord;
begin
  for WorkerIndex := Workers.Count - 1 downto 0 do
  begin
    if WorkerIndex >= Workers.Count then
      Continue;
    Worker := TSharedWorkerRecord(Workers[WorkerIndex]);
    for Index := Worker.Connections.Count - 1 downto 0 do
      if TSharedWorkerConnection(Worker.Connections[Index]).Context = Context then
      begin
        TSharedWorkerConnection(Worker.Connections[Index]).Free;
        Worker.Connections.Delete(Index);
        if (Worker.Connections.Count = 0) and (Worker.Agent <> nil) then
        begin
          { Retiring frees the record. }
          Worker.Agent.Retire;
          Break;
        end;
      end;
  end;
end;

procedure DefineSharedWorkerNatives(Context: TBindingContext; Natives: TJsObject);
begin
  Context.Engine.DefineFunction(Natives, 'sharedWorkerConnect', @NativeSharedWorkerConnect, 4);
  Context.Engine.DefineFunction(Natives, 'sharedWorkerFailed', @NativeSharedWorkerFailed, 1);
  Context.Engine.DefineFunction(Natives, 'sharedWorkerClose', @NativeSharedWorkerClose, 0);
end;

initialization
  Workers := TList.Create;
  AddContextEndHook(@ContextEnded);
finalization
  while Workers.Count > 0 do
  begin
    if TSharedWorkerRecord(Workers[0]).Agent <> nil then
      TSharedWorkerRecord(Workers[0]).Agent.OnRetired := nil;
    TSharedWorkerRecord(Workers[0]).Free;
    Workers.Delete(0);
  end;
  FreeAndNil(Workers);
end.
