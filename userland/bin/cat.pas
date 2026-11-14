{
  cat - concatenate files and print on the standard output

  cat [-AbeEnstTv] [FILE]...

  With no FILE, or when FILE is -, reads standard input.
}
program cat;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: cat [OPTION]... [FILE]...'#10 +
    'Concatenate FILE(s) to standard output.'#10 +
    #10 +
    'With no FILE, or when FILE is -, read standard input.'#10 +
    #10 +
    '  -A, --show-all           equivalent to -vET'#10 +
    '  -b, --number-nonblank    number nonempty output lines, overrides -n'#10 +
    '  -e                       equivalent to -vE'#10 +
    '  -E, --show-ends          display $ at end of each line'#10 +
    '  -n, --number             number all output lines'#10 +
    '  -s, --squeeze-blank      suppress repeated empty output lines'#10 +
    '  -t                       equivalent to -vT'#10 +
    '  -T, --show-tabs          display TAB characters as ^I'#10 +
    '  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB'#10;

  OptionShowAll = 1;
  OptionNumberNonblank = 2;
  OptionE = 3;
  OptionShowEnds = 4;
  OptionNumber = 5;
  OptionSqueeze = 6;
  OptionT = 7;
  OptionShowTabs = 8;
  OptionShowNonprinting = 9;

var
  NumberLines: Boolean;
  NumberNonblank: Boolean;
  ShowEnds: Boolean;
  SqueezeBlank: Boolean;
  ShowTabs: Boolean;
  ShowNonprinting: Boolean;
  { State carried across files, as GNU cat does. }
  LineNumber: Int64;
  AtLineStart: Boolean;
  PreviousLineBlank: Boolean;

function NeedsLineProcessing: Boolean;
begin
  Result := NumberLines or NumberNonblank or ShowEnds or SqueezeBlank or ShowTabs or ShowNonprinting;
end;

procedure CopyRaw(Stream: PInputStream);
var
  Buffer: array[0..4095] of Char;
  Count: QWord;
begin
  repeat
    Count := ReadBytes(Stream, @Buffer[0], SizeOf(Buffer));
    WriteBytes(StandardOutput, @Buffer[0], Count);
  until Count = 0;
end;

procedure WriteVisible(Character: Char);
var
  Code: Integer;
begin
  Code := Ord(Character);
  if (Character = #9) and not ShowTabs then
  begin
    WriteCharacter(StandardOutput, #9);
    Exit;
  end;
  if not ShowNonprinting and (Character <> #9) then
  begin
    WriteCharacter(StandardOutput, Character);
    Exit;
  end;
  if Code >= 128 then
  begin
    WriteText(StandardOutput, 'M-');
    Code := Code - 128;
  end;
  if Code < 32 then
  begin
    WriteCharacter(StandardOutput, '^');
    WriteCharacter(StandardOutput, Char(Code + 64));
  end
  else if Code = 127 then
    WriteText(StandardOutput, '^?')
  else
    WriteCharacter(StandardOutput, Char(Code));
end;

procedure CopyProcessed(Stream: PInputStream);
var
  Character: Char;
  LineIsBlank: Boolean;
begin
  while ReadCharacter(Stream, Character) do
  begin
    if AtLineStart then
    begin
      LineIsBlank := Character = #10;
      if SqueezeBlank and LineIsBlank and PreviousLineBlank then
        Continue;
      PreviousLineBlank := LineIsBlank;
      if NumberLines and not (NumberNonblank and LineIsBlank) then
      begin
        Inc(LineNumber);
        WriteFormatted(StandardOutput, '%6d'#9, [ArgumentNumber(LineNumber)]);
      end;
      AtLineStart := False;
    end;
    if Character = #10 then
    begin
      if ShowEnds then
        WriteCharacter(StandardOutput, '$');
      WriteCharacter(StandardOutput, #10);
      AtLineStart := True;
    end
    else
      WriteVisible(Character);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Stream: PInputStream;
  ExitStatus: LongInt;
begin
  BeginOptions(Parser, [
    OptionDefinition('A', 'show-all', False, OptionShowAll),
    OptionDefinition('b', 'number-nonblank', False, OptionNumberNonblank),
    OptionDefinition('e', nil, False, OptionE),
    OptionDefinition('E', 'show-ends', False, OptionShowEnds),
    OptionDefinition('n', 'number', False, OptionNumber),
    OptionDefinition('s', 'squeeze-blank', False, OptionSqueeze),
    OptionDefinition('t', nil, False, OptionT),
    OptionDefinition('T', 'show-tabs', False, OptionShowTabs),
    OptionDefinition('u', nil, False, 0),
    OptionDefinition('v', 'show-nonprinting', False, OptionShowNonprinting)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionShowAll:
        begin
          ShowNonprinting := True;
          ShowEnds := True;
          ShowTabs := True;
        end;
      OptionNumberNonblank:
        begin
          NumberLines := True;
          NumberNonblank := True;
        end;
      OptionE:
        begin
          ShowNonprinting := True;
          ShowEnds := True;
        end;
      OptionShowEnds: ShowEnds := True;
      OptionNumber: NumberLines := True;
      OptionSqueeze: SqueezeBlank := True;
      OptionT:
        begin
          ShowNonprinting := True;
          ShowTabs := True;
        end;
      OptionShowTabs: ShowTabs := True;
      OptionShowNonprinting: ShowNonprinting := True;
    end;

  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;

  LineNumber := 0;
  AtLineStart := True;
  PreviousLineBlank := False;
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Stream := OpenInput(Parser.Operands[Index]);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    if NeedsLineProcessing then
      CopyProcessed(Stream)
    else
      CopyRaw(Stream);
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
