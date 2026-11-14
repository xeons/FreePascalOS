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
  Unicode helpers for file names.

  The kernel represents text as UTF-8. File systems store names in other
  forms (FAT long names and exFAT use UTF-16), so these routines convert
  between the two and compare names without regard to letter case where a
  file system requires it.

  Case folding here covers ASCII and the Latin-1 supplement. File systems
  with their own case tables (exFAT) use those instead.
}
unit Runtime.Unicode;

{$mode objfpc}
{$pointermath on}

interface

const
  ReplacementCharacter = $FFFD;

type
  { A growing UTF-8 string in a caller supplied buffer. }
  TUtf8Builder = record
    Buffer: PChar;
    Capacity: PtrUInt;
    Length: PtrUInt;
    Overflowed: Boolean;
  end;

procedure BeginUtf8(out Builder: TUtf8Builder; Buffer: PChar; Capacity: PtrUInt);
procedure AppendCodePoint(var Builder: TUtf8Builder; CodePoint: LongWord);
procedure AppendAsciiText(var Builder: TUtf8Builder; Text: PChar);

{ Appends UTF-16 text, combining surrogate pairs. Stops at a zero unit
  or after UnitCount units. }
procedure AppendUtf16(var Builder: TUtf8Builder; Units: PWord; UnitCount: PtrUInt);

{ Decodes one code point from UTF-8 text and advances Position past it.
  Malformed input yields the replacement character. }
function DecodeUtf8(Text: PChar; var Position: PtrUInt): LongWord;

{ Converts UTF-8 to UTF-16. Returns the number of units written, or -1 if
  the destination is too small. No terminator is added. }
function Utf8ToUtf16(Text: PChar; Destination: PWord; Capacity: PtrUInt): PtrInt;

function FoldCase(CodePoint: LongWord): LongWord;

function NamesAreEqualIgnoringCase(First, Second: PChar): Boolean;

implementation

uses
  Runtime.Text;

procedure BeginUtf8(out Builder: TUtf8Builder; Buffer: PChar; Capacity: PtrUInt);
begin
  Builder.Buffer := Buffer;
  Builder.Capacity := Capacity;
  Builder.Length := 0;
  Builder.Overflowed := Capacity = 0;
  if Capacity > 0 then
    Buffer[0] := #0;
end;

procedure AppendByte(var Builder: TUtf8Builder; Value: Byte);
begin
  if Builder.Length + 1 >= Builder.Capacity then
  begin
    Builder.Overflowed := True;
    Exit;
  end;
  Builder.Buffer[Builder.Length] := Char(Value);
  Inc(Builder.Length);
  Builder.Buffer[Builder.Length] := #0;
end;

function EncodedLength(CodePoint: LongWord): PtrUInt;
begin
  if CodePoint < $80 then
    Result := 1
  else if CodePoint < $800 then
    Result := 2
  else if CodePoint < $10000 then
    Result := 3
  else
    Result := 4;
end;

procedure AppendCodePoint(var Builder: TUtf8Builder; CodePoint: LongWord);
begin
  if CodePoint > $10FFFF then
    CodePoint := ReplacementCharacter;

  { Never write half a character. }
  if Builder.Length + EncodedLength(CodePoint) >= Builder.Capacity then
  begin
    Builder.Overflowed := True;
    Exit;
  end;

  if CodePoint < $80 then
    AppendByte(Builder, Byte(CodePoint))
  else if CodePoint < $800 then
  begin
    AppendByte(Builder, $C0 or (CodePoint shr 6));
    AppendByte(Builder, $80 or (CodePoint and $3F));
  end
  else if CodePoint < $10000 then
  begin
    AppendByte(Builder, $E0 or (CodePoint shr 12));
    AppendByte(Builder, $80 or ((CodePoint shr 6) and $3F));
    AppendByte(Builder, $80 or (CodePoint and $3F));
  end
  else
  begin
    AppendByte(Builder, $F0 or (CodePoint shr 18));
    AppendByte(Builder, $80 or ((CodePoint shr 12) and $3F));
    AppendByte(Builder, $80 or ((CodePoint shr 6) and $3F));
    AppendByte(Builder, $80 or (CodePoint and $3F));
  end;
end;

procedure AppendAsciiText(var Builder: TUtf8Builder; Text: PChar);
begin
  while Text^ <> #0 do
  begin
    AppendByte(Builder, Byte(Text^));
    Inc(Text);
  end;
end;

function IsHighSurrogate(UnitValue: Word): Boolean;
begin
  Result := (UnitValue >= $D800) and (UnitValue <= $DBFF);
end;

function IsLowSurrogate(UnitValue: Word): Boolean;
begin
  Result := (UnitValue >= $DC00) and (UnitValue <= $DFFF);
end;

procedure AppendUtf16(var Builder: TUtf8Builder; Units: PWord; UnitCount: PtrUInt);
var
  Index: PtrUInt;
  UnitValue: Word;
  CodePoint: LongWord;
begin
  Index := 0;
  while (Index < UnitCount) and (Units[Index] <> 0) do
  begin
    UnitValue := Units[Index];
    Inc(Index);

    if IsHighSurrogate(UnitValue) and (Index < UnitCount) and IsLowSurrogate(Units[Index]) then
    begin
      CodePoint := $10000 + ((LongWord(UnitValue) - $D800) shl 10) + (LongWord(Units[Index]) - $DC00);
      Inc(Index);
    end
    else if IsHighSurrogate(UnitValue) or IsLowSurrogate(UnitValue) then
      CodePoint := ReplacementCharacter
    else
      CodePoint := UnitValue;

    AppendCodePoint(Builder, CodePoint);
  end;
end;

function DecodeUtf8(Text: PChar; var Position: PtrUInt): LongWord;
var
  LeadByte: Byte;
  ContinuationCount: Integer;
  ContinuationIndex: Integer;
  NextByte: Byte;
begin
  LeadByte := Byte(Text[Position]);
  Inc(Position);

  if LeadByte < $80 then
    Exit(LeadByte);

  if (LeadByte and $E0) = $C0 then
  begin
    Result := LeadByte and $1F;
    ContinuationCount := 1;
  end
  else if (LeadByte and $F0) = $E0 then
  begin
    Result := LeadByte and $0F;
    ContinuationCount := 2;
  end
  else if (LeadByte and $F8) = $F0 then
  begin
    Result := LeadByte and $07;
    ContinuationCount := 3;
  end
  else
    Exit(ReplacementCharacter);

  for ContinuationIndex := 1 to ContinuationCount do
  begin
    NextByte := Byte(Text[Position]);
    if (NextByte and $C0) <> $80 then
      Exit(ReplacementCharacter);
    Result := (Result shl 6) or (NextByte and $3F);
    Inc(Position);
  end;
end;

function Utf8ToUtf16(Text: PChar; Destination: PWord; Capacity: PtrUInt): PtrInt;
var
  Position: PtrUInt;
  Written: PtrUInt;
  CodePoint: LongWord;
begin
  Position := 0;
  Written := 0;
  while Text[Position] <> #0 do
  begin
    CodePoint := DecodeUtf8(Text, Position);
    if CodePoint >= $10000 then
    begin
      if Written + 2 > Capacity then
        Exit(-1);
      CodePoint := CodePoint - $10000;
      Destination[Written] := Word($D800 + (CodePoint shr 10));
      Destination[Written + 1] := Word($DC00 + (CodePoint and $3FF));
      Inc(Written, 2);
    end
    else
    begin
      if Written + 1 > Capacity then
        Exit(-1);
      Destination[Written] := Word(CodePoint);
      Inc(Written);
    end;
  end;
  Result := PtrInt(Written);
end;

function FoldCase(CodePoint: LongWord): LongWord;
begin
  Result := CodePoint;
  if (CodePoint >= Ord('a')) and (CodePoint <= Ord('z')) then
    Result := CodePoint - 32
  else if (CodePoint >= $E0) and (CodePoint <= $FE) and (CodePoint <> $F7) then
    Result := CodePoint - 32;
end;

function NamesAreEqualIgnoringCase(First, Second: PChar): Boolean;
var
  FirstPosition: PtrUInt;
  SecondPosition: PtrUInt;
begin
  FirstPosition := 0;
  SecondPosition := 0;
  while (First[FirstPosition] <> #0) and (Second[SecondPosition] <> #0) do
  begin
    if FoldCase(DecodeUtf8(First, FirstPosition)) <> FoldCase(DecodeUtf8(Second, SecondPosition)) then
      Exit(False);
  end;
  Result := (First[FirstPosition] = #0) and (Second[SecondPosition] = #0);
end;

end.
