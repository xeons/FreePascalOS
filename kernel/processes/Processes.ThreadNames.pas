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
  Thread names and the thread list of a process (CallSetThreadName,
  CallListThreads).

  Every thread has a name in its control block (Kernel.Threads): a
  user thread starts with its process's name, and the program may give
  it its own (TThread.NameThreadForDebugging, Sys.Threads.SetThreadName)
  so that hang reports, the debug shell's thread list, ps -L and the
  task manager tell its threads apart. Names are changed and read under
  the process's thread list lock, so a reader never sees half of one.
}
unit Processes.ThreadNames;

{$mode objfpc}

interface

function PerformSetThreadName(ThreadSelector: Int64; NameAddress: QWord): Int64;
function PerformListThreads(ProcessId: QWord; BufferAddress: QWord; Capacity: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Threads,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess;

const
  { The most threads one call describes; a process with more is listed
    in part (the count still says how many there are). }
  MaximumListedThreads = 4096;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ --- Naming -------------------------------------------------------------- }

type
  TNaming = record
    ThreadId: QWord;
    Name: array[0..ThreadNameCapacity - 1] of Char;
    Found: Boolean;
  end;
  PNaming = ^TNaming;

{ Runs under the thread list lock. }
procedure NameMatchingThread(Thread: PThread; Context: Pointer);
var
  Naming: PNaming;
begin
  Naming := PNaming(Context);
  if Thread^.ControlBlock.ThreadId <> Naming^.ThreadId then
    Exit;
  CopyMemory(@Thread^.ControlBlock.Name[0], @Naming^.Name[0], ThreadNameLength);
  Naming^.Found := True;
end;

function PerformSetThreadName(ThreadSelector: Int64; NameAddress: QWord): Int64;
var
  Process: PProcess;
  Naming: TNaming;
  Text: array[0..AbiTextCapacity - 1] of Char;
  Error: LongInt;
begin
  Process := CurrentProcess;
  FillMemory(@Naming, SizeOf(Naming), 0);
  if ThreadSelector = CurrentThreadHandle then
    Naming.ThreadId := CurrentThreadObject^.ControlBlock.ThreadId
  else if ThreadSelector > 0 then
    Naming.ThreadId := QWord(ThreadSelector)
  else
    Exit(Failure(ErrorInvalidArgument));

  { Longer names are cut to fit, as with pthread_setname_np's limit. }
  FillMemory(@Text[0], SizeOf(Text), 0);
  Error := CopyStringFromUser(NameAddress, @Text[0], Length(Text));
  if (Error <> ErrorNone) and (Error <> ErrorNameTooLong) then
    Exit(Failure(Error));
  if Text[0] = #0 then
    CopyText(@Naming.Name[0], @Process^.Name[0], ThreadNameCapacity)
  else
    CopyText(@Naming.Name[0], @Text[0], ThreadNameCapacity);

  VisitProcessThreads(Process, @NameMatchingThread, @Naming);
  if not Naming.Found then
    Exit(Failure(ErrorNotFound));
  Result := 0;
end;

{ --- Listing ------------------------------------------------------------- }

type
  TThreadListing = record
    Records: PAbiThreadDetails;
    Capacity: QWord;
    Count: QWord;
  end;
  PThreadListing = ^TThreadListing;

function DetailsStateOf(Thread: PThread): LongWord;
begin
  if Thread^.SuspendCount > 0 then
    Exit(ThreadDetailsSuspended);
  case Thread^.ControlBlock.State of
    ThreadStateRunning: Result := ThreadDetailsRunning;
    ThreadStateReady, ThreadStateInitialized: Result := ThreadDetailsReady;
    ThreadStateWaiting: Result := ThreadDetailsWaiting;
  else
    Result := ThreadDetailsExiting;
  end;
end;

{ Runs under the thread list lock: only fills the kernel buffer. }
procedure DescribeThread(Thread: PThread; Context: Pointer);
var
  Listing: PThreadListing;
  Details: PAbiThreadDetails;
begin
  Listing := PThreadListing(Context);
  if Listing^.Count < Listing^.Capacity then
  begin
    Details := Listing^.Records + Listing^.Count;
    Details^.ThreadId := Thread^.ControlBlock.ThreadId;
    Details^.ProcessorNanoseconds := Thread^.ControlBlock.RunNanoseconds;
    Details^.State := DetailsStateOf(Thread);
    Details^.Priority := Thread^.ControlBlock.Priority;
    Details^.LastProcessor := Thread^.ControlBlock.LastProcessorIndex;
    CopyMemory(@Details^.Name[0], @Thread^.ControlBlock.Name[0], ThreadNameLength);
    Details^.Name[ThreadNameCapacity - 1] := #0;
  end;
  Inc(Listing^.Count);
end;

function PerformListThreads(ProcessId: QWord; BufferAddress: QWord; Capacity: QWord): Int64;
var
  Process: PProcess;
  Listing: TThreadListing;
  Copied: QWord;
  Error: LongInt;
begin
  if Capacity > MaximumListedThreads then
    Capacity := MaximumListedThreads;
  if (Capacity > 0) and not UserRangeIsValid(BufferAddress, Capacity * SizeOf(TAbiThreadDetails), True) then
    Exit(Failure(ErrorBadAddress));

  FillMemory(@Listing, SizeOf(Listing), 0);
  Listing.Capacity := Capacity;
  if Capacity > 0 then
  begin
    Listing.Records := PAbiThreadDetails(AllocateZeroedKernelMemory(Capacity * SizeOf(TAbiThreadDetails)));
    if Listing.Records = nil then
      Exit(Failure(ErrorOutOfMemory));
  end;

  LockProcessRegistry;
  if ProcessId = 0 then
    Process := CurrentProcess
  else
    Process := FindRunningProcessLocked(ProcessId);
  if Process <> nil then
    VisitProcessThreads(Process, @DescribeThread, @Listing);
  UnlockProcessRegistry;

  Error := ErrorNone;
  if Process = nil then
    Error := ErrorNotFound
  else if Capacity > 0 then
  begin
    Copied := Listing.Count;
    if Copied > Capacity then
      Copied := Capacity;
    if Copied > 0 then
      Error := CopyToUser(BufferAddress, Listing.Records, Copied * SizeOf(TAbiThreadDetails));
  end;
  FreeKernelMemory(Listing.Records);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Int64(Listing.Count);
end;

end.
