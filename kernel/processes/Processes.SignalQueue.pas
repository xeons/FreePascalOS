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
  The signal queue of a process: signals that wait with information of
  their own (TQueuedSignal), in the order they were sent.

  A real-time signal (FirstRealTimeSignal .. HighestSignal) queues once
  per sending: kill and sigqueue each add an entry from the kernel heap
  (at most MaximumQueuedSignals per process), and taking the signal
  takes its oldest entry, so the values arrive in order. A POSIX timer
  queues the entry embedded in it, whatever its signal: at most once,
  its expiries while it waits counting as its overrun. The other
  signals wait as a bit and one TAbiSignalInformation
  (Processes.Signals).

  Everything here runs under the process's signal lock (a spin lock, so
  a timer's deferred call can queue too), apart from allocating and
  freeing entries, which the callers do outside it.
}
unit Processes.SignalQueue;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Processes.PosixState,
  Processes.Process;

{ A heap entry for Information; nil if memory is short. }
function AllocateQueuedSignal(const Information: TAbiSignalInformation): PQueuedSignal;
{ Frees heap entries (a list linked by Next) taken off the queue. }
procedure FreeQueuedSignals(List: PQueuedSignal);

{ Appends Entry. False (nothing queued) for a heap entry when the
  process has MaximumQueuedSignals already. }
function AppendQueuedSignalLocked(Process: PProcess; Entry: PQueuedSignal): Boolean;
{ True if an entry for Signal waits. }
function SignalIsQueuedLocked(Process: PProcess; Signal: LongInt): Boolean;
{ Takes the oldest entry for Signal off the queue; nil if none. A heap
  entry is the caller's to free (after the lock). }
function TakeQueuedSignalLocked(Process: PProcess; Signal: LongInt): PQueuedSignal;
{ Takes Entry off the queue if it waits there (a timer being deleted);
  its signal is no longer pending if nothing else of it waits. }
procedure RemoveQueuedSignalLocked(Process: PProcess; Entry: PQueuedSignal);
{ Takes every entry for Signal off the queue (it is ignored now); the
  heap ones are returned for FreeQueuedSignals. }
function RemoveSignalFromQueueLocked(Process: PProcess; Signal: LongInt): PQueuedSignal;
{ Takes every heap entry off the queue (the process ends) and returns
  them; timers' entries are left to the timers. }
function RemoveAllQueuedSignalsLocked(Process: PProcess): PQueuedSignal;

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap;

function AllocateQueuedSignal(const Information: TAbiSignalInformation): PQueuedSignal;
begin
  Result := PQueuedSignal(AllocateKernelMemory(SizeOf(TQueuedSignal)));
  if Result = nil then
    Exit;
  ZeroMemory(Result, SizeOf(TQueuedSignal));
  Result^.Information := Information;
end;

procedure FreeQueuedSignals(List: PQueuedSignal);
var
  Next: PQueuedSignal;
begin
  while List <> nil do
  begin
    Next := List^.Next;
    FreeKernelMemory(List);
    List := Next;
  end;
end;

function AppendQueuedSignalLocked(Process: PProcess; Entry: PQueuedSignal): Boolean;
var
  Posix: ^TProcessPosixState;
begin
  Posix := @Process^.Posix;
  if Entry^.IsQueued then
    Exit(True);
  if Entry^.Timer = nil then
  begin
    if Posix^.QueuedCount >= MaximumQueuedSignals then
      Exit(False);
    Inc(Posix^.QueuedCount);
  end;
  Entry^.Next := nil;
  Entry^.IsQueued := True;
  if Posix^.QueueTail = nil then
    Posix^.QueueHead := Entry
  else
    Posix^.QueueTail^.Next := Entry;
  Posix^.QueueTail := Entry;
  Result := True;
end;

function SignalIsQueuedLocked(Process: PProcess; Signal: LongInt): Boolean;
var
  Entry: PQueuedSignal;
begin
  Entry := Process^.Posix.QueueHead;
  while (Entry <> nil) and (LongInt(Entry^.Information.Signal) <> Signal) do
    Entry := Entry^.Next;
  Result := Entry <> nil;
end;

{ Unlinks Entry, which follows Previous (nil: it is the first). }
procedure UnlinkLocked(Process: PProcess; Previous, Entry: PQueuedSignal);
var
  Posix: ^TProcessPosixState;
begin
  Posix := @Process^.Posix;
  if Previous = nil then
    Posix^.QueueHead := Entry^.Next
  else
    Previous^.Next := Entry^.Next;
  if Posix^.QueueTail = Entry then
    Posix^.QueueTail := Previous;
  Entry^.Next := nil;
  Entry^.IsQueued := False;
  if Entry^.Timer = nil then
    Dec(Posix^.QueuedCount);
end;

function TakeQueuedSignalLocked(Process: PProcess; Signal: LongInt): PQueuedSignal;
var
  Previous: PQueuedSignal;
begin
  Previous := nil;
  Result := Process^.Posix.QueueHead;
  while (Result <> nil) and (LongInt(Result^.Information.Signal) <> Signal) do
  begin
    Previous := Result;
    Result := Result^.Next;
  end;
  if Result <> nil then
    UnlinkLocked(Process, Previous, Result);
end;

procedure RemoveQueuedSignalLocked(Process: PProcess; Entry: PQueuedSignal);
var
  Previous: PQueuedSignal;
  Current: PQueuedSignal;
  Signal: LongInt;
begin
  if not Entry^.IsQueued then
    Exit;
  Previous := nil;
  Current := Process^.Posix.QueueHead;
  while (Current <> nil) and (Current <> Entry) do
  begin
    Previous := Current;
    Current := Current^.Next;
  end;
  if Current = nil then
    Exit;
  UnlinkLocked(Process, Previous, Current);
  { Nothing else of that signal waits: not a queued one, nor one waiting
    as a bit (whose information has its signal set). }
  Signal := LongInt(Entry^.Information.Signal);
  if not SignalIsQueuedLocked(Process, Signal) and (Process^.Posix.PendingInformation[Signal].Signal = 0) then
    Process^.Posix.PendingSignals := Process^.Posix.PendingSignals and not (QWord(1) shl (Signal - 1));
end;

{ Takes off every entry Matches accepts; returns the heap ones. }
type
  TEntryFilter = function(Entry: PQueuedSignal; Signal: LongInt): Boolean;

function RemoveMatchingLocked(Process: PProcess; Matches: TEntryFilter; Signal: LongInt): PQueuedSignal;
var
  Previous: PQueuedSignal;
  Current: PQueuedSignal;
  Next: PQueuedSignal;
begin
  Result := nil;
  Previous := nil;
  Current := Process^.Posix.QueueHead;
  while Current <> nil do
  begin
    Next := Current^.Next;
    if Matches(Current, Signal) then
    begin
      UnlinkLocked(Process, Previous, Current);
      if Current^.Timer = nil then
      begin
        Current^.Next := Result;
        Result := Current;
      end;
    end
    else
      Previous := Current;
    Current := Next;
  end;
end;

function IsOfSignal(Entry: PQueuedSignal; Signal: LongInt): Boolean;
begin
  Result := LongInt(Entry^.Information.Signal) = Signal;
end;

function IsFromHeap(Entry: PQueuedSignal; Signal: LongInt): Boolean;
begin
  Result := Entry^.Timer = nil;
end;

function RemoveSignalFromQueueLocked(Process: PProcess; Signal: LongInt): PQueuedSignal;
begin
  Result := RemoveMatchingLocked(Process, @IsOfSignal, Signal);
end;

function RemoveAllQueuedSignalsLocked(Process: PProcess): PQueuedSignal;
begin
  Result := RemoveMatchingLocked(Process, @IsFromHeap, 0);
end;

end.
