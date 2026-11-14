{
  cut - remove sections from each line of files

  cut -b LIST [-n] [FILE]...
  cut -c LIST [FILE]...
  cut -f LIST [-d DELIMITER] [-s] [--output-delimiter=TEXT] [FILE]...

  LIST is made of ranges separated by commas: N, N-M, N- or -M,
  counted from 1.
}
program cut;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: cut OPTION... [FILE]...'#10 +
    'Print selected parts of lines from each FILE to standard output.'#10 +
    #10 +
    '  -b, --bytes=LIST        select only these bytes'#10 +
    '  -c, --characters=LIST   select only these characters'#10 +
    '  -d, --delimiter=DELIM   use DELIM instead of TAB for field delimiter'#10 +
    '  -f, --fields=LIST       select only these fields'#10 +
    '  -s, --only-delimited    do not print lines not containing delimiters'#10 +
    '      --output-delimiter=STRING  use STRING as the output delimiter'#10 +
    '      --complement        complement the set of selected bytes or fields'#10;

  OptionBytes = 1;
  OptionCharacters = 2;
  OptionDelimiter = 3;
  OptionFields = 4;
  OptionOnlyDelimited = 5;
  OptionOutputDelimiter = 6;
  OptionComplement = 7;
  OptionNoSplit = 8;

  MaximumRanges = 64;
  Unbounded = High(LongInt);

type
  TRange = record
    First: LongInt;
    Last: LongInt;
  end;

  TCutMode = (CutNone, CutBytes, CutCharacters, CutFields);

var
  Ranges: array[0..MaximumRanges - 1] of TRange;
  RangeCount: Integer;
  Mode: TCutMode;
  Delimiter: Char;
  OutputDelimiter: PChar;
  OnlyDelimited: Boolean;
  Complement: Boolean;

procedure ParseList(Text: PChar);
var
  Position: Integer;
  Number: LongInt;
  Range: TRange;
  HasDash: Boolean;
  SawDigits: Boolean;
begin
  RangeCount := 0;
  Position := 0;
  repeat
    Range.First := 1;
    Range.Last := Unbounded;
    HasDash := False;
    SawDigits := False;
    Number := 0;
    while IsDigit(Text[Position]) do
    begin
      Number := Number * 10 + Ord(Text[Position]) - Ord('0');
      SawDigits := True;
      Inc(Position);
    end;
    if SawDigits then
      Range.First := Number;
    if Text[Position] = '-' then
    begin
      HasDash := True;
      Inc(Position);
      Number := 0;
      SawDigits := False;
      while IsDigit(Text[Position]) do
      begin
        Number := Number * 10 + Ord(Text[Position]) - Ord('0');
        SawDigits := True;
        Inc(Position);
      end;
      if SawDigits then
        Range.Last := Number;
    end
    else
      Range.Last := Range.First;
    if (Range.First < 1) or (Range.Last < Range.First) or (not HasDash and not SawDigits) then
      Fail(1, 'invalid byte, character or field list', []);
    if RangeCount = MaximumRanges then
      Fail(1, 'too many ranges', []);
    Ranges[RangeCount] := Range;
    Inc(RangeCount);
    if Text[Position] = ',' then
      Inc(Position)
    else if Text[Position] <> #0 then
      Fail(1, 'invalid byte, character or field list', []);
  until Text[Position] = #0;
end;

function IsSelected(Number: LongInt): Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 0 to RangeCount - 1 do
  begin
    if (Number >= Ranges[Index].First) and (Number <= Ranges[Index].Last) then
    begin
      Result := True;
      Break;
    end;
  end;
  if Complement then
    Result := not Result;
end;

procedure CutPositions(Line: PChar);
var
  Position: LongInt;
  Number: LongInt;
  PreviousSelected: Boolean;
  PrintedAny: Boolean;
begin
  Position := 0;
  Number := 0;
  PreviousSelected := False;
  PrintedAny := False;
  while Line[Position] <> #0 do
  begin
    { With -c, a character is a whole UTF-8 sequence. }
    if (Mode = CutBytes) or ((Byte(Line[Position]) and $C0) <> $80) then
      Inc(Number);
    if IsSelected(Number) then
    begin
      if (OutputDelimiter <> nil) and PrintedAny and not PreviousSelected then
        WriteText(StandardOutput, OutputDelimiter);
      WriteCharacter(StandardOutput, Line[Position]);
      PrintedAny := True;
      PreviousSelected := True;
    end
    else
      PreviousSelected := False;
    Inc(Position);
  end;
  WriteCharacter(StandardOutput, #10);
end;

procedure CutFieldsOfLine(Line: PChar);
var
  Position: LongInt;
  FieldNumber: LongInt;
  FieldStart: LongInt;
  PrintedAny: Boolean;
begin
  if FindCharacter(Line, Delimiter) < 0 then
  begin
    if not OnlyDelimited then
      WriteLine(StandardOutput, Line);
    Exit;
  end;
  Position := 0;
  FieldNumber := 1;
  FieldStart := 0;
  PrintedAny := False;
  while True do
  begin
    if (Line[Position] = Delimiter) or (Line[Position] = #0) then
    begin
      if IsSelected(FieldNumber) then
      begin
        if PrintedAny then
        begin
          if OutputDelimiter <> nil then
            WriteText(StandardOutput, OutputDelimiter)
          else
            WriteCharacter(StandardOutput, Delimiter);
        end;
        WriteBytes(StandardOutput, Line + FieldStart, QWord(Position - FieldStart));
        PrintedAny := True;
      end;
      if Line[Position] = #0 then
        Break;
      Inc(FieldNumber);
      FieldStart := Position + 1;
    end;
    Inc(Position);
  end;
  WriteCharacter(StandardOutput, #10);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Stream: PInputStream;
  Line: PChar;
  HadLineEnd: Boolean;
  ExitStatus: LongInt;
begin
  Mode := CutNone;
  Delimiter := #9;
  OutputDelimiter := nil;
  BeginOptions(Parser, [
    OptionDefinition('b', 'bytes', True, OptionBytes),
    OptionDefinition('c', 'characters', True, OptionCharacters),
    OptionDefinition('d', 'delimiter', True, OptionDelimiter),
    OptionDefinition('f', 'fields', True, OptionFields),
    OptionDefinition('s', 'only-delimited', False, OptionOnlyDelimited),
    OptionDefinition('n', nil, False, OptionNoSplit),
    OptionDefinition(#0, 'output-delimiter', True, OptionOutputDelimiter),
    OptionDefinition(#0, 'complement', False, OptionComplement)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionBytes, OptionCharacters, OptionFields:
        begin
          if Mode <> CutNone then
            FailWithUsageHint('only one type of list may be specified', []);
          case Code of
            OptionBytes: Mode := CutBytes;
            OptionCharacters: Mode := CutCharacters;
          else
            Mode := CutFields;
          end;
          ParseList(Value);
        end;
      OptionDelimiter:
        begin
          if (Value[0] = #0) or (Value[1] <> #0) then
            Fail(1, 'the delimiter must be a single character', []);
          Delimiter := Value[0];
        end;
      OptionOnlyDelimited: OnlyDelimited := True;
      OptionOutputDelimiter: OutputDelimiter := Value;
      OptionComplement: Complement := True;
    end;
  if Mode = CutNone then
    FailWithUsageHint('you must specify a list of bytes, characters, or fields', []);

  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Stream := OpenInput(Parser.Operands[Index]);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    while ReadLine(Stream, Line, HadLineEnd) do
    begin
      if Mode = CutFields then
        CutFieldsOfLine(Line)
      else
        CutPositions(Line);
      FreeMemory(Line);
    end;
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
