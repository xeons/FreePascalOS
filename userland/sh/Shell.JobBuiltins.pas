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
{$pointermath on}

interface

uses
  Shell.Builtins;

{ Returns nil if Name is not one of these builtins. }
function FindJobBuiltin(Name: PChar): TBuiltinRoutine;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Console,
  Sys.Errors,
  Sys.Format,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Shell.Variables,
  Shell.Execution,
  Shell.Jobs;

const
  StatusInterrupted = 130;
  StatusNotChild = 127;
  PollMilliseconds = 20;
  ProgramPathCapacity = 1024;

procedure JobError(Name: PChar; Format: PChar; const Arguments: array of TFormatArgument);
begin
  FlushStream(StandardOutput);
  WriteText(StandardError, 'sh: ');
  WriteText(StandardError, Name);
  WriteText(StandardError, ': ');
  WriteFormatted(StandardError, Format, Arguments);
  WriteCharacter(StandardError, #10);
end;

{ The job named by Specification (nil = current), or reports it. }
function LookUpJob(Name: PChar; Specification: PChar): PJob;
begin
  Result := FindJob(Specification);
  if Result <> nil then
    Exit;
  if Specification = nil then
    JobError(Name, 'current: no such job', [])
  else
    JobError(Name, '%s: no such job', [ArgumentText(Specification)]);
end;

{ --- jobs ---------------------------------------------------------------- }

procedure ListJob(Job: PJob; ShowProcessIds, OnlyProcessIds: Boolean);
var
  Index: Integer;
begin
  if OnlyProcessIds then
  begin
    for Index := 0 to Job^.Count - 1 do
      WriteFormatted(StandardOutput, '%d'#10, [ArgumentNumber(Job^.ProcessIds[Index])]);
    Exit;
  end;
  if ShowProcessIds then
    WriteFormatted(StandardOutput, '[%d]%c %d ', [ArgumentNumber(Job^.Number),
      ArgumentCharacter(JobMark(Job)), ArgumentNumber(Job^.ProcessIds[0])]);
  if ShowProcessIds then
  begin
    { The state and command without the "[N]+" already printed. }
    case Job^.State of
      JobRunning: WriteFormatted(StandardOutput, '%-24s%s &'#10, [ArgumentText('Running'), ArgumentText(Job^.Command)]);
      JobStopped: WriteFormatted(StandardOutput, '%-24s%s'#10, [ArgumentText('Stopped'), ArgumentText(Job^.Command)]);
    else
      WriteFormatted(StandardOutput, '%-24s%s'#10, [ArgumentText('Done'), ArgumentText(Job^.Command)]);
    end;
  end
  else
    PrintJob(StandardOutput, Job, True);
end;

function BuiltinJobs(Arguments: PPChar; Count: Integer): LongInt;
var
  ShowProcessIds: Boolean;
  OnlyProcessIds: Boolean;
  First: Integer;
  Index: Integer;
  Job: PJob;
begin
  Result := 0;
  ShowProcessIds := False;
  OnlyProcessIds := False;
  First := 1;
  while (First < Count) and (Arguments[First][0] = '-') and (Arguments[First][1] <> #0) do
  begin
    if TextIsEqual(Arguments[First], '-l') then
      ShowProcessIds := True
    else if TextIsEqual(Arguments[First], '-p') then
      OnlyProcessIds := True
    else
    begin
      JobError('jobs', '%s: invalid option', [ArgumentText(Arguments[First])]);
      Exit(2);
    end;
    Inc(First);
  end;

  UpdateJobs;
  if First < Count then
  begin
    for Index := First to Count - 1 do
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

  { Finished jobs have now been reported. }
  for Index := 0 to MaximumJobs - 1 do
  begin
    Job := JobInSlot(Index);
    if (Job <> nil) and (Job^.State = JobDone) then
      RemoveJob(Job);
  end;
end;

{ --- fg and bg ----------------------------------------------------------- }

function BuiltinForeground(Arguments: PPChar; Count: Integer): LongInt;
var
  Job: PJob;
  OwnsConsole: Boolean;
begin
  if Count > 2 then
  begin
    JobError('fg', 'too many arguments', []);
    Exit(2);
  end;
  UpdateJobs;
  if Count = 2 then
    Job := LookUpJob('fg', Arguments[1])
  else
    Job := LookUpJob('fg', nil);
  if Job = nil then
    Exit(1);

  WriteLine(StandardOutput, Job^.Command);
  FlushStream(StandardOutput);
  OwnsConsole := ShellIsInteractive and (Job^.GroupId > 0) and IsConsole(StandardInputHandle);
  if OwnsConsole then
    SetForegroundGroup(StandardInputHandle, Job^.GroupId);
  TouchJob(Job);
  ContinueJob(Job);
  Job^.State := JobRunning;
  Result := WaitForJob(Job, ShellIsInteractive);
  if OwnsConsole then
    SetForegroundGroup(StandardInputHandle, CurrentProcessGroup);

  if Job^.State = JobStopped then
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

procedure ContinueInBackground(Job: PJob; var Status: LongInt);
begin
  if Job^.State = JobRunning then
  begin
    { It may have stopped without the table hearing of it yet. }
    ContinueJob(Job);
    JobError('bg', 'job %d already in background', [ArgumentNumber(Job^.Number)]);
    Exit;
  end;
  if Job^.State = JobDone then
  begin
    JobError('bg', 'job has terminated', []);
    Status := 1;
    Exit;
  end;
  TouchJob(Job);
  ContinueJob(Job);
  WriteFormatted(StandardOutput, '[%d]%c %s &'#10, [ArgumentNumber(Job^.Number),
    ArgumentCharacter(JobMark(Job)), ArgumentText(Job^.Command)]);
end;

function BuiltinBackground(Arguments: PPChar; Count: Integer): LongInt;
var
  Index: Integer;
  Job: PJob;
begin
  Result := 0;
  UpdateJobs;
  if Count < 2 then
  begin
    Job := LookUpJob('bg', nil);
    if Job = nil then
      Exit(1);
    ContinueInBackground(Job, Result);
  end
  else
  begin
    for Index := 1 to Count - 1 do
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
function WaitForJobToEnd(Job: PJob): LongInt;
begin
  if not ShellIsInteractive then
    Exit(WaitForJob(Job, False));
  repeat
    UpdateJobs;
    if Job^.State <> JobRunning then
      Exit(JobStatus(Job));
    if IsConsole(StandardInputHandle) and TakePendingInterrupt(StandardInputHandle) then
    begin
      WriteLine(StandardError, '^C');
      InterruptRequested := True;
      Exit(StatusInterrupted);
    end;
    SleepMilliseconds(PollMilliseconds);
  until False;
end;

function WaitForOperand(Operand: PChar): LongInt;
var
  Job: PJob;
  ProcessId: Int64;
begin
  if Operand[0] = '%' then
  begin
    Job := LookUpJob('wait', Operand);
    if Job = nil then
      Exit(StatusNotChild);
  end
  else
  begin
    if not ParseInteger(Operand, ProcessId) then
    begin
      JobError('wait', '`%s'': not a pid or valid job spec', [ArgumentText(Operand)]);
      Exit(2);
    end;
    Job := FindJobByProcessId(ProcessId);
    if Job = nil then
    begin
      JobError('wait', 'pid %d is not a child of this shell', [ArgumentNumber(ProcessId)]);
      Exit(StatusNotChild);
    end;
  end;
  Result := WaitForJobToEnd(Job);
  if Job^.State = JobDone then
    RemoveJob(Job);
end;

function BuiltinWait(Arguments: PPChar; Count: Integer): LongInt;
var
  Index: Integer;
  Job: PJob;
begin
  Result := 0;
  if Count >= 2 then
  begin
    for Index := 1 to Count - 1 do
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
    if (Job = nil) or (Job^.State = JobStopped) then
      Continue;
    WaitForJobToEnd(Job);
    if InterruptRequested then
      Exit(StatusInterrupted);
    if Job^.State = JobDone then
      RemoveJob(Job);
  end;
end;

{ --- kill ---------------------------------------------------------------- }

function BuiltinKill(Arguments: PPChar; Count: Integer): LongInt;
var
  Translated: PPChar;
  TranslatedCount: Integer;
  Index: Integer;
  ProcessIndex: Integer;
  Job: PJob;
  Buffer: TNumberText;
  ProgramPath: array[0..ProgramPathCapacity - 1] of Char;
  Options: TProcessOptions;
  Handle: Int64;
begin
  { A job may stand for up to MaximumJobProcesses process ids. }
  Translated := PPChar(AllocateZeroedMemory(QWord(Count * MaximumJobProcesses + 1) * SizeOf(PChar)));
  TranslatedCount := 0;
  Result := 0;
  UpdateJobs;
  for Index := 0 to Count - 1 do
  begin
    if (Index = 0) or (Arguments[Index][0] <> '%') then
    begin
      Translated[TranslatedCount] := DuplicateText(Arguments[Index]);
      Inc(TranslatedCount);
      Continue;
    end;
    Job := LookUpJob('kill', Arguments[Index]);
    if Job = nil then
    begin
      Result := 1;
      Continue;
    end;
    for ProcessIndex := 0 to Job^.Count - 1 do
    begin
      if Job^.Finished[ProcessIndex] then
        Continue;
      Translated[TranslatedCount] := DuplicateText(FormatSignedDecimal(Job^.ProcessIds[ProcessIndex], Buffer));
      Inc(TranslatedCount);
    end;
  end;

  { Only job operands, all of them unknown or finished: nothing to do. }
  if (Result <> 0) and (TranslatedCount <= 1) then
  begin
    for Index := 0 to TranslatedCount - 1 do
      FreeMemory(Translated[Index]);
    FreeMemory(Translated);
    Exit;
  end;

  if not FindProgram('kill', @ProgramPath[0], ProgramPathCapacity) then
  begin
    JobError('kill', 'command not found', []);
    Result := StatusNotChild;
  end
  else
  begin
    DefaultProcessOptions(Options);
    FlushStream(StandardOutput);
    Handle := StartProgram(@ProgramPath[0], Translated, Options);
    if Handle < 0 then
    begin
      JobError('kill', '%s', [ArgumentText(ErrorMessage(ErrorCodeOf(Handle)))]);
      Result := 126;
    end
    else if WaitForProgram(Handle) <> 0 then
      Result := 1;
  end;
  for Index := 0 to TranslatedCount - 1 do
    FreeMemory(Translated[Index]);
  FreeMemory(Translated);
end;

function FindJobBuiltin(Name: PChar): TBuiltinRoutine;
begin
  if TextIsEqual(Name, 'jobs') then
    Result := @BuiltinJobs
  else if TextIsEqual(Name, 'fg') then
    Result := @BuiltinForeground
  else if TextIsEqual(Name, 'bg') then
    Result := @BuiltinBackground
  else if TextIsEqual(Name, 'wait') then
    Result := @BuiltinWait
  else if TextIsEqual(Name, 'kill') then
    Result := @BuiltinKill
  else
    Result := nil;
end;

end.
