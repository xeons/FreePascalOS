{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  sort - sort lines of text files

  sort [-bfnru] [-k START[,END]] [-t SEPARATOR] [-o FILE] [FILE]...

  Fields for -k are counted from 1 and separated by SEPARATOR, or by
  runs of blanks when -t is not given.
}
program sort;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options,
  Util.Sorting;

const
  Usage: PChar = 'Usage: sort [OPTION]... [FILE]...'#10 +
    'Write sorted concatenation of all FILE(s) to standard output.'#10 +
    #10 +
    '  -b, --ignore-leading-blanks  ignore leading blanks'#10 +
    '  -f, --ignore-case            fold lower case to upper case characters'#10 +
    '  -n, --numeric-sort           compare according to string numerical value'#10 +
    '  -r, --reverse                reverse the result of comparisons'#10 +
    '  -k, --key=START[,END]        sort via a key between fields START and END'#10 +
    '  -t, --field-separator=SEP    use SEP instead of non-blank to blank transition'#10 +
    '  -o, --output=FILE            write result to FILE instead of standard output'#10 +
    '  -u, --unique                 output only the first of an equal run'#10;

  OptionIgnoreBlanks = 1;
  OptionIgnoreCase = 2;
  OptionNumeric = 3;
  OptionReverse = 4;
  OptionKey = 5;
  OptionSeparator = 6;
  OptionOutput = 7;
  OptionUnique = 8;

var
  IgnoreBlanks: Boolean;
  IgnoreCase: Boolean;
  Numeric: Boolean;
  Reverse: Boolean;
  Unique: Boolean;
  KeyStart: Integer;   { 0 = whole line }
  KeyEnd: Integer;     { 0 = to the end of the line }
  Separator: Char;     { #0 = blanks }

{ Finds where field Number (from 1) starts in Line. }
function FieldStart(Line: PChar; Number: Integer): PChar;
var
  Field: Integer;
begin
  Result := Line;
  Field := 1;
  while (Field < Number) and (Result^ <> #0) do
  begin
    if Separator <> #0 then
    begin
      while (Result^ <> #0) and (Result^ <> Separator) do
        Inc(Result);
      if Result^ = Separator then
        Inc(Result);
    end
    else
    begin
      { Blank separated: a field includes its leading blanks. }
      while (Result^ <> #0) and IsSpace(Result^) do
        Inc(Result);
      while (Result^ <> #0) and not IsSpace(Result^) do
        Inc(Result);
    end;
    Inc(Field);
  end;
end;

{ The end of the key: the end of field KeyEnd, or of the line. }
function FieldEnd(Line: PChar): PChar;
begin
  if KeyEnd = 0 then
  begin
    Result := Line + TextLength(Line);
    Exit;
  end;
  Result := FieldStart(Line, KeyEnd);
  if Separator <> #0 then
    while (Result^ <> #0) and (Result^ <> Separator) do
      Inc(Result)
  else
  begin
    while (Result^ <> #0) and IsSpace(Result^) do
      Inc(Result);
    while (Result^ <> #0) and not IsSpace(Result^) do
      Inc(Result);
  end;
end;

procedure KeyOf(Line: PChar; out Start, Finish: PChar);
begin
  if KeyStart = 0 then
  begin
    Start := Line;
    Finish := Line + TextLength(Line);
  end
  else
  begin
    Start := FieldStart(Line, KeyStart);
    Finish := FieldEnd(Line);
    if Finish < Start then
      Finish := Start;
  end;
  if IgnoreBlanks or Numeric then
    while (Start < Finish) and IsSpace(Start^) do
      Inc(Start);
end;

{ Reads a number (sign, digits, optional fraction) as an integer part and
  fraction digits, so "10" > "9" and "-3" < "2". }
function CompareNumbers(First, FirstEnd, Second, SecondEnd: PChar): Integer;

  procedure ReadNumber(Text, Finish: PChar; out IsNegative: Boolean; out Whole: Int64; out Fraction: Int64);
  var
    Scale: Integer;
  begin
    IsNegative := False;
    Whole := 0;
    Fraction := 0;
    if (Text < Finish) and (Text^ = '-') then
    begin
      IsNegative := True;
      Inc(Text);
    end;
    while (Text < Finish) and IsDigit(Text^) do
    begin
      Whole := Whole * 10 + Ord(Text^) - Ord('0');
      Inc(Text);
    end;
    Scale := 0;
    if (Text < Finish) and (Text^ = '.') then
    begin
      Inc(Text);
      while (Text < Finish) and IsDigit(Text^) and (Scale < 9) do
      begin
        Fraction := Fraction * 10 + Ord(Text^) - Ord('0');
        Inc(Scale);
        Inc(Text);
      end;
    end;
    while Scale < 9 do
    begin
      Fraction := Fraction * 10;
      Inc(Scale);
    end;
  end;

var
  FirstNegative, SecondNegative: Boolean;
  FirstWhole, SecondWhole: Int64;
  FirstFraction, SecondFraction: Int64;
begin
  ReadNumber(First, FirstEnd, FirstNegative, FirstWhole, FirstFraction);
  ReadNumber(Second, SecondEnd, SecondNegative, SecondWhole, SecondFraction);
  if FirstNegative then
  begin
    FirstWhole := -FirstWhole;
    FirstFraction := -FirstFraction;
  end;
  if SecondNegative then
  begin
    SecondWhole := -SecondWhole;
    SecondFraction := -SecondFraction;
  end;
  if FirstWhole <> SecondWhole then
  begin
    if FirstWhole < SecondWhole then
      Exit(-1);
    Exit(1);
  end;
  if FirstFraction < SecondFraction then
    Exit(-1);
  if FirstFraction > SecondFraction then
    Exit(1);
  Result := 0;
end;

function CompareRanges(First, FirstEnd, Second, SecondEnd: PChar): Integer;
var
  Left: Char;
  Right: Char;
begin
  while (First < FirstEnd) and (Second < SecondEnd) do
  begin
    Left := First^;
    Right := Second^;
    if IgnoreCase then
    begin
      Left := ToUpperCase(Left);
      Right := ToUpperCase(Right);
    end;
    if Left <> Right then
      Exit(Integer(Byte(Left)) - Integer(Byte(Right)));
    Inc(First);
    Inc(Second);
  end;
  if First < FirstEnd then
    Exit(1);
  if Second < SecondEnd then
    Exit(-1);
  Result := 0;
end;

function CompareKeys(First, Second: PChar): Integer;
var
  FirstStart, FirstFinish: PChar;
  SecondStart, SecondFinish: PChar;
begin
  KeyOf(First, FirstStart, FirstFinish);
  KeyOf(Second, SecondStart, SecondFinish);
  if Numeric then
    Result := CompareNumbers(FirstStart, FirstFinish, SecondStart, SecondFinish)
  else
    Result := CompareRanges(FirstStart, FirstFinish, SecondStart, SecondFinish);
end;

function CompareLines(First, Second: Pointer; Context: Pointer): Integer;
begin
  Result := CompareKeys(PChar(First), PChar(Second));
  { As GNU sort does, equal keys fall back to comparing whole lines,
    unless -u asks for keys alone. }
  if (Result = 0) and not Unique then
    Result := CompareText(PChar(First), PChar(Second));
  if Reverse then
    Result := -Result;
end;

procedure ParseKey(Text: PChar);
var
  Comma: PtrInt;
  Number: Int64;
  Part: array[0..31] of Char;
begin
  Comma := FindCharacter(Text, ',');
  if Comma >= 0 then
  begin
    CopyText(@Part[0], Text, PtrUInt(Comma) + 1);
    Text := Text + Comma + 1;
  end
  else
  begin
    CopyText(@Part[0], Text, SizeOf(Part));
    Text := nil;
  end;
  { Per-key options such as "2n" apply to the whole sort here. }
  while (TextLength(@Part[0]) > 0) and IsLetter(Part[TextLength(@Part[0]) - 1]) do
  begin
    case Part[TextLength(@Part[0]) - 1] of
      'n': Numeric := True;
      'r': Reverse := True;
      'f': IgnoreCase := True;
      'b': IgnoreBlanks := True;
    end;
    Part[TextLength(@Part[0]) - 1] := #0;
  end;
  if not ParseInteger(@Part[0], Number) or (Number < 1) then
    Fail(2, 'invalid number at field start: invalid count at start of ''%s''', [ArgumentText(@Part[0])]);
  KeyStart := Integer(Number);
  KeyEnd := 0;
  if Text <> nil then
  begin
    CopyText(@Part[0], Text, SizeOf(Part));
    while (TextLength(@Part[0]) > 0) and IsLetter(Part[TextLength(@Part[0]) - 1]) do
      Part[TextLength(@Part[0]) - 1] := #0;
    if not ParseInteger(@Part[0], Number) or (Number < 1) then
      Fail(2, 'invalid number after '','': invalid count at start of ''%s''', [ArgumentText(@Part[0])]);
    KeyEnd := Integer(Number);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  OutputPath: PChar;
  Lines: TLineList;
  Index: Integer;
  Stream: PInputStream;
  Output: POutputStream;
  OutputHandle: Int64;
  ExitStatus: LongInt;
begin
  OutputPath := nil;
  Separator := #0;
  KeyStart := 0;
  KeyEnd := 0;
  BeginOptions(Parser, [
    OptionDefinition('b', 'ignore-leading-blanks', False, OptionIgnoreBlanks),
    OptionDefinition('f', 'ignore-case', False, OptionIgnoreCase),
    OptionDefinition('n', 'numeric-sort', False, OptionNumeric),
    OptionDefinition('r', 'reverse', False, OptionReverse),
    OptionDefinition('k', 'key', True, OptionKey),
    OptionDefinition('t', 'field-separator', True, OptionSeparator),
    OptionDefinition('o', 'output', True, OptionOutput),
    OptionDefinition('u', 'unique', False, OptionUnique)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionIgnoreBlanks: IgnoreBlanks := True;
      OptionIgnoreCase: IgnoreCase := True;
      OptionNumeric: Numeric := True;
      OptionReverse: Reverse := True;
      OptionKey: ParseKey(Value);
      OptionSeparator:
        begin
          if (Value[0] = #0) or (Value[1] <> #0) then
            Fail(2, 'multi-character tab ''%s''', [ArgumentText(Value)]);
          Separator := Value[0];
        end;
      OptionOutput: OutputPath := Value;
      OptionUnique: Unique := True;
    end;

  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;

  ExitStatus := 0;
  BeginLineList(Lines);
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Stream := OpenInput(Parser.Operands[Index]);
    if Stream = nil then
      Fail(2, 'cannot read: %s', [ArgumentText(Parser.Operands[Index])]);
    ReadAllLines(Stream, Lines);
    CloseInput(Stream);
  end;

  SortPointers(PPointer(Lines.Items), Lines.Count, @CompareLines, nil);

  { The output file may be one of the inputs, so open it only now. }
  Output := StandardOutput;
  OutputHandle := -1;
  if OutputPath <> nil then
  begin
    OutputHandle := OpenFile(OutputPath, OpenWrite or OpenCreate or OpenTruncate);
    if OutputHandle < 0 then
      FailWithError(2, ErrorCodeOf(OutputHandle), 'open failed: %s', [ArgumentText(OutputPath)]);
    Output := CreateOutputStream(OutputHandle);
  end;
  for Index := 0 to Lines.Count - 1 do
  begin
    if Unique and (Index > 0) and (CompareKeys(Lines.Items[Index - 1], Lines.Items[Index]) = 0) then
      Continue;
    WriteLine(Output, Lines.Items[Index]);
  end;
  if OutputHandle >= 0 then
  begin
    DestroyOutputStream(Output);
    CloseFile(OutputHandle);
  end;
  Halt(ExitStatus);
end.
