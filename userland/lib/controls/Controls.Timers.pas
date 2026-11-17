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
  Timers: OnTimer every Interval milliseconds while Enabled, run by the
  message loop like everything else a window hears.

  However many timers a program makes, they share one kernel timer,
  which the message loop waits on as one of the program's own handles
  (Windowing.HandleWatches): it is set for whichever timer is due
  first (Controls.TimerQueue), so timers take nothing from the loop's
  window timers (of which there are only 32) and need no window. A
  timer keeps its rhythm (each tick an interval after the last one was
  due), and ticks missed while the program was busy are skipped rather
  than run in a burst.

  A timer's Owner (a window or a control, optional) has its display's
  scale selected before OnTimer runs, as for a message to it, so OnTimer
  may lay out and draw in pixels. The timer must be freed before its
  owner is.
}
unit Controls.Timers;

{$mode objfpc}

interface

uses
  Windowing.Messages;

const
  DefaultTimerInterval = 1000;

type
  TTimer = class;
  TTimerEvent = procedure(Sender: TTimer) of object;

  TTimer = class
  private
    FOwner: TMessageReceiver;
    FInterval: LongWord;
    FEnabled: Boolean;
    FDue: QWord;
    FTag: PtrInt;
    FOnTimer: TTimerEvent;
    procedure SetInterval(Value: LongWord);
    procedure SetEnabled(Value: Boolean);
    procedure Restart;
  protected
    { Runs OnTimer. }
    procedure Timer; virtual;
  public
    { Enabled, every DefaultTimerInterval milliseconds. }
    constructor Create(AOwner: TMessageReceiver = nil);
    destructor Destroy; override;
    { For the shared kernel timer: the timer was due at Now or before. }
    procedure Fire(Now: QWord);
    { Enabled := True, counting the interval from now. }
    procedure Start;
    procedure Stop;
    property Owner: TMessageReceiver read FOwner write FOwner;
    { Milliseconds; 0 stops it. Changing it starts counting again. }
    property Interval: LongWord read FInterval write SetInterval;
    property Enabled: Boolean read FEnabled write SetEnabled;
    { The program's own, for anything. }
    property Tag: PtrInt read FTag write FTag;
    property OnTimer: TTimerEvent read FOnTimer write FOnTimer;
  end;

{ Milliseconds since the system started: the timers' clock. }
function TimerClock: QWord;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Objects,
  Windowing.HandleWatches,
  Controls.TimerQueue;

type
  { Hears the shared kernel timer (a handle watch's handler is a method). }
  TTimerDispatcher = class
  public
    procedure HandleReady(Handle: Int64);
  end;

var
  Queue: TTimerQueue;
  Dispatcher: TTimerDispatcher;
  KernelTimer: Int64 = -1;

function TimerClock: QWord;
begin
  Result := QWord(KernelGetTime(TimeUptimeMilliseconds));
end;

function KernelTimerReady: Boolean;
begin
  if KernelTimer >= 0 then
    Exit(True);
  KernelTimer := CreateTimer(False);
  if KernelTimer < 0 then
    Exit(False);
  if Dispatcher = nil then
    Dispatcher := TTimerDispatcher.Create;
  if not WatchHandle(KernelTimer, @Dispatcher.HandleReady) then
  begin
    CloseHandle(KernelTimer);
    KernelTimer := -1;
    Exit(False);
  end;
  Result := True;
end;

{ Sets the kernel timer for the earliest timer due (stops it if none). }
procedure ArmKernelTimer;
var
  Due: QWord;
  Now: QWord;
  Delay: QWord;
begin
  if (Queue = nil) or not Queue.NextDue(Due) then
  begin
    if KernelTimer >= 0 then
      SetTimer(KernelTimer, 0, 0);
    Exit;
  end;
  if not KernelTimerReady then
    Exit;
  Now := TimerClock;
  { (A due time of 0 would stop it.) }
  Delay := 1;
  if Due > Now then
    Delay := Due - Now;
  SetTimer(KernelTimer, Delay, 0);
end;

procedure TTimerDispatcher.HandleReady(Handle: Int64);
var
  Now: QWord;
  Client: TObject;
begin
  Now := TimerClock;
  while Queue.TakeDue(Now, Client) do
    TTimer(Client).Fire(Now);
  ArmKernelTimer;
end;

{ --- TTimer ------------------------------------------------------------------ }

constructor TTimer.Create(AOwner: TMessageReceiver);
begin
  inherited Create;
  FOwner := AOwner;
  FInterval := DefaultTimerInterval;
  FEnabled := True;
  Restart;
end;

destructor TTimer.Destroy;
begin
  FEnabled := False;
  Restart;
  inherited Destroy;
end;

{ In the queue an interval from now while it runs, out of it otherwise. }
procedure TTimer.Restart;
begin
  if Queue = nil then
    Queue := TTimerQueue.Create;
  if FEnabled and (FInterval > 0) then
  begin
    FDue := TimerClock + FInterval;
    Queue.Schedule(Self, FDue);
  end
  else
    Queue.Cancel(Self);
  ArmKernelTimer;
end;

procedure TTimer.SetInterval(Value: LongWord);
begin
  FInterval := Value;
  Restart;
end;

procedure TTimer.SetEnabled(Value: Boolean);
begin
  if FEnabled = Value then
    Exit;
  FEnabled := Value;
  Restart;
end;

procedure TTimer.Start;
begin
  FEnabled := True;
  Restart;
end;

procedure TTimer.Stop;
begin
  Enabled := False;
end;

procedure TTimer.Fire(Now: QWord);
begin
  if not FEnabled or (FInterval = 0) then
    Exit;
  { Back in the queue first, so OnTimer may stop it or change it. }
  FDue := NextPeriodicDue(FDue, FInterval, Now);
  Queue.Schedule(Self, FDue);
  if FOwner <> nil then
    FOwner.PrepareToReceive;
  Timer;
end;

procedure TTimer.Timer;
begin
  if Assigned(FOnTimer) then
    FOnTimer(Self);
end;

end.
