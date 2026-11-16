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
  The running processes, all at once: who they are, their state, their
  processor time and memory (TAbiProcessDetails), for ps, top and the
  task manager.

  A snapshot holds every process as it was at one moment, in a buffer
  that grows as needed and is kept for the next snapshot, so a program
  that looks every second allocates nothing after the first time. Two
  snapshots tell how busy a process was in between
  (ProcessorShareTenths).
}
unit Sys.ProcessList;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls;

type
  TProcessDetails = TAbiProcessDetails;
  PProcessDetails = PAbiProcessDetails;

  TProcessSnapshot = record
    Entries: PProcessDetails;
    Count: LongInt;
    Capacity: LongInt;
    { When it was taken: milliseconds since the system started. }
    TakenAtMilliseconds: QWord;
  end;

procedure InitializeProcessSnapshot(out Snapshot: TProcessSnapshot);
{ Fills Snapshot with every running process (in the order they
  started); ErrorNone or an error code. }
function TakeProcessSnapshot(var Snapshot: TProcessSnapshot): LongInt;
procedure FreeProcessSnapshot(var Snapshot: TProcessSnapshot);
{ The process with ProcessId in Snapshot, or nil. }
function FindProcessInSnapshot(const Snapshot: TProcessSnapshot; ProcessId: QWord): PProcessDetails;
{ The details of one process (taken now); False if it does not run. }
function GetProcessDetails(ProcessId: QWord; out Details: TProcessDetails): Boolean;

{ How much of the processors' time a process used between two looks at
  its processor time, ElapsedMilliseconds apart, in tenths of a percent:
  1000 is ProcessorCount processors kept busy the whole time (give 1 for
  the share of one processor, as ps shows it). }
function ProcessorShareTenths(EarlierNanoseconds, LaterNanoseconds: QWord; ElapsedMilliseconds: QWord;
  ProcessorCount: LongWord): LongWord;

{ "running", "waiting", "stopped" or "ending" (ProcessState*). }
function ProcessStateName(State: LongWord): PChar;

implementation

uses
  Runtime.Memory,
  Sys.Kernel,
  Sys.Memory,
  Sys.Errors;

const
  InitialCapacity = 64;
  { How many times to try when processes keep starting between asking
    how many there are and listing them. }
  ListAttempts = 4;

procedure InitializeProcessSnapshot(out Snapshot: TProcessSnapshot);
begin
  Snapshot.Entries := nil;
  Snapshot.Count := 0;
  Snapshot.Capacity := 0;
  Snapshot.TakenAtMilliseconds := 0;
end;

function GrowSnapshot(var Snapshot: TProcessSnapshot; Wanted: LongInt): Boolean;
var
  Bigger: PProcessDetails;
begin
  Bigger := PProcessDetails(ReallocateMemory(Snapshot.Entries, QWord(Wanted) * SizeOf(TProcessDetails)));
  if Bigger = nil then
    Exit(False);
  Snapshot.Entries := Bigger;
  Snapshot.Capacity := Wanted;
  Result := True;
end;

function TakeProcessSnapshot(var Snapshot: TProcessSnapshot): LongInt;
var
  Attempt: LongInt;
  Total: Int64;
begin
  Snapshot.Count := 0;
  if (Snapshot.Capacity = 0) and not GrowSnapshot(Snapshot, InitialCapacity) then
    Exit(ErrorOutOfMemory);
  for Attempt := 1 to ListAttempts do
  begin
    Snapshot.TakenAtMilliseconds := QWord(KernelGetTime(1));
    Total := KernelListProcessDetails(Snapshot.Entries, QWord(Snapshot.Capacity));
    if Total < 0 then
      Exit(ErrorCodeOf(Total));
    if Total <= Snapshot.Capacity then
    begin
      Snapshot.Count := LongInt(Total);
      Exit(ErrorNone);
    end;
    { Room for those, and a few more starting meanwhile. }
    if not GrowSnapshot(Snapshot, LongInt(Total) + InitialCapacity div 4) then
      Exit(ErrorOutOfMemory);
  end;
  Snapshot.Count := Snapshot.Capacity;
  Result := ErrorNone;
end;

procedure FreeProcessSnapshot(var Snapshot: TProcessSnapshot);
begin
  FreeMemory(Snapshot.Entries);
  InitializeProcessSnapshot(Snapshot);
end;

function FindProcessInSnapshot(const Snapshot: TProcessSnapshot; ProcessId: QWord): PProcessDetails;
var
  Index: LongInt;
begin
  for Index := 0 to Snapshot.Count - 1 do
    if Snapshot.Entries[Index].ProcessId = ProcessId then
      Exit(@Snapshot.Entries[Index]);
  Result := nil;
end;

function GetProcessDetails(ProcessId: QWord; out Details: TProcessDetails): Boolean;
var
  Snapshot: TProcessSnapshot;
  Found: PProcessDetails;
begin
  FillMemory(@Details, SizeOf(Details), 0);
  InitializeProcessSnapshot(Snapshot);
  Result := False;
  if TakeProcessSnapshot(Snapshot) = ErrorNone then
  begin
    Found := FindProcessInSnapshot(Snapshot, ProcessId);
    if Found <> nil then
    begin
      Details := Found^;
      Result := True;
    end;
  end;
  FreeProcessSnapshot(Snapshot);
end;

function ProcessorShareTenths(EarlierNanoseconds, LaterNanoseconds: QWord; ElapsedMilliseconds: QWord;
  ProcessorCount: LongWord): LongWord;
var
  Used: QWord;
  Available: QWord;
begin
  if (LaterNanoseconds <= EarlierNanoseconds) or (ElapsedMilliseconds = 0) or (ProcessorCount = 0) then
    Exit(0);
  Used := LaterNanoseconds - EarlierNanoseconds;
  Available := ElapsedMilliseconds * 1000000 * ProcessorCount;
  Result := LongWord((Used * 1000 + Available div 2) div Available);
  if Result > 1000 then
    Result := 1000;
end;

function ProcessStateName(State: LongWord): PChar;
begin
  case State of
    ProcessStateRunning: Result := 'running';
    ProcessStateStopped: Result := 'stopped';
    ProcessStateExiting: Result := 'ending';
  else
    Result := 'waiting';
  end;
end;

end.
