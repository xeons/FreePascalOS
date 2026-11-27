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
  The job table: pipelines running in the background or stopped.

  A job is the external programs of one pipeline, with the process group
  they run in (in an interactive shell every pipeline has its own group;
  otherwise they share the shell's and GroupId is 0). The shell holds a
  process handle for each program until the job is removed.

  Jobs are numbered from 1, taking the lowest free number. The current
  job ("%+", "%%", and the default for fg and bg) is the one most
  recently started in the background, stopped or brought to the
  foreground; the previous job ("%-") is the one before it.

  The table learns about changes by asking the kernel without waiting
  (UpdateJobs) or by waiting (TJob.WaitUntilDone). A stop is reported
  once per process; a job continued by someone else (kill -CONT) keeps
  showing as stopped until it changes again.
}
unit Shell.Jobs;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Sys.Streams;

const
  MaximumJobs = 32;
  { The status of a pipeline that was stopped: 128 + SIGTSTP. }
  StatusStopped = 148;

type
  TJobState = (JobRunning, JobStopped, JobDone);

  TJobProcess = record
    Handle: Int64;
    ProcessId: Int64;
    Finished: Boolean;
    Status: LongInt;
  end;

  TJob = class
  private
    procedure Poll(Index: Integer);
    procedure Settle;
  public
    Number: Integer;
    { The process group, or 0 when the programs share the shell's. }
    GroupId: Int64;
    Processes: array of TJobProcess;
    State: TJobState;
    { The command line as shown by jobs, fg and bg. }
    Command: string;
    { Larger is more recent; decides the current and previous job. }
    Recency: QWord;
    destructor Destroy; override;
    { Asks the kernel, without waiting, whether programs ended or
      stopped. }
    procedure Update;
    { Waits until every program has ended, or (with ReportStops) until
      one stops. Returns the status of the last program, or
      StatusStopped. }
    function WaitUntilDone(ReportStops: Boolean): LongInt;
    { The status of the last program. }
    function Status: LongInt;
    { Lets the stopped programs run again; the job counts as running. }
    procedure Continue;
    { Ends every program with ExitCode. }
    procedure Terminate(ExitCode: LongInt);
    { Makes the job the current job. }
    procedure Touch;
    { "Running", "Stopped", "Done" or "Exit 3". }
    function StateText: string;
  end;

  THandleArray = array of Int64;

{ Adds a job for the given process handles, which it takes over (when
  the table is full they are closed and nil is returned). }
function AddJob(const Handles: THandleArray; GroupId: Int64; const Command: string;
  State: TJobState): TJob;
{ Closes the job's handles and forgets it. }
procedure RemoveJob(Job: TJob);

{ The job in slot Index (0 .. MaximumJobs - 1), or nil. }
function JobInSlot(Index: Integer): TJob;
{ Finds a job by specification: %N, N, %%, %+, %-, %text (command starts
  with text) or %?text (command contains text). Returns nil if there is
  no such job. }
function FindJob(const Specification: string): TJob;
{ The current job, or nil if there are none. }
function CurrentJob: TJob;
function FindJobByProcessId(ProcessId: Int64): TJob;
{ '+' for the current job, '-' for the previous one, else ' '. }
function JobMark(Job: TJob): Char;

{ Asks the kernel, without waiting, whether programs ended or stopped. }
procedure UpdateJobs;

{ "[1]+  Stopped                 sleep 30" (with " &" for a running
  job when ShowAmpersand). }
procedure PrintJob(Stream: POutputStream; Job: TJob; ShowAmpersand: Boolean);
{ Prints finished jobs ("Done", "Exit 3") on standard error and removes
  them; an interactive shell does this before each prompt. }
procedure NotifyFinishedJobs;

implementation

uses
  Abi.SystemCalls,
  StrUtils,
  Sys.Files,
  Sys.Processes,
  Shell.Text,
  Shell.Output;

var
  Jobs: array[0..MaximumJobs - 1] of TJob;
  RecencyCounter: QWord = 0;

{ --- TJob -------------------------------------------------------------- }

destructor TJob.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Processes) do
    CloseFile(Processes[Index].Handle);
  inherited Destroy;
end;

procedure TJob.Touch;
begin
  Inc(RecencyCounter);
  Recency := RecencyCounter;
end;

{ Asks about one program without waiting. }
procedure TJob.Poll(Index: Integer);
var
  Stopped: Boolean;
  ExitCode: LongInt;
begin
  if Processes[Index].Finished then
    Exit;
  if WaitForProgramChange(Processes[Index].Handle, 0, Stopped, ExitCode) <> ErrorNone then
    Exit;
  if Stopped then
    State := JobStopped
  else
  begin
    Processes[Index].Finished := True;
    Processes[Index].Status := ExitCode;
  end;
end;

procedure TJob.Settle;
var
  Index: Integer;
begin
  for Index := 0 to High(Processes) do
    if not Processes[Index].Finished then
      Exit;
  State := JobDone;
end;

procedure TJob.Update;
var
  Index: Integer;
begin
  if State = JobDone then
    Exit;
  for Index := 0 to High(Processes) do
    Poll(Index);
  Settle;
end;

function TJob.Status: LongInt;
begin
  if State = JobStopped then
    Exit(StatusStopped);
  Result := Processes[High(Processes)].Status;
end;

function TJob.WaitUntilDone(ReportStops: Boolean): LongInt;
var
  Index: Integer;
  Stopped: Boolean;
  ExitCode: LongInt;
begin
  for Index := 0 to High(Processes) do
  begin
    while not Processes[Index].Finished do
    begin
      if WaitForProgramChange(Processes[Index].Handle, InfiniteWait, Stopped, ExitCode) <> ErrorNone then
      begin
        { The handle is unusable; count the program as failed. }
        Processes[Index].Finished := True;
        Processes[Index].Status := 1;
      end
      else if not Stopped then
      begin
        Processes[Index].Finished := True;
        Processes[Index].Status := ExitCode;
      end
      else if ReportStops then
      begin
        State := JobStopped;
        Touch;
        Exit(StatusStopped);
      end;
    end;
  end;
  State := JobDone;
  Result := Status;
end;

procedure TJob.Continue;
var
  Index: Integer;
begin
  if GroupId > 0 then
    ContinuePrograms(-GroupId)
  else
    for Index := 0 to High(Processes) do
      if not Processes[Index].Finished then
        ContinuePrograms(Processes[Index].ProcessId);
  if State = JobStopped then
    State := JobRunning;
end;

procedure TJob.Terminate(ExitCode: LongInt);
var
  Index: Integer;
begin
  for Index := 0 to High(Processes) do
    if not Processes[Index].Finished then
      TerminateProgram(QWord(Processes[Index].ProcessId), ExitCode);
end;

function TJob.StateText: string;
begin
  case State of
    JobRunning: Result := 'Running';
    JobStopped: Result := 'Stopped';
  else
    if Status = 0 then
      Result := 'Done'
    else
      Result := 'Exit ' + IntToStr(Status);
  end;
end;

{ --- The table --------------------------------------------------------- }

function JobInSlot(Index: Integer): TJob;
begin
  if (Index < 0) or (Index >= MaximumJobs) then
    Exit(nil);
  Result := Jobs[Index];
end;

procedure RemoveJob(Job: TJob);
var
  Index: Integer;
begin
  for Index := 0 to MaximumJobs - 1 do
    if Jobs[Index] = Job then
      Jobs[Index] := nil;
  Job.Free;
end;

procedure UpdateJobs;
var
  Slot: Integer;
begin
  for Slot := 0 to MaximumJobs - 1 do
    if Jobs[Slot] <> nil then
      Jobs[Slot].Update;
end;

{ Makes room in a full table by dropping finished jobs. }
procedure DropFinishedJobs;
var
  Slot: Integer;
begin
  UpdateJobs;
  for Slot := 0 to MaximumJobs - 1 do
    if (Jobs[Slot] <> nil) and (Jobs[Slot].State = JobDone) then
      RemoveJob(Jobs[Slot]);
end;

function FreeSlot: Integer;
var
  Slot: Integer;
begin
  for Slot := 0 to MaximumJobs - 1 do
    if Jobs[Slot] = nil then
      Exit(Slot);
  Result := -1;
end;

function AddJob(const Handles: THandleArray; GroupId: Int64; const Command: string;
  State: TJobState): TJob;
var
  Slot: Integer;
  Index: Integer;
begin
  Result := nil;
  Slot := FreeSlot;
  if Slot < 0 then
  begin
    DropFinishedJobs;
    Slot := FreeSlot;
  end;
  if (Slot < 0) or (Length(Handles) = 0) then
  begin
    for Index := 0 to High(Handles) do
      CloseFile(Handles[Index]);
    Exit;
  end;
  Result := TJob.Create;
  Result.Number := Slot + 1;
  Result.GroupId := GroupId;
  SetLength(Result.Processes, Length(Handles));
  for Index := 0 to High(Handles) do
  begin
    Result.Processes[Index].Handle := Handles[Index];
    Result.Processes[Index].ProcessId := ProcessIdOf(Handles[Index]);
  end;
  Result.State := State;
  Result.Command := Command;
  Result.Touch;
  Jobs[Slot] := Result;
end;

{ The most recent job, skipping Excluded. }
function MostRecentJob(Excluded: TJob): TJob;
var
  Slot: Integer;
begin
  Result := nil;
  for Slot := 0 to MaximumJobs - 1 do
  begin
    if (Jobs[Slot] = nil) or (Jobs[Slot] = Excluded) then
      Continue;
    if (Result = nil) or (Jobs[Slot].Recency > Result.Recency) then
      Result := Jobs[Slot];
  end;
end;

function JobMark(Job: TJob): Char;
var
  Current: TJob;
begin
  Current := MostRecentJob(nil);
  if Job = Current then
    Result := '+'
  else if Job = MostRecentJob(Current) then
    Result := '-'
  else
    Result := ' ';
end;

function CurrentJob: TJob;
begin
  Result := MostRecentJob(nil);
end;

{ An empty Part is in every text. }
function TextContains(const Text, Part: string): Boolean;
begin
  Result := (Part = '') or (Pos(Part, Text) > 0);
end;

function FindJob(const Specification: string): TJob;
var
  Number: Int64;
  Slot: Integer;
  Text: string;
begin
  Result := nil;
  if (Specification = '%%') or (Specification = '%+') or (Specification = '%') then
    Exit(CurrentJob);
  if Specification = '%-' then
    Exit(MostRecentJob(CurrentJob));
  Text := Specification;
  if CharAt(Text, 1) = '%' then
    Delete(Text, 1, 1);
  if TryParseInteger(Text, Number) then
  begin
    if (Number >= 1) and (Number <= MaximumJobs) then
      Result := Jobs[Number - 1];
    Exit;
  end;
  if CharAt(Specification, 1) <> '%' then
    Exit;
  for Slot := 0 to MaximumJobs - 1 do
  begin
    if Jobs[Slot] = nil then
      Continue;
    if (CharAt(Text, 1) = '?') and TextContains(Jobs[Slot].Command, Copy(Text, 2, MaxInt)) then
      Exit(Jobs[Slot]);
    if (CharAt(Text, 1) <> '?') and StartsStr(Text, Jobs[Slot].Command) then
      Exit(Jobs[Slot]);
  end;
end;

function FindJobByProcessId(ProcessId: Int64): TJob;
var
  Slot: Integer;
  Index: Integer;
begin
  for Slot := 0 to MaximumJobs - 1 do
  begin
    if Jobs[Slot] = nil then
      Continue;
    for Index := 0 to High(Jobs[Slot].Processes) do
      if Jobs[Slot].Processes[Index].ProcessId = ProcessId then
        Exit(Jobs[Slot]);
  end;
  Result := nil;
end;

procedure PrintJob(Stream: POutputStream; Job: TJob; ShowAmpersand: Boolean);
var
  Line: string;
begin
  Line := Format('[%d]', [Job.Number]) + JobMark(Job) + Format('  %-24s%s', [Job.StateText, Job.Command]);
  if ShowAmpersand and (Job.State = JobRunning) then
    Line := Line + ' &';
  WriteStringLine(Stream, Line);
end;

procedure NotifyFinishedJobs;
var
  Slot: Integer;
begin
  UpdateJobs;
  for Slot := 0 to MaximumJobs - 1 do
    if (Jobs[Slot] <> nil) and (Jobs[Slot].State = JobDone) then
    begin
      PrintJob(StandardError, Jobs[Slot], False);
      RemoveJob(Jobs[Slot]);
    end;
  FlushStream(StandardError);
end;

end.
