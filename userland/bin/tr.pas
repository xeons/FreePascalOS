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
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
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

type
  TCharacterList = record
    Items: array[0..1023] of Char;
    Count: Integer;
  end;
  TCharacterSet = array[Char] of Boolean;

procedure AddCharacter(var List: TCharacterList; Character: Char);
begin
  if List.Count < Length(List.Items) then
  begin
    List.Items[List.Count] := Character;
    Inc(List.Count);
  end;
end;

function ClassMatches(ClassName: PChar; Character: Char): Boolean;
begin
  if TextIsEqual(ClassName, 'alpha') then
    Result := IsLetter(Character)
  else if TextIsEqual(ClassName, 'digit') then
    Result := IsDigit(Character)
  else if TextIsEqual(ClassName, 'alnum') then
    Result := IsAlphanumeric(Character)
  else if TextIsEqual(ClassName, 'upper') then
    Result := IsUpperCase(Character)
  else if TextIsEqual(ClassName, 'lower') then
    Result := IsLowerCase(Character)
  else if TextIsEqual(ClassName, 'space') then
    Result := IsSpace(Character)
  else if TextIsEqual(ClassName, 'blank') then
    Result := (Character = ' ') or (Character = #9)
  else if TextIsEqual(ClassName, 'punct') then
    Result := IsPrintable(Character) and not IsAlphanumeric(Character) and (Character <> ' ') and (Byte(Character) < 128)
  else
    Fail(1, 'invalid character class ''%s''', [ArgumentText(ClassName)]);
end;

{ Reads one (possibly escaped) character at Text[Position]. }
function ReadSetCharacter(Text: PChar; var Position: Integer): Char;
var
  Value: Integer;
  DigitCount: Integer;
begin
  if (Text[Position] = '\') and (Text[Position + 1] <> #0) then
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
          while (DigitCount < 3) and (Text[Position] in ['0'..'7']) do
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

procedure ExpandSet(Text: PChar; var List: TCharacterList);
var
  Position: Integer;
  First: Char;
  Last: Char;
  Character: Char;
  ClassName: array[0..15] of Char;
  ClassEnd: PtrInt;
begin
  List.Count := 0;
  Position := 0;
  while Text[Position] <> #0 do
  begin
    if (Text[Position] = '[') and (Text[Position + 1] = ':') then
    begin
      ClassEnd := FindText(Text + Position, ':]');
      if (ClassEnd > 2) and (ClassEnd - 2 < Length(ClassName)) then
      begin
        CopyText(@ClassName[0], Text + Position + 2, PtrUInt(ClassEnd - 2) + 1);
        for Character := #1 to #255 do
          if ClassMatches(@ClassName[0], Character) then
            AddCharacter(List, Character);
        Position := Position + Integer(ClassEnd) + 2;
        Continue;
      end;
    end;
    First := ReadSetCharacter(Text, Position);
    if (Text[Position] = '-') and (Text[Position + 1] <> #0) then
    begin
      Inc(Position);
      Last := ReadSetCharacter(Text, Position);
      if Last < First then
        Fail(1, 'range-endpoints of ''%c-%c'' are in reverse collating sequence order',
          [ArgumentCharacter(First), ArgumentCharacter(Last)]);
      for Character := First to Last do
        AddCharacter(List, Character);
    end
    else
      AddCharacter(List, First);
  end;
end;

procedure MakeSet(const List: TCharacterList; Complement: Boolean; out CharacterSet: TCharacterSet);
var
  Character: Char;
  Index: Integer;
begin
  for Character := #0 to #255 do
    CharacterSet[Character] := Complement;
  for Index := 0 to List.Count - 1 do
    CharacterSet[List.Items[Index]] := not Complement;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Complement: Boolean;
  DeleteMode: Boolean;
  Squeeze: Boolean;
  FirstList: TCharacterList;
  SecondList: TCharacterList;
  FirstSet: TCharacterSet;
  SqueezeSet: TCharacterSet;
  Translation: array[Char] of Char;
  Character: Char;
  Index: Integer;
  Buffer: array[0..4095] of Char;
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

  ExpandSet(Parser.Operands[0], FirstList);
  MakeSet(FirstList, Complement, FirstSet);
  SecondList.Count := 0;
  if Parser.OperandCount >= 2 then
    ExpandSet(Parser.Operands[1], SecondList);

  { The translation table; SET2 is padded with its last character. }
  for Character := #0 to #255 do
    Translation[Character] := Character;
  if not DeleteMode and (SecondList.Count > 0) then
  begin
    if Complement then
    begin
      for Character := #0 to #255 do
        if FirstSet[Character] then
          Translation[Character] := SecondList.Items[SecondList.Count - 1];
    end
    else
      for Index := 0 to FirstList.Count - 1 do
      begin
        if Index < SecondList.Count then
          Translation[FirstList.Items[Index]] := SecondList.Items[Index]
        else
          Translation[FirstList.Items[Index]] := SecondList.Items[SecondList.Count - 1];
      end;
  end;

  { Squeezing applies to the last set given. }
  if DeleteMode or (SecondList.Count = 0) then
    SqueezeSet := FirstSet
  else
    MakeSet(SecondList, False, SqueezeSet);
  if DeleteMode and (SecondList.Count = 0) then
    for Character := #0 to #255 do
      SqueezeSet[Character] := False;
  if DeleteMode and (SecondList.Count > 0) then
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
