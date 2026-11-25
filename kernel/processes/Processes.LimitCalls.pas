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

  Two more settings go through CallSetProcessLimit: how many processes
  the caller's user may run at once (ProcessLimitProcesses, counted
  when a process is started: UserMayStartProcess), and how willingly
  the process is ended when memory runs out (ProcessLimitOomScoreAdjust,
  Processes.OutOfMemory), passed as the adjustment plus
  OomScoreAdjustOffset so that it is never negative.
}
unit Processes.LimitCalls;

{$mode objfpc}

interface

function PerformGetProcessResources(ProcessId: QWord; ResourcesAddress: QWord): Int64;
function PerformSetProcessLimit(Limit: QWord; Value: QWord): Int64;

{ True if the user may start another process: fewer of its processes
  run than Limit (0: the default); root always may. }
function UserMayStartProcess(UserId: LongWord; Limit: LongWord): Boolean;

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
  Processes.UserAccess,
  Processes.Restrictions;

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
  Resources.SystemCommitChargePages := Memory.CommitCharge.SystemCommittedPages;
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

type
  TUserProcessCount = record
    UserId: LongWord;
    Count: LongWord;
  end;
  PUserProcessCount = ^TUserProcessCount;

procedure CountProcessOfUser(Process: PProcess; Context: Pointer);
var
  Counting: PUserProcessCount;
begin
  Counting := PUserProcessCount(Context);
  if Process^.IsUserProcess and not Process^.HasExited and
     (Process^.Credentials.RealUserId = Counting^.UserId) then
    Inc(Counting^.Count);
end;

function UserMayStartProcess(UserId: LongWord; Limit: LongWord): Boolean;
var
  Counting: TUserProcessCount;
begin
  if UserId = RootUserId then
    Exit(True);
  if Limit = 0 then
    Limit := DefaultProcessCountLimit;
  Counting.UserId := UserId;
  Counting.Count := 0;
  LockProcessRegistry;
  VisitRunningProcessesLocked(@CountProcessOfUser, @Counting);
  UnlockProcessRegistry;
  Result := Counting.Count < Limit;
end;

function EffectiveProcessCountLimit(Process: PProcess): QWord;
begin
  Result := Process^.ProcessCountLimit;
  if Result = 0 then
    Result := DefaultProcessCountLimit;
end;

{ ProcessLimitOomScoreAdjust: Value is the adjustment plus the offset. }
function SetOomScoreAdjust(Value: QWord): Int64;
var
  Process: PProcess;
  Adjust: LongInt;
begin
  if Value > 2 * OomScoreAdjustOffset then
    Exit(Failure(ErrorInvalidArgument));
  Adjust := LongInt(Value) - OomScoreAdjustOffset;
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := Int64(Process^.OomScoreAdjust + OomScoreAdjustOffset);
  { Becoming harder to choose than the default is root's. }
  if (Adjust < Process^.OomScoreAdjust) and (Adjust < 0) and
     (Process^.Credentials.EffectiveUserId <> RootUserId) then
    Result := Failure(ErrorNotPermitted)
  else
    Process^.OomScoreAdjust := Adjust;
  ReleaseMutex(Process^.Lock);
end;

function SetProcessCountLimit(Value: QWord): Int64;
var
  Process: PProcess;
begin
  if (Value = 0) or (Value > ProcessCountLimitCeiling) then
    Exit(Failure(ErrorInvalidArgument));
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := Int64(EffectiveProcessCountLimit(Process));
  if (Value > QWord(Result)) and (Value > DefaultProcessCountLimit) and
     (Process^.Credentials.EffectiveUserId <> RootUserId) then
    Result := Failure(ErrorNotPermitted)
  else
    Process^.ProcessCountLimit := LongWord(Value);
  ReleaseMutex(Process^.Lock);
end;

function PerformSetProcessLimit(Limit: QWord; Value: QWord): Int64;
var
  Process: PProcess;
  Default: QWord;
  Ceiling: QWord;
  Previous: QWord;
begin
  if Limit = ProcessLimitOomScoreAdjust then
    Exit(SetOomScoreAdjust(Value));
  if Limit = ProcessLimitProcesses then
    Exit(SetProcessCountLimit(Value));
  if Limit = ProcessLimitRestrictions then
    Exit(AddRestrictions(Value));
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
