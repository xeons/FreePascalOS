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
  The named character references of the HTML Standard (all 2231 of them,
  generated from data/named-character-references.txt) and the longest
  match at a position: the sorted names are narrowed one character at a
  time by binary search, so a match costs a few comparisons per
  character, and input that ends while a longer name is still possible
  asks for more.
}
unit Web.Html.NamedReferences;

{$mode objfpc}
{$H+}

interface

type
  TNamedReference = record
    NameOffset: Word;
    NameLength: Byte;
    FirstCodePoint: LongWord;
    SecondCodePoint: Word;
  end;

{$I Web.Html.NamedReferenceTable.inc}

type
  TNamedReferenceMatch = (NamedReferenceNoMatch, NamedReferenceFound, NamedReferenceNeedsMoreInput);

{ The longest name (with its ";" if it has one) that Text starts with.
  Text is what follows the ampersand, Available bytes of it; AtEnd when
  nothing more will come. }
function MatchNamedReference(Text: PChar; Available: SizeInt; AtEnd: Boolean; out ReferenceIndex: Integer;
  out MatchLength: Integer): TNamedReferenceMatch;
function NamedReferenceName(ReferenceIndex: Integer): string;
{ The replacement text of a reference, UTF-8. }
function NamedReferenceText(ReferenceIndex: Integer): string;

implementation

uses
  Web.Encoding.Utf8;

function NameCharacter(Entry, Position: Integer): Char; inline;
begin
  Result := NamedReferenceNameData[NamedReferences[Entry].NameOffset + Position + 1];
end;

function MatchNamedReference(Text: PChar; Available: SizeInt; AtEnd: Boolean; out ReferenceIndex: Integer;
  out MatchLength: Integer): TNamedReferenceMatch;
var
  Low, High, Position, Probe, First, Last: Integer;
  Wanted: Char;
begin
  ReferenceIndex := -1;
  MatchLength := 0;
  Low := 0;
  High := NamedReferenceCount - 1;
  Position := 0;
  while Low <= High do
  begin
    { All names in Low..High start with the Position characters read. }
    if NamedReferences[Low].NameLength = Position then
    begin
      ReferenceIndex := Low;
      MatchLength := Position;
      Inc(Low);
      if Low > High then
        Break;
    end;
    if Position >= Available then
    begin
      if AtEnd then
        Break;
      Exit(NamedReferenceNeedsMoreInput);
    end;
    Wanted := Text[Position];
    { The first name in the range with Wanted here. }
    First := Low;
    Last := High;
    while First < Last do
    begin
      Probe := (First + Last) div 2;
      if NameCharacter(Probe, Position) < Wanted then
        First := Probe + 1
      else
        Last := Probe;
    end;
    if NameCharacter(First, Position) <> Wanted then
      Break;
    Low := First;
    { The last one. }
    Last := High;
    while First < Last do
    begin
      Probe := (First + Last + 1) div 2;
      if NameCharacter(Probe, Position) > Wanted then
        Last := Probe - 1
      else
        First := Probe;
    end;
    High := Last;
    Inc(Position);
  end;
  if ReferenceIndex >= 0 then
    Result := NamedReferenceFound
  else
    Result := NamedReferenceNoMatch;
end;

function NamedReferenceName(ReferenceIndex: Integer): string;
begin
  Result := Copy(NamedReferenceNameData, NamedReferences[ReferenceIndex].NameOffset + 1,
    NamedReferences[ReferenceIndex].NameLength);
end;

function NamedReferenceText(ReferenceIndex: Integer): string;
begin
  Result := EncodeCodePoint(NamedReferences[ReferenceIndex].FirstCodePoint);
  if NamedReferences[ReferenceIndex].SecondCodePoint <> 0 then
    Result := Result + EncodeCodePoint(NamedReferences[ReferenceIndex].SecondCodePoint);
end;

end.
