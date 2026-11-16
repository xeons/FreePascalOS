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
  join - join lines of two files on a common field

  join [-i] [-t CHAR] [-1 FIELD] [-2 FIELD] [-j FIELD] [-a FILENUM]
       [-v FILENUM] [-e EMPTY] [-o FORMAT] FILE1 FILE2

  Both files must be sorted on the join field. Fields are separated by
  runs of blanks, or by CHAR with -t. The output is the join field, the
  other fields of FILE1, then the other fields of FILE2, unless -o gives
  a list such as "1.2,2.3,0".
}
program join;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Numbers,
  Util.Output;

const
  Usage = 'Usage: join [OPTION]... FILE1 FILE2'#10 +
    'For each pair of input lines with identical join fields, write a line to'#10 +
    'standard output.  The default join field is the first, delimited by blanks.'#10#10 +
    '  -a FILENUM        also print unpairable lines from file FILENUM'#10 +
    '  -e STRING         replace missing (empty) input fields with STRING'#10 +
    '  -i, --ignore-case  ignore differences in case when comparing fields'#10 +
    '  -j FIELD          equivalent to ''-1 FIELD -2 FIELD'''#10 +
    '  -o FORMAT         obey FORMAT while constructing output line'#10 +
    '  -t CHAR           use CHAR as input and output field separator'#10 +
    '  -v FILENUM        like -a FILENUM, but suppress joined output lines'#10 +
    '  -1 FIELD          join on this FIELD of file 1'#10 +
    '  -2 FIELD          join on this FIELD of file 2'#10;

  OptionUnpaired = 1;
  OptionEmpty = 2;
  OptionIgnoreCase = 3;
  OptionBothFields = 4;
  OptionFormat = 5;
  OptionSeparator = 6;
  OptionOnlyUnpaired = 7;
  OptionFieldOne = 8;
  OptionFieldTwo = 9;
  { The highest field number -1, -2 and -j accept. }
  MaximumFieldNumber = 128;

  Blanks = [' ', #9, #10, #11, #12, #13];

type
  TFormatItem = record
    FileNumber: Integer;  { 0 = the join field }
    Field: Integer;
  end;

  { One input line split into fields, or none (an unpaired side). }
  TLineFields = record
    Present: Boolean;
    Fields: TStringArray;
  end;

var
  Separator: Char;   { #0 = blanks }
  IgnoreCase: Boolean;
  JoinField: array[1..2] of Integer;
  PrintUnpaired: array[1..2] of Boolean;
  PrintPaired: Boolean;
  Empty: string;
  FormatItems: array of TFormatItem;

function SplitAtBlanks(const Line: string): TStringArray;
var
  Position: Integer;
  Start: Integer;
begin
  Result := nil;
  Position := 1;
  while Position <= Length(Line) do
  begin
    while (Position <= Length(Line)) and (Line[Position] in Blanks) do
      Inc(Position);
    if Position > Length(Line) then
      Break;
    Start := Position;
    while (Position <= Length(Line)) and not (Line[Position] in Blanks) do
      Inc(Position);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(Line, Start, Position - Start);
  end;
end;

{ Every separator starts a new field, so a line without text still has
  one (empty) field. }
function SplitAtSeparator(const Line: string): TStringArray;
var
  Position: Integer;
  Start: Integer;
begin
  Result := nil;
  Start := 1;
  for Position := 1 to Length(Line) do
    if Line[Position] = Separator then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Line, Start, Position - Start);
      Start := Position + 1;
    end;
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)] := Copy(Line, Start, MaxInt);
end;

function SplitLine(const Line: string): TLineFields;
begin
  Result.Present := True;
  if Separator = #0 then
    Result.Fields := SplitAtBlanks(Line)
  else
    Result.Fields := SplitAtSeparator(Line);
end;

function NoLine: TLineFields;
begin
  Result.Present := False;
  Result.Fields := nil;
end;

{ Field Number (from 1); '' when the line has no such field. }
function FieldOf(const Line: TLineFields; Number: Integer): string;
begin
  if (Number >= 1) and (Number <= Length(Line.Fields)) then
    Result := Line.Fields[Number - 1]
  else
    Result := '';
end;

function CompareKeys(const First, Second: string): Integer;
begin
  if IgnoreCase then
    Result := CompareStr(LowerCase(First), LowerCase(Second))
  else
    Result := CompareStr(First, Second);
end;

function OutputSeparator: string;
begin
  if Separator = #0 then
    Result := ' '
  else
    Result := Separator;
end;

{ A field as printed: missing and empty fields become the -e text. }
function ShownField(const Text: string): string;
begin
  if Text = '' then
    Result := Empty
  else
    Result := Text;
end;

function FormattedLine(const One, Two: TLineFields; const Key: string): string;
var
  Index: Integer;
  Item: TFormatItem;
begin
  Result := '';
  for Index := 0 to High(FormatItems) do
  begin
    if Index > 0 then
      Result := Result + OutputSeparator;
    Item := FormatItems[Index];
    if Item.FileNumber = 0 then
      Result := Result + ShownField(Key)
    else if Item.FileNumber = 1 then
      Result := Result + ShownField(FieldOf(One, Item.Field))
    else
      Result := Result + ShownField(FieldOf(Two, Item.Field));
  end;
end;

{ The fields of Line other than its join field, each after a separator. }
function OtherFields(const Line: TLineFields; Join: Integer): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 1 to Length(Line.Fields) do
    if Index <> Join then
      Result := Result + OutputSeparator + ShownField(Line.Fields[Index - 1]);
end;

{ One output line; either side may be missing (unpaired lines). }
procedure WriteJoined(const One, Two: TLineFields);
var
  Key: string;
begin
  if One.Present then
    Key := FieldOf(One, JoinField[1])
  else
    Key := FieldOf(Two, JoinField[2]);

  if Length(FormatItems) > 0 then
    PrintStringLine(FormattedLine(One, Two, Key))
  else
    PrintStringLine(ShownField(Key) + OtherFields(One, JoinField[1]) + OtherFields(Two, JoinField[2]));
end;

procedure FailOnFieldSpecifier(const Text: string);
begin
  Fail(1, Format('invalid field specifier: ''%s''', [Text]));
end;

procedure ParseFormat(const Text: string);
var
  Position: Integer;
  Item: TFormatItem;
begin
  Position := 1;
  FormatItems := nil;
  while Position <= Length(Text) do
  begin
    if Text[Position] = '0' then
    begin
      Item.FileNumber := 0;
      Item.Field := 0;
      Inc(Position);
    end
    else if (Text[Position] in ['1', '2']) and (Position < Length(Text)) and (Text[Position + 1] = '.') then
    begin
      Item.FileNumber := Ord(Text[Position]) - Ord('0');
      Position := Position + 2;
      Item.Field := 0;
      while (Position <= Length(Text)) and (Text[Position] in ['0'..'9']) do
      begin
        Item.Field := Item.Field * 10 + Ord(Text[Position]) - Ord('0');
        Inc(Position);
      end;
      if Item.Field = 0 then
        FailOnFieldSpecifier(Text);
    end
    else
      FailOnFieldSpecifier(Text);
    SetLength(FormatItems, Length(FormatItems) + 1);
    FormatItems[High(FormatItems)] := Item;
    if (Position <= Length(Text)) and (Text[Position] in [',', ' ']) then
      Inc(Position);
  end;
end;

function ParseFieldNumber(const Text: string): Integer;
var
  Value: Int64;
begin
  if not ParseDecimal(Text, Value) or (Value < 1) or (Value > MaximumFieldNumber) then
    Fail(1, Format('invalid field number: ''%s''', [Text]));
  Result := Integer(Value);
end;

function ParseFileNumber(const Text: string): Integer;
begin
  if Text = '1' then
    Result := 1
  else if Text = '2' then
    Result := 2
  else
  begin
    Fail(1, Format('invalid file number: ''%s''', [Text]));
    Result := 1;
  end;
end;

procedure ReadOptions(out FirstPath, SecondPath: string);
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
begin
  CommandLine := TCommandLine.Create([
    CommandOption('a', '', True, OptionUnpaired),
    CommandOption('e', '', True, OptionEmpty),
    CommandOption('i', 'ignore-case', False, OptionIgnoreCase),
    CommandOption('j', '', True, OptionBothFields),
    CommandOption('o', '', True, OptionFormat),
    CommandOption('t', '', True, OptionSeparator),
    CommandOption('v', '', True, OptionOnlyUnpaired),
    CommandOption('1', '', True, OptionFieldOne),
    CommandOption('2', '', True, OptionFieldTwo)], Usage);
  try
    while CommandLine.NextOption(Code, Value) do
      case Code of
        OptionUnpaired: PrintUnpaired[ParseFileNumber(Value)] := True;
        OptionEmpty: Empty := Value;
        OptionIgnoreCase: IgnoreCase := True;
        OptionBothFields:
          begin
            JoinField[1] := ParseFieldNumber(Value);
            JoinField[2] := JoinField[1];
          end;
        OptionFormat: ParseFormat(Value);
        OptionSeparator:
          begin
            if Length(Value) <> 1 then
              Fail(1, Format('multi-character tab ''%s''', [Value]));
            Separator := Value[1];
          end;
        OptionOnlyUnpaired:
          begin
            PrintUnpaired[ParseFileNumber(Value)] := True;
            PrintPaired := False;
          end;
        OptionFieldOne: JoinField[1] := ParseFieldNumber(Value);
        OptionFieldTwo: JoinField[2] := ParseFieldNumber(Value);
      end;
    if CommandLine.OperandCount <> 2 then
      FailWithUsageHint('missing operand');
    FirstPath := CommandLine.Operands[0];
    SecondPath := CommandLine.Operands[1];
  finally
    CommandLine.Free;
  end;
end;

{ The next line of Stream split into fields; not Present at the end. }
function NextLine(Stream: PInputStream): TLineFields;
var
  Line: string;
  HadLineEnd: Boolean;
begin
  if ReadTextLine(Stream, Line, HadLineEnd) then
    Result := SplitLine(Line)
  else
    Result := NoLine;
end;

procedure JoinStreams(FirstStream, SecondStream: PInputStream);
var
  One: TLineFields;
  Two: TLineFields;
  Order: Integer;
  Key: string;
  Group: array of TLineFields;
  Member: TLineFields;
begin
  One := NextLine(FirstStream);
  Two := NextLine(SecondStream);
  while One.Present or Two.Present do
  begin
    if One.Present and Two.Present then
      Order := CompareKeys(FieldOf(One, JoinField[1]), FieldOf(Two, JoinField[2]))
    else if One.Present then
      Order := -1
    else
      Order := 1;

    if Order < 0 then
    begin
      if PrintUnpaired[1] then
        WriteJoined(One, NoLine);
      One := NextLine(FirstStream);
      Continue;
    end;
    if Order > 0 then
    begin
      if PrintUnpaired[2] then
        WriteJoined(NoLine, Two);
      Two := NextLine(SecondStream);
      Continue;
    end;

    { Equal keys: every line of file 2 with this key pairs with every
      line of file 1 with this key. Collect file 2's group first. }
    Key := FieldOf(Two, JoinField[2]);
    Group := nil;
    repeat
      SetLength(Group, Length(Group) + 1);
      Group[High(Group)] := Two;
      Two := NextLine(SecondStream);
    until not Two.Present or (CompareKeys(FieldOf(Two, JoinField[2]), Key) <> 0);

    repeat
      if PrintPaired then
        for Member in Group do
          WriteJoined(One, Member);
      One := NextLine(FirstStream);
    until not One.Present or (CompareKeys(FieldOf(One, JoinField[1]), Key) <> 0);
  end;
end;

var
  FirstPath: string;
  SecondPath: string;
  FirstStream: PInputStream;
  SecondStream: PInputStream;
begin
  Separator := #0;
  JoinField[1] := 1;
  JoinField[2] := 1;
  PrintPaired := True;
  Empty := '';
  ReadOptions(FirstPath, SecondPath);
  FirstStream := OpenInput(FirstPath);
  SecondStream := OpenInput(SecondPath);
  if (FirstStream = nil) or (SecondStream = nil) then
    Halt(1);
  JoinStreams(FirstStream, SecondStream);
  CloseInput(FirstStream);
  CloseInput(SecondStream);
end.
