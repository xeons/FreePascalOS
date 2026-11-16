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
  A TrueType font's character map ("cmap"): which glyph each character
  has.

  The table holds subtables for platforms and encodings; the Unicode
  ones are used: the full repertoire (Windows 3/10 or Unicode 0/4 and
  0/6, format 12: groups of consecutive characters with consecutive
  glyphs) when there is one, else the Basic Multilingual Plane
  (Windows 3/1, Unicode 0/0 to 0/3, format 4: segments of characters,
  each with a delta added to the character or an array of glyphs).

  The map is read whole, into mappings by increasing code point; a
  character mapped to glyph 0 or to a glyph past the font's is left
  out. A subtable reaching past its table, segments that are not in
  order, or more characters than Unicode has refuse the whole map.
}
unit Font.CharacterMaps;

{$mode objfpc}
{$H+}

interface

uses
  Font.FontData,
  Font.Outlines;

{ The Unicode mappings of the cmap table; False if it has none that can
  be read. }
function ReadCharacterMap(const Table: TFontTable; GlyphCount: LongWord; out Mappings: TCharacterMappings): Boolean;

implementation

const
  PlatformUnicode = 0;
  PlatformWindows = 3;
  EncodingWindowsBasic = 1;
  EncodingWindowsFull = 10;
  UnicodeEncodingFull = 4;
  UnicodeEncodingFullAll = 6;
  LastUnicodeCodePoint = $10FFFF;
  { At most one mapping a code point. }
  MaximumMappings = LastUnicodeCodePoint + 1;

type
  TMappingList = record
    Items: TCharacterMappings;
    Count: LongInt;
    GlyphCount: LongWord;
  end;

procedure AddMapping(var List: TMappingList; CodePoint, Glyph: LongWord);
begin
  if (Glyph = 0) or (Glyph >= List.GlyphCount) then
    Exit;
  if List.Count = Length(List.Items) then
    SetLength(List.Items, 2 * List.Count + 256);
  List.Items[List.Count].CodePoint := CodePoint;
  List.Items[List.Count].Glyph := Glyph;
  Inc(List.Count);
end;

{ Format 4: segments of 16-bit characters. }
function ReadFormat4(const Subtable: TFontTable; var List: TMappingList): Boolean;
var
  Length: LongWord;
  SegmentCount: LongWord;
  Segment: LongWord;
  EndCodes: QWord;
  StartCodes: QWord;
  Deltas: QWord;
  RangeOffsets: QWord;
  FirstCode: LongWord;
  LastCode: LongWord;
  PreviousLast: LongInt;
  Delta: LongWord;
  RangeOffset: LongWord;
  Code: LongWord;
  Glyph: LongWord;
  GlyphPosition: QWord;
  Table: TFontTable;
begin
  Result := False;
  if not Has(Subtable, 0, 14) then
    Exit;
  Length := ReadUnsigned16(Subtable, 2);
  if not Has(Subtable, 0, Length) then
    Exit;
  { Only this subtable's bytes from here on (some fonts round the
    length down; the arrays are checked against it). }
  Table := Subtable;
  Table.Length := Length;
  SegmentCount := ReadUnsigned16(Table, 6) div 2;
  EndCodes := 14;
  StartCodes := EndCodes + 2 * QWord(SegmentCount) + 2;
  Deltas := StartCodes + 2 * QWord(SegmentCount);
  RangeOffsets := Deltas + 2 * QWord(SegmentCount);
  if (SegmentCount = 0) or not Has(Table, 0, RangeOffsets + 2 * QWord(SegmentCount)) then
    Exit;
  PreviousLast := -1;
  for Segment := 0 to SegmentCount - 1 do
  begin
    LastCode := ReadUnsigned16(Table, EndCodes + 2 * Segment);
    FirstCode := ReadUnsigned16(Table, StartCodes + 2 * Segment);
    Delta := ReadUnsigned16(Table, Deltas + 2 * Segment);
    RangeOffset := ReadUnsigned16(Table, RangeOffsets + 2 * Segment);
    if (FirstCode > LastCode) or (LongInt(FirstCode) <= PreviousLast) then
      Exit;
    PreviousLast := LastCode;
    for Code := FirstCode to LastCode do
    begin
      { The last segment ends with U+FFFF, which is no character. }
      if Code = $FFFF then
        Break;
      if RangeOffset = 0 then
        Glyph := (Code + Delta) and $FFFF
      else
      begin
        GlyphPosition := RangeOffsets + 2 * QWord(Segment) + RangeOffset + 2 * QWord(Code - FirstCode);
        if not Has(Table, GlyphPosition, 2) then
          Exit;
        Glyph := ReadUnsigned16(Table, GlyphPosition);
        if Glyph <> 0 then
          Glyph := (Glyph + Delta) and $FFFF;
      end;
      AddMapping(List, Code, Glyph);
    end;
  end;
  Result := True;
end;

{ Format 12: groups of 32-bit characters, glyphs counting up. }
function ReadFormat12(const Subtable: TFontTable; var List: TMappingList): Boolean;
var
  Length: QWord;
  GroupCount: LongWord;
  Group: LongWord;
  Entry: QWord;
  FirstCode: LongWord;
  LastCode: LongWord;
  StartGlyph: LongWord;
  PreviousLast: Int64;
  Total: QWord;
  Code: LongWord;
  Table: TFontTable;
begin
  Result := False;
  if not Has(Subtable, 0, 16) then
    Exit;
  Length := ReadUnsigned32(Subtable, 4);
  if not Has(Subtable, 0, Length) then
    Exit;
  Table := Subtable;
  Table.Length := Length;
  GroupCount := ReadUnsigned32(Table, 12);
  if not Has(Table, 16, 12 * QWord(GroupCount)) then
    Exit;
  PreviousLast := -1;
  Total := 0;
  for Group := 1 to GroupCount do
  begin
    Entry := 16 + 12 * QWord(Group - 1);
    FirstCode := ReadUnsigned32(Table, Entry);
    LastCode := ReadUnsigned32(Table, Entry + 4);
    StartGlyph := ReadUnsigned32(Table, Entry + 8);
    if (FirstCode > LastCode) or (LastCode > LastUnicodeCodePoint) or (Int64(FirstCode) <= PreviousLast) then
      Exit;
    PreviousLast := LastCode;
    Total := Total + (LastCode - FirstCode) + 1;
    if Total > MaximumMappings then
      Exit;
    for Code := FirstCode to LastCode do
      if QWord(StartGlyph) + (Code - FirstCode) < List.GlyphCount then
        AddMapping(List, Code, StartGlyph + (Code - FirstCode));
  end;
  Result := True;
end;

{ How good a subtable is: 0 not usable, higher better. }
function SubtableRank(PlatformId, EncodingId, Format: LongWord): LongInt;
begin
  Result := 0;
  if Format = 12 then
  begin
    if ((PlatformId = PlatformWindows) and (EncodingId = EncodingWindowsFull)) or
       ((PlatformId = PlatformUnicode) and ((EncodingId = UnicodeEncodingFull) or
       (EncodingId = UnicodeEncodingFullAll))) then
      Result := 3;
  end
  else if Format = 4 then
  begin
    if (PlatformId = PlatformWindows) and (EncodingId = EncodingWindowsBasic) then
      Result := 2
    else if (PlatformId = PlatformUnicode) and (EncodingId <= 3) then
      Result := 1;
  end;
end;

function ReadCharacterMap(const Table: TFontTable; GlyphCount: LongWord; out Mappings: TCharacterMappings): Boolean;
var
  SubtableCount: LongWord;
  Index: LongWord;
  Record_: QWord;
  Offset: LongWord;
  Format: LongWord;
  Rank: LongInt;
  BestRank: LongInt;
  BestOffset: LongWord;
  BestFormat: LongWord;
  List: TMappingList;
begin
  Result := False;
  Mappings := nil;
  if not Has(Table, 0, 4) then
    Exit;
  SubtableCount := ReadUnsigned16(Table, 2);
  if not Has(Table, 4, 8 * QWord(SubtableCount)) then
    Exit;
  BestRank := 0;
  BestOffset := 0;
  BestFormat := 0;
  for Index := 1 to SubtableCount do
  begin
    Record_ := 4 + 8 * QWord(Index - 1);
    Offset := ReadUnsigned32(Table, Record_ + 4);
    if not Has(Table, Offset, 2) then
      Continue;
    Format := ReadUnsigned16(Table, Offset);
    Rank := SubtableRank(ReadUnsigned16(Table, Record_), ReadUnsigned16(Table, Record_ + 2), Format);
    if Rank > BestRank then
    begin
      BestRank := Rank;
      BestOffset := Offset;
      BestFormat := Format;
    end;
  end;
  if BestRank = 0 then
    Exit;
  List.Items := nil;
  List.Count := 0;
  List.GlyphCount := GlyphCount;
  if BestFormat = 12 then
    Result := ReadFormat12(TablePart(Table, BestOffset), List)
  else
    Result := ReadFormat4(TablePart(Table, BestOffset), List);
  if not Result then
    Exit;
  { Both formats give characters in increasing order. }
  SetLength(List.Items, List.Count);
  Mappings := List.Items;
end;

end.
