{
  timeout - run a command with a time limit

  timeout [-k DURATION] [-s SIGNAL] [--preserve-status] DURATION COMMAND [ARG]...

  DURATION is a number with an optional suffix s, m, h or d (fractions
  allowed); 0 disables the limit. If the command is still running when
  the time is up it is ended, and timeout exits with 124 (or, with
  --preserve-status, the command's status, 128 + the signal number).
}
program timeout;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Environment,
  Sys.Format,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Commands,
  Util.Messages;

const
  Usage: PChar = 'Usage: timeout [OPTION] DURATION COMMAND [ARG]...'#10 +
    'Start COMMAND, and kill it if still running after DURATION.'#10#10 +
    '      --preserve-status'#10 +
    '                 exit with the same status as COMMAND, even when the'#10 +
    '                   command times out'#10 +
    '  -k, --kill-after=DURATION'#10 +
    '                 also send a KILL signal if COMMAND is still running'#10 +
    '                   this long after the initial signal was sent'#10 +
    '  -s, --signal=SIGNAL'#10 +
    '                 specify the signal to be sent on timeout'#10 +
    #10'If the command times out, and --preserve-status is not set, then exit'#10 +
    'with status 124.'#10;

  StatusTimedOut = 124;
  StatusTimeoutFailed = 125;

{ "1.5m" into milliseconds. }
function ParseDuration(Text: PChar; out Milliseconds: QWord): Boolean;
var
  Position: Integer;
  Whole: QWord;
  Fraction: QWord;
  Scale: QWord;
  Multiplier: QWord;
begin
  Milliseconds := 0;
  Position := 0;
  Whole := 0;
  Fraction := 0;
  Scale := 1;
  if not IsDigit(Text[0]) and (Text[0] <> '.') then
    Exit(False);
  while IsDigit(Text[Position]) do
  begin
    Whole := Whole * 10 + QWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
  end;
  if Text[Position] = '.' then
  begin
    Inc(Position);
    while IsDigit(Text[Position]) do
    begin
      if Scale < 1000 then
      begin
        Fraction := Fraction * 10 + QWord(Ord(Text[Position]) - Ord('0'));
        Scale := Scale * 10;
      end;
      Inc(Position);
    end;
  end;
  case Text[Position] of
    #0, 's': Multiplier := 1000;
    'm': Multiplier := 60 * 1000;
    'h': Multiplier := 60 * 60 * 1000;
    'd': Multiplier := 24 * 60 * 60 * 1000;
  else
    Exit(False);
  end;
  if (Text[Position] <> #0) and (Text[Position + 1] <> #0) then
    Exit(False);
  Milliseconds := Whole * Multiplier + (Fraction * Multiplier) div Scale;
  Result := True;
end;

procedure FailUsage(Message: PChar);
begin
  Report('%s', [ArgumentText(Message)]);
  WriteFormatted(StandardError, 'Try ''%s --help'' for more information.'#10, [ArgumentText(ProgramName)]);
  Halt(StatusTimeoutFailed);
end;

var
  First: Integer;
  Signal: Integer;
  PreserveStatus: Boolean;
  KillAfter: QWord;
  Limit: QWord;
  Options: TProcessOptions;
  Handle: Int64;
  ProcessId: Int64;
  Status: LongInt;
  Error: LongInt;
  Text: PChar;
begin
  Signal := SignalTerminate;
  PreserveStatus := False;
  KillAfter := 0;
  First := 1;
  { Options end at the duration, so the command keeps its own options. }
  while (First < ArgumentTotal) and (Argument(First)[0] = '-') and (Argument(First)[1] <> #0) do
  begin
    Text := Argument(First);
    if TextIsEqual(Text, '--help') then
    begin
      Print(Usage);
      Halt(0);
    end
    else if TextIsEqual(Text, '--preserve-status') then
      PreserveStatus := True
    else if TextIsEqual(Text, '--foreground') or TextIsEqual(Text, '-v') or TextIsEqual(Text, '--verbose') then
      { accepted; there are no process groups to leave }
    else if (TextIsEqual(Text, '-s') or TextIsEqual(Text, '--signal')) and (First + 1 < ArgumentTotal) then
    begin
      Inc(First);
      Signal := ParseSignal(Argument(First));
    end
    else if TextStartsWith(Text, '--signal=') then
      Signal := ParseSignal(Text + 9)
    else if TextStartsWith(Text, '-s') then
      Signal := ParseSignal(Text + 2)
    else if (TextIsEqual(Text, '-k') or TextIsEqual(Text, '--kill-after')) and (First + 1 < ArgumentTotal) then
    begin
      Inc(First);
      if not ParseDuration(Argument(First), KillAfter) then
        FailUsage('invalid time interval');
    end
    else if TextStartsWith(Text, '--kill-after=') then
    begin
      if not ParseDuration(Text + 13, KillAfter) then
        FailUsage('invalid time interval');
    end
    else if TextIsEqual(Text, '--') then
    begin
      Inc(First);
      Break;
    end
    else
      FailUsage('invalid option');
    Inc(First);
  end;
  if Signal < 0 then
    FailUsage('invalid signal');
  if First + 1 >= ArgumentTotal then
    FailUsage('missing operand');
  if not ParseDuration(Argument(First), Limit) then
    FailUsage('invalid time interval');

  DefaultProcessOptions(Options);
  Handle := StartCommand(ArgumentValues + First + 1, Options, Status);
  if Handle < 0 then
    Halt(Status);
  if Limit = 0 then
    Halt(WaitForProgram(Handle));

  Error := WaitForProgramWithTimeout(Handle, Limit, Status);
  if Error = 0 then
    Halt(Status);

  { Time is up. }
  ProcessId := ProcessIdOf(Handle);
  TerminateProgram(QWord(ProcessId), 128 + Signal);
  if KillAfter > 0 then
  begin
    if WaitForProgramWithTimeout(Handle, KillAfter, Status) <> 0 then
    begin
      TerminateProgram(QWord(ProcessId), 128 + SignalKill);
      Status := WaitForProgram(Handle);
    end;
  end
  else
    Status := WaitForProgram(Handle);
  if PreserveStatus then
    Halt(Status);
  Halt(StatusTimedOut);
end.
