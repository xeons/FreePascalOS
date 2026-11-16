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
  The job control builtins: jobs, fg, bg, wait and kill.

    jobs [-l | -p] [JOB...]   list jobs (finished ones are then forgotten)
    fg [JOB]                  continue a job in the foreground and wait
    bg [JOB...]               continue stopped jobs in the background
    wait [JOB | PID...]       wait for jobs to end (all running ones
                              without operands)
    kill [OPTIONS] TARGET...  /bin/kill, with job specifications (%1)
                              replaced by the job's process ids

  A job is named as described in Shell.Jobs (%1, %+, %-, %name). In an
  interactive shell, fg makes the job's process group the console's
  foreground group while it waits, so Ctrl-C and Ctrl-Z reach the job,
  and wait can be cut short by Ctrl-C.
}
unit Shell.JobBuiltins;

{$mode objfpc}
{$H+}

interface

uses
  Shell.Builtins;

{ Returns nil if Name is not one of these builtins. }
function FindJobBuiltin(const Name: string): TBuiltinRoutine;

implementation

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Errors,
  Sys.Processes,
  Sys.Streams,
  Shell.Text,
  Shell.Output,
  Shell.Host,
  Shell.Variables,
  Shell.Execution,
  Shell.Jobs;

const
  StatusInterrupted = 130;
  StatusNotChild = 127;
  StatusCannotRun = 126;
  PollMilliseconds = 20;

{ The job named by Specification, or reports it. }
function LookUpJob(const Name, Specification: string): TJob;
begin
  Result := FindJob(Specification);
  if Result = nil then
    CommandError(Name, Specification + ': no such job');
end;

{ The current job, or reports that there is none. }
function LookUpCurrentJob(const Name: string): TJob;
begin
  Result := CurrentJob;
  if Result = nil then
    CommandError(Name, 'current: no such job');
end;

{ --- jobs ---------------------------------------------------------------- }

procedure ListJob(Job: TJob; ShowProcessIds, OnlyProcessIds: Boolean);
var
  Index: Integer;
  StateText: string;
  Line: string;
begin
  if OnlyProcessIds then
  begin
    for Index := 0 to High(Job.Processes) do
      WriteStringLine(StandardOutput, IntToStr(Job.Processes[Index].ProcessId));
    Exit;
  end;
  if not ShowProcessIds then
  begin
    PrintJob(StandardOutput, Job, True);
    Exit;
  end;
  { "[N]+ PID", then the state and command. }
  case Job.State of
    JobRunning: StateText := 'Running';
    JobStopped: StateText := 'Stopped';
  else
    StateText := 'Done';
  end;
  Line := Format('[%d]', [Job.Number]) + JobMark(Job) + Format(' %d %-24s%s',
    [Job.Processes[0].ProcessId, StateText, Job.Command]);
  if Job.State = JobRunning then
    Line := Line + ' &';
  WriteStringLine(StandardOutput, Line);
end;

{ Forgets the jobs that have finished (they have now been reported). }
procedure RemoveFinishedJobs;
var
  Index: Integer;
  Job: TJob;
begin
  for Index := 0 to MaximumJobs - 1 do
  begin
    Job := JobInSlot(Index);
    if (Job <> nil) and (Job.State = JobDone) then
      RemoveJob(Job);
  end;
end;

function BuiltinJobs(Arguments: TStrings): LongInt;
var
  ShowProcessIds: Boolean;
  OnlyProcessIds: Boolean;
  First: Integer;
  Index: Integer;
  Job: TJob;
begin
  Result := 0;
  ShowProcessIds := False;
  OnlyProcessIds := False;
  First := 1;
  while (First < Arguments.Count) and (CharAt(Arguments[First], 1) = '-') and (Length(Arguments[First]) > 1) do
  begin
    if Arguments[First] = '-l' then
      ShowProcessIds := True
    else if Arguments[First] = '-p' then
      OnlyProcessIds := True
    else
    begin
      CommandError('jobs', Arguments[First] + ': invalid option');
      Exit(2);
    end;
    Inc(First);
  end;

  UpdateJobs;
  if First < Arguments.Count then
  begin
    for Index := First to Arguments.Count - 1 do
    begin
      Job := LookUpJob('jobs', Arguments[Index]);
      if Job = nil then
        Result := 1
      else
        ListJob(Job, ShowProcessIds, OnlyProcessIds);
    end;
  end
  else
  begin
    for Index := 0 to MaximumJobs - 1 do
    begin
      Job := JobInSlot(Index);
      if Job <> nil then
        ListJob(Job, ShowProcessIds, OnlyProcessIds);
    end;
  end;
  FlushStream(StandardOutput);
  RemoveFinishedJobs;
end;

{ --- fg and bg ----------------------------------------------------------- }

function BuiltinForeground(Arguments: TStrings): LongInt;
var
  Job: TJob;
  OwnsConsole: Boolean;
begin
  if Arguments.Count > 2 then
  begin
    CommandError('fg', 'too many arguments');
    Exit(2);
  end;
  UpdateJobs;
  if Arguments.Count = 2 then
    Job := LookUpJob('fg', Arguments[1])
  else
    Job := LookUpCurrentJob('fg');
  if Job = nil then
    Exit(1);

  WriteStringLine(StandardOutput, Job.Command);
  FlushStream(StandardOutput);
  OwnsConsole := ShellIsInteractive and (Job.GroupId > 0) and IsConsole(StandardInputHandle);
  if OwnsConsole then
    SetForegroundGroup(StandardInputHandle, Job.GroupId);
  Job.Touch;
  Job.Continue;
  Job.State := JobRunning;
  Result := Job.WaitUntilDone(ShellIsInteractive);
  if OwnsConsole then
    SetForegroundGroup(StandardInputHandle, CurrentProcessGroup);

  if Job.State = JobStopped then
  begin
    PrintJob(StandardError, Job, False);
    FlushStream(StandardError);
    InterruptRequested := True;
  end
  else
  begin
    if ShellIsInteractive and (Result = StatusInterrupted) then
      InterruptRequested := True;
    RemoveJob(Job);
  end;
end;

procedure ContinueInBackground(Job: TJob; var Status: LongInt);
begin
  if Job.State = JobRunning then
  begin
    { It may have stopped without the table hearing of it yet. }
    Job.Continue;
    CommandError('bg', 'job ' + IntToStr(Job.Number) + ' already in background');
    Exit;
  end;
  if Job.State = JobDone then
  begin
    CommandError('bg', 'job has terminated');
    Status := 1;
    Exit;
  end;
  Job.Touch;
  Job.Continue;
  WriteStringLine(StandardOutput, Format('[%d]', [Job.Number]) + JobMark(Job) + ' ' + Job.Command + ' &');
end;

function BuiltinBackground(Arguments: TStrings): LongInt;
var
  Index: Integer;
  Job: TJob;
begin
  Result := 0;
  UpdateJobs;
  if Arguments.Count < 2 then
  begin
    Job := LookUpCurrentJob('bg');
    if Job = nil then
      Exit(1);
    ContinueInBackground(Job, Result);
  end
  else
  begin
    for Index := 1 to Arguments.Count - 1 do
    begin
      Job := LookUpJob('bg', Arguments[Index]);
      if Job = nil then
        Result := 1
      else
        ContinueInBackground(Job, Result);
    end;
  end;
  FlushStream(StandardOutput);
end;

{ --- wait ---------------------------------------------------------------- }

{ Waits for a job to end. An interactive shell checks for Ctrl-C while it
  waits (the job is not in the foreground, so the key comes to the
  shell). }
function WaitForJobToEnd(Job: TJob): LongInt;
begin
  if not ShellIsInteractive then
    Exit(Job.WaitUntilDone(False));
  repeat
    UpdateJobs;
    if Job.State <> JobRunning then
      Exit(Job.Status);
    if IsConsole(StandardInputHandle) and TakePendingInterrupt(StandardInputHandle) then
    begin
      WriteStringLine(StandardError, '^C');
      InterruptRequested := True;
      Exit(StatusInterrupted);
    end;
    SleepMilliseconds(PollMilliseconds);
  until False;
end;

function WaitForOperand(const Operand: string): LongInt;
var
  Job: TJob;
  ProcessId: Int64;
begin
  if CharAt(Operand, 1) = '%' then
  begin
    Job := LookUpJob('wait', Operand);
    if Job = nil then
      Exit(StatusNotChild);
  end
  else
  begin
    if not TryParseInteger(Operand, ProcessId) then
    begin
      CommandError('wait', '`' + Operand + ''': not a pid or valid job spec');
      Exit(2);
    end;
    Job := FindJobByProcessId(ProcessId);
    if Job = nil then
    begin
      CommandError('wait', 'pid ' + IntToStr(ProcessId) + ' is not a child of this shell');
      Exit(StatusNotChild);
    end;
  end;
  Result := WaitForJobToEnd(Job);
  if Job.State = JobDone then
    RemoveJob(Job);
end;

function BuiltinWait(Arguments: TStrings): LongInt;
var
  Index: Integer;
  Job: TJob;
begin
  Result := 0;
  if Arguments.Count >= 2 then
  begin
    for Index := 1 to Arguments.Count - 1 do
    begin
      Result := WaitForOperand(Arguments[Index]);
      if InterruptRequested then
        Exit;
    end;
    Exit;
  end;
  { Every running job; stopped ones would never end on their own. }
  for Index := 0 to MaximumJobs - 1 do
  begin
    Job := JobInSlot(Index);
    if (Job = nil) or (Job.State = JobStopped) then
      Continue;
    WaitForJobToEnd(Job);
    if InterruptRequested then
      Exit(StatusInterrupted);
    if Job.State = JobDone then
      RemoveJob(Job);
  end;
end;

{ --- kill ---------------------------------------------------------------- }

{ The arguments for /bin/kill: job operands become the process ids of
  their programs that are still running. JobsUnknown tells whether an
  operand named no job. }
function TranslateKillArguments(Arguments: TStrings; out JobsUnknown: Boolean): TStringList;
var
  Index: Integer;
  ProcessIndex: Integer;
  Job: TJob;
begin
  JobsUnknown := False;
  Result := TStringList.Create;
  for Index := 0 to Arguments.Count - 1 do
  begin
    if (Index = 0) or (CharAt(Arguments[Index], 1) <> '%') then
    begin
      Result.Add(Arguments[Index]);
      Continue;
    end;
    Job := LookUpJob('kill', Arguments[Index]);
    if Job = nil then
    begin
      JobsUnknown := True;
      Continue;
    end;
    for ProcessIndex := 0 to High(Job.Processes) do
      if not Job.Processes[ProcessIndex].Finished then
        Result.Add(IntToStr(Job.Processes[ProcessIndex].ProcessId));
  end;
end;

{ Runs /bin/kill with Arguments and returns the builtin's status. }
function RunKillProgram(Arguments: TStrings): LongInt;
var
  ProgramPath: string;
  Vector: TTextVector;
  Options: TProcessOptions;
  Handle: Int64;
begin
  Result := 0;
  if not LocateProgram('kill', ProgramPath) then
  begin
    CommandError('kill', 'command not found');
    Exit(StatusNotChild);
  end;
  Vector := MakeTextVector(Arguments);
  DefaultProcessOptions(Options);
  FlushStream(StandardOutput);
  Handle := StartProgram(PChar(ProgramPath), @Vector[0], Options);
  if Handle < 0 then
  begin
    CommandError('kill', ErrorMessage(ErrorCodeOf(Handle)));
    Result := StatusCannotRun;
  end
  else if WaitForProgram(Handle) <> 0 then
    Result := 1;
end;

function BuiltinKill(Arguments: TStrings): LongInt;
var
  Translated: TStringList;
  JobsUnknown: Boolean;
begin
  UpdateJobs;
  Translated := TranslateKillArguments(Arguments, JobsUnknown);
  try
    { Only job operands, all of them unknown or finished: nothing to do. }
    if JobsUnknown and (Translated.Count <= 1) then
      Exit(1);
    Result := RunKillProgram(Translated);
    if JobsUnknown and (Result = 0) then
      Result := 1;
  finally
    Translated.Free;
  end;
end;

function FindJobBuiltin(const Name: string): TBuiltinRoutine;
begin
  if Name = 'jobs' then
    Result := @BuiltinJobs
  else if Name = 'fg' then
    Result := @BuiltinForeground
  else if Name = 'bg' then
    Result := @BuiltinBackground
  else if Name = 'wait' then
    Result := @BuiltinWait
  else if Name = 'kill' then
    Result := @BuiltinKill
  else
    Result := nil;
end;

end.
