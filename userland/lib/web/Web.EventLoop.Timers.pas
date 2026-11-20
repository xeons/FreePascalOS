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
  setTimeout, setInterval, clearTimeout and clearInterval (HTML Standard
  section 8.6, "timer initialization steps") for one global (a window):
  its map of active timers, ids from 1 up, never reused.

  - A timeout below 0 is 0. The timer nesting level is the running timer
    task's (0 elsewhere); when it is above 5 a timeout below 4 ms becomes
    4 ms, and the new timer's tasks get the level plus one. An interval
    sets itself again from its own task, so its level grows each time
    and it is clamped from the sixth run on.
  - Timers due at the same moment run in the order they were set (the
    loop's delayed tasks keep that order); a timer cleared before its
    task runs does nothing, even when its task is already queued.
  - The handler is a TTimerHandler (the bindings will wrap a JavaScript
    function or string); the timer owns it.
}
unit Web.EventLoop.Timers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.IdMaps,
  Web.EventLoop.Tasks,
  Web.EventLoop;

const
  TimerClampNestingLevel = 5;
  TimerClampMilliseconds = 4;

type
  TTimerHandler = class
  public
    procedure Invoke; virtual; abstract;
  end;

  TTimerMethod = procedure of object;

  { A handler that calls a method (for Pascal users of the timers). }
  TMethodTimerHandler = class(TTimerHandler)
  private
    FMethod: TTimerMethod;
  public
    constructor Create(Method: TTimerMethod);
    procedure Invoke; override;
  end;

  TTimerList = class;

  TActiveTimer = class
  public
    Id: LongInt;
    Handler: TTimerHandler;
    Timeout: Double;
    Repeating: Boolean;
    ScheduledHandle: QWord;
    { Its handler is running: clearing it then frees it afterwards. }
    Running: Boolean;
    destructor Destroy; override;
  end;

  TTimerTask = class(TWebTask)
  private
    FList: TTimerList;
    FId: LongInt;
  public
    constructor Create(List: TTimerList; Id: LongInt);
    procedure Run; override;
  end;

  TTimerList = class
  private
    FLoop: TEventLoop;
    FGroup: Pointer;
    FTimers: TIdMap;
    FNextId: LongInt;
    function FindTimer(Id: LongInt; out Timer: TActiveTimer): Boolean;
    procedure Schedule(Timer: TActiveTimer);
    procedure RunTimer(Id: LongInt);
  public
    { Group: what the timer tasks belong to (the window). }
    constructor Create(Loop: TEventLoop; Group: Pointer);
    destructor Destroy; override;
    { The new timer's id; the list owns Handler. }
    function SetTimeout(Handler: TTimerHandler; TimeoutMilliseconds: Double): LongInt;
    function SetInterval(Handler: TTimerHandler; TimeoutMilliseconds: Double): LongInt;
    { clearTimeout and clearInterval (either clears either). }
    procedure ClearTimer(Id: LongInt);
    { Every timer stops (the document is unloaded). }
    procedure ClearAll;
    function ActiveCount: Integer;
    property Loop: TEventLoop read FLoop;
  end;

implementation

constructor TMethodTimerHandler.Create(Method: TTimerMethod);
begin
  inherited Create;
  FMethod := Method;
end;

procedure TMethodTimerHandler.Invoke;
begin
  if Assigned(FMethod) then
    FMethod();
end;

destructor TActiveTimer.Destroy;
begin
  Handler.Free;
  inherited Destroy;
end;

constructor TTimerTask.Create(List: TTimerList; Id: LongInt);
begin
  inherited Create;
  FList := List;
  FId := Id;
end;

procedure TTimerTask.Run;
begin
  FList.RunTimer(FId);
end;

constructor TTimerList.Create(Loop: TEventLoop; Group: Pointer);
begin
  inherited Create;
  FLoop := Loop;
  FGroup := Group;
  FTimers := TIdMap.Create;
end;

destructor TTimerList.Destroy;
begin
  ClearAll;
  FTimers.Free;
  inherited Destroy;
end;

procedure TTimerList.Schedule(Timer: TActiveTimer);
var
  NestingLevel: Integer;
  Timeout: Double;
  Task: TTimerTask;
begin
  NestingLevel := FLoop.CurrentTimerNestingLevel;
  Timeout := Timer.Timeout;
  if Timeout < 0 then
    Timeout := 0;
  if (NestingLevel > TimerClampNestingLevel) and (Timeout < TimerClampMilliseconds) then
    Timeout := TimerClampMilliseconds;
  Task := TTimerTask.Create(Self, Timer.Id);
  Task.Source := TaskSourceTimer;
  Task.Group := FGroup;
  Task.TimerNestingLevel := NestingLevel + 1;
  Timer.ScheduledHandle := FLoop.ScheduleTask(Task, Timeout);
end;

function TTimerList.SetTimeout(Handler: TTimerHandler; TimeoutMilliseconds: Double): LongInt;
var
  Timer: TActiveTimer;
begin
  Inc(FNextId);
  Timer := TActiveTimer.Create;
  Timer.Id := FNextId;
  Timer.Handler := Handler;
  Timer.Timeout := TimeoutMilliseconds;
  FTimers.Add(QWord(Timer.Id), Timer);
  Schedule(Timer);
  Result := Timer.Id;
end;

function TTimerList.SetInterval(Handler: TTimerHandler; TimeoutMilliseconds: Double): LongInt;
var
  Timer: TActiveTimer;
begin
  Result := SetTimeout(Handler, TimeoutMilliseconds);
  if FindTimer(Result, Timer) then
    Timer.Repeating := True;
end;

procedure TTimerList.RunTimer(Id: LongInt);
var
  Timer: TActiveTimer;
begin
  if not FindTimer(Id, Timer) then
    Exit;
  Timer.ScheduledHandle := 0;
  Timer.Running := True;
  try
    Timer.Handler.Invoke;
  finally
    Timer.Running := False;
    if not FTimers.ContainsKey(QWord(Id)) then
      { The handler cleared its own timer. }
      Timer.Free
    else if Timer.Repeating then
      Schedule(Timer)
    else
    begin
      FTimers.Remove(QWord(Id));
      Timer.Free;
    end;
  end;
end;

procedure TTimerList.ClearTimer(Id: LongInt);
var
  Timer: TActiveTimer;
begin
  if not FindTimer(Id, Timer) then
    Exit;
  FTimers.Remove(QWord(Id));
  if Timer.ScheduledHandle <> 0 then
    FLoop.CancelScheduledTask(Timer.ScheduledHandle);
  if not Timer.Running then
    Timer.Free;
end;

procedure TTimerList.ClearAll;
var
  Ids: TIdArray;
  Index: Integer;
begin
  Ids := FTimers.Keys;
  for Index := 0 to High(Ids) do
    ClearTimer(LongInt(Ids[Index]));
end;

function TTimerList.FindTimer(Id: LongInt; out Timer: TActiveTimer): Boolean;
var
  Found: TObject;
begin
  Result := FTimers.TryGetValue(QWord(Id), Found);
  Timer := TActiveTimer(Found);
end;

function TTimerList.ActiveCount: Integer;
begin
  Result := FTimers.Count;
end;

end.
