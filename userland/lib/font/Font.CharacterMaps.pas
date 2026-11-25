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

  A symbol font's map (Windows 3/0, format 4: its characters at U+F020
  to U+F0FF) is taken when there is no Unicode one, its characters also
  given at U+0020 to U+00FF (as other systems do).

  Variation sequences (format 14, Unicode 0/5): a character followed by
  a variation selector may have a glyph of its own (a non-default
  variant), or be the character's usual glyph (a default one);
  VariationGlyph looks a pair up in place.

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
{ The format 14 subtable (missing if there is none). }
function FindVariationSequences(const Table: TFontTable): TFontTable;
{ The glyph for CodePoint followed by Selector: True with Glyph for a
  variant of its own, True with Glyph 0 when the sequence is the
  character's usual glyph, False when the font does not list it. }
function VariationGlyph(const Sequences: TFontTable; CodePoint, Selector: LongWord; out Glyph: LongWord): Boolean;

implementation

const
  PlatformUnicode = 0;
  PlatformWindows = 3;
  EncodingWindowsBasic = 1;
  EncodingWindowsFull = 10;
  UnicodeEncodingFull = 4;
  UnicodeEncodingFullAll = 6;
  UnicodeEncodingVariations = 5;
  EncodingWindowsSymbol = 0;
  SymbolAreaStart = $F000;
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
      Result := 1
    else if (PlatformId = PlatformWindows) and (EncodingId = EncodingWindowsSymbol) then
      Result := 1;
  end;
end;

{ A symbol font's characters, U+F020 to U+F0FF, also at U+0020 to
  U+00FF (unless the font has those already), kept in order. }
procedure AddSymbolAliases(var List: TMappingList);
var
  Aliases: TMappingList;
  Merged: TMappingList;
  Index: LongInt;
  AliasIndex: LongInt;
begin
  Aliases.Items := nil;
  Aliases.Count := 0;
  Aliases.GlyphCount := List.GlyphCount;
  for Index := 0 to List.Count - 1 do
    if (List.Items[Index].CodePoint >= SymbolAreaStart + $20) and (List.Items[Index].CodePoint <= SymbolAreaStart + $FF) then
      AddMapping(Aliases, List.Items[Index].CodePoint - SymbolAreaStart, List.Items[Index].Glyph);
  if Aliases.Count = 0 then
    Exit;
  Merged.Items := nil;
  Merged.Count := 0;
  Merged.GlyphCount := List.GlyphCount;
  Index := 0;
  AliasIndex := 0;
  while (Index < List.Count) or (AliasIndex < Aliases.Count) do
    if (AliasIndex >= Aliases.Count) or
       ((Index < List.Count) and (List.Items[Index].CodePoint <= Aliases.Items[AliasIndex].CodePoint)) then
    begin
      if (AliasIndex < Aliases.Count) and (List.Items[Index].CodePoint = Aliases.Items[AliasIndex].CodePoint) then
        Inc(AliasIndex);
      AddMapping(Merged, List.Items[Index].CodePoint, List.Items[Index].Glyph);
      Inc(Index);
    end
    else
    begin
      AddMapping(Merged, Aliases.Items[AliasIndex].CodePoint, Aliases.Items[AliasIndex].Glyph);
      Inc(AliasIndex);
    end;
  List := Merged;
end;

function FindVariationSequences(const Table: TFontTable): TFontTable;
var
  SubtableCount: LongWord;
  Index: LongWord;
  Record_: QWord;
  Offset: LongWord;
  Subtable: TFontTable;
begin
  Result := MissingTable;
  if not Has(Table, 0, 4) then
    Exit;
  SubtableCount := ReadUnsigned16(Table, 2);
  if not Has(Table, 4, 8 * QWord(SubtableCount)) then
    Exit;
  for Index := 1 to SubtableCount do
  begin
    Record_ := 4 + 8 * QWord(Index - 1);
    if (ReadUnsigned16(Table, Record_) <> PlatformUnicode) or
       (ReadUnsigned16(Table, Record_ + 2) <> UnicodeEncodingVariations) then
      Continue;
    Offset := ReadUnsigned32(Table, Record_ + 4);
    Subtable := TablePart(Table, Offset);
    if not Has(Subtable, 0, 10) or (ReadUnsigned16(Subtable, 0) <> 14) or
       not Has(Subtable, 0, ReadUnsigned32(Subtable, 2)) then
      Continue;
    Subtable.Length := ReadUnsigned32(Subtable, 2);
    Exit(Subtable);
  end;
end;

function ReadUnsigned24(const Table: TFontTable; Offset: QWord): LongWord;
begin
  Result := (ReadByte(Table, Offset) shl 16) or ReadUnsigned16(Table, Offset + 1);
end;

function VariationGlyph(const Sequences: TFontTable; CodePoint, Selector: LongWord; out Glyph: LongWord): Boolean;
var
  RecordCount: LongWord;
  Index: LongWord;
  Record_: QWord;
  DefaultOffset: LongWord;
  OtherOffset: LongWord;
  Count: LongWord;
  Entry: LongWord;
  Start: LongWord;
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
  Value: LongWord;
begin
  Result := False;
  Glyph := 0;
  if not Has(Sequences, 0, 10) then
    Exit;
  RecordCount := ReadUnsigned32(Sequences, 6);
  if not Has(Sequences, 10, 11 * QWord(RecordCount)) then
    Exit;
  for Index := 1 to RecordCount do
  begin
    Record_ := 10 + 11 * QWord(Index - 1);
    if ReadUnsigned24(Sequences, Record_) <> Selector then
      Continue;
    DefaultOffset := ReadUnsigned32(Sequences, Record_ + 3);
    OtherOffset := ReadUnsigned32(Sequences, Record_ + 7);
    { Variants of their own: pairs of a character and a glyph. }
    if (OtherOffset <> 0) and Has(Sequences, OtherOffset, 4) then
    begin
      Count := ReadUnsigned32(Sequences, OtherOffset);
      if Has(Sequences, OtherOffset + 4, 5 * QWord(Count)) then
      begin
        Low := 0;
        High := LongInt(Count) - 1;
        while Low <= High do
        begin
          Middle := (Low + High) div 2;
          Value := ReadUnsigned24(Sequences, OtherOffset + 4 + 5 * QWord(Middle));
          if Value = CodePoint then
          begin
            Glyph := ReadUnsigned16(Sequences, OtherOffset + 4 + 5 * QWord(Middle) + 3);
            Exit(True);
          end;
          if Value < CodePoint then
            Low := Middle + 1
          else
            High := Middle - 1;
        end;
      end;
    end;
    { Ranges of characters whose usual glyph the sequence is. }
    if (DefaultOffset <> 0) and Has(Sequences, DefaultOffset, 4) then
    begin
      Count := ReadUnsigned32(Sequences, DefaultOffset);
      if Has(Sequences, DefaultOffset + 4, 4 * QWord(Count)) then
        for Entry := 1 to Count do
        begin
          Start := ReadUnsigned24(Sequences, DefaultOffset + 4 + 4 * QWord(Entry - 1));
          if (CodePoint >= Start) and
             (CodePoint <= Start + ReadByte(Sequences, DefaultOffset + 4 + 4 * QWord(Entry - 1) + 3)) then
            Exit(True);
        end;
    end;
    Exit;
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
  BestIsSymbol: Boolean;
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
  BestIsSymbol := False;
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
      BestIsSymbol := (ReadUnsigned16(Table, Record_) = PlatformWindows) and
        (ReadUnsigned16(Table, Record_ + 2) = EncodingWindowsSymbol);
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
  if BestIsSymbol then
    AddSymbolAliases(List);
  { Both formats give characters in increasing order. }
  SetLength(List.Items, List.Count);
  Mappings := List.Items;
end;

end.
