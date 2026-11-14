{
  yes - output a string repeatedly until killed

  yes [STRING]...

  Writes the arguments separated by spaces (or "y") followed by a line
  end, over and over. It stops when the output can no longer be written,
  for example when the reading end of a pipe closes.
}
program yes;

{$mode objfpc}

uses
  Sys.Environment,
  Sys.Streams,
  Sys.Text,
  Util.Options;

const
  Usage: PChar = 'Usage: yes [STRING]...'#10 +
    'Repeatedly output a line with all specified STRING(s), or ''y''.'#10;

var
  Parser: TOptionParser;
  Line: TTextBuilder;
  Index: Integer;
begin
  ParseOperandsOnly(Parser, Usage);
  BeginText(Line);
  if Parser.OperandCount = 0 then
    AppendText(Line, 'y')
  else
    for Index := 0 to Parser.OperandCount - 1 do
    begin
      if Index > 0 then
        AppendCharacter(Line, ' ');
      AppendText(Line, Parser.Operands[Index]);
    end;
  AppendCharacter(Line, #10);

  while not StandardOutput^.HadError do
    WriteBytes(StandardOutput, Line.Text, Line.Length);
  Halt(0);
end.
