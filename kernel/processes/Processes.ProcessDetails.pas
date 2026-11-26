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
  Describing the running processes for a task manager and ps
  (CallListProcessDetails): who they are, their state, their processor
  time and their memory, all in one call.

  The list is taken under the registry lock, so no process starts or
  ends halfway through it, and each record goes straight to the
  caller's buffer. Anyone may see every process, as with ps on Unix;
  only the command line, which may carry what a user typed (a file
  name, a password given as an argument), is kept to its own user and
  root.
}
unit Processes.ProcessDetails;

{$mode objfpc}

interface

uses
  Abi.SystemCalls,
  Processes.Process;

function PerformListProcessDetails(BufferAddress: QWord; Capacity: QWord): Int64;

{ Fills Details for Process (the registry lock held, so it keeps
  running), as seen by a caller acting as CallerUserId. }
procedure DescribeProcessDetails(Process: PProcess; CallerUserId: LongWord; out Details: TAbiProcessDetails);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.Layout,
  Kernel.ProcessorTime,
  Kernel.Clock,
  Io.Manager,
  Processes.AddressSpace,
  Processes.Handles,
  Processes.Thread,
  Processes.UserThread,
  Processes.UserAccess;

function StateOf(Process: PProcess): LongWord;
begin
  if Process^.HasExited or Process^.TerminationRequested then
    Result := ProcessStateExiting
  else if Process^.IsStopped then
    Result := ProcessStateStopped
  else if ProcessIsRunnable(Process) then
    Result := ProcessStateRunning
  else
    Result := ProcessStateSleeping;
end;

procedure DescribeTimes(Process: PProcess; var Details: TAbiProcessDetails);
var
  Times: TThreadTimes;
begin
  GetProcessTimes(Process, Times);
  Details.ProcessorNanoseconds := Times.RunNanoseconds;
  SplitRunTime(Times, Details.UserNanoseconds, Details.KernelNanoseconds);
end;

procedure DescribeMemory(Process: PProcess; var Details: TAbiProcessDetails);
var
  Usage: TAddressSpaceUsage;
begin
  if not ReadPublishedSpaceUsage(Process^.AddressSpace, Usage) then
    Exit;
  Details.VirtualBytes := Usage.VirtualBytes;
  Details.ResidentBytes := Usage.ResidentPages * PageSize;
  Details.SharedBytes := Usage.SharedPages * PageSize;
  Details.PrivateBytes := (Usage.ResidentPages - Usage.SharedPages) * PageSize;
  Details.PeakResidentBytes := Usage.PeakResidentPages * PageSize;
end;

function MaySeeCommandLine(Process: PProcess; CallerUserId: LongWord): Boolean;
begin
  Result := (CallerUserId = RootUserId) or (Process^.Credentials.RealUserId = CallerUserId) or
    (Process^.Credentials.EffectiveUserId = CallerUserId);
end;

procedure DescribeProcessDetails(Process: PProcess; CallerUserId: LongWord; out Details: TAbiProcessDetails);
begin
  FillMemory(@Details, SizeOf(Details), 0);
  Details.ProcessId := Process^.ProcessId;
  Details.ParentProcessId := Process^.ParentProcessId;
  Details.GroupId := Process^.GroupId;
  Details.SessionId := Process^.SessionId;
  Details.RealUserId := Process^.Credentials.RealUserId;
  Details.EffectiveUserId := Process^.Credentials.EffectiveUserId;
  Details.State := StateOf(Process);
  Details.ThreadCount := Process^.ThreadCount;
  Details.HandleCount := CountOpenHandles(Process^.Handles);
  Details.Nice := Process^.Credentials.Nice;
  Details.Priority := ProcessThreadPriority(Process);
  Details.PriorityClass := Process^.PriorityClass;
  if Process^.Job <> nil then
    Details.Flags := Details.Flags or ProcessDetailsInJob;
  if Process^.IgnoresInterrupt then
    Details.Flags := Details.Flags or ProcessDetailsIgnoresInterrupt;
  Details.StartTime := Process^.StartTime;
  Details.StartUptimeMilliseconds := Process^.StartUptimeNanoseconds div NanosecondsPerMillisecond;
  DescribeTimes(Process, Details);
  DescribeMemory(Process, Details);
  CopyText(@Details.Name[0], @Process^.Name[0], AbiTextCapacity);
  if Process^.ControllingTerminal <> nil then
    CopyText(@Details.Terminal[0], @PDeviceObject(Process^.ControllingTerminal)^.Name[0], AbiTerminalNameCapacity);
  if MaySeeCommandLine(Process, CallerUserId) then
    CopyText(@Details.CommandLine[0], @Process^.CommandLine[0], AbiCommandLineCapacity)
  else
    Details.Flags := Details.Flags or ProcessDetailsCommandLineHidden;
end;

type
  TListing = record
    BufferAddress: QWord;
    Capacity: QWord;
    CallerUserId: LongWord;
    Count: QWord;
    Error: LongInt;
  end;
  PListing = ^TListing;

procedure ListOne(Process: PProcess; Context: Pointer);
var
  Listing: PListing;
  Details: TAbiProcessDetails;
begin
  Listing := PListing(Context);
  if not Process^.IsUserProcess then
    Exit;
  if (Listing^.Count < Listing^.Capacity) and (Listing^.Error = ErrorNone) then
  begin
    DescribeProcessDetails(Process, Listing^.CallerUserId, Details);
    Listing^.Error := CopyToUser(Listing^.BufferAddress + Listing^.Count * SizeOf(Details), @Details,
      SizeOf(Details));
  end;
  Inc(Listing^.Count);
end;

function PerformListProcessDetails(BufferAddress: QWord; Capacity: QWord): Int64;
var
  Listing: TListing;
begin
  Listing.BufferAddress := BufferAddress;
  Listing.Capacity := Capacity;
  Listing.CallerUserId := CurrentProcess^.Credentials.EffectiveUserId;
  Listing.Count := 0;
  Listing.Error := ErrorNone;
  LockProcessRegistryShared;
  VisitRunningProcessesLocked(@ListOne, @Listing);
  UnlockProcessRegistry;
  if Listing.Error <> ErrorNone then
    Exit(-Int64(Listing.Error));
  Result := Int64(Listing.Count);
end;

end.
