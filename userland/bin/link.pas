{
  link - make a hard link

  link FILE1 FILE2

  Only ext2/3/4 volumes support hard links.
}
program link;

{$mode objfpc}

uses
  Sys.Files,
  Sys.Format,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: link FILE1 FILE2'#10 +
    'Call the link function to create a link named FILE2 to an existing FILE1.'#10;

var
  Parser: TOptionParser;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount < 2 then
    FailWithUsageHint('missing operand', []);
  if Parser.OperandCount > 2 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
  Error := CreateHardLink(Parser.Operands[0], Parser.Operands[1]);
  if Error <> 0 then
    FailWithError(1, Error, 'cannot create link ''%s'' to ''%s''', [ArgumentText(Parser.Operands[1]),
      ArgumentText(Parser.Operands[0])]);
end.
