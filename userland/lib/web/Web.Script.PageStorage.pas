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
  A page's way to the storage service (IndexedDB, the Cache API,
  navigator.storage) for TPageScriptEnvironment: a TIndexedDbClient per
  script context, the backend the host gave (the browser's service in
  the program, or a content process's channel to it) or a service of
  its own in memory, and the tasks that deliver the service's notices
  and the platform scripts' queued tasks in the context's event loop.

  Notices may come from any thread (the browser's IPC thread runs the
  service for content processes): they are posted to the loop, and run
  only while the context lives. When the backend is a service in this
  program, its changes are written a second after a request (the
  service writes only origins that changed and have nothing
  uncommitted).
}
unit Web.Script.PageStorage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Web.EventLoop,
  Web.EventLoop.Tasks,
  Web.IndexedDb.Service;

type
  TContextLiveness = function(Context: TObject): Boolean of object;

  TPageStorage = class;

  TContextStorageClient = class(TIndexedDbClient)
  public
    Owner: TPageStorage;
    Context: TObject;
    Loop: TEventLoop;
    procedure Notice(const Payload: TBytes); override;
  end;

  TPageStorage = class
  private
    FBackend: TIndexedDbBackend;
    FOwnsBackend: Boolean;
    FClients: TList;
    FFlushScheduled: Boolean;
    FFlushHandle: QWord;
    function ClientOf(Context: TObject): TContextStorageClient;
    procedure SetBackend(Value: TIndexedDbBackend);
    procedure ScheduleFlush;
  public
    { The page's event loop (nil: notices are dropped, nothing queued). }
    Loop: TEventLoop;
    IsLive: TContextLiveness;
    constructor Create;
    destructor Destroy; override;
    function Backend: TIndexedDbBackend;
    { The host's backend when one was set (nil while the page has a
      service of its own): worker agents take it, so a service worker
      sees the caches and databases of its pages. }
    function SharedBackend: TIndexedDbBackend;
    function Execute(Context: TObject; const Origin: string; const Request: TBytes): TBytes;
    function QueueTask(Context: TObject; TaskId: Integer): Boolean;
    { The context is gone: its connections close, its transactions abort. }
    procedure ForgetContext(Context: TObject);
    { Writes what changed (a service of this program only). }
    procedure Flush;
    procedure FlushDue;
    { The host's backend (not owned; nil: a service in memory of the
      page's own). Set before the first request. }
    property HostBackend: TIndexedDbBackend read FBackend write SetBackend;
  end;

implementation

uses
  Js.Values,
  Js.Engine,
  Web.Bindings.Context;

const
  FlushDelay = 1000;

type
  TStorageNoticeTask = class(TWebTask)
  public
    Owner: TPageStorage;
    Context: TObject;
    Payload: TBytes;
    procedure Run; override;
  end;

  TStorageQueuedTask = class(TWebTask)
  public
    Owner: TPageStorage;
    Context: TObject;
    TaskId: Integer;
    procedure Run; override;
  end;

  TStorageFlushTask = class(TWebTask)
  public
    Owner: TPageStorage;
    procedure Run; override;
  end;

function LiveBindingContext(Owner: TPageStorage; Context: TObject): TBindingContext;
begin
  Result := nil;
  if not (Context is TBindingContext) then
    Exit;
  if Assigned(Owner.IsLive) and not Owner.IsLive(Context) then
    Exit;
  Result := TBindingContext(Context);
end;

procedure TStorageNoticeTask.Run;
var
  Target: TBindingContext;
  Bytes: TJsValue;
begin
  Target := LiveBindingContext(Owner, Context);
  if (Target = nil) or (Length(Payload) = 0) then
    Exit;
  Bytes := Target.Engine.NewUint8Array(@Payload[0], Length(Payload));
  Target.CallPlatform('onIndexedDbNotice', [Bytes]);
  Target.PerformMicrotaskCheckpoint;
end;

procedure TStorageQueuedTask.Run;
var
  Target: TBindingContext;
begin
  Target := LiveBindingContext(Owner, Context);
  if Target = nil then
    Exit;
  Target.CallPlatform('onQueuedTask', [JsInteger(TaskId)]);
  Target.PerformMicrotaskCheckpoint;
end;

procedure TStorageFlushTask.Run;
begin
  Owner.FlushDue;
end;

{ TContextStorageClient }

procedure TContextStorageClient.Notice(const Payload: TBytes);
var
  Task: TStorageNoticeTask;
begin
  if Loop = nil then
    Exit;
  Task := TStorageNoticeTask.Create;
  Task.Owner := Owner;
  Task.Context := Context;
  Task.Payload := Copy(Payload);
  Task.Source := TaskSourceDomManipulation;
  Task.Group := Context;
  Loop.PostTask(Task);
end;

{ TPageStorage }

constructor TPageStorage.Create;
begin
  inherited Create;
  FClients := TList.Create;
end;

destructor TPageStorage.Destroy;
var
  Index: Integer;
begin
  if (Loop <> nil) and FFlushScheduled then
    Loop.CancelScheduledTask(FFlushHandle);
  for Index := 0 to FClients.Count - 1 do
  begin
    if FBackend <> nil then
      FBackend.ClientClosed(TContextStorageClient(FClients[Index]));
    TContextStorageClient(FClients[Index]).Free;
  end;
  FClients.Free;
  Flush;
  if FOwnsBackend then
    FBackend.Free;
  inherited Destroy;
end;

procedure TPageStorage.SetBackend(Value: TIndexedDbBackend);
begin
  if Value = FBackend then
    Exit;
  if FOwnsBackend then
    FBackend.Free;
  FBackend := Value;
  FOwnsBackend := False;
end;

function TPageStorage.Backend: TIndexedDbBackend;
begin
  if FBackend = nil then
  begin
    FBackend := TIndexedDbService.Create('');
    FOwnsBackend := True;
  end;
  Result := FBackend;
end;

function TPageStorage.SharedBackend: TIndexedDbBackend;
begin
  if FOwnsBackend then
    Result := nil
  else
    Result := FBackend;
end;

function TPageStorage.ClientOf(Context: TObject): TContextStorageClient;
var
  Index: Integer;
begin
  for Index := 0 to FClients.Count - 1 do
    if TContextStorageClient(FClients[Index]).Context = Context then
      Exit(TContextStorageClient(FClients[Index]));
  Result := TContextStorageClient.Create;
  Result.Owner := Self;
  Result.Context := Context;
  Result.Loop := Loop;
  FClients.Add(Result);
end;

function TPageStorage.Execute(Context: TObject; const Origin: string; const Request: TBytes): TBytes;
var
  Client: TContextStorageClient;
begin
  Client := ClientOf(Context);
  Client.Loop := Loop;
  Result := Backend.Execute(Client, Origin, Request);
  if FBackend is TIndexedDbService then
    ScheduleFlush;
end;

function TPageStorage.QueueTask(Context: TObject; TaskId: Integer): Boolean;
var
  Task: TStorageQueuedTask;
begin
  Result := Loop <> nil;
  if not Result then
    Exit;
  Task := TStorageQueuedTask.Create;
  Task.Owner := Self;
  Task.Context := Context;
  Task.TaskId := TaskId;
  Loop.QueueTask(Task, TaskSourceDomManipulation, Context);
end;

procedure TPageStorage.ForgetContext(Context: TObject);
var
  Index: Integer;
  Client: TContextStorageClient;
begin
  for Index := FClients.Count - 1 downto 0 do
  begin
    Client := TContextStorageClient(FClients[Index]);
    if Client.Context <> Context then
      Continue;
    FClients.Delete(Index);
    if FBackend <> nil then
      FBackend.ClientClosed(Client);
    Client.Free;
  end;
end;

procedure TPageStorage.ScheduleFlush;
var
  Task: TStorageFlushTask;
begin
  if FFlushScheduled or (Loop = nil) then
    Exit;
  Task := TStorageFlushTask.Create;
  Task.Owner := Self;
  Task.Source := TaskSourceTimer;
  Task.Group := Self;
  FFlushHandle := Loop.ScheduleTask(Task, FlushDelay);
  FFlushScheduled := True;
end;

procedure TPageStorage.FlushDue;
begin
  FFlushScheduled := False;
  Flush;
end;

procedure TPageStorage.Flush;
begin
  if FBackend is TIndexedDbService then
    TIndexedDbService(FBackend).SaveAll;
end;

end.
