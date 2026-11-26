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
  The wall clock, to the nanosecond.

  The date and time is the uptime (Kernel.Clock's nanoseconds) plus an
  offset: the battery backed clock's reading at start less the uptime
  then, changed whenever the time is set. Setting the time either steps
  it (the offset changes at once: CallSetWallClock, and a time server's
  answer far off) or slews it (CallAdjustWallClock gradually): the
  offset moves towards the target at SlewPartsPerMillion of the time
  passing, so the clock runs a little fast or slow but never jumps or
  goes back, as NTP clients adjust it. A new adjustment replaces what is
  left of the last one.

  Whoever keeps times of the wall clock as uptime deadlines (timers due
  at a date: Objects.TimerDescriptors) registers a step routine, called
  after every step (not a gradual adjustment), below DispatchLevel. (Not
  after the time is read from the battery backed clock again on resume:
  the other processors are still frozen then.)

  The state is read without a lock under a sequence count (odd while it
  changes; a reader that sees it change reads again), so any level may
  read the time; changes take a spin lock, with interrupts off.
}
unit Kernel.WallClock;

{$mode objfpc}

interface

uses
  Runtime.Time;

const
  NanosecondsPerSecond = 1000000000;
  { How fast a gradual adjustment moves the clock: 500 parts per
    million (half a millisecond a second, 1.8 s an hour). }
  SlewPartsPerMillion = 500;
  { The largest gradual adjustment: an hour (which takes 83 days). }
  MaximumSlewNanoseconds = Int64(3600) * NanosecondsPerSecond;
  { The latest time the clock may be stepped to: 2200-01-01, well
    inside what nanoseconds in 64 bits count (2262). }
  LatestWallClockNanoseconds = Int64(7258118400) * NanosecondsPerSecond;

{ At start: the battery backed clock's time. }
procedure StartWallClock;
{ After suspend to RAM: the battery backed clock is read again (the
  uptime does not count the time asleep); an adjustment under way is
  dropped. }
procedure ReadWallClockFromHardware;

{ Nanoseconds since 1970-01-01 00:00:00 UTC. Any level. }
function WallClockNanoseconds: Int64;
{ The same in whole seconds. }
function WallClockSeconds: TUnixTime;

{ Steps the clock to Time (whole seconds) and writes the battery backed
  clock. Passive level. }
procedure StepWallClockTo(Time: TUnixTime);
{ Moves the clock by OffsetNanoseconds: at once (and the battery backed
  clock with it) or gradually. Passive level. False (nothing changed)
  if a step would take the clock outside 1970 to 2200, or a gradual
  adjustment is larger than MaximumSlewNanoseconds. }
function AdjustWallClock(OffsetNanoseconds: Int64; Gradually: Boolean): Boolean;
{ What a gradual adjustment still has to move the clock by. }
function WallClockAdjustmentRemaining: Int64;

type
  TWallClockStepRoutine = procedure;

{ Registers Routine to be called after each step of the clock (at most
  MaximumWallClockStepRoutines, registered once at start). }
procedure AddWallClockStepRoutine(Routine: TWallClockStepRoutine);

const
  MaximumWallClockStepRoutines = 4;
{ The offset from the uptime and the gradual adjustment (its total and
  since when), consistent with each other: for the clock page. Any
  level. }
procedure ReadWallClockState(out Offset, Total: Int64; out Start: QWord);

implementation

uses
  Hal.RealTimeClock,
  Runtime.Atomic,
  Runtime.ClockPage,
  Kernel.ClockPage,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Clock;

var
  { Changes take the lock; Sequence is odd while they are made. }
  Lock: TSpinLock;
  Sequence: PtrUInt = 0;
  { Interrupts are off while Sequence is odd: a reader interrupting the
    change on the same processor would wait for it forever. }
  InterruptsWereEnabled: Boolean;
  { Wall clock nanoseconds less uptime nanoseconds. }
  BaseOffset: Int64 = 0;
  { The gradual adjustment: by how much in all (signed) and since when
    (uptime nanoseconds). }
  SlewTotal: Int64 = 0;
  SlewStart: QWord = 0;

{ How far a slew begun at Start has moved the clock by Now (always
  towards Total, never past it): the clock page's arithmetic, so that
  programs reading the time from the page agree with the kernel. }
function SlewProgress(Total: Int64; Start, Now: QWord): Int64;
begin
  Result := ClockSlewProgress(Total, Start, Now, SlewPartsPerMillion);
end;

procedure BeginChange(out PreviousLevel: TPriorityLevel);
begin
  PreviousLevel := AcquireSpinLock(Lock);
  InterruptsWereEnabled := SaveAndDisableInterrupts;
  AtomicStore(Sequence, Sequence + 1);
  FullMemoryBarrier;
end;

procedure EndChange(PreviousLevel: TPriorityLevel);
begin
  FullMemoryBarrier;
  AtomicStore(Sequence, Sequence + 1);
  RestoreInterrupts(InterruptsWereEnabled);
  ReleaseSpinLock(Lock, PreviousLevel);
  { Programs read the wall clock from the clock page. }
  PublishClockPage;
end;

{ Folds the slew's progress so far into the base (lock held). }
procedure SettleSlewLocked(Now: QWord);
var
  Progress: Int64;
begin
  Progress := SlewProgress(SlewTotal, SlewStart, Now);
  BaseOffset := BaseOffset + Progress;
  SlewTotal := SlewTotal - Progress;
  SlewStart := Now;
end;

var
  StepRoutines: array[0..MaximumWallClockStepRoutines - 1] of TWallClockStepRoutine;
  StepRoutineCount: LongInt = 0;

procedure AddWallClockStepRoutine(Routine: TWallClockStepRoutine);
begin
  if StepRoutineCount >= MaximumWallClockStepRoutines then
    Exit;
  StepRoutines[StepRoutineCount] := Routine;
  Inc(StepRoutineCount);
end;

procedure CallStepRoutines;
var
  Index: LongInt;
begin
  for Index := 0 to StepRoutineCount - 1 do
    StepRoutines[Index]();
end;

procedure SetFromHardware;
var
  PreviousLevel: TPriorityLevel;
  Time: TUnixTime;
begin
  Time := ReadRealTimeClock;
  BeginChange(PreviousLevel);
  BaseOffset := Time * NanosecondsPerSecond - Int64(ClockNanoseconds);
  SlewTotal := 0;
  SlewStart := ClockNanoseconds;
  EndChange(PreviousLevel);
end;

procedure StartWallClock;
begin
  SetFromHardware;
end;

procedure ReadWallClockFromHardware;
begin
  SetFromHardware;
end;

procedure ReadWallClockState(out Offset, Total: Int64; out Start: QWord);
var
  Before: PtrUInt;
begin
  repeat
    Before := AtomicLoad(Sequence);
    if (Before and 1) <> 0 then
    begin
      CpuRelax;
      Continue;
    end;
    Offset := BaseOffset;
    Total := SlewTotal;
    Start := SlewStart;
    FullMemoryBarrier;
  until AtomicLoad(Sequence) = Before;
end;

function WallClockNanoseconds: Int64;
var
  Before: PtrUInt;
  Offset: Int64;
  Total: Int64;
  Start: QWord;
  Now: QWord;
begin
  repeat
    Before := AtomicLoad(Sequence);
    if (Before and 1) <> 0 then
    begin
      CpuRelax;
      Continue;
    end;
    Offset := BaseOffset;
    Total := SlewTotal;
    Start := SlewStart;
    FullMemoryBarrier;
  until AtomicLoad(Sequence) = Before;
  Now := ClockNanoseconds;
  Result := Int64(Now) + Offset + SlewProgress(Total, Start, Now);
end;

function WallClockSeconds: TUnixTime;
var
  Nanoseconds: Int64;
begin
  Nanoseconds := WallClockNanoseconds;
  { Rounded down for times before 1970 too. }
  if Nanoseconds >= 0 then
    Result := Nanoseconds div NanosecondsPerSecond
  else
    Result := -((-Nanoseconds + NanosecondsPerSecond - 1) div NanosecondsPerSecond);
end;

procedure StepWallClockTo(Time: TUnixTime);
var
  PreviousLevel: TPriorityLevel;
begin
  BeginChange(PreviousLevel);
  BaseOffset := Time * NanosecondsPerSecond - Int64(ClockNanoseconds);
  SlewTotal := 0;
  SlewStart := ClockNanoseconds;
  EndChange(PreviousLevel);
  WriteRealTimeClock(Time);
  CallStepRoutines;
end;

{ Whether stepping the clock (now Current) by Offset keeps it between
  1970 and LatestWallClockNanoseconds; tested without overflowing. }
function StepStaysInRange(Current, Offset: Int64): Boolean;
begin
  if Offset >= 0 then
    Result := (Current <= LatestWallClockNanoseconds) and (Offset <= LatestWallClockNanoseconds - Current)
  else
    Result := (Current >= 0) and (Offset >= -Current);
end;

function AdjustWallClock(OffsetNanoseconds: Int64; Gradually: Boolean): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Now: QWord;
begin
  if Gradually and ((OffsetNanoseconds > MaximumSlewNanoseconds) or
     (OffsetNanoseconds < -MaximumSlewNanoseconds)) then
    Exit(False);
  BeginChange(PreviousLevel);
  Now := ClockNanoseconds;
  SettleSlewLocked(Now);
  Result := Gradually or StepStaysInRange(BaseOffset + Int64(Now), OffsetNanoseconds);
  if not Result then
  begin
    EndChange(PreviousLevel);
    Exit;
  end;
  if Gradually then
    SlewTotal := OffsetNanoseconds
  else
  begin
    { A step replaces what was left of an adjustment. }
    BaseOffset := BaseOffset + OffsetNanoseconds;
    SlewTotal := 0;
  end;
  SlewStart := Now;
  EndChange(PreviousLevel);
  if not Gradually then
  begin
    WriteRealTimeClock(WallClockSeconds);
    CallStepRoutines;
  end;
end;

function WallClockAdjustmentRemaining: Int64;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Lock);
  Result := SlewTotal - SlewProgress(SlewTotal, SlewStart, ClockNanoseconds);
  ReleaseSpinLock(Lock, PreviousLevel);
end;

end.
