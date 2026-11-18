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
  The kernel log, kept in memory from its very first line, for those who
  read it later (the network log, Network.LogStreaming).

  Debug.Output hands every character it writes to CaptureLogCharacter;
  characters are gathered into lines, and each line is kept with a
  sequence number (from 1) and the uptime when it ended. A line longer
  than LogLineCapacity is cut into several (the later ones marked
  Continued).

  The lines live in fixed slots, so a line is found from its sequence
  number at once:
    - the first StartSlotCount lines of the boot stay for good (the
      start-up, which matters most when something goes wrong early);
    - the lines after them go round a ring of RingSlotCount, the oldest
      overwritten first.
  A reader keeps the sequence number it wants next; ReadLogLine gives it
  that line, or the oldest one still kept after it (a gap the reader can
  see in the numbers).

  Writers are Debug.Output's callers, at any level, with its lock held;
  the slots have a spin lock of their own (taken at HighLevel) so that
  readers see whole lines. Nothing here allocates, waits or signals, so
  capturing is safe from interrupt handlers and inside any lock.
}
unit Debug.LogRing;

{$mode objfpc}

interface

const
  LogLineCapacity = 112;
  StartSlotCount = 1024;
  RingSlotCount = 3072;

type
  TLogLine = record
    Sequence: LongWord;
    Length: Word;
    { The rest of a line too long for one slot. }
    Continued: Boolean;
    Reserved: Byte;
    UptimeNanoseconds: QWord;
    Text: array[0..LogLineCapacity - 1] of Char;
  end;
  PLogLine = ^TLogLine;

{ Called by Debug.Output for every character it writes. }
procedure CaptureLogCharacter(Character: Char);

{ The sequence number the next finished line will get. }
function NextLogSequence: LongWord;

{ Copies the line numbered Sequence into Line, or (if that one is no
  longer kept) the oldest line after it; False if there is no such line
  yet. Line.Sequence says which line it is. }
function ReadLogLine(Sequence: LongWord; out Line: TLogLine): Boolean;

{ Only for the panic path: forgets a holder of the lock, which may be
  the code that crashed. }
procedure ForceUnlockLogRingForPanic;

implementation

uses
  Runtime.Memory,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Hal.Platform;

var
  { All zero at start: empty slots (sequence 0) and a free lock. }
  StartSlots: array[0..StartSlotCount - 1] of TLogLine;
  RingSlots: array[0..RingSlotCount - 1] of TLogLine;
  SlotLock: TSpinLock;
  { The line being gathered. }
  PendingText: array[0..LogLineCapacity - 1] of Char;
  PendingLength: LongWord = 0;
  PendingIsContinuation: Boolean = False;
  { The number of the next line to finish; lines are numbered from 1. }
  NextSequence: LongWord = 1;

function SlotOf(Sequence: LongWord): PLogLine;
begin
  if Sequence <= StartSlotCount then
    Result := @StartSlots[Sequence - 1]
  else
    Result := @RingSlots[(Sequence - StartSlotCount - 1) mod RingSlotCount];
end;

function LockSlots: TPriorityLevel;
begin
  Result := RaisePriorityLevel(HighLevel);
  AcquireSpinLockAtCurrentLevel(SlotLock);
end;

procedure UnlockSlots(PreviousLevel: TPriorityLevel);
begin
  ReleaseSpinLockAtCurrentLevel(SlotLock);
  LowerPriorityLevel(PreviousLevel);
end;

procedure FinishPendingLine(Continues: Boolean);
var
  Slot: PLogLine;
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := LockSlots;
  Slot := SlotOf(NextSequence);
  Slot^.Sequence := NextSequence;
  Slot^.Length := PendingLength;
  Slot^.Continued := PendingIsContinuation;
  Slot^.Reserved := 0;
  Slot^.UptimeNanoseconds := HalClockNanoseconds;
  CopyMemory(@Slot^.Text[0], @PendingText[0], PendingLength);
  Inc(NextSequence);
  { After a wrap of 2^32 lines the numbers would start again at 0, which
    marks an empty slot: skip it. }
  if NextSequence = 0 then
    NextSequence := 1;
  UnlockSlots(PreviousLevel);
  PendingLength := 0;
  PendingIsContinuation := Continues;
end;

procedure CaptureLogCharacter(Character: Char);
begin
  case Character of
    #10:
      FinishPendingLine(False);
    #13:
      ;
  else
    begin
      if PendingLength >= LogLineCapacity then
        FinishPendingLine(True);
      PendingText[PendingLength] := Character;
      Inc(PendingLength);
    end;
  end;
end;

function NextLogSequence: LongWord;
begin
  Result := NextSequence;
end;

function OldestKeptAfterStart: LongWord;
begin
  { Everything in the ring is kept while it has not gone round. }
  if NextSequence - StartSlotCount - 1 <= RingSlotCount then
    Result := StartSlotCount + 1
  else
    Result := NextSequence - RingSlotCount;
end;

function ReadLogLine(Sequence: LongWord; out Line: TLogLine): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Wanted: LongWord;
  Slot: PLogLine;
begin
  Result := False;
  if Sequence = 0 then
    Sequence := 1;
  PreviousLevel := LockSlots;
  if Sequence < NextSequence then
  begin
    Wanted := Sequence;
    if (Wanted > StartSlotCount) and (Wanted < OldestKeptAfterStart) then
      Wanted := OldestKeptAfterStart;
    Slot := SlotOf(Wanted);
    if Slot^.Sequence = Wanted then
    begin
      Line := Slot^;
      Result := True;
    end;
  end;
  UnlockSlots(PreviousLevel);
end;

procedure ForceUnlockLogRingForPanic;
begin
  InitializeSpinLock(SlotLock);
end;

end.
