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
  The event loop of a page (HTML Standard section 8.1.7), single
  threaded: everything of the page's documents runs on the thread that
  drives the loop (the page thread: a GUI thread or one of its own).

  - Task queues, one per task source (Web.EventLoop.Tasks). Each turn
    takes one task: the user interaction queue first, otherwise the
    oldest task of all queues, so tasks of one source run in order and
    sources are not starved.
  - The microtask queue, emptied by a microtask checkpoint after every
    task (and after every animation frame callback); the JavaScript
    engine's jobs go in as microtasks, and OnMicrotaskCheckpoint runs
    after the queue is empty (the engine's cleanup hook).
  - Delayed tasks (timers: Web.EventLoop.DelayedTasks): due ones move
    to their task queue (the timer task source) before a task is
    chosen.
  - Tasks from other threads (network completions) are posted with
    PostTask, which is thread safe: they wait in an inbox until the page
    thread takes them, and OnWake (called on the posting thread) lets a
    GUI thread post itself a message. WaitForWork blocks a dedicated
    page thread until a task is posted or a timer is due.
  - Rendering opportunities: the web view calls RenderingOpportunity
    when it can paint (a frame); the loop then runs the "update the
    rendering" steps of each rendering client (a document: resize and
    scroll steps, animation frame callbacks, then layout and paint).
    RequestRendering asks for one (OnRenderingRequested tells the view).

  The clock is in milliseconds and can be replaced (tests drive time by
  hand).

  Satellite loops: a loop that belongs to no page (a shared or service
  worker's agent, Web.Workers.Agents) calls MakeSatellite. Every other
  loop of the thread (a primary) then runs one of the satellites' ready
  tasks after each of its own, counts their tasks and timers in
  HasReadyTask and MillisecondsUntilNextTimer, and is woken when a task
  is posted to a satellite, so whatever drives the pages drives the
  workers too. SatelliteReaper (if set) runs before a primary takes a
  satellite's task, outside every satellite task: agents are freed
  there.
}
unit Web.EventLoop;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Web.EventLoop.Tasks,
  Web.EventLoop.DelayedTasks;

type
  TEventLoop = class;

  { Milliseconds from an arbitrary start, never going back. }
  TEventLoopClock = function: Double of object;

  { A document taking part in "update the rendering". }
  TRenderingClient = class
  public
    { The steps for one frame at Now (milliseconds of the loop's clock). }
    procedure UpdateRendering(Loop: TEventLoop; Now: Double); virtual; abstract;
  end;

  TEventLoop = class
  private
    FQueues: array[TTaskSource] of TTaskQueue;
    FMicrotasks: TTaskQueue;
    FDelayed: TDelayedTaskList;
    FInbox: TWebTaskArray;
    FInboxCount: Integer;
    FInboxLock: TRTLCriticalSection;
    FWakeEvent: PRTLEvent;
    FNextSequence: QWord;
    FClock: TEventLoopClock;
    FCurrentTask: TWebTask;
    FPerformingMicrotaskCheckpoint: Boolean;
    FRenderingClients: TList;
    FRenderingRequested: Boolean;
    FInRendering: Boolean;
    FOnWake: TNotifyEvent;
    FOnMicrotaskCheckpoint: TNotifyEvent;
    FOnRenderingRequested: TNotifyEvent;
    FOnTaskException: TNotifyEvent;
    FLastException: string;
    FTasksRun: QWord;
    FSatellite: Boolean;
    function DefaultClock: Double;
    function RunOwnTask: Boolean;
    function OwnReadyTask: Boolean;
    function OwnMillisecondsUntilNextTimer: Double;
    procedure WakeSelf;
    procedure TakeInbox;
    procedure QueueDueTimers;
    function ChooseQueue: TTaskQueue;
    procedure RunTask(Task: TWebTask);
    procedure ReportException(Error: Exception);
    function GetCurrentTimerNestingLevel: Integer;
  public
    constructor Create(Clock: TEventLoopClock = nil);
    destructor Destroy; override;
    function Now: Double;
    { Page thread: queues Task on Source (the loop owns it). }
    procedure QueueTask(Task: TWebTask; Source: TTaskSource; Group: Pointer = nil);
    procedure QueueMethod(Method: TTaskMethod; Source: TTaskSource; Group: Pointer = nil);
    { Any thread: Task (its Source and Group set) runs on the page thread. }
    procedure PostTask(Task: TWebTask);
    procedure PostMethod(Method: TTaskDataMethod; Data: TObject; Source: TTaskSource; Group: Pointer = nil);
    procedure QueueMicrotask(Task: TWebTask);
    procedure QueueMicrotaskMethod(Method: TTaskMethod);
    procedure PerformMicrotaskCheckpoint;
    { Task is queued on its source after DelayMilliseconds. }
    function ScheduleTask(Task: TWebTask; DelayMilliseconds: Double): QWord;
    function CancelScheduledTask(Handle: QWord): Boolean;
    { Frees every queued and scheduled task of Group (a document going). }
    procedure DiscardTasks(Group: Pointer);
    { One turn: the due timers queued, one task run, the microtasks.
      False when no task was ready. }
    function RunNextTask: Boolean;
    { Turns until no task is ready, or MaximumTasks (0: no limit) ran,
      or BudgetMilliseconds (0: no limit) passed. Tasks run. }
    function RunPendingTasks(MaximumTasks: Integer = 0; BudgetMilliseconds: Double = 0): Integer;
    function HasReadyTask: Boolean;
    { Milliseconds until the next timer is due (0 if one is), or -1. }
    function MillisecondsUntilNextTimer: Double;
    { Blocks until a task is posted or the next timer is due, at most
      TimeoutMilliseconds (negative: no limit). True if work is ready. }
    function WaitForWork(TimeoutMilliseconds: Integer): Boolean;
    { Any thread: wakes WaitForWork and calls OnWake. }
    procedure Wake;
    procedure AddRenderingClient(Client: TRenderingClient);
    procedure RemoveRenderingClient(Client: TRenderingClient);
    { A client wants a frame (an animation frame callback, a change). }
    procedure RequestRendering;
    { The web view can paint now: "update the rendering". }
    procedure RenderingOpportunity;
    { This loop stops being a primary and becomes a satellite (above). }
    procedure MakeSatellite;
    property Satellite: Boolean read FSatellite;
    property CurrentTask: TWebTask read FCurrentTask;
    { The running timer task's nesting level, 0 outside timers. }
    property CurrentTimerNestingLevel: Integer read GetCurrentTimerNestingLevel;
    property RenderingRequested: Boolean read FRenderingRequested;
    property TasksRun: QWord read FTasksRun;
    { Called on the posting thread when a task arrives from PostTask. }
    property OnWake: TNotifyEvent read FOnWake write FOnWake;
    { After each microtask checkpoint emptied the queue. }
    property OnMicrotaskCheckpoint: TNotifyEvent read FOnMicrotaskCheckpoint write FOnMicrotaskCheckpoint;
    property OnRenderingRequested: TNotifyEvent read FOnRenderingRequested write FOnRenderingRequested;
    { A task raised an exception (the loop goes on); LastException has it. }
    property OnTaskException: TNotifyEvent read FOnTaskException write FOnTaskException;
    property LastException: string read FLastException;
  end;

  TSatelliteReaper = procedure;

var
  { Runs before primaries take satellites' tasks (see above). }
  SatelliteReaper: TSatelliteReaper;

implementation

uses
  Web.Profiling;

var
  { Every loop of the process, primaries and satellites apart; the lock
    guards the lists (Wake comes from any thread). }
  LoopListLock: TRTLCriticalSection;
  PrimaryLoops: TList;
  SatelliteLoops: TList;
  NextSatellite: Integer;

{ The satellites in order, from the round-robin position on. }
function SatelliteSnapshot: TList;
var
  Index, Count: Integer;
begin
  Result := TList.Create;
  EnterCriticalSection(LoopListLock);
  try
    Count := SatelliteLoops.Count;
    for Index := 0 to Count - 1 do
      Result.Add(SatelliteLoops[(NextSatellite + Index) mod Count]);
  finally
    LeaveCriticalSection(LoopListLock);
  end;
end;

function SatelliteAlive(Loop: TEventLoop): Boolean;
begin
  EnterCriticalSection(LoopListLock);
  try
    Result := SatelliteLoops.IndexOf(Loop) >= 0;
  finally
    LeaveCriticalSection(LoopListLock);
  end;
end;

constructor TEventLoop.Create(Clock: TEventLoopClock);
var
  Source: TTaskSource;
begin
  inherited Create;
  for Source := Low(TTaskSource) to High(TTaskSource) do
    FQueues[Source] := TTaskQueue.Create;
  FMicrotasks := TTaskQueue.Create;
  FDelayed := TDelayedTaskList.Create;
  InitCriticalSection(FInboxLock);
  FWakeEvent := RTLEventCreate;
  FRenderingClients := TList.Create;
  if Assigned(Clock) then
    FClock := Clock
  else
    FClock := @DefaultClock;
  EnterCriticalSection(LoopListLock);
  PrimaryLoops.Add(Self);
  LeaveCriticalSection(LoopListLock);
end;

destructor TEventLoop.Destroy;
var
  Source: TTaskSource;
  Index: Integer;
begin
  EnterCriticalSection(LoopListLock);
  PrimaryLoops.Remove(Self);
  SatelliteLoops.Remove(Self);
  LeaveCriticalSection(LoopListLock);
  EnterCriticalSection(FInboxLock);
  for Index := 0 to FInboxCount - 1 do
    FInbox[Index].Free;
  FInboxCount := 0;
  LeaveCriticalSection(FInboxLock);
  for Source := Low(TTaskSource) to High(TTaskSource) do
    FQueues[Source].Free;
  FMicrotasks.Free;
  FDelayed.Free;
  FRenderingClients.Free;
  RTLEventDestroy(FWakeEvent);
  DoneCriticalSection(FInboxLock);
  inherited Destroy;
end;

function TEventLoop.DefaultClock: Double;
begin
  Result := GetTickCount64;
end;

function TEventLoop.Now: Double;
begin
  Result := FClock();
end;

procedure TEventLoop.QueueTask(Task: TWebTask; Source: TTaskSource; Group: Pointer);
begin
  Task.Source := Source;
  if Group <> nil then
    Task.Group := Group;
  Inc(FNextSequence);
  Task.Sequence := FNextSequence;
  FQueues[Source].Push(Task);
end;

procedure TEventLoop.QueueMethod(Method: TTaskMethod; Source: TTaskSource; Group: Pointer);
begin
  QueueTask(TMethodTask.Create(Method), Source, Group);
end;

procedure TEventLoop.PostTask(Task: TWebTask);
begin
  EnterCriticalSection(FInboxLock);
  try
    if FInboxCount = Length(FInbox) then
      SetLength(FInbox, FInboxCount * 2 + 16);
    FInbox[FInboxCount] := Task;
    Inc(FInboxCount);
  finally
    LeaveCriticalSection(FInboxLock);
  end;
  Wake;
end;

procedure TEventLoop.PostMethod(Method: TTaskDataMethod; Data: TObject; Source: TTaskSource; Group: Pointer);
var
  Task: TDataTask;
begin
  Task := TDataTask.Create(Method, Data);
  Task.Source := Source;
  Task.Group := Group;
  PostTask(Task);
end;

procedure TEventLoop.WakeSelf;
begin
  RTLEventSetEvent(FWakeEvent);
  if Assigned(FOnWake) then
    FOnWake(Self);
end;

procedure TEventLoop.Wake;
var
  Primaries: array of TEventLoop;
  Index: Integer;
begin
  if not FSatellite then
  begin
    WakeSelf;
    Exit;
  end;
  { A satellite's work is done by the primaries: wake them all. }
  Primaries := nil;
  EnterCriticalSection(LoopListLock);
  try
    SetLength(Primaries, PrimaryLoops.Count);
    for Index := 0 to PrimaryLoops.Count - 1 do
      Primaries[Index] := TEventLoop(PrimaryLoops[Index]);
    { Woken under the lock: a loop cannot be freed meanwhile. }
    for Index := 0 to High(Primaries) do
      Primaries[Index].WakeSelf;
  finally
    LeaveCriticalSection(LoopListLock);
  end;
end;

procedure TEventLoop.MakeSatellite;
begin
  if FSatellite then
    Exit;
  EnterCriticalSection(LoopListLock);
  try
    PrimaryLoops.Remove(Self);
    SatelliteLoops.Add(Self);
    FSatellite := True;
  finally
    LeaveCriticalSection(LoopListLock);
  end;
end;

procedure TEventLoop.TakeInbox;
var
  Taken: TWebTaskArray;
  Count, Index: Integer;
begin
  EnterCriticalSection(FInboxLock);
  try
    Taken := FInbox;
    Count := FInboxCount;
    FInbox := nil;
    FInboxCount := 0;
  finally
    LeaveCriticalSection(FInboxLock);
  end;
  for Index := 0 to Count - 1 do
    QueueTask(Taken[Index], Taken[Index].Source);
end;

procedure TEventLoop.QueueMicrotask(Task: TWebTask);
begin
  FMicrotasks.Push(Task);
end;

procedure TEventLoop.QueueMicrotaskMethod(Method: TTaskMethod);
begin
  FMicrotasks.Push(TMethodTask.Create(Method));
end;

procedure TEventLoop.PerformMicrotaskCheckpoint;
var
  Task: TWebTask;
begin
  if FPerformingMicrotaskCheckpoint then
    Exit;
  FPerformingMicrotaskCheckpoint := True;
  try
    while FMicrotasks.Count > 0 do
    begin
      Task := FMicrotasks.Pop;
      try
        try
          Task.Run;
        except
          on Error: Exception do
            ReportException(Error);
        end;
      finally
        Task.Free;
      end;
    end;
    if Assigned(FOnMicrotaskCheckpoint) then
      FOnMicrotaskCheckpoint(Self);
  finally
    FPerformingMicrotaskCheckpoint := False;
  end;
end;

function TEventLoop.ScheduleTask(Task: TWebTask; DelayMilliseconds: Double): QWord;
begin
  if DelayMilliseconds < 0 then
    DelayMilliseconds := 0;
  Result := FDelayed.Add(Task, Now + DelayMilliseconds);
end;

function TEventLoop.CancelScheduledTask(Handle: QWord): Boolean;
begin
  Result := FDelayed.Cancel(Handle);
end;

procedure TEventLoop.DiscardTasks(Group: Pointer);
var
  Source: TTaskSource;
begin
  TakeInbox;
  for Source := Low(TTaskSource) to High(TTaskSource) do
    FQueues[Source].Discard(Group);
  FDelayed.Discard(Group);
end;

procedure TEventLoop.QueueDueTimers;
var
  Task: TWebTask;
  Moment: Double;
begin
  Moment := Now;
  Task := FDelayed.TakeDue(Moment);
  while Task <> nil do
  begin
    QueueTask(Task, Task.Source);
    Task := FDelayed.TakeDue(Moment);
  end;
end;

function TEventLoop.ChooseQueue: TTaskQueue;
var
  Source: TTaskSource;
  Head: TWebTask;
  Oldest: QWord;
begin
  if FQueues[TaskSourceUserInteraction].Count > 0 then
    Exit(FQueues[TaskSourceUserInteraction]);
  Result := nil;
  Oldest := High(QWord);
  for Source := Succ(TaskSourceUserInteraction) to High(TTaskSource) do
  begin
    Head := FQueues[Source].Peek;
    if (Head <> nil) and (Head.Sequence < Oldest) then
    begin
      Oldest := Head.Sequence;
      Result := FQueues[Source];
    end;
  end;
end;

procedure TEventLoop.ReportException(Error: Exception);
begin
  FLastException := Error.ClassName + ': ' + Error.Message;
  if Assigned(FOnTaskException) then
    FOnTaskException(Self);
end;

procedure TEventLoop.RunTask(Task: TWebTask);
var
  Previous: TWebTask;
begin
  Previous := FCurrentTask;
  FCurrentTask := Task;
  EnterPhase(PhaseTask);
  try
    try
      Task.Run;
    except
      on Error: Exception do
        ReportException(Error);
    end;
  finally
    LeavePhase;
    FCurrentTask := Previous;
    Task.Free;
  end;
  Inc(FTasksRun);
  PerformMicrotaskCheckpoint;
end;

function TEventLoop.RunNextTask: Boolean;
var
  Satellites: TList;
  Index: Integer;
begin
  Result := RunOwnTask;
  if FSatellite then
    Exit;
  if Assigned(SatelliteReaper) then
    SatelliteReaper();
  if SatelliteLoops.Count = 0 then
    Exit;
  Satellites := SatelliteSnapshot;
  try
    for Index := 0 to Satellites.Count - 1 do
      if SatelliteAlive(TEventLoop(Satellites[Index])) and TEventLoop(Satellites[Index]).RunOwnTask then
      begin
        EnterCriticalSection(LoopListLock);
        Inc(NextSatellite);
        LeaveCriticalSection(LoopListLock);
        Exit(True);
      end;
  finally
    Satellites.Free;
  end;
end;

function TEventLoop.RunOwnTask: Boolean;
var
  Queue: TTaskQueue;
begin
  TakeInbox;
  QueueDueTimers;
  Queue := ChooseQueue;
  if Queue = nil then
  begin
    PerformMicrotaskCheckpoint;
    Exit(False);
  end;
  RunTask(Queue.Pop);
  Result := True;
end;

function TEventLoop.RunPendingTasks(MaximumTasks: Integer; BudgetMilliseconds: Double): Integer;
var
  Started: Double;
begin
  Result := 0;
  Started := Now;
  while RunNextTask do
  begin
    Inc(Result);
    if (MaximumTasks > 0) and (Result >= MaximumTasks) then
      Break;
    if (BudgetMilliseconds > 0) and (Now - Started >= BudgetMilliseconds) then
      Break;
  end;
end;

function TEventLoop.HasReadyTask: Boolean;
var
  Satellites: TList;
  Index: Integer;
begin
  Result := OwnReadyTask;
  if Result or FSatellite or (SatelliteLoops.Count = 0) then
    Exit;
  Satellites := SatelliteSnapshot;
  try
    for Index := 0 to Satellites.Count - 1 do
      if TEventLoop(Satellites[Index]).OwnReadyTask then
        Exit(True);
  finally
    Satellites.Free;
  end;
end;

function TEventLoop.OwnReadyTask: Boolean;
var
  Source: TTaskSource;
  Due: Double;
begin
  TakeInbox;
  for Source := Low(TTaskSource) to High(TTaskSource) do
    if FQueues[Source].Count > 0 then
      Exit(True);
  Result := FDelayed.NextDue(Due) and (Due <= Now);
end;

function TEventLoop.MillisecondsUntilNextTimer: Double;
var
  Satellites: TList;
  Index: Integer;
  Wait: Double;
begin
  Result := OwnMillisecondsUntilNextTimer;
  if FSatellite or (SatelliteLoops.Count = 0) then
    Exit;
  Satellites := SatelliteSnapshot;
  try
    for Index := 0 to Satellites.Count - 1 do
    begin
      Wait := TEventLoop(Satellites[Index]).OwnMillisecondsUntilNextTimer;
      if (Wait >= 0) and ((Result < 0) or (Wait < Result)) then
        Result := Wait;
    end;
  finally
    Satellites.Free;
  end;
end;

function TEventLoop.OwnMillisecondsUntilNextTimer: Double;
var
  Due: Double;
begin
  if not FDelayed.NextDue(Due) then
    Exit(-1);
  Result := Due - Now;
  if Result < 0 then
    Result := 0;
end;

function TEventLoop.WaitForWork(TimeoutMilliseconds: Integer): Boolean;
var
  Wait: Double;
begin
  if HasReadyTask then
    Exit(True);
  Wait := MillisecondsUntilNextTimer;
  if (TimeoutMilliseconds >= 0) and ((Wait < 0) or (Wait > TimeoutMilliseconds)) then
    Wait := TimeoutMilliseconds;
  if Wait < 0 then
    RTLEventWaitFor(FWakeEvent)
  else if Wait > 0 then
    RTLEventWaitFor(FWakeEvent, Trunc(Wait) + 1);
  RTLEventResetEvent(FWakeEvent);
  Result := HasReadyTask;
end;

function TEventLoop.GetCurrentTimerNestingLevel: Integer;
begin
  if (FCurrentTask <> nil) and (FCurrentTask.Source = TaskSourceTimer) then
    Result := FCurrentTask.TimerNestingLevel
  else
    Result := 0;
end;

procedure TEventLoop.AddRenderingClient(Client: TRenderingClient);
begin
  if FRenderingClients.IndexOf(Client) < 0 then
    FRenderingClients.Add(Client);
end;

procedure TEventLoop.RemoveRenderingClient(Client: TRenderingClient);
begin
  FRenderingClients.Remove(Client);
end;

procedure TEventLoop.RequestRendering;
begin
  if FRenderingRequested then
    Exit;
  FRenderingRequested := True;
  if Assigned(FOnRenderingRequested) then
    FOnRenderingRequested(Self);
end;

procedure TEventLoop.RenderingOpportunity;
var
  Clients: array of TRenderingClient;
  Index: Integer;
  Moment: Double;
begin
  if FInRendering then
    Exit;
  FInRendering := True;
  try
    FRenderingRequested := False;
    Moment := Now;
    Clients := nil;
    SetLength(Clients, FRenderingClients.Count);
    for Index := 0 to FRenderingClients.Count - 1 do
      Clients[Index] := TRenderingClient(FRenderingClients[Index]);
    for Index := 0 to High(Clients) do
      if FRenderingClients.IndexOf(Clients[Index]) >= 0 then
      begin
        try
          Clients[Index].UpdateRendering(Self, Moment);
        except
          on Error: Exception do
            ReportException(Error);
        end;
        PerformMicrotaskCheckpoint;
      end;
  finally
    FInRendering := False;
  end;
end;

initialization
  InitCriticalSection(LoopListLock);
  PrimaryLoops := TList.Create;
  SatelliteLoops := TList.Create;
finalization
  PrimaryLoops.Free;
  SatelliteLoops.Free;
  DoneCriticalSection(LoopListLock);
end.
