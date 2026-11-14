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
  Usage: PChar = 'Usage: join [OPTION]... FILE1 FILE2'#10 +
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
  MaximumFields = 128;
  MaximumFormatItems = 64;

type
  TFields = record
    Items: array[0..MaximumFields - 1] of PChar;
    Count: Integer;
    Storage: PChar;
  end;

  PFields = ^TFields;

  TFormatItem = record
    FileNumber: Integer;  { 0 = the join field }
    Field: Integer;
  end;

var
  Separator: Char;   { #0 = blanks }
  IgnoreCase: Boolean;
  JoinField: array[1..2] of Integer;
  PrintUnpaired: array[1..2] of Boolean;
  PrintPaired: Boolean;
  Empty: PChar;
  FormatItems: array[0..MaximumFormatItems - 1] of TFormatItem;
  FormatCount: Integer;

procedure SplitLine(Line: PChar; out Fields: TFields);
var
  Position: PtrUInt;
begin
  Fields.Storage := DuplicateText(Line);
  Fields.Count := 0;
  Position := 0;
  if Separator = #0 then
  begin
    while Fields.Storage[Position] <> #0 do
    begin
      while IsSpace(Fields.Storage[Position]) do
        Inc(Position);
      if Fields.Storage[Position] = #0 then
        Break;
      if Fields.Count < MaximumFields then
      begin
        Fields.Items[Fields.Count] := Fields.Storage + Position;
        Inc(Fields.Count);
      end;
      while (Fields.Storage[Position] <> #0) and not IsSpace(Fields.Storage[Position]) do
        Inc(Position);
      if Fields.Storage[Position] <> #0 then
      begin
        Fields.Storage[Position] := #0;
        Inc(Position);
      end;
    end;
    Exit;
  end;
  Fields.Items[0] := Fields.Storage;
  Fields.Count := 1;
  while Fields.Storage[Position] <> #0 do
  begin
    if (Fields.Storage[Position] = Separator) and (Fields.Count < MaximumFields) then
    begin
      Fields.Storage[Position] := #0;
      Fields.Items[Fields.Count] := Fields.Storage + Position + 1;
      Inc(Fields.Count);
    end;
    Inc(Position);
  end;
end;

function FieldOf(const Fields: TFields; Number: Integer): PChar;
begin
  if (Number >= 1) and (Number <= Fields.Count) then
    Result := Fields.Items[Number - 1]
  else
    Result := nil;
end;

function CompareKeys(First, Second: PChar): Integer;
begin
  if First = nil then
    First := '';
  if Second = nil then
    Second := '';
  if IgnoreCase then
    Result := CompareTextIgnoringCase(First, Second)
  else
    Result := CompareText(First, Second);
end;

procedure WriteSeparator;
begin
  if Separator = #0 then
    WriteCharacter(StandardOutput, ' ')
  else
    WriteCharacter(StandardOutput, Separator);
end;

procedure WriteField(Text: PChar);
begin
  if (Text = nil) or ((Text^ = #0) and (Empty <> nil)) then
    Text := Empty;
  if Text <> nil then
    WriteText(StandardOutput, Text);
end;

{ One output line; either side may be missing (unpaired lines). }
procedure WriteJoined(One, Two: PFields);
var
  Key: PChar;
  Index: Integer;
  Item: TFormatItem;
  Source: PFields;
begin
  if One <> nil then
    Key := FieldOf(One^, JoinField[1])
  else
    Key := FieldOf(Two^, JoinField[2]);

  if FormatCount > 0 then
  begin
    for Index := 0 to FormatCount - 1 do
    begin
      if Index > 0 then
        WriteSeparator;
      Item := FormatItems[Index];
      if Item.FileNumber = 0 then
        WriteField(Key)
      else
      begin
        if Item.FileNumber = 1 then
          Source := One
        else
          Source := Two;
        if Source = nil then
          WriteField(nil)
        else
          WriteField(FieldOf(Source^, Item.Field));
      end;
    end;
    WriteCharacter(StandardOutput, #10);
    Exit;
  end;

  WriteField(Key);
  if One <> nil then
    for Index := 1 to One^.Count do
      if Index <> JoinField[1] then
      begin
        WriteSeparator;
        WriteField(One^.Items[Index - 1]);
      end;
  if Two <> nil then
    for Index := 1 to Two^.Count do
      if Index <> JoinField[2] then
      begin
        WriteSeparator;
        WriteField(Two^.Items[Index - 1]);
      end;
  WriteCharacter(StandardOutput, #10);
end;

procedure ParseFormat(Text: PChar);
var
  Position: Integer;
  Item: TFormatItem;
begin
  Position := 0;
  FormatCount := 0;
  while Text[Position] <> #0 do
  begin
    if Text[Position] = '0' then
    begin
      Item.FileNumber := 0;
      Item.Field := 0;
      Inc(Position);
    end
    else if (Text[Position] in ['1', '2']) and (Text[Position + 1] = '.') then
    begin
      Item.FileNumber := Ord(Text[Position]) - Ord('0');
      Position := Position + 2;
      Item.Field := 0;
      while IsDigit(Text[Position]) do
      begin
        Item.Field := Item.Field * 10 + Ord(Text[Position]) - Ord('0');
        Inc(Position);
      end;
      if Item.Field = 0 then
        Fail(1, 'invalid field specifier: ''%s''', [ArgumentText(Text)]);
    end
    else
      Fail(1, 'invalid field specifier: ''%s''', [ArgumentText(Text)]);
    if FormatCount < MaximumFormatItems then
    begin
      FormatItems[FormatCount] := Item;
      Inc(FormatCount);
    end;
    if (Text[Position] = ',') or (Text[Position] = ' ') then
      Inc(Position);
  end;
end;

function ParseFieldNumber(Text: PChar): Integer;
var
  Value: Int64;
begin
  if not ParseInteger(Text, Value) or (Value < 1) or (Value > MaximumFields) then
    Fail(1, 'invalid field number: ''%s''', [ArgumentText(Text)]);
  Result := Integer(Value);
end;

function ParseFileNumber(Text: PChar): Integer;
begin
  if TextIsEqual(Text, '1') then
    Result := 1
  else if TextIsEqual(Text, '2') then
    Result := 2
  else
  begin
    Fail(1, 'invalid file number: ''%s''', [ArgumentText(Text)]);
    Result := 1;
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Streams: array[1..2] of PInputStream;
  Lines: array[1..2] of PChar;
  Has: array[1..2] of Boolean;
  Fields: array[1..2] of TFields;
  HadLineEnd: Boolean;
  Order: Integer;
  Group: TLineList;
  GroupIndex: Integer;
  GroupFields: TFields;
  Key: PChar;
begin
  Separator := #0;
  JoinField[1] := 1;
  JoinField[2] := 1;
  PrintPaired := True;
  Empty := nil;
  FormatCount := 0;
  BeginOptions(Parser, [
    OptionDefinition('a', nil, True, OptionUnpaired),
    OptionDefinition('e', nil, True, OptionEmpty),
    OptionDefinition('i', 'ignore-case', False, OptionIgnoreCase),
    OptionDefinition('j', nil, True, OptionBothFields),
    OptionDefinition('o', nil, True, OptionFormat),
    OptionDefinition('t', nil, True, OptionSeparator),
    OptionDefinition('v', nil, True, OptionOnlyUnpaired),
    OptionDefinition('1', nil, True, OptionFieldOne),
    OptionDefinition('2', nil, True, OptionFieldTwo)], Usage);
  while NextOption(Parser, Code, Value) do
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
          if (Value[0] = #0) or (Value[1] <> #0) then
            Fail(1, 'multi-character tab ''%s''', [ArgumentText(Value)]);
          Separator := Value[0];
        end;
      OptionOnlyUnpaired:
        begin
          PrintUnpaired[ParseFileNumber(Value)] := True;
          PrintPaired := False;
        end;
      OptionFieldOne: JoinField[1] := ParseFieldNumber(Value);
      OptionFieldTwo: JoinField[2] := ParseFieldNumber(Value);
    end;
  if Parser.OperandCount <> 2 then
    FailWithUsageHint('missing operand', []);
  Streams[1] := OpenInput(Parser.Operands[0]);
  Streams[2] := OpenInput(Parser.Operands[1]);
  if (Streams[1] = nil) or (Streams[2] = nil) then
    Halt(1);

  Has[1] := ReadLine(Streams[1], Lines[1], HadLineEnd);
  Has[2] := ReadLine(Streams[2], Lines[2], HadLineEnd);
  while Has[1] or Has[2] do
  begin
    if Has[1] then
      SplitLine(Lines[1], Fields[1]);
    if Has[2] then
      SplitLine(Lines[2], Fields[2]);
    if Has[1] and Has[2] then
      Order := CompareKeys(FieldOf(Fields[1], JoinField[1]), FieldOf(Fields[2], JoinField[2]))
    else if Has[1] then
      Order := -1
    else
      Order := 1;

    if Order < 0 then
    begin
      if PrintUnpaired[1] then
        WriteJoined(@Fields[1], nil);
      FreeMemory(Fields[1].Storage);
      if Has[2] then
        FreeMemory(Fields[2].Storage);
      FreeMemory(Lines[1]);
      Has[1] := ReadLine(Streams[1], Lines[1], HadLineEnd);
      Continue;
    end;
    if Order > 0 then
    begin
      if PrintUnpaired[2] then
        WriteJoined(nil, @Fields[2]);
      FreeMemory(Fields[2].Storage);
      if Has[1] then
        FreeMemory(Fields[1].Storage);
      FreeMemory(Lines[2]);
      Has[2] := ReadLine(Streams[2], Lines[2], HadLineEnd);
      Continue;
    end;

    { Equal keys: every line of file 2 with this key pairs with every
      line of file 1 with this key. Collect file 2's group first. }
    Key := DuplicateText(FieldOf(Fields[2], JoinField[2]));
    BeginLineList(Group);
    AddLine(Group, Lines[2]);
    FreeMemory(Fields[2].Storage);
    repeat
      Has[2] := ReadLine(Streams[2], Lines[2], HadLineEnd);
      if not Has[2] then
        Break;
      SplitLine(Lines[2], Fields[2]);
      Order := CompareKeys(FieldOf(Fields[2], JoinField[2]), Key);
      FreeMemory(Fields[2].Storage);
      if Order <> 0 then
        Break;
      AddLine(Group, Lines[2]);
    until False;

    repeat
      if PrintPaired then
        for GroupIndex := 0 to Group.Count - 1 do
        begin
          SplitLine(Group.Items[GroupIndex], GroupFields);
          WriteJoined(@Fields[1], @GroupFields);
          FreeMemory(GroupFields.Storage);
        end;
      FreeMemory(Fields[1].Storage);
      FreeMemory(Lines[1]);
      Has[1] := ReadLine(Streams[1], Lines[1], HadLineEnd);
      if not Has[1] then
        Break;
      SplitLine(Lines[1], Fields[1]);
      if CompareKeys(FieldOf(Fields[1], JoinField[1]), Key) <> 0 then
      begin
        FreeMemory(Fields[1].Storage);
        Break;
      end;
    until False;
    FreeLineList(Group);
    FreeMemory(Key);
  end;
  CloseInput(Streams[1]);
  CloseInput(Streams[2]);
end.
