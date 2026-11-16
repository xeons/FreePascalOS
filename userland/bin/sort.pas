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
{$H+}

uses
  Classes,
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Streams,
  Sys.Text,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Output,
  Util.Sorting;

const
  Usage = 'Usage: sort [OPTION]... [FILE]...'#10 +
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

type
  { The order of the lines, as the options ask for it. }
  TLineOrder = class
    function Compare(const First, Second: string): Integer;
  end;

var
  IgnoreBlanks: Boolean;
  IgnoreCase: Boolean;
  Numeric: Boolean;
  Reverse: Boolean;
  Unique: Boolean;
  KeyStart: Integer;   { 0 = whole line }
  KeyEnd: Integer;     { 0 = to the end of the line }
  Separator: Char;     { #0 = blanks }

{ Moves Position past one field: up to the separator, or over leading
  blanks and then the field's other characters. }
procedure SkipField(const Line: string; var Position: Integer);
begin
  if Separator <> #0 then
    while (Position <= Length(Line)) and (Line[Position] <> Separator) do
      Inc(Position)
  else
  begin
    while (Position <= Length(Line)) and IsSpace(Line[Position]) do
      Inc(Position);
    while (Position <= Length(Line)) and not IsSpace(Line[Position]) do
      Inc(Position);
  end;
end;

{ Where field Number (from 1) starts in Line. A blank separated field
  includes its leading blanks. }
function FieldStart(const Line: string; Number: Integer): Integer;
var
  Field: Integer;
begin
  Result := 1;
  Field := 1;
  while (Field < Number) and (Result <= Length(Line)) do
  begin
    SkipField(Line, Result);
    if (Separator <> #0) and (Result <= Length(Line)) then
      Inc(Result);
    Inc(Field);
  end;
end;

{ Just after the end of the key: the end of field KeyEnd, or of the line. }
function FieldEnd(const Line: string): Integer;
begin
  if KeyEnd = 0 then
    Exit(Length(Line) + 1);
  Result := FieldStart(Line, KeyEnd);
  SkipField(Line, Result);
end;

{ The key is Line[Start..Finish - 1]. }
procedure KeyOf(const Line: string; out Start, Finish: Integer);
begin
  if KeyStart = 0 then
  begin
    Start := 1;
    Finish := Length(Line) + 1;
  end
  else
  begin
    Start := FieldStart(Line, KeyStart);
    Finish := FieldEnd(Line);
    if Finish < Start then
      Finish := Start;
  end;
  if IgnoreBlanks or Numeric then
    while (Start < Finish) and IsSpace(Line[Start]) do
      Inc(Start);
end;

{ Reads a number (sign, digits, optional fraction) as an integer part and
  nine fraction digits, so "10" > "9" and "-3" < "2". Negative numbers
  come back with both parts negated. }
procedure ReadNumber(const Text: string; Position, Finish: Integer; out Whole: Int64; out Fraction: Int64);
var
  IsNegative: Boolean;
  Scale: Integer;
begin
  IsNegative := False;
  Whole := 0;
  Fraction := 0;
  if (Position < Finish) and (Text[Position] = '-') then
  begin
    IsNegative := True;
    Inc(Position);
  end;
  while (Position < Finish) and IsDigit(Text[Position]) do
  begin
    Whole := Whole * 10 + Ord(Text[Position]) - Ord('0');
    Inc(Position);
  end;
  Scale := 0;
  if (Position < Finish) and (Text[Position] = '.') then
  begin
    Inc(Position);
    while (Position < Finish) and IsDigit(Text[Position]) and (Scale < 9) do
    begin
      Fraction := Fraction * 10 + Ord(Text[Position]) - Ord('0');
      Inc(Scale);
      Inc(Position);
    end;
  end;
  while Scale < 9 do
  begin
    Fraction := Fraction * 10;
    Inc(Scale);
  end;
  if IsNegative then
  begin
    Whole := -Whole;
    Fraction := -Fraction;
  end;
end;

function CompareNumbers(const First: string; FirstStart, FirstEnd: Integer;
  const Second: string; SecondStart, SecondEnd: Integer): Integer;
var
  FirstWhole, SecondWhole: Int64;
  FirstFraction, SecondFraction: Int64;
begin
  ReadNumber(First, FirstStart, FirstEnd, FirstWhole, FirstFraction);
  ReadNumber(Second, SecondStart, SecondEnd, SecondWhole, SecondFraction);
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

function CompareRanges(const First: string; FirstStart, FirstEnd: Integer;
  const Second: string; SecondStart, SecondEnd: Integer): Integer;
var
  Left: Char;
  Right: Char;
begin
  while (FirstStart < FirstEnd) and (SecondStart < SecondEnd) do
  begin
    Left := First[FirstStart];
    Right := Second[SecondStart];
    if IgnoreCase then
    begin
      Left := UpCase(Left);
      Right := UpCase(Right);
    end;
    if Left <> Right then
      Exit(Integer(Byte(Left)) - Integer(Byte(Right)));
    Inc(FirstStart);
    Inc(SecondStart);
  end;
  if FirstStart < FirstEnd then
    Exit(1);
  if SecondStart < SecondEnd then
    Exit(-1);
  Result := 0;
end;

function CompareKeys(const First, Second: string): Integer;
var
  FirstStart, FirstFinish: Integer;
  SecondStart, SecondFinish: Integer;
begin
  KeyOf(First, FirstStart, FirstFinish);
  KeyOf(Second, SecondStart, SecondFinish);
  if Numeric then
    Result := CompareNumbers(First, FirstStart, FirstFinish, Second, SecondStart, SecondFinish)
  else
    Result := CompareRanges(First, FirstStart, FirstFinish, Second, SecondStart, SecondFinish);
end;

function TLineOrder.Compare(const First, Second: string): Integer;
begin
  Result := CompareKeys(First, Second);
  { As GNU sort does, equal keys fall back to comparing whole lines,
    unless -u asks for keys alone. }
  if (Result = 0) and not Unique then
    Result := CompareStr(First, Second);
  if Reverse then
    Result := -Result;
end;

{ Removes the letters at the end of Part, applying the per-key options
  among them (such as "2n") to the whole sort when ApplyOptions. }
function StripKeyOptions(const Part: string; ApplyOptions: Boolean): string;
begin
  Result := Part;
  while (Result <> '') and IsLetter(Result[Length(Result)]) do
  begin
    if ApplyOptions then
      case Result[Length(Result)] of
        'n': Numeric := True;
        'r': Reverse := True;
        'f': IgnoreCase := True;
        'b': IgnoreBlanks := True;
      end;
    SetLength(Result, Length(Result) - 1);
  end;
end;

procedure ParseKey(const Text: string);
var
  Comma: Integer;
  Number: Int64;
  Part: string;
begin
  Comma := Pos(',', Text);
  if Comma > 0 then
    Part := Copy(Text, 1, Comma - 1)
  else
    Part := Text;
  Part := StripKeyOptions(Part, True);
  if not ParseDecimal(Part, Number) or (Number < 1) then
    Fail(2, Format('invalid number at field start: invalid count at start of ''%s''', [Part]));
  KeyStart := Integer(Number);
  KeyEnd := 0;
  if Comma > 0 then
  begin
    Part := StripKeyOptions(Copy(Text, Comma + 1, MaxInt), False);
    if not ParseDecimal(Part, Number) or (Number < 1) then
      Fail(2, Format('invalid number after '','': invalid count at start of ''%s''', [Part]));
    KeyEnd := Integer(Number);
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  OutputPath: string;
  InputLines: TStringList;
  Lines: TStringArray;
  Order: TLineOrder;
  Operand: string;
  Index: Integer;
  Stream: PInputStream;
  Output: POutputStream;
  OutputHandle: Int64;
  ExitStatus: LongInt;
begin
  Separator := #0;
  KeyStart := 0;
  KeyEnd := 0;
  CommandLine := TCommandLine.Create([
    CommandOption('b', 'ignore-leading-blanks', False, OptionIgnoreBlanks),
    CommandOption('f', 'ignore-case', False, OptionIgnoreCase),
    CommandOption('n', 'numeric-sort', False, OptionNumeric),
    CommandOption('r', 'reverse', False, OptionReverse),
    CommandOption('k', 'key', True, OptionKey),
    CommandOption('t', 'field-separator', True, OptionSeparator),
    CommandOption('o', 'output', True, OptionOutput),
    CommandOption('u', 'unique', False, OptionUnique)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionIgnoreBlanks: IgnoreBlanks := True;
      OptionIgnoreCase: IgnoreCase := True;
      OptionNumeric: Numeric := True;
      OptionReverse: Reverse := True;
      OptionKey: ParseKey(Value);
      OptionSeparator:
        begin
          if Length(Value) <> 1 then
            Fail(2, Format('multi-character tab ''%s''', [Value]));
          Separator := Value[1];
        end;
      OptionOutput: OutputPath := Value;
      OptionUnique: Unique := True;
    end;

  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];

  ExitStatus := 0;
  InputLines := TStringList.Create;
  for Operand in CommandLine.Operands do
  begin
    Stream := OpenInput(Operand);
    if Stream = nil then
      Fail(2, 'cannot read: ' + Operand);
    ReadLinesInto(Stream, InputLines);
    CloseInput(Stream);
  end;
  Lines := InputLines.ToStringArray;
  InputLines.Free;

  Order := TLineOrder.Create;
  SortStrings(Lines, @Order.Compare);
  Order.Free;

  { The output file may be one of the inputs, so open it only now. }
  Output := StandardOutput;
  OutputHandle := -1;
  if CommandLine.OptionGiven(OptionOutput) then
  begin
    OutputHandle := OpenFile(PChar(OutputPath), OpenWrite or OpenCreate or OpenTruncate);
    if OutputHandle < 0 then
      FailWithError(2, ErrorCodeOf(OutputHandle), 'open failed: ' + OutputPath);
    Output := CreateOutputStream(OutputHandle);
  end;
  for Index := 0 to High(Lines) do
  begin
    if Unique and (Index > 0) and (CompareKeys(Lines[Index - 1], Lines[Index]) = 0) then
      Continue;
    WriteStringLine(Output, Lines[Index]);
  end;
  if OutputHandle >= 0 then
  begin
    DestroyOutputStream(Output);
    CloseFile(OutputHandle);
  end;
  Halt(ExitStatus);
end.
