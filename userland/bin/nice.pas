{
  nice - run a program with modified scheduling priority

  nice [-n ADJUSTMENT] [COMMAND [ARG]...]

  Without COMMAND prints the current niceness. Otherwise adds ADJUSTMENT
  to it (clamped to -20 .. 19) and runs COMMAND, which inherits it. Only
  root may lower the niceness; for others nice warns and runs COMMAND
  anyway, as GNU nice does.
}
program nice;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Kernel,
  Sys.Errors,
  Sys.Environment,
  Sys.Format,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Commands,
  Util.Messages;

const
  Usage: PChar = 'Usage: nice [OPTION] [COMMAND [ARG]...]'#10 +
    'Run COMMAND with an adjusted niceness, which affects process scheduling.'#10 +
    'With no COMMAND, print the current niceness.'#10#10 +
    '  -n, --adjustment=N   add integer N to the niceness (default 10)'#10;

var
  First: Integer;
  Adjustment: Int64;
  Options: TProcessOptions;
  Text: PChar;
  Current: LongInt;
  Wanted: Int64;
  Error: Int64;
begin
  First := 1;
  Adjustment := 10;
  if (ArgumentTotal > 1) and TextIsEqual(Argument(1), '--help') then
  begin
    Print(Usage);
    Halt(0);
  end;
  if First < ArgumentTotal then
  begin
    Text := Argument(First);
    if (TextIsEqual(Text, '-n') or TextIsEqual(Text, '--adjustment')) and (First + 1 < ArgumentTotal) then
    begin
      if not ParseInteger(Argument(First + 1), Adjustment) then
        Fail(125, 'invalid adjustment ''%s''', [ArgumentText(Argument(First + 1))]);
      First := First + 2;
    end
    else if TextStartsWith(Text, '--adjustment=') then
    begin
      if not ParseInteger(Text + 13, Adjustment) then
        Fail(125, 'invalid adjustment ''%s''', [ArgumentText(Text + 13)]);
      Inc(First);
    end
    else if (Text[0] = '-') and (IsDigit(Text[1]) or ((Text[1] = '-') and IsDigit(Text[2]))) then
    begin
      { The old form "nice -5 command". }
      if not ParseInteger(Text + 1, Adjustment) then
        Fail(125, 'invalid adjustment ''%s''', [ArgumentText(Text + 1)]);
      Inc(First);
    end;
  end;
  if (First < ArgumentTotal) and TextIsEqual(Argument(First), '--') then
    Inc(First);

  KernelGetPriority(0, Current);
  if First >= ArgumentTotal then
  begin
    WriteFormatted(StandardOutput, '%d'#10, [ArgumentNumber(Current)]);
    Halt(0);
  end;
  Wanted := Current + Adjustment;
  if Wanted < -20 then
    Wanted := -20;
  if Wanted > 19 then
    Wanted := 19;
  Error := KernelSetPriority(0, LongInt(Wanted));
  if Error < 0 then
    Report('cannot set niceness: %s', [ArgumentText(ErrorMessage(ErrorCodeOf(Error)))]);
  DefaultProcessOptions(Options);
  RunCommandAndExit(ArgumentValues + First, Options);
end.
