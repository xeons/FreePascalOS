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
  (UpdateJobs) or by waiting (WaitForJob). A stop is reported once per
  process; a job continued by someone else (kill -CONT) keeps showing as
  stopped until it changes again.
}
unit Shell.Jobs;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.Streams;

const
  MaximumJobs = 32;
  MaximumJobProcesses = 16;
  { The status of a pipeline that was stopped: 128 + SIGTSTP. }
  StatusStopped = 148;

type
  TJobState = (JobRunning, JobStopped, JobDone);

  PJob = ^TJob;
  TJob = record
    Number: Integer;
    { The process group, or 0 when the programs share the shell's. }
    GroupId: Int64;
    Count: Integer;
    Handles: array[0..MaximumJobProcesses - 1] of Int64;
    ProcessIds: array[0..MaximumJobProcesses - 1] of Int64;
    Finished: array[0..MaximumJobProcesses - 1] of Boolean;
    Statuses: array[0..MaximumJobProcesses - 1] of LongInt;
    State: TJobState;
    { The command line as shown by jobs, fg and bg. }
    Command: PChar;
    { Larger is more recent; decides the current and previous job. }
    Recency: QWord;
  end;

{ Adds a job for the given process handles, which it takes over (when
  the table is full they are closed and nil is returned). }
function AddJob(Handles: PInt64; Count: Integer; GroupId: Int64; Command: PChar;
  State: TJobState): PJob;
{ Closes the job's handles and forgets it. }
procedure RemoveJob(Job: PJob);

{ The job in slot Index (0 .. MaximumJobs - 1), or nil. }
function JobInSlot(Index: Integer): PJob;
{ Finds a job by specification: %N, N, %%, %+, %-, %text (command starts
  with text) or %?text (command contains text); nil means the current
  job. Returns nil if there is no such job. }
function FindJob(Specification: PChar): PJob;
function FindJobByProcessId(ProcessId: Int64): PJob;
{ '+' for the current job, '-' for the previous one, else ' '. }
function JobMark(Job: PJob): Char;
{ Makes Job the current job. }
procedure TouchJob(Job: PJob);

{ Asks the kernel, without waiting, whether programs ended or stopped. }
procedure UpdateJobs;
{ Waits until every program of the job has ended, or (with ReportStops)
  until one stops. Returns the status of the job's last program, or
  StatusStopped. }
function WaitForJob(Job: PJob; ReportStops: Boolean): LongInt;
{ The status of the job's last program. }
function JobStatus(Job: PJob): LongInt;
{ Lets the job's stopped programs run again; it counts as running. }
procedure ContinueJob(Job: PJob);
{ Ends every program of the job with ExitCode. }
procedure TerminateJob(Job: PJob; ExitCode: LongInt);

{ "[1]+  Stopped                 sleep 30" (with " &" for a running
  job when ShowAmpersand). }
procedure PrintJob(Stream: POutputStream; Job: PJob; ShowAmpersand: Boolean);
{ Prints finished jobs ("Done", "Exit 3") on standard error and removes
  them; an interactive shell does this before each prompt. }
procedure NotifyFinishedJobs;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Processes,
  Sys.Text;

var
  Jobs: array[0..MaximumJobs - 1] of PJob;
  RecencyCounter: QWord = 0;

function JobInSlot(Index: Integer): PJob;
begin
  if (Index < 0) or (Index >= MaximumJobs) then
    Exit(nil);
  Result := Jobs[Index];
end;

procedure TouchJob(Job: PJob);
begin
  Inc(RecencyCounter);
  Job^.Recency := RecencyCounter;
end;

procedure RemoveJob(Job: PJob);
var
  Index: Integer;
begin
  for Index := 0 to Job^.Count - 1 do
    CloseFile(Job^.Handles[Index]);
  for Index := 0 to MaximumJobs - 1 do
  begin
    if Jobs[Index] = Job then
      Jobs[Index] := nil;
  end;
  FreeMemory(Job^.Command);
  FreeMemory(Job);
end;

{ Asks about one program without waiting. }
procedure PollProcess(Job: PJob; Index: Integer);
var
  Stopped: Boolean;
  ExitCode: LongInt;
begin
  if Job^.Finished[Index] then
    Exit;
  if WaitForProgramChange(Job^.Handles[Index], 0, Stopped, ExitCode) <> ErrorNone then
    Exit;
  if Stopped then
    Job^.State := JobStopped
  else
  begin
    Job^.Finished[Index] := True;
    Job^.Statuses[Index] := ExitCode;
  end;
end;

procedure SettleJobState(Job: PJob);
var
  Index: Integer;
begin
  for Index := 0 to Job^.Count - 1 do
  begin
    if not Job^.Finished[Index] then
      Exit;
  end;
  Job^.State := JobDone;
end;

procedure UpdateJobs;
var
  Slot: Integer;
  Index: Integer;
  Job: PJob;
begin
  for Slot := 0 to MaximumJobs - 1 do
  begin
    Job := Jobs[Slot];
    if (Job = nil) or (Job^.State = JobDone) then
      Continue;
    for Index := 0 to Job^.Count - 1 do
      PollProcess(Job, Index);
    SettleJobState(Job);
  end;
end;

{ Makes room in a full table by dropping finished jobs. }
procedure DropFinishedJobs;
var
  Slot: Integer;
begin
  UpdateJobs;
  for Slot := 0 to MaximumJobs - 1 do
  begin
    if (Jobs[Slot] <> nil) and (Jobs[Slot]^.State = JobDone) then
      RemoveJob(Jobs[Slot]);
  end;
end;

function FreeSlot: Integer;
var
  Slot: Integer;
begin
  for Slot := 0 to MaximumJobs - 1 do
  begin
    if Jobs[Slot] = nil then
      Exit(Slot);
  end;
  Result := -1;
end;

function AddJob(Handles: PInt64; Count: Integer; GroupId: Int64; Command: PChar;
  State: TJobState): PJob;
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
  if (Slot < 0) or (Count > MaximumJobProcesses) or (Count = 0) then
  begin
    for Index := 0 to Count - 1 do
      CloseFile(Handles[Index]);
    Exit;
  end;
  Result := PJob(AllocateZeroedMemory(SizeOf(TJob)));
  Result^.Number := Slot + 1;
  Result^.GroupId := GroupId;
  Result^.Count := Count;
  for Index := 0 to Count - 1 do
  begin
    Result^.Handles[Index] := Handles[Index];
    Result^.ProcessIds[Index] := ProcessIdOf(Handles[Index]);
  end;
  Result^.State := State;
  Result^.Command := DuplicateText(Command);
  TouchJob(Result);
  Jobs[Slot] := Result;
end;

{ The most recent job, skipping Excluded. }
function MostRecentJob(Excluded: PJob): PJob;
var
  Slot: Integer;
begin
  Result := nil;
  for Slot := 0 to MaximumJobs - 1 do
  begin
    if (Jobs[Slot] = nil) or (Jobs[Slot] = Excluded) then
      Continue;
    if (Result = nil) or (Jobs[Slot]^.Recency > Result^.Recency) then
      Result := Jobs[Slot];
  end;
end;

function JobMark(Job: PJob): Char;
var
  Current: PJob;
begin
  Current := MostRecentJob(nil);
  if Job = Current then
    Result := '+'
  else if Job = MostRecentJob(Current) then
    Result := '-'
  else
    Result := ' ';
end;

function FindJob(Specification: PChar): PJob;
var
  Number: Int64;
  Slot: Integer;
  Text: PChar;
begin
  Result := nil;
  if (Specification = nil) or TextIsEqual(Specification, '%%') or
     TextIsEqual(Specification, '%+') or TextIsEqual(Specification, '%') then
    Exit(MostRecentJob(nil));
  if TextIsEqual(Specification, '%-') then
    Exit(MostRecentJob(MostRecentJob(nil)));
  Text := Specification;
  if Text[0] = '%' then
    Inc(Text);
  if ParseInteger(Text, Number) then
  begin
    if (Number >= 1) and (Number <= MaximumJobs) then
      Result := Jobs[Number - 1];
    Exit;
  end;
  if Specification[0] <> '%' then
    Exit;
  for Slot := 0 to MaximumJobs - 1 do
  begin
    if Jobs[Slot] = nil then
      Continue;
    if (Text[0] = '?') and (FindText(Jobs[Slot]^.Command, Text + 1) >= 0) then
      Exit(Jobs[Slot]);
    if (Text[0] <> '?') and TextStartsWith(Jobs[Slot]^.Command, Text) then
      Exit(Jobs[Slot]);
  end;
end;

function FindJobByProcessId(ProcessId: Int64): PJob;
var
  Slot: Integer;
  Index: Integer;
begin
  for Slot := 0 to MaximumJobs - 1 do
  begin
    if Jobs[Slot] = nil then
      Continue;
    for Index := 0 to Jobs[Slot]^.Count - 1 do
    begin
      if Jobs[Slot]^.ProcessIds[Index] = ProcessId then
        Exit(Jobs[Slot]);
    end;
  end;
  Result := nil;
end;

function JobStatus(Job: PJob): LongInt;
begin
  if Job^.State = JobStopped then
    Exit(StatusStopped);
  Result := Job^.Statuses[Job^.Count - 1];
end;

function WaitForJob(Job: PJob; ReportStops: Boolean): LongInt;
var
  Index: Integer;
  Stopped: Boolean;
  ExitCode: LongInt;
begin
  for Index := 0 to Job^.Count - 1 do
  begin
    while not Job^.Finished[Index] do
    begin
      if WaitForProgramChange(Job^.Handles[Index], InfiniteWait, Stopped, ExitCode) <> ErrorNone then
      begin
        { The handle is unusable; count the program as failed. }
        Job^.Finished[Index] := True;
        Job^.Statuses[Index] := 1;
      end
      else if not Stopped then
      begin
        Job^.Finished[Index] := True;
        Job^.Statuses[Index] := ExitCode;
      end
      else if ReportStops then
      begin
        Job^.State := JobStopped;
        TouchJob(Job);
        Exit(StatusStopped);
      end;
    end;
  end;
  Job^.State := JobDone;
  Result := JobStatus(Job);
end;

procedure ContinueJob(Job: PJob);
var
  Index: Integer;
begin
  if Job^.GroupId > 0 then
    ContinuePrograms(-Job^.GroupId)
  else
  begin
    for Index := 0 to Job^.Count - 1 do
    begin
      if not Job^.Finished[Index] then
        ContinuePrograms(Job^.ProcessIds[Index]);
    end;
  end;
  if Job^.State = JobStopped then
    Job^.State := JobRunning;
end;

procedure TerminateJob(Job: PJob; ExitCode: LongInt);
var
  Index: Integer;
begin
  for Index := 0 to Job^.Count - 1 do
  begin
    if not Job^.Finished[Index] then
      TerminateProgram(QWord(Job^.ProcessIds[Index]), ExitCode);
  end;
end;

procedure PrintJob(Stream: POutputStream; Job: PJob; ShowAmpersand: Boolean);
var
  StateText: array[0..31] of Char;
  Status: LongInt;
  Formatted: PChar;
begin
  case Job^.State of
    JobRunning: CopyText(@StateText[0], 'Running', SizeOf(StateText));
    JobStopped: CopyText(@StateText[0], 'Stopped', SizeOf(StateText));
  else
    begin
      Status := JobStatus(Job);
      if Status = 0 then
        CopyText(@StateText[0], 'Done', SizeOf(StateText))
      else
      begin
        Formatted := FormatText('Exit %d', [ArgumentNumber(Status)]);
        CopyText(@StateText[0], Formatted, SizeOf(StateText));
        FreeMemory(Formatted);
      end;
    end;
  end;
  WriteFormatted(Stream, '[%d]%c  %-24s%s', [ArgumentNumber(Job^.Number),
    ArgumentCharacter(JobMark(Job)), ArgumentText(@StateText[0]), ArgumentText(Job^.Command)]);
  if ShowAmpersand and (Job^.State = JobRunning) then
    WriteText(Stream, ' &');
  WriteCharacter(Stream, #10);
end;

procedure NotifyFinishedJobs;
var
  Slot: Integer;
begin
  UpdateJobs;
  for Slot := 0 to MaximumJobs - 1 do
  begin
    if (Jobs[Slot] <> nil) and (Jobs[Slot]^.State = JobDone) then
    begin
      PrintJob(StandardError, Jobs[Slot], False);
      RemoveJob(Jobs[Slot]);
    end;
  end;
  FlushStream(StandardError);
end;

end.
