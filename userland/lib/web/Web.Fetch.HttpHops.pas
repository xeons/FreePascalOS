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
  One HTTP exchange of a fetch (a "hop": the request, a redirect's next
  request, or a CORS preflight) run by libhttp's fetch tasks on their
  own threads. The task's callbacks copy what they get (the head, each
  piece of the body, the outcome) into messages posted to the page's
  event loop on the networking task source; the page thread then works
  on them. Redirects are not followed by libhttp (the fetcher decides
  each one: CORS, mixed content and HSTS apply per hop).
}
unit Web.Fetch.HttpHops;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records,
  Http.Client,
  Http.FetchTasks,
  Http.HeaderFields,
  Http.Messages,
  Http.Connections,
  Http.Results,
  Web.EventLoop.Tasks,
  Web.EventLoop;

type
  THopHeadMessage = class
  public
    HopId: QWord;
    Status: Integer;
    Reason: string;
    Fields: THttpHeaderFieldArray;
    Url: TUrlRecord;
    FromCache: Boolean;
    Protocol: string;
  end;

  THopDataMessage = class
  public
    HopId: QWord;
    Bytes: TBytes;
  end;

  THopDoneMessage = class
  public
    HopId: QWord;
    Outcome: THttpResult;
  end;

  THopHeadEvent = procedure(Message: THopHeadMessage) of object;
  THopDataEvent = procedure(Message: THopDataMessage) of object;
  THopDoneEvent = procedure(Message: THopDoneMessage) of object;

  { A hop waiting for a thread. }
  THopQueued = class
  public
    Client: THttpClient;
    Request: THttpRequest;
    HopId: QWord;
  end;

  { Starts hops and posts their results; Group is the fetcher (so its
    pending messages can be dropped when it goes). At most
    MaximumRunningHops run at once, each on a thread of its own; the
    others wait in order (urgent ones - documents, style sheets,
    scripts, fonts - ahead of the rest). A hop whose thread cannot be
    made fails like a network error. }
  THopRunner = class
  private
    FLoop: TEventLoop;
    FGroup: Pointer;
    FOnHead: THopHeadEvent;
    FOnData: THopDataEvent;
    FOnDone: THopDoneEvent;
    FLock: TRTLCriticalSection;
    FTasks: TList;
    FQueue: TList;
    FUrgentCount: Integer;
    procedure Launch(Client: THttpClient; Request: THttpRequest; HopId: QWord);
    procedure StartQueued;
    procedure PostDone(HopId: QWord; constref Outcome: THttpResult);
    procedure TaskHead(Task: THttpFetchTask; Response: THttpResponse);
    procedure TaskData(Task: THttpFetchTask; Data: Pointer; Count: PtrUInt);
    procedure TaskDone(Task: THttpFetchTask; constref Outcome: THttpResult);
    procedure DeliverHead(Data: TObject);
    procedure DeliverData(Data: TObject);
    procedure DeliverDone(Data: TObject);
    function FindTask(HopId: QWord): THttpFetchTask;
  public
    constructor Create(Loop: TEventLoop; Group: Pointer; OnHead: THopHeadEvent; OnData: THopDataEvent;
      OnDone: THopDoneEvent);
    { Cancels and frees every task (waiting for their threads). }
    destructor Destroy; override;
    { Starts Request (taken over) on Client as hop HopId, or queues it. }
    procedure Start(Client: THttpClient; Request: THttpRequest; HopId: QWord; Urgent: Boolean = False);
    { From the page thread: stop the hop (its done message still comes). }
    procedure Cancel(HopId: QWord);
    { After its done message: the task's thread is over, free it. }
    procedure Release(HopId: QWord);
    function RunningCount: Integer;
  end;

const
  MaximumRunningHops = 12;

function ProtocolName(Protocol: THttpProtocol): string;

implementation

function ProtocolName(Protocol: THttpProtocol): string;
begin
  case Protocol of
    HttpProtocol11: Result := 'http/1.1';
    HttpProtocol2: Result := 'h2';
    HttpProtocol3: Result := 'h3';
  else
    Result := '';
  end;
end;

constructor THopRunner.Create(Loop: TEventLoop; Group: Pointer; OnHead: THopHeadEvent; OnData: THopDataEvent;
  OnDone: THopDoneEvent);
begin
  inherited Create;
  FLoop := Loop;
  FGroup := Group;
  FOnHead := OnHead;
  FOnData := OnData;
  FOnDone := OnDone;
  InitCriticalSection(FLock);
  FTasks := TList.Create;
  FQueue := TList.Create;
end;

destructor THopRunner.Destroy;
var
  Index: Integer;
  Tasks: array of THttpFetchTask;
begin
  EnterCriticalSection(FLock);
  try
    Tasks := nil;
    SetLength(Tasks, FTasks.Count);
    for Index := 0 to FTasks.Count - 1 do
      Tasks[Index] := THttpFetchTask(FTasks[Index]);
    FTasks.Clear;
  finally
    LeaveCriticalSection(FLock);
  end;
  for Index := 0 to High(Tasks) do
    Tasks[Index].Free;
  FTasks.Free;
  for Index := 0 to FQueue.Count - 1 do
  begin
    THopQueued(FQueue[Index]).Request.Free;
    THopQueued(FQueue[Index]).Free;
  end;
  FQueue.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure THopRunner.PostDone(HopId: QWord; constref Outcome: THttpResult);
var
  Message: THopDoneMessage;
begin
  Message := THopDoneMessage.Create;
  Message.HopId := HopId;
  Message.Outcome := Outcome;
  FLoop.PostMethod(@DeliverDone, Message, TaskSourceNetworking, FGroup);
end;

{ On the page thread, the lock not held. }
procedure THopRunner.Launch(Client: THttpClient; Request: THttpRequest; HopId: QWord);
var
  Task: THttpFetchTask;
begin
  { The task starts at once; it is listed under the lock before its
    callbacks can look for it. }
  EnterCriticalSection(FLock);
  try
    try
      Task := THttpFetchTask.Create(Client, Request, @TaskHead, @TaskData, @TaskDone, PtrInt(HopId));
      FTasks.Add(Task);
    except
      on Error: Exception do
      begin
        { No thread for it (the system is out of them): a network error. }
        Request.Free;
        PostDone(HopId, HttpFailure(HttpConnectFailed, 'cannot start the request: ' + Error.Message));
      end;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THopRunner.Start(Client: THttpClient; Request: THttpRequest; HopId: QWord; Urgent: Boolean);
var
  Queued: THopQueued;
begin
  if (RunningCount < MaximumRunningHops) and (FQueue.Count = 0) then
  begin
    Launch(Client, Request, HopId);
    Exit;
  end;
  Queued := THopQueued.Create;
  Queued.Client := Client;
  Queued.Request := Request;
  Queued.HopId := HopId;
  if Urgent then
  begin
    FQueue.Insert(FUrgentCount, Queued);
    Inc(FUrgentCount);
  end
  else
    FQueue.Add(Queued);
  StartQueued;
end;

{ Starts waiting hops while there is room. }
procedure THopRunner.StartQueued;
var
  Queued: THopQueued;
begin
  while (FQueue.Count > 0) and (RunningCount < MaximumRunningHops) do
  begin
    Queued := THopQueued(FQueue[0]);
    FQueue.Delete(0);
    if FUrgentCount > 0 then
      Dec(FUrgentCount);
    Launch(Queued.Client, Queued.Request, Queued.HopId);
    Queued.Free;
  end;
end;

function THopRunner.FindTask(HopId: QWord): THttpFetchTask;
var
  Index: Integer;
begin
  for Index := 0 to FTasks.Count - 1 do
    if QWord(THttpFetchTask(FTasks[Index]).Tag) = HopId then
      Exit(THttpFetchTask(FTasks[Index]));
  Result := nil;
end;

procedure THopRunner.Cancel(HopId: QWord);
var
  Task: THttpFetchTask;
  Index: Integer;
begin
  for Index := 0 to FQueue.Count - 1 do
    if THopQueued(FQueue[Index]).HopId = HopId then
    begin
      { Never started: its done message comes now. }
      THopQueued(FQueue[Index]).Request.Free;
      THopQueued(FQueue[Index]).Free;
      FQueue.Delete(Index);
      if Index < FUrgentCount then
        Dec(FUrgentCount);
      PostDone(HopId, HttpFailure(HttpCanceled, 'canceled'));
      Exit;
    end;
  EnterCriticalSection(FLock);
  try
    Task := FindTask(HopId);
    if Task <> nil then
      Task.Cancel;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THopRunner.Release(HopId: QWord);
var
  Task: THttpFetchTask;
begin
  EnterCriticalSection(FLock);
  try
    Task := FindTask(HopId);
    if Task <> nil then
      FTasks.Remove(Task);
  finally
    LeaveCriticalSection(FLock);
  end;
  Task.Free;
  StartQueued;
end;

function THopRunner.RunningCount: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FTasks.Count;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THopRunner.TaskHead(Task: THttpFetchTask; Response: THttpResponse);
var
  Message: THopHeadMessage;
begin
  Message := THopHeadMessage.Create;
  Message.HopId := QWord(Task.Tag);
  Message.Status := Response.Status;
  Message.Reason := Response.Reason;
  Message.Fields := Response.Headers.FieldArray;
  Message.Url := Response.Url;
  Message.FromCache := Response.FromCache;
  Message.Protocol := ProtocolName(Response.Protocol);
  FLoop.PostMethod(@DeliverHead, Message, TaskSourceNetworking, FGroup);
end;

procedure THopRunner.TaskData(Task: THttpFetchTask; Data: Pointer; Count: PtrUInt);
var
  Message: THopDataMessage;
begin
  if Count = 0 then
    Exit;
  Message := THopDataMessage.Create;
  Message.HopId := QWord(Task.Tag);
  SetLength(Message.Bytes, Count);
  Move(Data^, Message.Bytes[0], Count);
  FLoop.PostMethod(@DeliverData, Message, TaskSourceNetworking, FGroup);
end;

procedure THopRunner.TaskDone(Task: THttpFetchTask; constref Outcome: THttpResult);
begin
  PostDone(QWord(Task.Tag), Outcome);
end;

procedure THopRunner.DeliverHead(Data: TObject);
begin
  FOnHead(THopHeadMessage(Data));
end;

procedure THopRunner.DeliverData(Data: TObject);
begin
  FOnData(THopDataMessage(Data));
end;

procedure THopRunner.DeliverDone(Data: TObject);
begin
  FOnDone(THopDoneMessage(Data));
end;

end.
