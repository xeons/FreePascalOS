{
  env - run a program in a modified environment

  env [-i] [-u NAME]... [NAME=VALUE]... [COMMAND [ARG]...]

  Without COMMAND, prints the resulting environment.
}
program env;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Format,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]'#10 +
    'Set each NAME to VALUE in the environment and run COMMAND.'#10 +
    #10 +
    '  -i, --ignore-environment  start with an empty environment'#10 +
    '  -u, --unset=NAME          remove variable from the environment'#10 +
    '  -0, --null                end each output line with NUL, not newline'#10;

  OptionIgnore = 1;
  OptionUnset = 2;
  OptionNull = 3;
  ProgramPathCapacity = 1024;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  LineEnd: Char;
  First: Integer;
  Index: Integer;
  Block: PPChar;
  EqualsPosition: PtrInt;
  Name: array[0..255] of Char;
  ProgramPath: array[0..ProgramPathCapacity - 1] of Char;
  Status: LongInt;
begin
  LineEnd := #10;
  { Options end at the first operand, so the command's own options are
    left alone: parse by hand up to it. }
  First := 1;
  while (First < ArgumentTotal) and (Argument(First)[0] = '-') and (Argument(First)[1] <> #0) do
  begin
    if TextIsEqual(Argument(First), '--') then
    begin
      Inc(First);
      Break;
    end;
    if TextIsEqual(Argument(First), '-i') or TextIsEqual(Argument(First), '--ignore-environment') then
    begin
      while EnvironmentCount > 0 do
      begin
        EqualsPosition := FindCharacter(EnvironmentBlock[0], '=');
        CopyText(@Name[0], EnvironmentBlock[0], PtrUInt(EqualsPosition) + 1);
        RemoveVariable(@Name[0]);
      end;
    end
    else if TextIsEqual(Argument(First), '-u') and (First + 1 < ArgumentTotal) then
    begin
      Inc(First);
      RemoveVariable(Argument(First));
    end
    else if TextStartsWith(Argument(First), '--unset=') then
      RemoveVariable(Argument(First) + 8)
    else if TextIsEqual(Argument(First), '-0') or TextIsEqual(Argument(First), '--null') then
      LineEnd := #0
    else
    begin
      { Let the option parser handle --help, --version and errors. }
      BeginOptions(Parser, [
        OptionDefinition('i', 'ignore-environment', False, OptionIgnore),
        OptionDefinition('u', 'unset', True, OptionUnset),
        OptionDefinition('0', 'null', False, OptionNull)], Usage);
      NextOption(Parser, Code, Value);
      FailWithUsageHint('invalid option ''%s''', [ArgumentText(Argument(First))]);
    end;
    Inc(First);
  end;
  if (First < ArgumentTotal) and TextIsEqual(Argument(First), '-') then
  begin
    while EnvironmentCount > 0 do
    begin
      EqualsPosition := FindCharacter(EnvironmentBlock[0], '=');
      CopyText(@Name[0], EnvironmentBlock[0], PtrUInt(EqualsPosition) + 1);
      RemoveVariable(@Name[0]);
    end;
    Inc(First);
  end;

  while (First < ArgumentTotal) and (FindCharacter(Argument(First), '=') > 0) do
  begin
    EqualsPosition := FindCharacter(Argument(First), '=');
    if EqualsPosition < Length(Name) then
    begin
      CopyText(@Name[0], Argument(First), PtrUInt(EqualsPosition) + 1);
      SetVariable(@Name[0], Argument(First) + EqualsPosition + 1);
    end;
    Inc(First);
  end;

  if First >= ArgumentTotal then
  begin
    Block := EnvironmentBlock;
    Index := 0;
    while Block[Index] <> nil do
    begin
      WriteText(StandardOutput, Block[Index]);
      WriteCharacter(StandardOutput, LineEnd);
      Inc(Index);
    end;
    Halt(0);
  end;

  if not FindProgram(Argument(First), @ProgramPath[0], ProgramPathCapacity) then
  begin
    Report('''%s'': No such file or directory', [ArgumentText(Argument(First))]);
    Halt(127);
  end;
  FlushStandardStreams;
  Status := RunProgram(@ProgramPath[0], ArgumentValues + First);
  if Status < 0 then
  begin
    ReportError(ErrorCodeOf(Status), '''%s''', [ArgumentText(Argument(First))]);
    Halt(126);
  end;
  Halt(Status);
end.
