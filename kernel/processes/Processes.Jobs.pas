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
  Jobs: groups of processes whose memory is charged together against
  one limit - a browser's content processes, so that all the pages it
  renders together cannot take more than their share of the machine,
  whatever each one's own limit (ProcessLimitCommit).

  A job is an object (handles of HandleKindJob). A process joins one
  for good (CallAssignProcessToJob): its commit charge, and that of the
  sections it made, moves into the job's pool (Memory.CommitCharge), and
  every commitment after is charged to the process, the job and the
  system together, refused if any of them would go over its limit. The
  processes it starts or forks are in the job from their start
  (JoinJobAtStart). Each member references the job, as does each of
  its address spaces (whose charge is given back to the pool when the
  space goes), so a job lives as long as anything is charged to it.
}
unit Processes.Jobs;

{$mode objfpc}

interface

uses
  Memory.CommitCharge,
  Objects.Manager,
  Processes.Process;

type
  PJob = ^TJob;
  TJob = record
    { First: a member's address space and its sections charge the job
      through a PCommitPool pointing here. }
    Pool: TCommitPool;
    { Processes that ever joined. }
    TotalProcesses: Int64;
  end;

var
  JobObjectType: TObjectType;

procedure InitializeJobs;
function CreateJob: PJob;
{ Puts Process (running) in Job: an Abi error code (ErrorExists if it is
  in a job already). }
function AssignProcessToJob(Process: PProcess; Job: PJob): LongInt;
{ A process being made (fork, spawn) joins Job, the job of the one that
  makes it, before anything is charged to it (nil: none). }
procedure JoinJobAtStart(Process: PProcess; Job: PJob);
{ The processes in Job now. }
function CountJobProcesses(Job: PJob): LongWord;

implementation

uses
  Runtime.Atomic,
  Abi.SystemCalls,
  Kernel.Mutex,
  Processes.AddressSpace;

procedure DeleteJob(ObjectBody: Pointer);
begin
end;

procedure InitializeJobs;
begin
  RegisterObjectType(JobObjectType, 'Job', SizeOf(TJob), @DeleteJob);
end;

function CreateJob: PJob;
begin
  Result := PJob(CreateObject(JobObjectType, nil));
  if Result = nil then
    Exit;
  InitializeCommitPool(Result^.Pool);
  Result^.TotalProcesses := 0;
end;

procedure JoinJobAtStart(Process: PProcess; Job: PJob);
begin
  if (Job = nil) or (Process^.Job <> nil) then
    Exit;
  ReferenceObject(Job);
  Process^.Job := Job;
  AtomicIncrement(Job^.TotalProcesses);
  if Process^.AddressSpace <> nil then
    JoinCommitPool(Process^.AddressSpace, @Job^.Pool, Job);
end;

function AssignProcessToJob(Process: PProcess; Job: PJob): LongInt;
var
  Space: PAddressSpace;
begin
  AcquireMutex(Process^.Lock);
  if Process^.Job <> nil then
  begin
    ReleaseMutex(Process^.Lock);
    Exit(ErrorExists);
  end;
  ReferenceObject(Job);
  Process^.Job := Job;
  ReleaseMutex(Process^.Lock);
  AtomicIncrement(Job^.TotalProcesses);
  if Process^.SectionChargePages > 0 then
    ForceChargeCommitPool(@Job^.Pool, QWord(Process^.SectionChargePages));
  Space := ReferencePublishedSpace(Process^.AddressSpace);
  if Space <> nil then
  begin
    JoinCommitPool(Space, @Job^.Pool, Job);
    ReleaseAddressSpaceReference(Space);
  end;
  Result := ErrorNone;
end;

type
  TMemberCount = record
    Job: PJob;
    Count: LongWord;
  end;
  PMemberCount = ^TMemberCount;

procedure CountMember(Process: PProcess; Context: Pointer);
begin
  if (Process^.Job = PMemberCount(Context)^.Job) and not Process^.HasExited then
    Inc(PMemberCount(Context)^.Count);
end;

function CountJobProcesses(Job: PJob): LongWord;
var
  Members: TMemberCount;
begin
  Members.Job := Job;
  Members.Count := 0;
  LockProcessRegistryShared;
  VisitRunningProcessesLocked(@CountMember, @Members);
  UnlockProcessRegistry;
  Result := Members.Count;
end;

end.
