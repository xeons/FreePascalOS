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
  System calls for the limits of a process (CallGetProcessResources,
  CallSetProcessLimit).

  A process may have at most so many regions in its address space
  (Processes.AddressSpace), so many handles (Processes.Handles) and so
  many pages committed (its commit charge; no limit by default). The
  limits are generous by default; a process may lower its own (a
  service that should never need many), and root may raise them up to
  their ceilings. The processes it starts inherit them
  (Processes.UserProcess). CallGetProcessResources shows what a process
  holds against them, which is also how tests see that what a program
  gave back really went.
}
unit Processes.LimitCalls;

{$mode objfpc}

interface

function PerformGetProcessResources(ProcessId: QWord; ResourcesAddress: QWord): Int64;
function PerformSetProcessLimit(Limit: QWord; Value: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.Mutex,
  Objects.Manager,
  Processes.Process,
  Processes.Thread,
  Memory.CommitCharge,
  Processes.AddressSpace,
  Processes.Handles,
  Processes.SecurityCalls,
  Processes.UserAccess;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

procedure DescribeResources(Process: PProcess; out Resources: TAbiProcessResources);
var
  Usage: TAddressSpaceUsage;
begin
  FillMemory(@Resources, SizeOf(Resources), 0);
  AcquireMutex(Process^.Lock);
  Resources.HandleCount := CountOpenHandles(Process^.Handles);
  Resources.HandleLimit := Process^.Handles.Limit;
  Resources.ThreadCount := Process^.ThreadCount;
  { Gone once the process has ended. }
  if Process^.AddressSpace <> nil then
  begin
    GetAddressSpaceUsage(Process^.AddressSpace, Usage);
    Resources.RegionCount := Usage.RegionCount;
    Resources.RegionLimit := Usage.RegionLimit;
    Resources.VirtualBytes := Usage.VirtualBytes;
    Resources.CommittedPages := Usage.ResidentPages;
    Resources.PeakCommittedPages := Usage.PeakResidentPages;
    Resources.SharedPages := Usage.SharedPages;
    Resources.CommitChargePages := Usage.CommitChargePages;
    Resources.CommitLimitPages := Usage.CommitLimitPages;
    Resources.PagesMappedElsewhere := CountPagesMappedElsewhere(Process^.AddressSpace);
  end;
  Resources.SystemCommitChargePages := SystemCommittedPages;
  ReleaseMutex(Process^.Lock);
end;

function PerformGetProcessResources(ProcessId: QWord; ResourcesAddress: QWord): Int64;
var
  Target: PProcess;
  Resources: TAbiProcessResources;
begin
  Target := ReferenceProcess(ProcessId);
  if Target = nil then
    Exit(Failure(ErrorNotFound));
  DescribeResources(Target, Resources);
  DereferenceObject(Target);
  Result := -Int64(CopyToUser(ResourcesAddress, @Resources, SizeOf(Resources)));
end;

function PerformSetProcessLimit(Limit: QWord; Value: QWord): Int64;
var
  Process: PProcess;
  Default: QWord;
  Ceiling: QWord;
  Previous: QWord;
begin
  case Limit of
    ProcessLimitRegions:
      begin
        Default := DefaultRegionLimit;
        Ceiling := RegionLimitCeiling;
      end;
    ProcessLimitHandles:
      begin
        Default := DefaultHandleLimit;
        Ceiling := HandleLimitCeiling;
      end;
    ProcessLimitCommit:
      begin
        { 0 is no limit, which is also the default. }
        Default := 0;
        Ceiling := High(Int64);
      end;
  else
    Exit(Failure(ErrorInvalidArgument));
  end;
  if Value > Ceiling then
    Exit(Failure(ErrorInvalidArgument));

  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  case Limit of
    ProcessLimitRegions: Previous := Process^.AddressSpace^.RegionLimit;
    ProcessLimitCommit: Previous := Process^.AddressSpace^.CommitLimitPages;
  else
    Previous := Process^.Handles.Limit;
  end;
  { Only root may raise a commit limit or take it away (0). }
  if (Process^.Credentials.EffectiveUserId <> RootUserId) and
     (((Limit <> ProcessLimitCommit) and (Value > Previous) and (Value > Default)) or
      ((Limit = ProcessLimitCommit) and (Previous <> 0) and ((Value = 0) or (Value > Previous)))) then
  begin
    ReleaseMutex(Process^.Lock);
    Exit(Failure(ErrorNotPermitted));
  end;
  case Limit of
    ProcessLimitRegions: SetRegionLimit(Process^.AddressSpace, LongWord(Value));
    ProcessLimitCommit: SetCommitLimit(Process^.AddressSpace, Value);
  else
    SetHandleLimit(Process^.Handles, LongWord(Value));
  end;
  ReleaseMutex(Process^.Lock);
  Result := Int64(Previous);
end;

end.
