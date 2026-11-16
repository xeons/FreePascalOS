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
  cut - remove sections from each line of files

  cut -b LIST [-n] [FILE]...
  cut -c LIST [FILE]...
  cut -f LIST [-d DELIMITER] [-s] [--output-delimiter=TEXT] [FILE]...

  LIST is made of ranges separated by commas: N, N-M, N- or -M,
  counted from 1.
}
program cut;

{$mode objfpc}{$H+}

uses
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: cut OPTION... [FILE]...'#10 +
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

  Unbounded = High(LongInt);
  InvalidList = 'invalid byte, character or field list';

type
  TRange = record
    First: LongInt;
    Last: LongInt;
  end;

  TCutMode = (CutNone, CutBytes, CutCharacters, CutFields);

var
  Ranges: array of TRange;
  Mode: TCutMode;
  Delimiter: Char;
  OutputDelimiter: string;
  HasOutputDelimiter: Boolean;
  OnlyDelimited: Boolean;
  Complement: Boolean;

{ The character at Position, #0 past the end. }
function CharacterAt(const Text: string; Position: Integer): Char;
begin
  if Position <= Length(Text) then
    Result := Text[Position]
  else
    Result := #0;
end;

{ Reads the digits at Position into Number; False if there are none. }
function ReadNumber(const Text: string; var Position: Integer; out Number: LongInt): Boolean;
begin
  Number := 0;
  Result := False;
  while CharacterAt(Text, Position) in ['0'..'9'] do
  begin
    Number := Number * 10 + Ord(Text[Position]) - Ord('0');
    Result := True;
    Inc(Position);
  end;
end;

procedure ParseList(const Text: string);
var
  Position: Integer;
  Number: LongInt;
  Range: TRange;
  HasDash: Boolean;
  SawDigits: Boolean;
begin
  Ranges := nil;
  Position := 1;
  repeat
    Range.First := 1;
    Range.Last := Unbounded;
    HasDash := False;
    SawDigits := ReadNumber(Text, Position, Number);
    if SawDigits then
      Range.First := Number;
    if CharacterAt(Text, Position) = '-' then
    begin
      HasDash := True;
      Inc(Position);
      SawDigits := ReadNumber(Text, Position, Number);
      if SawDigits then
        Range.Last := Number;
    end
    else
      Range.Last := Range.First;
    if (Range.First < 1) or (Range.Last < Range.First) or (not HasDash and not SawDigits) then
      Fail(1, InvalidList);
    SetLength(Ranges, Length(Ranges) + 1);
    Ranges[High(Ranges)] := Range;
    if CharacterAt(Text, Position) = ',' then
      Inc(Position)
    else if Position <= Length(Text) then
      Fail(1, InvalidList);
  until Position > Length(Text);
end;

function IsSelected(Number: LongInt): Boolean;
var
  Range: TRange;
begin
  Result := False;
  for Range in Ranges do
    if (Number >= Range.First) and (Number <= Range.Last) then
    begin
      Result := True;
      Break;
    end;
  if Complement then
    Result := not Result;
end;

procedure CutPositions(const Line: string);
var
  Position: Integer;
  Number: LongInt;
  PreviousSelected: Boolean;
  PrintedAny: Boolean;
  Selected: string;
begin
  Number := 0;
  PreviousSelected := False;
  PrintedAny := False;
  Selected := '';
  for Position := 1 to Length(Line) do
  begin
    { With -c, a character is a whole UTF-8 sequence. }
    if (Mode = CutBytes) or ((Byte(Line[Position]) and $C0) <> $80) then
      Inc(Number);
    if IsSelected(Number) then
    begin
      if HasOutputDelimiter and PrintedAny and not PreviousSelected then
        Selected := Selected + OutputDelimiter;
      Selected := Selected + Line[Position];
      PrintedAny := True;
      PreviousSelected := True;
    end
    else
      PreviousSelected := False;
  end;
  PrintStringLine(Selected);
end;

procedure CutFieldsOfLine(const Line: string);
var
  Position: Integer;
  FieldNumber: LongInt;
  FieldStart: Integer;
  PrintedAny: Boolean;
  Separator: string;
  Selected: string;
begin
  if Pos(Delimiter, Line) = 0 then
  begin
    if not OnlyDelimited then
      PrintStringLine(Line);
    Exit;
  end;
  if HasOutputDelimiter then
    Separator := OutputDelimiter
  else
    Separator := Delimiter;
  FieldNumber := 1;
  FieldStart := 1;
  PrintedAny := False;
  Selected := '';
  { One position past the end closes the last field. }
  for Position := 1 to Length(Line) + 1 do
    if (Position > Length(Line)) or (Line[Position] = Delimiter) then
    begin
      if IsSelected(FieldNumber) then
      begin
        if PrintedAny then
          Selected := Selected + Separator;
        Selected := Selected + Copy(Line, FieldStart, Position - FieldStart);
        PrintedAny := True;
      end;
      Inc(FieldNumber);
      FieldStart := Position + 1;
    end;
  PrintStringLine(Selected);
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Operand: string;
  Stream: PInputStream;
  Line: string;
  HadLineEnd: Boolean;
  ExitStatus: LongInt;
begin
  Mode := CutNone;
  Delimiter := #9;
  HasOutputDelimiter := False;
  CommandLine := TCommandLine.Create([
    CommandOption('b', 'bytes', True, OptionBytes),
    CommandOption('c', 'characters', True, OptionCharacters),
    CommandOption('d', 'delimiter', True, OptionDelimiter),
    CommandOption('f', 'fields', True, OptionFields),
    CommandOption('s', 'only-delimited', False, OptionOnlyDelimited),
    CommandOption('n', '', False, OptionNoSplit),
    CommandOption(#0, 'output-delimiter', True, OptionOutputDelimiter),
    CommandOption(#0, 'complement', False, OptionComplement)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionBytes, OptionCharacters, OptionFields:
        begin
          if Mode <> CutNone then
            FailWithUsageHint('only one type of list may be specified');
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
          if Length(Value) <> 1 then
            Fail(1, 'the delimiter must be a single character');
          Delimiter := Value[1];
        end;
      OptionOnlyDelimited: OnlyDelimited := True;
      OptionOutputDelimiter:
        begin
          OutputDelimiter := Value;
          HasOutputDelimiter := True;
        end;
      OptionComplement: Complement := True;
    end;
  if Mode = CutNone then
    FailWithUsageHint('you must specify a list of bytes, characters, or fields');

  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];
  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    Stream := OpenInput(Operand);
    if Stream = nil then
    begin
      ExitStatus := 1;
      Continue;
    end;
    while ReadTextLine(Stream, Line, HadLineEnd) do
      if Mode = CutFields then
        CutFieldsOfLine(Line)
      else
        CutPositions(Line);
    CloseInput(Stream);
  end;
  Halt(ExitStatus);
end.
