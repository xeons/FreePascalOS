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
  tr - translate or delete characters

  tr [-cds] SET1 [SET2]

  Copies standard input to standard output, replacing characters of SET1
  with the corresponding ones of SET2 (-d deletes them, -s squeezes runs
  of repeated characters). Sets may contain ranges (a-z), escapes
  (\n \t \\ \NNN) and the classes [:alpha:] [:digit:] [:alnum:]
  [:upper:] [:lower:] [:space:] [:punct:].
}
program tr;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: tr [OPTION]... SET1 [SET2]'#10 +
    'Translate, squeeze, and/or delete characters from standard input,'#10 +
    'writing to standard output.'#10 +
    #10 +
    '  -c, -C, --complement    use the complement of SET1'#10 +
    '  -d, --delete            delete characters in SET1, do not translate'#10 +
    '  -s, --squeeze-repeats   replace each sequence of a repeated character'#10 +
    '                            that is listed in the last specified SET,'#10 +
    '                            with a single occurrence of that character'#10;

  OptionComplement = 1;
  OptionDelete = 2;
  OptionSqueeze = 3;

  { Longer names after '[:' are taken as plain characters. }
  ClassNameLimit = 16;

type
  TCharacterSet = array[Char] of Boolean;

function ClassMatches(const ClassName: string; Character: Char): Boolean;
begin
  case ClassName of
    'alpha': Result := IsLetter(Character);
    'digit': Result := IsDigit(Character);
    'alnum': Result := IsAlphanumeric(Character);
    'upper': Result := IsUpperCase(Character);
    'lower': Result := IsLowerCase(Character);
    'space': Result := IsSpace(Character);
    'blank': Result := (Character = ' ') or (Character = #9);
    'punct':
      Result := IsPrintable(Character) and not IsAlphanumeric(Character) and (Character <> ' ') and
        (Byte(Character) < 128);
  else
    begin
      Fail(1, 'invalid character class ''%s''', [ArgumentText(PChar(ClassName))]);
      Result := False;
    end;
  end;
end;

{ Reads one (possibly escaped) character at Text[Position]. }
function ReadSetCharacter(const Text: string; var Position: Integer): Char;
var
  Value: Integer;
  DigitCount: Integer;
begin
  if (Text[Position] = '\') and (Position < Length(Text)) then
  begin
    Inc(Position);
    case Text[Position] of
      'n': Result := #10;
      't': Result := #9;
      'r': Result := #13;
      'a': Result := #7;
      'b': Result := #8;
      'f': Result := #12;
      'v': Result := #11;
      '0'..'7':
        begin
          Value := 0;
          DigitCount := 0;
          while (DigitCount < 3) and (Position <= Length(Text)) and (Text[Position] in ['0'..'7']) do
          begin
            Value := Value * 8 + Ord(Text[Position]) - Ord('0');
            Inc(Position);
            Inc(DigitCount);
          end;
          Exit(Char(Value and $FF));
        end;
    else
      Result := Text[Position];
    end;
    Inc(Position);
    Exit;
  end;
  Result := Text[Position];
  Inc(Position);
end;

{ The characters of a set, in order, with ranges and classes expanded. }
function ExpandSet(const Text: string): string;
var
  Position: Integer;
  First: Char;
  Last: Char;
  Character: Char;
  ClassEnd: Integer;
  ClassName: string;
begin
  Result := '';
  Position := 1;
  while Position <= Length(Text) do
  begin
    if (Text[Position] = '[') and (Position < Length(Text)) and (Text[Position + 1] = ':') then
    begin
      ClassEnd := Pos(':]', Text, Position);
      if (ClassEnd > Position + 2) and (ClassEnd - Position - 2 < ClassNameLimit) then
      begin
        ClassName := Copy(Text, Position + 2, ClassEnd - Position - 2);
        for Character := #1 to #255 do
          if ClassMatches(ClassName, Character) then
            Result := Result + Character;
        Position := ClassEnd + 2;
        Continue;
      end;
    end;
    First := ReadSetCharacter(Text, Position);
    if (Position < Length(Text)) and (Text[Position] = '-') then
    begin
      Inc(Position);
      Last := ReadSetCharacter(Text, Position);
      if Last < First then
        Fail(1, 'range-endpoints of ''%c-%c'' are in reverse collating sequence order',
          [ArgumentCharacter(First), ArgumentCharacter(Last)]);
      for Character := First to Last do
        Result := Result + Character;
    end
    else
      Result := Result + First;
  end;
end;

procedure MakeSet(const Characters: string; Complement: Boolean; out CharacterSet: TCharacterSet);
var
  Character: Char;
  Index: Integer;
begin
  for Character := #0 to #255 do
    CharacterSet[Character] := Complement;
  for Index := 1 to Length(Characters) do
    CharacterSet[Characters[Index]] := not Complement;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Complement: Boolean;
  DeleteMode: Boolean;
  Squeeze: Boolean;
  FirstList: string;
  SecondList: string;
  FirstSet: TCharacterSet;
  SqueezeSet: TCharacterSet;
  Translation: array[Char] of Char;
  Character: Char;
  Index: Integer;
  Buffer: array[0..4095] of Char;
  LastSecond: Char;
  Count: Int64;
  Position: Int64;
  LastWritten: Integer;
  Output: Char;
begin
  Complement := False;
  DeleteMode := False;
  Squeeze := False;
  BeginOptions(Parser, [
    OptionDefinition('c', 'complement', False, OptionComplement),
    OptionDefinition('C', nil, False, OptionComplement),
    OptionDefinition('d', 'delete', False, OptionDelete),
    OptionDefinition('s', 'squeeze-repeats', False, OptionSqueeze)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionComplement: Complement := True;
      OptionDelete: DeleteMode := True;
      OptionSqueeze: Squeeze := True;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);
  if (Parser.OperandCount = 1) and not DeleteMode and not Squeeze then
    FailWithUsageHint('missing operand after ''%s''', [ArgumentText(Parser.Operands[0])]);

  FirstList := ExpandSet(Parser.Operands[0]);
  MakeSet(FirstList, Complement, FirstSet);
  SecondList := '';
  if Parser.OperandCount >= 2 then
    SecondList := ExpandSet(Parser.Operands[1]);

  { The translation table; SET2 is padded with its last character. }
  for Character := #0 to #255 do
    Translation[Character] := Character;
  if not DeleteMode and (SecondList <> '') then
  begin
    LastSecond := SecondList[Length(SecondList)];
    if Complement then
    begin
      for Character := #0 to #255 do
        if FirstSet[Character] then
          Translation[Character] := LastSecond;
    end
    else
      for Index := 1 to Length(FirstList) do
      begin
        if Index <= Length(SecondList) then
          Translation[FirstList[Index]] := SecondList[Index]
        else
          Translation[FirstList[Index]] := LastSecond;
      end;
  end;

  { Squeezing applies to the last set given. }
  if DeleteMode or (SecondList = '') then
    SqueezeSet := FirstSet
  else
    MakeSet(SecondList, False, SqueezeSet);
  if DeleteMode and (SecondList = '') then
    for Character := #0 to #255 do
      SqueezeSet[Character] := False;
  if DeleteMode and (SecondList <> '') then
    MakeSet(SecondList, False, SqueezeSet);

  LastWritten := -1;
  repeat
    Count := ReadFile(StandardInputHandle, @Buffer[0], SizeOf(Buffer));
    if Count <= 0 then
      Break;
    Position := 0;
    while Position < Count do
    begin
      Character := Buffer[Position];
      Inc(Position);
      if DeleteMode and FirstSet[Character] then
        Continue;
      Output := Translation[Character];
      if Squeeze and SqueezeSet[Output] and (LastWritten = Ord(Output)) then
        Continue;
      WriteCharacter(StandardOutput, Output);
      LastWritten := Ord(Output);
    end;
  until False;
end.
