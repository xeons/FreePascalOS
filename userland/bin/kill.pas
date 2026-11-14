{
  kill - end processes

  kill [-s SIGNAL | -SIGNAL] PID...
  kill -l [NUMBER]...

  The system has no signals yet. Every signal that would end a program
  ends it, with exit status 128 + the signal number; STOP, TSTP, TTIN and
  TTOU stop it and CONT continues it; the others (and signal 0) only
  check that the process exists (Util.Commands.SendSignal). A negative
  PID names a process group, for stopping and continuing.
}
program kill;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Format,
  Sys.Environment,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Commands,
  Util.Messages;

const
  Usage: PChar = 'Usage: kill [-s SIGNAL | -SIGNAL] PID...'#10 +
    '  or:  kill -l [SIGNAL]...'#10 +
    'Send signals to processes, or list signals.'#10#10 +
    '  -s, --signal=SIGNAL, -SIGNAL'#10 +
    '                   specify the name or number of the signal to be sent'#10 +
    '  -l, --list       list signal names, or convert signal names to/from numbers'#10;

procedure ListSignals(First: Integer);
var
  Index: Integer;
  Number: Int64;
begin
  if First >= ArgumentTotal then
  begin
    for Index := 1 to HighestSignal do
    begin
      WriteFormatted(StandardOutput, '%2d) SIG%-8s', [ArgumentNumber(Index), ArgumentText(SignalName(Index))]);
      if Index mod 5 = 0 then
        WriteCharacter(StandardOutput, #10);
    end;
    WriteCharacter(StandardOutput, #10);
    Halt(0);
  end;
  for Index := First to ArgumentTotal - 1 do
  begin
    if ParseInteger(Argument(Index), Number) then
    begin
      { Exit statuses above 128 name the signal that ended a program. }
      if Number > 128 then
        Number := Number - 128;
      if SignalName(Integer(Number)) = nil then
        Fail(1, '%s: invalid signal', [ArgumentText(Argument(Index))]);
      PrintLine(SignalName(Integer(Number)));
    end
    else
    begin
      Number := ParseSignal(Argument(Index));
      if Number < 0 then
        Fail(1, '%s: invalid signal', [ArgumentText(Argument(Index))]);
      WriteDecimal(StandardOutput, Number);
      WriteCharacter(StandardOutput, #10);
    end;
  end;
  Halt(0);
end;

var
  Signal: Integer;
  First: Integer;
  Index: Integer;
  ProcessId: Int64;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Signal := SignalTerminate;
  First := 1;
  if ArgumentTotal < 2 then
  begin
    Report('not enough arguments', []);
    Halt(1);
  end;
  if TextIsEqual(Argument(1), '--help') then
  begin
    Print(Usage);
    Halt(0);
  end;
  if TextIsEqual(Argument(1), '-l') or TextIsEqual(Argument(1), '--list') or
     TextIsEqual(Argument(1), '-L') or TextIsEqual(Argument(1), '--table') then
    ListSignals(2);

  if TextIsEqual(Argument(1), '-s') or TextIsEqual(Argument(1), '--signal') or
     TextIsEqual(Argument(1), '-n') then
  begin
    if ArgumentTotal < 3 then
      Fail(1, 'option requires an argument -- ''s''', []);
    Signal := ParseSignal(Argument(2));
    First := 3;
  end
  else if TextStartsWith(Argument(1), '--signal=') then
  begin
    Signal := ParseSignal(Argument(1) + 9);
    First := 2;
  end
  else if (Argument(1)[0] = '-') and (Argument(1)[1] <> #0) and (Argument(1)[1] <> '-') then
  begin
    Signal := ParseSignal(Argument(1) + 1);
    First := 2;
  end;
  if (First < ArgumentTotal) and TextIsEqual(Argument(First), '--') then
    Inc(First);
  if Signal < 0 then
    Fail(1, 'invalid signal', []);
  if First >= ArgumentTotal then
    Fail(1, 'no process ID specified', []);

  ExitStatus := 0;
  for Index := First to ArgumentTotal - 1 do
  begin
    if not ParseInteger(Argument(Index), ProcessId) or (ProcessId = 0) then
    begin
      Report('failed to parse argument: ''%s''', [ArgumentText(Argument(Index))]);
      ExitStatus := 1;
      Continue;
    end;
    Error := SendSignal(ProcessId, Signal);
    if Error <> ErrorNone then
    begin
      ReportError(Error, '(%d)', [ArgumentNumber(ProcessId)]);
      ExitStatus := 1;
    end;
  end;
  Halt(ExitStatus);
end.
