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
  Kerning between two glyphs, from a TrueType font's tables.

  The "kern" table (the old way): subtables of format 0, pairs of
  glyphs sorted by left then right glyph with an adjustment each; the
  horizontal ones (not cross-stream, not minimums) are added up.

  "GPOS" (OpenType): the lookups that the "kern" features of one
  language system name (the Latin script's default one, else the
  default script's: the system lays out all text alike, and most of it
  is Latin) and of those their pair adjustment subtables (lookup type 2, or type 9
  extensions of it): format 1 lists second glyphs for each covered first
  glyph, format 2 gives an adjustment for each pair of glyph classes.
  The first glyph's x advance adjustment is the kerning. In each lookup
  the first subtable that has the pair decides it; lookups add up.

  A font with GPOS kerning uses it (as text shaping does) and its kern
  table only otherwise. Nothing is copied: lookups read the tables where
  they are, every offset checked as it is followed, so a broken table
  only gives no kerning.
}
unit Font.Kerning;

{$mode objfpc}
{$H+}

interface

uses
  Font.FontData;

type
  TKernSubtable = record
    Pairs: TFontTable;
    Count: LongWord;
  end;

  TFontKerning = record
    KernSubtables: array of TKernSubtable;
    Positioning: TFontTable;
    { The GPOS lookups of the kern features, by increasing index. }
    PositioningLookups: array of LongWord;
  end;

{ The kerning tables of a font (either may be missing). }
procedure ReadKerningTables(const Kern, Gpos: TFontTable; out Kerning: TFontKerning);
function KerningIsKnown(const Kerning: TFontKerning): Boolean;
{ The adjustment between two glyphs in font units. }
function KerningAdjustment(const Kerning: TFontKerning; Left, Right: LongWord): LongInt;
{ Each table on its own (for tests). }
function KernTableAdjustment(const Kerning: TFontKerning; Left, Right: LongWord): LongInt;
function PositioningAdjustment(const Kerning: TFontKerning; Left, Right: LongWord): LongInt;

implementation

const
  KernPairSize = 6;
  KernCoverageHorizontal = $0001;
  KernCoverageMinimum = $0002;
  KernCoverageCrossStream = $0004;
  PairAdjustmentLookup = 2;
  ExtensionLookup = 9;
  MaximumLookups = 64;

  ValueXPlacement = $0001;
  ValueYPlacement = $0002;
  ValueXAdvance = $0004;

{ --- kern -------------------------------------------------------------- }

procedure ReadKernTable(const Kern: TFontTable; var Kerning: TFontKerning);
var
  SubtableCount: LongWord;
  Index: LongWord;
  Position: QWord;
  Length: LongWord;
  Coverage: LongWord;
  PairCount: LongWord;
  Subtable: TKernSubtable;
begin
  if not Has(Kern, 0, 4) or (ReadUnsigned16(Kern, 0) <> 0) then
    Exit;
  SubtableCount := ReadUnsigned16(Kern, 2);
  Position := 4;
  for Index := 1 to SubtableCount do
  begin
    if not Has(Kern, Position, 14) then
      Exit;
    Length := ReadUnsigned16(Kern, Position + 2);
    Coverage := ReadUnsigned16(Kern, Position + 4);
    { Format 0 (the high byte), horizontal, adjustments. }
    if ((Coverage shr 8) = 0) and ((Coverage and KernCoverageHorizontal) <> 0) and
       ((Coverage and (KernCoverageMinimum or KernCoverageCrossStream)) = 0) then
    begin
      PairCount := ReadUnsigned16(Kern, Position + 6);
      { Fonts with more pairs than 16 bits of length hold wrap the
        length; the pairs are checked against the table instead. }
      if Has(Kern, Position + 14, KernPairSize * QWord(PairCount)) then
      begin
        Subtable.Pairs := TablePart(Kern, Position + 14);
        Subtable.Pairs.Length := KernPairSize * QWord(PairCount);
        Subtable.Count := PairCount;
        SetLength(Kerning.KernSubtables, System.Length(Kerning.KernSubtables) + 1);
        Kerning.KernSubtables[High(Kerning.KernSubtables)] := Subtable;
      end;
      Position := Position + 14 + KernPairSize * QWord(PairCount);
    end
    else
    begin
      if Length < 6 then
        Exit;
      Position := Position + Length;
    end;
  end;
end;

function KernTableAdjustment(const Kerning: TFontKerning; Left, Right: LongWord): LongInt;
var
  Index: LongInt;
  Wanted: LongWord;
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
  Key: LongWord;
  Pairs: TFontTable;
begin
  Result := 0;
  Wanted := (Left shl 16) or Right;
  for Index := 0 to System.Length(Kerning.KernSubtables) - 1 do
  begin
    Pairs := Kerning.KernSubtables[Index].Pairs;
    Low := 0;
    High := LongInt(Kerning.KernSubtables[Index].Count) - 1;
    while Low <= High do
    begin
      Middle := (Low + High) div 2;
      Key := ReadUnsigned32(Pairs, KernPairSize * QWord(Middle));
      if Key = Wanted then
      begin
        Result := Result + ReadSigned16(Pairs, KernPairSize * QWord(Middle) + 4);
        Break;
      end;
      if Key < Wanted then
        Low := Middle + 1
      else
        High := Middle - 1;
    end;
  end;
end;

{ --- GPOS -------------------------------------------------------------- }

procedure AddLookup(var Kerning: TFontKerning; Lookup: LongWord);
var
  Index: LongInt;
  Count: LongInt;
begin
  Count := Length(Kerning.PositioningLookups);
  if Count >= MaximumLookups then
    Exit;
  Index := 0;
  while (Index < Count) and (Kerning.PositioningLookups[Index] < Lookup) do
    Inc(Index);
  if (Index < Count) and (Kerning.PositioningLookups[Index] = Lookup) then
    Exit;
  SetLength(Kerning.PositioningLookups, Count + 1);
  while Count > Index do
  begin
    Kerning.PositioningLookups[Count] := Kerning.PositioningLookups[Count - 1];
    Dec(Count);
  end;
  Kerning.PositioningLookups[Index] := Lookup;
end;

{ The language system whose features apply: the Latin script's default
  one, else the default script's, else the first script's (missing if
  the script list has none). }
function ChosenLanguageSystem(const Gpos: TFontTable): TFontTable;
var
  Scripts: TFontTable;
  ScriptCount: LongWord;
  Index: LongWord;
  Chosen: LongInt;
  Tag: string;
  Script: TFontTable;
  DefaultOffset: LongWord;
begin
  Result := MissingTable;
  Scripts := TablePart(Gpos, ReadUnsigned16(Gpos, 4));
  if not Has(Scripts, 0, 2) then
    Exit;
  ScriptCount := ReadUnsigned16(Scripts, 0);
  if (ScriptCount = 0) or not Has(Scripts, 2, 6 * QWord(ScriptCount)) then
    Exit;
  Chosen := 0;
  for Index := 0 to ScriptCount - 1 do
  begin
    Tag := ReadTag(Scripts, 2 + 6 * QWord(Index));
    if Tag = 'latn' then
    begin
      Chosen := Index;
      Break;
    end;
    if Tag = 'DFLT' then
      Chosen := Index;
  end;
  Script := TablePart(Scripts, ReadUnsigned16(Scripts, 2 + 6 * QWord(Chosen) + 4));
  if not Has(Script, 0, 4) then
    Exit;
  DefaultOffset := ReadUnsigned16(Script, 0);
  if (DefaultOffset = 0) and (ReadUnsigned16(Script, 2) > 0) and Has(Script, 4, 6) then
    DefaultOffset := ReadUnsigned16(Script, 8);
  if DefaultOffset <> 0 then
    Result := TablePart(Script, DefaultOffset);
end;

{ The lookups of feature Index of the feature list, if it is "kern". }
procedure AddKernFeature(const FeatureList: TFontTable; Index: LongWord; var Kerning: TFontKerning);
var
  Feature: TFontTable;
  LookupCount: LongWord;
  Lookup: LongWord;
begin
  if (Index >= ReadUnsigned16(FeatureList, 0)) or (ReadTag(FeatureList, 2 + 6 * QWord(Index)) <> 'kern') then
    Exit;
  Feature := TablePart(FeatureList, ReadUnsigned16(FeatureList, 2 + 6 * QWord(Index) + 4));
  if not Has(Feature, 0, 4) then
    Exit;
  LookupCount := ReadUnsigned16(Feature, 2);
  if not Has(Feature, 4, 2 * QWord(LookupCount)) then
    Exit;
  for Lookup := 1 to LookupCount do
    AddLookup(Kerning, ReadUnsigned16(Feature, 4 + 2 * QWord(Lookup - 1)));
end;

{ The lookups of the kern features of the chosen language system; of
  every kern feature if the font has no script list to choose from. }
procedure ReadPositioningTable(const Gpos: TFontTable; var Kerning: TFontKerning);
const
  NoRequiredFeature = $FFFF;
var
  FeatureList: TFontTable;
  FeatureCount: LongWord;
  Index: LongWord;
  LanguageSystem: TFontTable;
  FeatureIndexCount: LongWord;
  Required: LongWord;
begin
  if not Has(Gpos, 0, 10) or (ReadUnsigned16(Gpos, 0) <> 1) then
    Exit;
  FeatureList := TablePart(Gpos, ReadUnsigned16(Gpos, 6));
  if not Has(FeatureList, 0, 2) then
    Exit;
  FeatureCount := ReadUnsigned16(FeatureList, 0);
  if not Has(FeatureList, 2, 6 * QWord(FeatureCount)) then
    Exit;
  LanguageSystem := ChosenLanguageSystem(Gpos);
  if Has(LanguageSystem, 0, 6) then
  begin
    Required := ReadUnsigned16(LanguageSystem, 2);
    if Required <> NoRequiredFeature then
      AddKernFeature(FeatureList, Required, Kerning);
    FeatureIndexCount := ReadUnsigned16(LanguageSystem, 4);
    if Has(LanguageSystem, 6, 2 * QWord(FeatureIndexCount)) then
      for Index := 1 to FeatureIndexCount do
        AddKernFeature(FeatureList, ReadUnsigned16(LanguageSystem, 6 + 2 * QWord(Index - 1)), Kerning);
  end
  else
    for Index := 1 to FeatureCount do
      AddKernFeature(FeatureList, Index - 1, Kerning);
  if Length(Kerning.PositioningLookups) > 0 then
    Kerning.Positioning := Gpos;
end;

{ The coverage index of Glyph in a coverage table; -1 if not covered. }
function CoverageIndex(const Coverage: TFontTable; Glyph: LongWord): LongInt;
var
  Count: LongWord;
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
  Value: LongWord;
  First: LongWord;
  Last: LongWord;
begin
  Result := -1;
  if not Has(Coverage, 0, 4) then
    Exit;
  Count := ReadUnsigned16(Coverage, 2);
  Low := 0;
  High := LongInt(Count) - 1;
  case ReadUnsigned16(Coverage, 0) of
    1:
      begin
        if not Has(Coverage, 4, 2 * QWord(Count)) then
          Exit;
        while Low <= High do
        begin
          Middle := (Low + High) div 2;
          Value := ReadUnsigned16(Coverage, 4 + 2 * QWord(Middle));
          if Value = Glyph then
            Exit(Middle);
          if Value < Glyph then
            Low := Middle + 1
          else
            High := Middle - 1;
        end;
      end;
    2:
      begin
        if not Has(Coverage, 4, 6 * QWord(Count)) then
          Exit;
        while Low <= High do
        begin
          Middle := (Low + High) div 2;
          First := ReadUnsigned16(Coverage, 4 + 6 * QWord(Middle));
          Last := ReadUnsigned16(Coverage, 4 + 6 * QWord(Middle) + 2);
          if Glyph < First then
            High := Middle - 1
          else if Glyph > Last then
            Low := Middle + 1
          else
            Exit(LongInt(ReadUnsigned16(Coverage, 4 + 6 * QWord(Middle) + 4) + (Glyph - First)));
        end;
      end;
  end;
end;

{ The class of Glyph in a class definition table (0 if it has none). }
function GlyphClass(const ClassDefinition: TFontTable; Glyph: LongWord): LongWord;
var
  First: LongWord;
  Count: LongWord;
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
  RangeFirst: LongWord;
  RangeLast: LongWord;
begin
  Result := 0;
  if not Has(ClassDefinition, 0, 4) then
    Exit;
  case ReadUnsigned16(ClassDefinition, 0) of
    1:
      begin
        if not Has(ClassDefinition, 0, 6) then
          Exit;
        First := ReadUnsigned16(ClassDefinition, 2);
        Count := ReadUnsigned16(ClassDefinition, 4);
        if (Glyph >= First) and (Glyph - First < Count) and Has(ClassDefinition, 6, 2 * QWord(Count)) then
          Result := ReadUnsigned16(ClassDefinition, 6 + 2 * QWord(Glyph - First));
      end;
    2:
      begin
        Count := ReadUnsigned16(ClassDefinition, 2);
        if not Has(ClassDefinition, 4, 6 * QWord(Count)) then
          Exit;
        Low := 0;
        High := LongInt(Count) - 1;
        while Low <= High do
        begin
          Middle := (Low + High) div 2;
          RangeFirst := ReadUnsigned16(ClassDefinition, 4 + 6 * QWord(Middle));
          RangeLast := ReadUnsigned16(ClassDefinition, 4 + 6 * QWord(Middle) + 2);
          if Glyph < RangeFirst then
            High := Middle - 1
          else if Glyph > RangeLast then
            Low := Middle + 1
          else
            Exit(ReadUnsigned16(ClassDefinition, 4 + 6 * QWord(Middle) + 4));
        end;
      end;
  end;
end;

{ The size of a value record of a format: two bytes a field. }
function ValueRecordSize(Format: LongWord): LongWord;
begin
  Result := 0;
  while Format <> 0 do
  begin
    if (Format and 1) <> 0 then
      Result := Result + 2;
    Format := Format shr 1;
  end;
end;

{ The x advance in the value record at Offset (0 if it has none). }
function ValueXAdvanceOf(const Table: TFontTable; Offset: QWord; Format: LongWord): LongInt;
var
  Position: QWord;
begin
  Result := 0;
  if (Format and ValueXAdvance) = 0 then
    Exit;
  Position := Offset;
  if (Format and ValueXPlacement) <> 0 then
    Position := Position + 2;
  if (Format and ValueYPlacement) <> 0 then
    Position := Position + 2;
  if Has(Table, Position, 2) then
    Result := ReadSigned16(Table, Position);
end;

{ A pair adjustment subtable: True and the adjustment if it has the pair. }
function PairSubtableAdjustment(const Subtable: TFontTable; Left, Right: LongWord; out Adjustment: LongInt): Boolean;
var
  Format: LongWord;
  CoverageAt: LongInt;
  FirstFormat: LongWord;
  SecondFormat: LongWord;
  RecordSize: QWord;
  PairSetCount: LongWord;
  PairSet: TFontTable;
  PairCount: LongWord;
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
  Second: LongWord;
  FirstClass: LongWord;
  SecondClass: LongWord;
  FirstClassCount: LongWord;
  SecondClassCount: LongWord;
  Position: QWord;
begin
  Result := False;
  Adjustment := 0;
  if not Has(Subtable, 0, 8) then
    Exit;
  Format := ReadUnsigned16(Subtable, 0);
  CoverageAt := CoverageIndex(TablePart(Subtable, ReadUnsigned16(Subtable, 2)), Left);
  if CoverageAt < 0 then
    Exit;
  FirstFormat := ReadUnsigned16(Subtable, 4);
  SecondFormat := ReadUnsigned16(Subtable, 6);
  if Format = 1 then
  begin
    if not Has(Subtable, 8, 2) then
      Exit;
    PairSetCount := ReadUnsigned16(Subtable, 8);
    if (LongWord(CoverageAt) >= PairSetCount) or not Has(Subtable, 10 + 2 * QWord(CoverageAt), 2) then
      Exit;
    PairSet := TablePart(Subtable, ReadUnsigned16(Subtable, 10 + 2 * QWord(CoverageAt)));
    if not Has(PairSet, 0, 2) then
      Exit;
    PairCount := ReadUnsigned16(PairSet, 0);
    RecordSize := 2 + ValueRecordSize(FirstFormat) + ValueRecordSize(SecondFormat);
    if not Has(PairSet, 2, RecordSize * PairCount) then
      Exit;
    Low := 0;
    High := LongInt(PairCount) - 1;
    while Low <= High do
    begin
      Middle := (Low + High) div 2;
      Second := ReadUnsigned16(PairSet, 2 + RecordSize * QWord(Middle));
      if Second = Right then
      begin
        Adjustment := ValueXAdvanceOf(PairSet, 2 + RecordSize * QWord(Middle) + 2, FirstFormat);
        Exit(True);
      end;
      if Second < Right then
        Low := Middle + 1
      else
        High := Middle - 1;
    end;
  end
  else if Format = 2 then
  begin
    if not Has(Subtable, 8, 8) then
      Exit;
    FirstClass := GlyphClass(TablePart(Subtable, ReadUnsigned16(Subtable, 8)), Left);
    SecondClass := GlyphClass(TablePart(Subtable, ReadUnsigned16(Subtable, 10)), Right);
    FirstClassCount := ReadUnsigned16(Subtable, 12);
    SecondClassCount := ReadUnsigned16(Subtable, 14);
    if (FirstClass >= FirstClassCount) or (SecondClass >= SecondClassCount) then
      Exit;
    RecordSize := ValueRecordSize(FirstFormat) + ValueRecordSize(SecondFormat);
    Position := 16 + (QWord(FirstClass) * SecondClassCount + SecondClass) * RecordSize;
    Adjustment := ValueXAdvanceOf(Subtable, Position, FirstFormat);
    Result := True;
  end;
end;

{ One lookup: its first subtable that has the pair decides. }
function LookupAdjustment(const Lookups: TFontTable; Index, Left, Right: LongWord; out Adjustment: LongInt): Boolean;
var
  Lookup: TFontTable;
  LookupType: LongWord;
  SubtableCount: LongWord;
  Subtable: LongWord;
  Data: TFontTable;
begin
  Result := False;
  Adjustment := 0;
  if not Has(Lookups, 2 + 2 * QWord(Index), 2) then
    Exit;
  Lookup := TablePart(Lookups, ReadUnsigned16(Lookups, 2 + 2 * QWord(Index)));
  if not Has(Lookup, 0, 6) then
    Exit;
  LookupType := ReadUnsigned16(Lookup, 0);
  SubtableCount := ReadUnsigned16(Lookup, 4);
  if not Has(Lookup, 6, 2 * QWord(SubtableCount)) then
    Exit;
  for Subtable := 1 to SubtableCount do
  begin
    Data := TablePart(Lookup, ReadUnsigned16(Lookup, 6 + 2 * QWord(Subtable - 1)));
    if LookupType = ExtensionLookup then
    begin
      if not Has(Data, 0, 8) or (ReadUnsigned16(Data, 0) <> 1) or
         (ReadUnsigned16(Data, 2) <> PairAdjustmentLookup) then
        Continue;
      Data := TablePart(Data, ReadUnsigned32(Data, 4));
    end
    else if LookupType <> PairAdjustmentLookup then
      Exit;
    if PairSubtableAdjustment(Data, Left, Right, Adjustment) then
      Exit(True);
  end;
end;

function PositioningAdjustment(const Kerning: TFontKerning; Left, Right: LongWord): LongInt;
var
  Lookups: TFontTable;
  Index: LongInt;
  Adjustment: LongInt;
begin
  Result := 0;
  if not Kerning.Positioning.Present then
    Exit;
  Lookups := TablePart(Kerning.Positioning, ReadUnsigned16(Kerning.Positioning, 8));
  if not Has(Lookups, 0, 2) then
    Exit;
  for Index := 0 to Length(Kerning.PositioningLookups) - 1 do
    if (Kerning.PositioningLookups[Index] < ReadUnsigned16(Lookups, 0)) and
       LookupAdjustment(Lookups, Kerning.PositioningLookups[Index], Left, Right, Adjustment) then
      Result := Result + Adjustment;
end;

{ --- Both -------------------------------------------------------------- }

procedure ReadKerningTables(const Kern, Gpos: TFontTable; out Kerning: TFontKerning);
begin
  Kerning.KernSubtables := nil;
  Kerning.Positioning := MissingTable;
  Kerning.PositioningLookups := nil;
  ReadKernTable(Kern, Kerning);
  ReadPositioningTable(Gpos, Kerning);
end;

function KerningIsKnown(const Kerning: TFontKerning): Boolean;
begin
  Result := Kerning.Positioning.Present or (Length(Kerning.KernSubtables) > 0);
end;

function KerningAdjustment(const Kerning: TFontKerning; Left, Right: LongWord): LongInt;
begin
  if Kerning.Positioning.Present then
    Result := PositioningAdjustment(Kerning, Left, Right)
  else
    Result := KernTableAdjustment(Kerning, Left, Right);
end;

end.
