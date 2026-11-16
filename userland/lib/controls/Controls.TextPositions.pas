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
  Positions in text kept as lines: a line and a character in it (UTF-8,
  counted by characters, from 0), and where a piece of text inserted at
  a position ends. Plain logic, shared by the multi-line edit box, its
  undo history and its search, and checked on the host.
}
unit Controls.TextPositions;

{$mode objfpc}
{$H+}

interface

type
  TTextPosition = record
    Line: LongInt;
    Column: LongInt;
  end;

  { Where each character of a line starts (bytes, from 0), and one more
    entry: the line's length. }
  TByteOffsets = array of LongInt;

function MakePosition(Line, Column: LongInt): TTextPosition;
function PositionBefore(const First, Second: TTextPosition): Boolean;
function SamePosition(const First, Second: TTextPosition): Boolean;
{ Where Text ends when inserted at Start: line feeds start new lines. }
function PositionAfterText(const Start: TTextPosition; const Text: string): TTextPosition;
{ The character starting at Text[Index] (from 1): its code point and
  its length in bytes; 0 past the end or at a zero byte (where Font.Utf8
  stops), with CodePoint 0. }
function CharacterAt(const Text: string; Index: LongInt; out CodePoint: LongWord): LongInt;
{ The number of characters in Text. }
function CountCharacters(const Text: string): LongInt;
function ByteOffsetsOf(const Text: string): TByteOffsets;
{ The character of Text that byte ByteIndex (from 0) starts or falls
  in; the character count for the end. }
function ColumnOfByte(const Text: string; ByteIndex: LongInt): LongInt;
{ The byte (from 0) where character Column of Text starts; the length
  for a column at or past the end. }
function ByteOfColumn(const Text: string; Column: LongInt): LongInt;
{ Characters First to First + Count - 1 of Text (as many as there are). }
function CharacterRange(const Text: string; First, Count: LongInt): string;
{ A code point (a typed character) as UTF-8. }
function Utf8Of(CodePoint: LongWord): string;

implementation

uses
  Font.Utf8;

function Utf8Of(CodePoint: LongWord): string;
begin
  if CodePoint < $80 then
    Result := Char(CodePoint)
  else if CodePoint < $800 then
    Result := Char($C0 or (CodePoint shr 6)) + Char($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Result := Char($E0 or (CodePoint shr 12)) + Char($80 or ((CodePoint shr 6) and $3F)) +
      Char($80 or (CodePoint and $3F))
  else
    Result := Char($F0 or (CodePoint shr 18)) + Char($80 or ((CodePoint shr 12) and $3F)) +
      Char($80 or ((CodePoint shr 6) and $3F)) + Char($80 or (CodePoint and $3F));
end;

function MakePosition(Line, Column: LongInt): TTextPosition;
begin
  Result.Line := Line;
  Result.Column := Column;
end;

function PositionBefore(const First, Second: TTextPosition): Boolean;
begin
  Result := (First.Line < Second.Line) or ((First.Line = Second.Line) and (First.Column < Second.Column));
end;

function SamePosition(const First, Second: TTextPosition): Boolean;
begin
  Result := (First.Line = Second.Line) and (First.Column = Second.Column);
end;

function CharacterAt(const Text: string; Index: LongInt; out CodePoint: LongWord): LongInt;
var
  Start: PChar;
  Cursor: PChar;
begin
  CodePoint := 0;
  if (Index < 1) or (Index > Length(Text)) then
    Exit(0);
  Start := PChar(Text) + Index - 1;
  Cursor := Start;
  if not NextCharacter(Cursor, CodePoint) then
    Exit(0);
  Result := Cursor - Start;
end;

{ The length in bytes of the character starting at Text[Index] (from 1).
  Font.Utf8 decides, so the counts agree with what is drawn; a zero byte
  (which Font.Utf8 takes for the end) is a character of its own. }
function CharacterLengthAt(const Text: string; Index: LongInt): LongInt;
var
  CodePoint: LongWord;
begin
  Result := CharacterAt(Text, Index, CodePoint);
  if Result = 0 then
    Result := 1;
end;

function CountCharacters(const Text: string): LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Index := Index + CharacterLengthAt(Text, Index);
    Inc(Result);
  end;
end;

function ByteOffsetsOf(const Text: string): TByteOffsets;
var
  Index: LongInt;
  Count: LongInt;
begin
  Result := nil;
  SetLength(Result, Length(Text) + 1);
  Count := 0;
  Index := 1;
  Result[0] := 0;
  while Index <= Length(Text) do
  begin
    Index := Index + CharacterLengthAt(Text, Index);
    Inc(Count);
    Result[Count] := Index - 1;
  end;
  SetLength(Result, Count + 1);
end;

function ColumnOfByte(const Text: string; ByteIndex: LongInt): LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  Index := 1;
  while (Index <= Length(Text)) and (Index - 1 < ByteIndex) do
  begin
    Index := Index + CharacterLengthAt(Text, Index);
    Inc(Result);
  end;
  { Stepped past ByteIndex: it is inside the character before. }
  if Index - 1 > ByteIndex then
    Dec(Result);
end;

function ByteOfColumn(const Text: string; Column: LongInt): LongInt;
var
  Index: LongInt;
  Counted: LongInt;
begin
  Index := 1;
  Counted := 0;
  while (Index <= Length(Text)) and (Counted < Column) do
  begin
    Index := Index + CharacterLengthAt(Text, Index);
    Inc(Counted);
  end;
  Result := Index - 1;
end;

function CharacterRange(const Text: string; First, Count: LongInt): string;
var
  StartByte: LongInt;
  EndByte: LongInt;
  Index: LongInt;
  Counted: LongInt;
begin
  if First < 0 then
    First := 0;
  if Count <= 0 then
    Exit('');
  StartByte := ByteOfColumn(Text, First);
  Index := StartByte + 1;
  Counted := 0;
  while (Index <= Length(Text)) and (Counted < Count) do
  begin
    Index := Index + CharacterLengthAt(Text, Index);
    Inc(Counted);
  end;
  EndByte := Index - 1;
  Result := Copy(Text, StartByte + 1, EndByte - StartByte);
end;

function PositionAfterText(const Start: TTextPosition; const Text: string): TTextPosition;
var
  Index: LongInt;
  LastBreak: LongInt;
begin
  Result := Start;
  LastBreak := 0;
  for Index := 1 to Length(Text) do
    if Text[Index] = #10 then
    begin
      Inc(Result.Line);
      LastBreak := Index;
    end;
  if LastBreak = 0 then
    Result.Column := Start.Column + CountCharacters(Text)
  else
    Result.Column := CountCharacters(Copy(Text, LastBreak + 1, Length(Text) - LastBreak));
end;

end.
