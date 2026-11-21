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
  clock with it) or gradually. Passive level. }
procedure AdjustWallClock(OffsetNanoseconds: Int64; Gradually: Boolean);
{ What a gradual adjustment still has to move the clock by. }
function WallClockAdjustmentRemaining: Int64;

implementation

uses
  Hal.RealTimeClock,
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Clock;

const
  MicrosecondsPerSecond = 1000000;

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
  towards Total, never past it). }
function SlewProgress(Total: Int64; Start, Now: QWord): Int64;
var
  Elapsed: QWord;
  Moved: QWord;
  Magnitude: QWord;
begin
  if (Total = 0) or (Now <= Start) then
    Exit(0);
  Elapsed := Now - Start;
  { In two parts, so the product cannot overflow. }
  Moved := (Elapsed div MicrosecondsPerSecond) * SlewPartsPerMillion +
    ((Elapsed mod MicrosecondsPerSecond) * SlewPartsPerMillion) div MicrosecondsPerSecond;
  if Total < 0 then
    Magnitude := QWord(-Total)
  else
    Magnitude := QWord(Total);
  if Moved > Magnitude then
    Moved := Magnitude;
  if Total < 0 then
    Result := -Int64(Moved)
  else
    Result := Int64(Moved);
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
end;

procedure AdjustWallClock(OffsetNanoseconds: Int64; Gradually: Boolean);
var
  PreviousLevel: TPriorityLevel;
  Now: QWord;
begin
  BeginChange(PreviousLevel);
  Now := ClockNanoseconds;
  SettleSlewLocked(Now);
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
    WriteRealTimeClock(WallClockSeconds);
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
