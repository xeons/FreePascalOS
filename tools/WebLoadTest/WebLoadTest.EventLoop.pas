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
  The event loop: tasks against microtasks, task sources, timers with a
  hand-driven clock (order, clearing, nesting clamps, intervals),
  animation frame callbacks, tasks posted from other threads, and
  dropping a group's tasks.
}
unit WebLoadTest.EventLoop;

{$mode objfpc}
{$H+}

interface

procedure RunEventLoopTests;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Web.EventLoop.Tasks,
  Web.EventLoop,
  Web.EventLoop.Timers,
  Web.EventLoop.AnimationFrames,
  Web.IdMaps;

type
  TManualClock = class
  public
    Value: Double;
    function Now: Double;
  end;

  TRecorder = class
  public
    Log: string;
    Loop: TEventLoop;
    Clock: TManualClock;
    Timers: TTimerList;
    Frames: TAnimationFrameList;
    Nested: Integer;
    procedure Add(const Text: string);
    procedure TaskA;
    procedure TaskB;
    procedure TaskC;
    procedure TaskUser;
    procedure MicroOne;
    procedure MicroTwo;
    procedure MicroNested;
    procedure TimerA;
    procedure TimerB;
    procedure TimerC;
    procedure TimerClearsC;
    procedure TimerNested;
    procedure TimerInterval;
  end;

  TLoggingTimer = class(TTimerHandler)
  public
    Recorder: TRecorder;
    Name: string;
    constructor Create(ARecorder: TRecorder; const AName: string);
    procedure Invoke; override;
  end;

  TFrameCallback = class(TAnimationFrameCallback)
  public
    Recorder: TRecorder;
    Name: string;
    RequestAnother: Boolean;
    CancelId: LongInt;
    constructor Create(ARecorder: TRecorder; const AName: string);
    procedure Invoke(Timestamp: Double); override;
  end;

  TPostingThread = class(TThread)
  private
    FLoop: TEventLoop;
    FRecorder: TRecorder;
  protected
    procedure Execute; override;
  public
    constructor Create(Loop: TEventLoop; Recorder: TRecorder);
  end;

  TNumberData = class
  public
    Number: Integer;
  end;

  TPostedSink = class
  public
    Numbers: array of Integer;
    procedure Take(Data: TObject);
  end;

var
  PostedSink: TPostedSink;

function TManualClock.Now: Double;
begin
  Result := Value;
end;

procedure TRecorder.Add(const Text: string);
begin
  if Log <> '' then
    Log := Log + ' ';
  Log := Log + Text;
end;

procedure TRecorder.TaskA;
begin
  Add('A');
  Loop.QueueMicrotaskMethod(@MicroOne);
  Loop.QueueMethod(@TaskC, TaskSourceDomManipulation);
end;

procedure TRecorder.TaskB;
begin
  Add('B');
end;

procedure TRecorder.TaskC;
begin
  Add('C');
end;

procedure TRecorder.TaskUser;
begin
  Add('U');
end;

procedure TRecorder.MicroOne;
begin
  Add('m1');
  Loop.QueueMicrotaskMethod(@MicroNested);
end;

procedure TRecorder.MicroTwo;
begin
  Add('m2');
end;

procedure TRecorder.MicroNested;
begin
  Add('mn');
end;

procedure TRecorder.TimerA;
begin
  Add('tA');
end;

procedure TRecorder.TimerB;
begin
  Add('tB');
  Loop.QueueMicrotaskMethod(@MicroTwo);
end;

procedure TRecorder.TimerC;
begin
  Add('tC');
end;

procedure TRecorder.TimerClearsC;
begin
  Add('clear');
  { Ids: tA is 1, tB 2, tC 3, this one 4. }
  Timers.ClearTimer(3);
end;

procedure TRecorder.TimerNested;
begin
  Inc(Nested);
  Add(IntToStr(Nested) + '@' + IntToStr(Round(Clock.Value)));
  if Nested < 8 then
    Timers.SetTimeout(TMethodTimerHandler.Create(@TimerNested), 0);
end;

procedure TRecorder.TimerInterval;
begin
  Inc(Nested);
  Add(IntToStr(Nested) + '@' + IntToStr(Round(Clock.Value)));
end;

constructor TLoggingTimer.Create(ARecorder: TRecorder; const AName: string);
begin
  inherited Create;
  Recorder := ARecorder;
  Name := AName;
end;

procedure TLoggingTimer.Invoke;
begin
  Recorder.Add(Name);
end;

constructor TFrameCallback.Create(ARecorder: TRecorder; const AName: string);
begin
  inherited Create;
  Recorder := ARecorder;
  Name := AName;
end;

procedure TFrameCallback.Invoke(Timestamp: Double);
begin
  Recorder.Add(Name + '@' + IntToStr(Round(Timestamp)));
  Recorder.Loop.QueueMicrotaskMethod(@Recorder.MicroTwo);
  if RequestAnother then
    Recorder.Frames.Request(TFrameCallback.Create(Recorder, Name + '+'));
  if CancelId <> 0 then
    Recorder.Frames.Cancel(CancelId);
end;

constructor TPostingThread.Create(Loop: TEventLoop; Recorder: TRecorder);
begin
  FLoop := Loop;
  FRecorder := Recorder;
  inherited Create(False);
end;

procedure TPostingThread.Execute;
var
  Index: Integer;
  Data: TNumberData;
begin
  for Index := 1 to 200 do
  begin
    Data := TNumberData.Create;
    Data.Number := Index;
    FLoop.PostMethod(@PostedSink.Take, Data, TaskSourceNetworking);
    if Index mod 50 = 0 then
      Sleep(1);
  end;
end;

procedure TPostedSink.Take(Data: TObject);
begin
  SetLength(Numbers, Length(Numbers) + 1);
  Numbers[High(Numbers)] := TNumberData(Data).Number;
end;

type
  TFrameClient = class(TRenderingClient)
  public
    Frames: TAnimationFrameList;
    Loop: TEventLoop;
    procedure UpdateRendering(ALoop: TEventLoop; Now: Double); override;
  end;

procedure TFrameClient.UpdateRendering(ALoop: TEventLoop; Now: Double);
begin
  Frames.Run(Now, @ALoop.PerformMicrotaskCheckpoint);
end;

procedure CheckTasksAndMicrotasks;
var
  Recorder: TRecorder;
  Loop: TEventLoop;
begin
  Recorder := TRecorder.Create;
  Loop := TEventLoop.Create;
  Recorder.Loop := Loop;
  try
    Loop.QueueMethod(@Recorder.TaskA, TaskSourceNetworking);
    Loop.QueueMethod(@Recorder.TaskB, TaskSourceDomManipulation);
    Loop.QueueMethod(@Recorder.TaskUser, TaskSourceUserInteraction);
    Check(Loop.RunPendingTasks = 4, 'event loop: four tasks ran');
    Check(Recorder.Log = 'U A m1 mn B C', 'event loop: user interaction first, microtasks after each task (' +
      Recorder.Log + ')');
    Check(not Loop.HasReadyTask, 'event loop: nothing left');
  finally
    Loop.Free;
    Recorder.Free;
  end;
end;

procedure CheckTimers;
var
  Recorder: TRecorder;
  Clock: TManualClock;
  Loop: TEventLoop;
  Timers: TTimerList;
  Index: Integer;
begin
  Recorder := TRecorder.Create;
  Clock := TManualClock.Create;
  Loop := TEventLoop.Create(@Clock.Now);
  Timers := TTimerList.Create(Loop, Recorder);
  Recorder.Loop := Loop;
  Recorder.Clock := Clock;
  Recorder.Timers := Timers;
  try
    Timers.SetTimeout(TMethodTimerHandler.Create(@Recorder.TimerA), 10);
    Timers.SetTimeout(TMethodTimerHandler.Create(@Recorder.TimerB), 0);
    Timers.SetTimeout(TMethodTimerHandler.Create(@Recorder.TimerC), 10);
    Timers.SetTimeout(TMethodTimerHandler.Create(@Recorder.TimerClearsC), 5);
    Loop.RunPendingTasks;
    Check(Recorder.Log = 'tB m2', 'timers: only the 0 ms one at once, its microtask after it (' + Recorder.Log + ')');
    Check(Abs(Loop.MillisecondsUntilNextTimer - 5) < 0.001, 'timers: next one in 5 ms');
    Clock.Value := 10;
    Loop.RunPendingTasks;
    Check(Recorder.Log = 'tB m2 clear tA', 'timers: due ones in order, a cleared one never runs (' + Recorder.Log + ')');
    Check(Timers.ActiveCount = 0, 'timers: none active');
    Check(Loop.MillisecondsUntilNextTimer < 0, 'timers: none scheduled');

    { Equal due times run in the order they were set. }
    Recorder.Log := '';
    Timers.SetTimeout(TLoggingTimer.Create(Recorder, 'x'), 3);
    Timers.SetTimeout(TLoggingTimer.Create(Recorder, 'y'), 1);
    Timers.SetTimeout(TLoggingTimer.Create(Recorder, 'z'), 3);
    Timers.SetTimeout(TLoggingTimer.Create(Recorder, 'w'), -5);
    Clock.Value := 20;
    Loop.RunPendingTasks;
    Check(Recorder.Log = 'w y x z', 'timers: by due time, then by order set; negative is 0 (' + Recorder.Log + ')');

    { Nesting: from the sixth nested level on, 0 ms becomes 4 ms. }
    Recorder.Log := '';
    Clock.Value := 100;
    Timers.SetTimeout(TMethodTimerHandler.Create(@Recorder.TimerNested), 0);
    while Recorder.Nested < 8 do
    begin
      Loop.RunPendingTasks;
      if Recorder.Nested < 8 then
        Clock.Value := Clock.Value + 1;
    end;
    Check(Recorder.Log = '1@100 2@100 3@100 4@100 5@100 6@100 7@104 8@108',
      'timers: nesting level above 5 clamps to 4 ms (' + Recorder.Log + ')');

    { An interval clamps from its sixth run on, and clearing stops it. }
    Recorder.Log := '';
    Recorder.Nested := 0;
    Clock.Value := 200;
    Timers.SetInterval(TMethodTimerHandler.Create(@Recorder.TimerInterval), 0);
    while Recorder.Nested < 8 do
    begin
      Loop.RunPendingTasks;
      if Recorder.Nested < 8 then
        Clock.Value := Clock.Value + 1;
    end;
    Check(Recorder.Log = '1@200 2@200 3@200 4@200 5@200 6@200 7@204 8@208',
      'timers: interval runs and clamps (' + Recorder.Log + ')');
    Check(Timers.ActiveCount = 1, 'timers: interval still active');
    Timers.ClearAll;
    Clock.Value := 300;
    Loop.RunPendingTasks;
    Check(Recorder.Nested = 8, 'timers: cleared interval stops');

    { Setting and clearing many timers keeps nothing. }
    for Index := 1 to 1000 do
      Timers.ClearTimer(Timers.SetTimeout(TLoggingTimer.Create(Recorder, 'never'), 100000));
    Check((Timers.ActiveCount = 0) and (Loop.MillisecondsUntilNextTimer < 0), 'timers: 1000 set and cleared');
  finally
    Timers.Free;
    Loop.Free;
    Clock.Free;
    Recorder.Free;
  end;
end;

procedure CheckAnimationFrames;
var
  Recorder: TRecorder;
  Clock: TManualClock;
  Loop: TEventLoop;
  Frames: TAnimationFrameList;
  Client: TFrameClient;
  First, Second, Third: TFrameCallback;
  ThirdId: LongInt;
begin
  Recorder := TRecorder.Create;
  Clock := TManualClock.Create;
  Loop := TEventLoop.Create(@Clock.Now);
  Frames := TAnimationFrameList.Create;
  Client := TFrameClient.Create;
  Client.Frames := Frames;
  Recorder.Loop := Loop;
  Recorder.Frames := Frames;
  Loop.AddRenderingClient(Client);
  try
    First := TFrameCallback.Create(Recorder, 'f1');
    First.RequestAnother := True;
    Second := TFrameCallback.Create(Recorder, 'f2');
    Third := TFrameCallback.Create(Recorder, 'f3');
    Frames.Request(First);
    Frames.Request(Second);
    ThirdId := Frames.Request(Third);
    Second.CancelId := ThirdId;
    Clock.Value := 16;
    Loop.RenderingOpportunity;
    Check(Recorder.Log = 'f1@16 m2 f2@16 m2', 'frames: microtasks after each callback, cancelled one skipped (' +
      Recorder.Log + ')');
    Check(Frames.Count = 1, 'frames: one requested during the frame waits');
    Recorder.Log := '';
    Clock.Value := 33;
    Loop.RenderingOpportunity;
    Check(Recorder.Log = 'f1+@33 m2', 'frames: next frame runs it (' + Recorder.Log + ')');
  finally
    Loop.Free;
    Frames.Free;
    Client.Free;
    Clock.Free;
    Recorder.Free;
  end;
end;

procedure CheckPostingAndDiscarding;
var
  Recorder: TRecorder;
  Loop: TEventLoop;
  Poster: TPostingThread;
  InOrder: Boolean;
  Index, Waits: Integer;
  Group: TObject;
  Task: TMethodTask;
begin
  Recorder := TRecorder.Create;
  Loop := TEventLoop.Create;
  PostedSink := TPostedSink.Create;
  Recorder.Loop := Loop;
  Group := TObject.Create;
  try
    Poster := TPostingThread.Create(Loop, Recorder);
    Waits := 0;
    while (Length(PostedSink.Numbers) < 200) and (Waits < 2000) do
    begin
      Loop.WaitForWork(50);
      Loop.RunPendingTasks;
      Inc(Waits);
    end;
    Poster.WaitFor;
    Poster.Free;
    InOrder := Length(PostedSink.Numbers) = 200;
    for Index := 0 to High(PostedSink.Numbers) do
      if PostedSink.Numbers[Index] <> Index + 1 then
        InOrder := False;
    Check(InOrder, 'event loop: 200 tasks posted from another thread arrive in order');

    Task := TMethodTask.Create(@Recorder.TaskB);
    Loop.QueueTask(Task, TaskSourceNetworking, Group);
    Loop.QueueMethod(@Recorder.TaskC, TaskSourceNetworking);
    Task := TMethodTask.Create(@Recorder.TaskB);
    Task.Source := TaskSourceTimer;
    Task.Group := Group;
    Loop.ScheduleTask(Task, 0);
    Loop.DiscardTasks(Group);
    Recorder.Log := '';
    Loop.RunPendingTasks;
    Check(Recorder.Log = 'C', 'event loop: a group''s tasks dropped (' + Recorder.Log + ')');
  finally
    Group.Free;
    PostedSink.Free;
    Loop.Free;
    Recorder.Free;
  end;
end;

procedure CheckIdMap;
var
  Map: TIdMap;
  Index: Integer;
  Value: TObject;
  Good: Boolean;
begin
  Map := TIdMap.Create;
  try
    for Index := 1 to 10000 do
      Map.Add(QWord(Index) * 7919, TObject(PtrUInt(Index)));
    for Index := 1 to 10000 do
      if Index mod 2 = 0 then
        Map.Remove(QWord(Index) * 7919);
    Good := Map.Count = 5000;
    for Index := 1 to 10000 do
      if Map.TryGetValue(QWord(Index) * 7919, Value) <> (Index mod 2 = 1) then
        Good := False
      else if (Index mod 2 = 1) and (PtrUInt(Value) <> PtrUInt(Index)) then
        Good := False;
    for Index := 1 to 100000 do
    begin
      Map.Add(QWord(Index) + 1000000000, nil);
      Map.Remove(QWord(Index) + 1000000000);
    end;
    Check(Good and (Map.Count = 5000) and (Length(Map.Keys) = 5000), 'id map: adds, removes, lookups');
  finally
    Map.Free;
  end;
end;

procedure RunEventLoopTests;
begin
  CheckIdMap;
  CheckTasksAndMicrotasks;
  CheckTimers;
  CheckAnimationFrames;
  CheckPostingAndDiscarding;
end;

end.
