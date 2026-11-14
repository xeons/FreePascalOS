{
  printenv - print all or part of environment

  printenv [-0] [VARIABLE]...

  Exits with 1 if a named variable is not set.
}
program printenv;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Environment,
  Sys.Streams,
  Util.Options;

const
  Usage: PChar = 'Usage: printenv [OPTION]... [VARIABLE]...'#10 +
    'Print the values of the specified environment VARIABLE(s).'#10 +
    'If no VARIABLE is specified, print name and value pairs for them all.'#10#10 +
    '  -0, --null     end each output line with NUL, not newline'#10;

  OptionNull = 1;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  LineEnd: Char;
  Index: Integer;
  Block: PPChar;
  ExitStatus: LongInt;
begin
  LineEnd := #10;
  BeginOptions(Parser, [OptionDefinition('0', 'null', False, OptionNull)], Usage);
  while NextOption(Parser, Code, Value) do
    LineEnd := #0;
  if Parser.OperandCount = 0 then
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
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Value := GetVariable(Parser.Operands[Index]);
    if Value = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    WriteText(StandardOutput, Value);
    WriteCharacter(StandardOutput, LineEnd);
  end;
  Halt(ExitStatus);
end.
