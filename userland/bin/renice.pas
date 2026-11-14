{
  renice - alter the priority of running processes

  renice [-n] PRIORITY [-p] PID...

  Sets the nice value (-20 .. 19) of each process. Users may change
  their own processes, and only root may lower a nice value.
}
program renice;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Format,
  Sys.Kernel,
  Sys.Streams,
  Sys.Text,
  Util.Messages;

const
  Usage: PChar = 'Usage: renice [-n] PRIORITY [-p] PID...'#10 +
    'Alter the priority of running processes.'#10#10 +
    '  -n, --priority N   set the nice value to N'#10 +
    '  -p, --pid          interpret the following arguments as process IDs (the default)'#10;

var
  Index: Integer;
  Priority: Int64;
  Text: PChar;
  ProcessId: Int64;
  OldNice: LongInt;
  Error: Int64;
  ExitStatus: LongInt;
  HavePriority: Boolean;
begin
  ExitStatus := 0;
  HavePriority := False;
  Priority := 0;
  Index := 1;
  if (ArgumentTotal > 1) and TextIsEqual(Argument(1), '--help') then
  begin
    Print(Usage);
    Halt(0);
  end;
  while Index < ArgumentTotal do
  begin
    Text := Argument(Index);
    Inc(Index);
    if TextIsEqual(Text, '-p') or TextIsEqual(Text, '--pid') then
      Continue;
    if TextIsEqual(Text, '-g') or TextIsEqual(Text, '-u') then
      Fail(1, 'option ''%s'' is not supported', [ArgumentText(Text)]);
    if TextIsEqual(Text, '-n') or TextIsEqual(Text, '--priority') then
    begin
      if Index >= ArgumentTotal then
        Fail(1, 'option ''%s'' requires an argument', [ArgumentText(Text)]);
      Text := Argument(Index);
      Inc(Index);
      if not ParseInteger(Text, Priority) then
        Fail(1, 'invalid priority ''%s''', [ArgumentText(Text)]);
      HavePriority := True;
      Continue;
    end;
    if not HavePriority then
    begin
      if not ParseInteger(Text, Priority) then
        Fail(1, 'invalid priority ''%s''', [ArgumentText(Text)]);
      HavePriority := True;
      Continue;
    end;
    if not ParseInteger(Text, ProcessId) or (ProcessId <= 0) then
    begin
      Report('invalid process ID ''%s''', [ArgumentText(Text)]);
      ExitStatus := 1;
      Continue;
    end;
    Error := KernelGetPriority(QWord(ProcessId), OldNice);
    if Error >= 0 then
      Error := KernelSetPriority(QWord(ProcessId), LongInt(Priority));
    if Error < 0 then
    begin
      Report('failed to set priority for %d (process ID): %s', [ArgumentNumber(ProcessId),
        ArgumentText(ErrorMessage(ErrorCodeOf(Error)))]);
      ExitStatus := 1;
      Continue;
    end;
    if Priority < -20 then
      Priority := -20;
    if Priority > 19 then
      Priority := 19;
    WriteFormatted(StandardOutput, '%d (process ID) old priority %d, new priority %d'#10,
      [ArgumentNumber(ProcessId), ArgumentNumber(OldNice), ArgumentNumber(Priority)]);
  end;
  if not HavePriority then
    FailWithUsageHint('missing priority', []);
  Halt(ExitStatus);
end.
