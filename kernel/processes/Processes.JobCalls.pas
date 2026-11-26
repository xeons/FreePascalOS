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
  The system calls of jobs (Processes.Jobs): CallCreateJob,
  CallAssignProcessToJob, CallSetJobLimit, CallGetJobInformation.
}
unit Processes.JobCalls;

{$mode objfpc}

interface

function PerformCreateJob(Flags: QWord): Int64;
function PerformAssignProcessToJob(JobHandle, ProcessHandle: Int64): Int64;
function PerformSetJobLimit(JobHandle: Int64; Limit, Value: QWord): Int64;
function PerformGetJobInformation(JobHandle: Int64; InformationAddress: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.Mutex,
  Memory.CommitCharge,
  Objects.Manager,
  Processes.Process,
  Processes.Handles,
  Processes.Thread,
  Processes.UserAccess,
  Processes.Jobs;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function PerformCreateJob(Flags: QWord): Int64;
var
  Job: PJob;
begin
  if Flags <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  Job := CreateJob;
  if Job = nil then
    Exit(Failure(ErrorOutOfMemory));
  AcquireMutex(CurrentProcess^.Lock);
  Result := InsertHandle(CurrentProcess^.Handles, Processes.Handles.HandleKindJob, Job, 0);
  ReleaseMutex(CurrentProcess^.Lock);
  DereferenceObject(Job);
  if Result < 0 then
    Result := Failure(ErrorTooManyHandles);
end;

{ The job behind Handle, referenced; nil if it is not a job's. }
function ReferenceJob(Handle: Int64): PJob;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  Result := nil;
  ObjectBody := ReferenceHandleEntry(CurrentProcess^.Handles, Handle, Kind);
  if ObjectBody = nil then
    Exit;
  if Kind = Processes.Handles.HandleKindJob then
    Result := PJob(ObjectBody)
  else
    DereferenceObject(ObjectBody);
end;

{ The process behind Handle (CurrentProcessHandle: the caller),
  referenced; nil if it is not a process's. }
function ReferenceTargetProcess(Handle: Int64): PProcess;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  if Handle = CurrentProcessHandle then
  begin
    Result := CurrentProcess;
    ReferenceObject(Result);
    Exit;
  end;
  Result := nil;
  ObjectBody := ReferenceHandleEntry(CurrentProcess^.Handles, Handle, Kind);
  if ObjectBody = nil then
    Exit;
  if Kind = Processes.Handles.HandleKindProcess then
    Result := PProcess(ObjectBody)
  else
    DereferenceObject(ObjectBody);
end;

function MayControl(Caller, Target: PProcess): Boolean;
var
  CallerUserId: LongWord;
begin
  CallerUserId := Caller^.Credentials.EffectiveUserId;
  Result := (CallerUserId = RootUserId) or (Caller = Target) or
    (CallerUserId = Target^.Credentials.RealUserId) or (CallerUserId = Target^.Credentials.EffectiveUserId);
end;

function PerformAssignProcessToJob(JobHandle, ProcessHandle: Int64): Int64;
var
  Job: PJob;
  Target: PProcess;
begin
  Job := ReferenceJob(JobHandle);
  if Job = nil then
    Exit(Failure(ErrorBadHandle));
  Target := ReferenceTargetProcess(ProcessHandle);
  if Target = nil then
    Result := Failure(ErrorBadHandle)
  else if not Target^.IsUserProcess or Target^.HasExited then
    Result := Failure(ErrorNoSuchProcess)
  else if not MayControl(CurrentProcess, Target) then
    Result := Failure(ErrorNotPermitted)
  else
    Result := -Int64(AssignProcessToJob(Target, Job));
  if Target <> nil then
    DereferenceObject(Target);
  DereferenceObject(Job);
end;

function PerformSetJobLimit(JobHandle: Int64; Limit, Value: QWord): Int64;
var
  Job: PJob;
begin
  Job := ReferenceJob(JobHandle);
  if Job = nil then
    Exit(Failure(ErrorBadHandle));
  if Limit = JobLimitCommit then
    Result := Int64(SetCommitPoolLimit(@Job^.Pool, Value))
  else
    Result := Failure(ErrorInvalidArgument);
  DereferenceObject(Job);
end;

function PerformGetJobInformation(JobHandle: Int64; InformationAddress: QWord): Int64;
var
  Job: PJob;
  Information: TAbiJobInformation;
begin
  Job := ReferenceJob(JobHandle);
  if Job = nil then
    Exit(Failure(ErrorBadHandle));
  FillMemory(@Information, SizeOf(Information), 0);
  Information.ActiveProcesses := CountJobProcesses(Job);
  Information.TotalProcesses := LongWord(Job^.TotalProcesses);
  Information.CommitChargePages := Job^.Pool.ChargedPages;
  Information.PeakCommitChargePages := Job^.Pool.PeakPages;
  Information.CommitLimitPages := Job^.Pool.LimitPages;
  Information.CommitFailures := Job^.Pool.Failures;
  DereferenceObject(Job);
  Result := -Int64(CopyToUser(InformationAddress, @Information, SizeOf(Information)));
end;

end.
