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
  Pseudo-terminals: a terminal for programs that some program shows
  (a terminal window) instead of the screen.

  Each one is a pair of sides. The terminal side (/dev/ptsN) behaves
  like the console for the programs that use it: it has a line
  discipline of its own (Io.LineDiscipline), so line editing, echo,
  Ctrl-C and Ctrl-Z, the modes, the size and the foreground group work
  as they do there. The master side belongs to the program showing it:
  what it writes is typed into the terminal (through the line
  discipline, so Ctrl-C there interrupts too), and what it reads is
  what programs wrote to the terminal, the echo included, as it was
  written (a line feed stays a line feed: the program showing it moves
  to the start of the next line, as the console does).

  The output waits in a buffer here: programs writing to a full buffer
  wait until the master reads (a terminal window that stops reading
  holds its programs up, as a slow screen would), while echo that does
  not fit is dropped rather than holding up the reader.

  The pairs are a pool of MaximumPseudoTerminals, made as they are first
  needed and reused (devices are never removed). A pair is taken by
  ReservePseudoTerminal and is free again once both sides are closed.
  Closing the master side hangs the terminal up: its readers get end of
  file, writers ErrorIo, and the processes it controls are ended
  (Processes.TerminalSignals). Once every handle to the terminal side is
  closed, reading the master gives end of file.

  The devices themselves (open, close, read, write and control) are in
  Drivers.PseudoTerminalDevices.
}
unit Io.PseudoTerminals;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Kernel.Events,
  Io.LineDiscipline;

const
  MaximumPseudoTerminals = 16;
  PseudoTerminalOutputCapacity = 16 * 1024;
  { ReadPseudoTerminalOutput and WritePseudoTerminalOutput: alerted
    before anything moved; and the terminal is hung up. }
  PseudoTerminalInterrupted = -1;
  PseudoTerminalHungUp = -2;

type
  PPseudoTerminal = ^TPseudoTerminal;
  TPseudoTerminal = record
    Number: LongInt;
    Terminal: TLineDiscipline;
    { The devices of the two sides (PDeviceObject), made by
      Drivers.PseudoTerminalDevices the first time the pair is used. }
    MasterDevice: Pointer;
    TerminalDevice: Pointer;

    { What programs wrote to the terminal, for the master to read. }
    Output: array[0..PseudoTerminalOutputCapacity - 1] of Byte;
    OutputStart: LongWord;
    OutputCount: LongWord;
    OutputLock: TSpinLock;
    { Notification events kept in step with the buffer under OutputLock:
      the master has something to read (or every terminal handle is
      closed), and programs may write (or the terminal is hung up). }
    OutputReadable: TEvent;
    OutputRoom: TEvent;

    { Open handles of each side (under the pool's lock). }
    MasterOpenCount: LongWord;
    TerminalOpenCount: LongWord;
    { Every terminal handle was closed after it was opened. }
    TerminalClosedByAll: Boolean;
    InUse: Boolean;
  end;

procedure InitializePseudoTerminals;

{ Takes a free pair, made new or as good as new; nil if every one is in
  use or memory is short. The pair counts as in use until both of its
  sides have been opened and closed again (or ReleasePseudoTerminal). }
function ReservePseudoTerminal: PPseudoTerminal;
{ Gives back a reserved pair whose sides were never opened. }
procedure ReleasePseudoTerminal(Pair: PPseudoTerminal);

{ Counting opens and closes (from the devices' open and close
  routines). Opening the terminal side of a pair that is not in use, or
  hung up, fails with ErrorIo. Closing the last master handle hangs the
  terminal up. }
procedure NoteMasterOpened(Pair: PPseudoTerminal);
procedure NoteMasterClosed(Pair: PPseudoTerminal);
function NoteTerminalOpened(Pair: PPseudoTerminal): LongInt;
procedure NoteTerminalClosed(Pair: PPseudoTerminal);

{ Adds Count bytes to the output. With MayWait, waits (alertably) while
  the buffer is full; otherwise drops what does not fit. Returns the
  bytes added, PseudoTerminalInterrupted or PseudoTerminalHungUp. }
function WritePseudoTerminalOutput(Pair: PPseudoTerminal; Source: PByte; Count: QWord;
  MayWait: Boolean): Int64;
{ Takes up to Count bytes of output, waiting (alertably) for some.
  Returns the bytes taken, 0 once every terminal handle is closed, or
  PseudoTerminalInterrupted. }
function ReadPseudoTerminalOutput(Pair: PPseudoTerminal; Destination: PByte; Count: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.PriorityLevel,
  Kernel.Threads,
  Kernel.Scheduler;

var
  Pairs: array[0..MaximumPseudoTerminals - 1] of PPseudoTerminal;
  PoolLock: TMutex;

procedure InitializePseudoTerminals;
begin
  InitializeMutex(PoolLock);
end;

{ --- The output buffer ------------------------------------------------- }

{ Brings the output's events in step. OutputLock held. }
procedure UpdateOutputReadinessLocked(Pair: PPseudoTerminal);
begin
  if (Pair^.OutputCount > 0) or Pair^.TerminalClosedByAll then
    SignalEvent(Pair^.OutputReadable)
  else
    ResetEvent(Pair^.OutputReadable);
  if (Pair^.OutputCount < PseudoTerminalOutputCapacity) or Pair^.Terminal.HungUp then
    SignalEvent(Pair^.OutputRoom)
  else
    ResetEvent(Pair^.OutputRoom);
end;

procedure UpdateOutputReadiness(Pair: PPseudoTerminal);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Pair^.OutputLock);
  UpdateOutputReadinessLocked(Pair);
  ReleaseSpinLock(Pair^.OutputLock, PreviousLevel);
end;

{ Copies what fits of Count bytes into the buffer; returns how many. }
function AddOutput(Pair: PPseudoTerminal; Source: PByte; Count: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
  Room: QWord;
  Index: QWord;
begin
  PreviousLevel := AcquireSpinLock(Pair^.OutputLock);
  Room := PseudoTerminalOutputCapacity - Pair^.OutputCount;
  if Count < Room then
    Room := Count;
  Index := 0;
  while Index < Room do
  begin
    Pair^.Output[(Pair^.OutputStart + Pair^.OutputCount) mod PseudoTerminalOutputCapacity] := Source[Index];
    Inc(Pair^.OutputCount);
    Inc(Index);
  end;
  UpdateOutputReadinessLocked(Pair);
  ReleaseSpinLock(Pair^.OutputLock, PreviousLevel);
  Result := Room;
end;

function TakeOutput(Pair: PPseudoTerminal; Destination: PByte; Count: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
  Index: QWord;
begin
  PreviousLevel := AcquireSpinLock(Pair^.OutputLock);
  Index := 0;
  while (Index < Count) and (Pair^.OutputCount > 0) do
  begin
    Destination[Index] := Pair^.Output[Pair^.OutputStart];
    Pair^.OutputStart := (Pair^.OutputStart + 1) mod PseudoTerminalOutputCapacity;
    Dec(Pair^.OutputCount);
    Inc(Index);
  end;
  UpdateOutputReadinessLocked(Pair);
  ReleaseSpinLock(Pair^.OutputLock, PreviousLevel);
  Result := Index;
end;

function WritePseudoTerminalOutput(Pair: PPseudoTerminal; Source: PByte; Count: QWord;
  MayWait: Boolean): Int64;
var
  Written: QWord;
  Added: QWord;
begin
  Written := 0;
  while Written < Count do
  begin
    if Pair^.Terminal.HungUp then
    begin
      if Written = 0 then
        Exit(PseudoTerminalHungUp);
      Break;
    end;
    Added := AddOutput(Pair, Source + Written, Count - Written);
    Written := Written + Added;
    if not MayWait then
      Break;
    if Added > 0 then
      Continue;
    if WaitForEventWithOptions(Pair^.OutputRoom, InfiniteTimeout, True) = WaitAlerted then
    begin
      if Written = 0 then
        Exit(PseudoTerminalInterrupted);
      Break;
    end;
  end;
  Result := Int64(Written);
end;

function ReadPseudoTerminalOutput(Pair: PPseudoTerminal; Destination: PByte; Count: QWord): Int64;
var
  Taken: QWord;
begin
  repeat
    Taken := TakeOutput(Pair, Destination, Count);
    if Taken > 0 then
      Exit(Int64(Taken));
    if Pair^.TerminalClosedByAll then
      Exit(0);
    if WaitForEventWithOptions(Pair^.OutputReadable, InfiniteTimeout, True) = WaitAlerted then
      Exit(PseudoTerminalInterrupted);
  until False;
end;

{ Echo and the "^C" after an interrupt: never waits. }
procedure ShowOnMaster(Terminal: PLineDiscipline; Text: PChar; Count: LongWord);
begin
  WritePseudoTerminalOutput(PPseudoTerminal(Terminal^.Owner), PByte(Text), Count, False);
end;

{ --- The pool --------------------------------------------------------- }

function MakePair(Number: LongInt): PPseudoTerminal;
begin
  Result := PPseudoTerminal(AllocateZeroedKernelMemory(SizeOf(TPseudoTerminal)));
  if Result = nil then
    Exit;
  Result^.Number := Number;
  InitializeSpinLock(Result^.OutputLock);
  InitializeEvent(Result^.OutputReadable, EventKindNotification, False);
  InitializeEvent(Result^.OutputRoom, EventKindNotification, True);
  InitializeLineDiscipline(Result^.Terminal, Number, Result, @ShowOnMaster);
end;

{ A pair used before starts again empty. Nobody has it open. }
procedure RenewPair(Pair: PPseudoTerminal);
var
  PreviousLevel: TPriorityLevel;
begin
  ResetLineDiscipline(Pair^.Terminal);
  PreviousLevel := AcquireSpinLock(Pair^.OutputLock);
  Pair^.OutputStart := 0;
  Pair^.OutputCount := 0;
  Pair^.TerminalClosedByAll := False;
  UpdateOutputReadinessLocked(Pair);
  ReleaseSpinLock(Pair^.OutputLock, PreviousLevel);
end;

function ReservePseudoTerminal: PPseudoTerminal;
var
  Index: LongInt;
  FreeSlot: LongInt;
begin
  Result := nil;
  AcquireMutex(PoolLock);
  { A pair made before is reused first, so devices are only added when
    more terminals are open at once than ever before. }
  for Index := 0 to MaximumPseudoTerminals - 1 do
    if (Pairs[Index] <> nil) and not Pairs[Index]^.InUse then
    begin
      Result := Pairs[Index];
      RenewPair(Result);
      Break;
    end;
  if Result = nil then
  begin
    FreeSlot := -1;
    for Index := MaximumPseudoTerminals - 1 downto 0 do
      if Pairs[Index] = nil then
        FreeSlot := Index;
    if FreeSlot >= 0 then
    begin
      Result := MakePair(FreeSlot);
      Pairs[FreeSlot] := Result;
    end;
  end;
  if Result <> nil then
    Result^.InUse := True;
  ReleaseMutex(PoolLock);
end;

procedure ReleasePseudoTerminal(Pair: PPseudoTerminal);
begin
  AcquireMutex(PoolLock);
  if (Pair^.MasterOpenCount = 0) and (Pair^.TerminalOpenCount = 0) then
    Pair^.InUse := False;
  ReleaseMutex(PoolLock);
end;

{ Both sides closed: the pair may be taken again. PoolLock held. }
procedure FreeIfUnusedLocked(Pair: PPseudoTerminal);
begin
  if (Pair^.MasterOpenCount = 0) and (Pair^.TerminalOpenCount = 0) then
    Pair^.InUse := False;
end;

procedure NoteMasterOpened(Pair: PPseudoTerminal);
begin
  AcquireMutex(PoolLock);
  Inc(Pair^.MasterOpenCount);
  ReleaseMutex(PoolLock);
end;

procedure NoteMasterClosed(Pair: PPseudoTerminal);
var
  HangUp: Boolean;
begin
  AcquireMutex(PoolLock);
  Dec(Pair^.MasterOpenCount);
  HangUp := Pair^.MasterOpenCount = 0;
  FreeIfUnusedLocked(Pair);
  ReleaseMutex(PoolLock);
  if not HangUp then
    Exit;
  HangUpTerminal(Pair^.Terminal);
  { Writers waiting for room find the terminal hung up. }
  UpdateOutputReadiness(Pair);
end;

function NoteTerminalOpened(Pair: PPseudoTerminal): LongInt;
begin
  AcquireMutex(PoolLock);
  if not Pair^.InUse or Pair^.Terminal.HungUp then
    Result := ErrorIo
  else
  begin
    Inc(Pair^.TerminalOpenCount);
    Pair^.TerminalClosedByAll := False;
    Result := ErrorNone;
  end;
  ReleaseMutex(PoolLock);
  UpdateOutputReadiness(Pair);
end;

procedure NoteTerminalClosed(Pair: PPseudoTerminal);
begin
  AcquireMutex(PoolLock);
  Dec(Pair^.TerminalOpenCount);
  if Pair^.TerminalOpenCount = 0 then
    Pair^.TerminalClosedByAll := True;
  FreeIfUnusedLocked(Pair);
  ReleaseMutex(PoolLock);
  { The master's reader sees end of file. }
  UpdateOutputReadiness(Pair);
end;

end.
