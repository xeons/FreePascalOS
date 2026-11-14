{
  dirname - strip the last component from file names

  dirname NAME...

  Prints each NAME without its last component: "/usr/bin/" gives
  "/usr", and a NAME without a slash gives ".".
}
program dirname;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Streams,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: dirname [OPTION] NAME...'#10 +
    'Output each NAME with its last non-slash component and trailing slashes'#10 +
    'removed; if NAME contains no /''s, output ''.'' (meaning the current directory).'#10 +
    #10 +
    '  -z, --zero     end each output line with NUL, not newline'#10;

  OptionZero = 1;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  LineEnd: Char;
  Index: Integer;
begin
  LineEnd := #10;
  BeginOptions(Parser, [OptionDefinition('z', 'zero', False, OptionZero)], Usage);
  while NextOption(Parser, Code, Value) do
    if Code = OptionZero then
      LineEnd := #0;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    WriteText(StandardOutput, DirectoryName(Parser.Operands[Index]));
    WriteCharacter(StandardOutput, LineEnd);
  end;
end.
