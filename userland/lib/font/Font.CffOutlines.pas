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
  PostScript outlines in OpenType fonts: the "CFF " table (CFF 1, as
  Source Sans, the URW fonts and Noto CJK have) and the "CFF2" table
  (variable fonts such as Cantarell).

  CFF 1: a header, the Name INDEX, the Top DICT INDEX (one font: the
  OpenType table holds one), the String INDEX and the global
  subroutines. The Top DICT points at the CharStrings INDEX (a glyph
  program a glyph, Font.CffCharStrings) and the Private DICT with the
  local subroutines; a CID-keyed font (Noto CJK: it has a ROS) has
  instead an FDArray of font DICTs, each with its own Private DICT and
  subroutines, and an FDSelect saying which a glyph uses (formats 0
  and 3).

  CFF2: a header with the Top DICT's length, the Top DICT, then the
  global subroutines (32-bit counts in every INDEX). The Top DICT
  always has an FDArray (FDSelect formats 0, 3 and 4 when there is more
  than one font DICT) and, for a variable font, the variation store,
  of which only each item variation data's region count is needed:
  blends keep their default values, so the font is drawn as its
  default instance. Font names, charsets and encodings are not needed
  (cmap gives the glyphs; hmtx the advances).
}
unit Font.CffOutlines;

{$mode objfpc}
{$H+}

interface

uses
  Font.FontData,
  Font.CffData,
  Font.CffCharStrings,
  Font.Outlines;

type
  TCffOutlines = record
    Opened: Boolean;
    IsCff2: Boolean;
    Table: TFontTable;
    GlobalSubroutines: TCffIndex;
    CharStrings: TCffIndex;
    { One for each font DICT (one for a font that is not CID-keyed). }
    LocalSubroutines: array of TCffIndex;
    DefaultVariationIndexes: array of LongInt;
    { The FDSelect (missing: every glyph uses font DICT 0). }
    FontSelect: TFontTable;
    FontSelectFormat: LongWord;
    RegionCounts: array of LongInt;
  end;

{ Opens the CFF (IsCff2 False) or CFF2 table of a font of GlyphCount
  glyphs; False if it is broken or not a Type 2 charstring font. }
function OpenCffOutlines(const Table: TFontTable; IsCff2: Boolean; GlyphCount: LongWord;
  out Outlines: TCffOutlines): Boolean;
{ Glyph's outline in font units; False if its program is broken. }
function LoadCffOutline(const Outlines: TCffOutlines; Glyph: LongWord; out Outline: TGlyphOutline): Boolean;

implementation

const
  OperatorCharStrings = 17;
  OperatorPrivate = 18;
  OperatorSubroutines = 19;
  OperatorVariationIndex = 22;
  OperatorVariationStore = 24;
  OperatorCharStringType = EscapedOperator + 6;
  OperatorRegistryOrderingSupplement = EscapedOperator + 30;
  OperatorFontArray = EscapedOperator + 36;
  OperatorFontSelect = EscapedOperator + 37;
  MaximumFontDicts = 256;

{ The local subroutines and default variation data of the Private
  DICT a DICT (the Top DICT or a font DICT) points at; an empty INDEX if
  it has none. }
function ReadPrivate(const Table, Dict: TFontTable; Wide: Boolean; out Subroutines: TCffIndex;
  out VariationIndex: LongInt): Boolean;
var
  Operands: TDictOperands;
  PrivateDict: TFontTable;
  PrivateOffset: QWord;
  PrivateSize: QWord;
begin
  Result := False;
  VariationIndex := 0;
  Subroutines.Present := False;
  Subroutines.Count := 0;
  Subroutines.Table := Table;
  if not FindDictOperands(Dict, OperatorPrivate, Operands) or (Operands.Count < 2) then
  begin
    { No Private DICT: no local subroutines. }
    Subroutines.Present := True;
    Exit(True);
  end;
  if (Operands.Values[0] < 0) or (Operands.Values[1] < 0) then
    Exit;
  PrivateSize := Trunc(Operands.Values[0]);
  PrivateOffset := Trunc(Operands.Values[1]);
  if not Has(Table, PrivateOffset, PrivateSize) then
    Exit;
  PrivateDict := Table;
  PrivateDict.Start := Table.Start + PrivateOffset;
  PrivateDict.Length := PrivateSize;
  if FindDictOperands(PrivateDict, OperatorVariationIndex, Operands) and (Operands.Count >= 1) then
    VariationIndex := Trunc(Operands.Values[0]);
  if FindDictOperands(PrivateDict, OperatorSubroutines, Operands) and (Operands.Count >= 1) and
     (Operands.Values[0] > 0) then
    Result := ReadCffIndex(Table, PrivateOffset + QWord(Trunc(Operands.Values[0])), Wide, Subroutines)
  else
  begin
    Subroutines.Present := True;
    Result := True;
  end;
end;

{ Every font DICT of the FDArray at Offset, with its subroutines. }
function ReadFontArray(var Outlines: TCffOutlines; Offset: QWord): Boolean;
var
  FontArray: TCffIndex;
  Item: LongWord;
begin
  Result := False;
  if not ReadCffIndex(Outlines.Table, Offset, Outlines.IsCff2, FontArray) or (FontArray.Count = 0) or
     (FontArray.Count > MaximumFontDicts) then
    Exit;
  SetLength(Outlines.LocalSubroutines, FontArray.Count);
  SetLength(Outlines.DefaultVariationIndexes, FontArray.Count);
  for Item := 0 to FontArray.Count - 1 do
    if not ReadPrivate(Outlines.Table, CffIndexItem(FontArray, Item), Outlines.IsCff2,
       Outlines.LocalSubroutines[Item], Outlines.DefaultVariationIndexes[Item]) then
      Exit;
  Result := True;
end;

{ The region count of each item variation data in the variation store
  at Offset (a 16-bit length, then the ItemVariationStore). }
function ReadRegionCounts(var Outlines: TCffOutlines; Offset: QWord): Boolean;
var
  Store: TFontTable;
  DataCount: LongWord;
  Item: LongWord;
  DataOffset: QWord;
begin
  Result := False;
  Store := TablePart(Outlines.Table, Offset + 2);
  if not Has(Store, 0, 8) or (ReadUnsigned16(Store, 0) <> 1) then
    Exit;
  DataCount := ReadUnsigned16(Store, 6);
  if not Has(Store, 8, 4 * QWord(DataCount)) then
    Exit;
  SetLength(Outlines.RegionCounts, DataCount);
  for Item := 1 to DataCount do
  begin
    DataOffset := ReadUnsigned32(Store, 8 + 4 * QWord(Item - 1));
    if not Has(Store, DataOffset, 6) then
      Exit;
    Outlines.RegionCounts[Item - 1] := ReadUnsigned16(Store, DataOffset + 4);
  end;
  Result := True;
end;

function OpenCffOutlines(const Table: TFontTable; IsCff2: Boolean; GlyphCount: LongWord;
  out Outlines: TCffOutlines): Boolean;
var
  HeaderSize: LongWord;
  TopDict: TFontTable;
  Names: TCffIndex;
  TopDicts: TCffIndex;
  Strings: TCffIndex;
  GlobalOffset: QWord;
  Operands: TDictOperands;
  Unused: LongInt;
begin
  Result := False;
  Outlines.Opened := False;
  Outlines.IsCff2 := IsCff2;
  Outlines.Table := Table;
  Outlines.LocalSubroutines := nil;
  Outlines.DefaultVariationIndexes := nil;
  Outlines.FontSelect := MissingTable;
  Outlines.FontSelectFormat := 0;
  Outlines.RegionCounts := nil;
  if not Has(Table, 0, 4) then
    Exit;
  HeaderSize := ReadByte(Table, 2);
  if IsCff2 then
  begin
    if (ReadByte(Table, 0) <> 2) or not Has(Table, 0, 5) then
      Exit;
    TopDict := Table;
    TopDict.Start := Table.Start + HeaderSize;
    TopDict.Length := ReadUnsigned16(Table, 3);
    if not Has(Table, HeaderSize, TopDict.Length) then
      Exit;
    GlobalOffset := QWord(HeaderSize) + TopDict.Length;
  end
  else
  begin
    if ReadByte(Table, 0) <> 1 then
      Exit;
    if not ReadCffIndex(Table, HeaderSize, False, Names) or
       not ReadCffIndex(Table, Names.EndOffset, False, TopDicts) or (TopDicts.Count < 1) or
       not ReadCffIndex(Table, TopDicts.EndOffset, False, Strings) then
      Exit;
    TopDict := CffIndexItem(TopDicts, 0);
    GlobalOffset := Strings.EndOffset;
    if FindDictOperands(TopDict, OperatorCharStringType, Operands) and (Operands.Count >= 1) and
       (Operands.Values[0] <> 2) then
      Exit;
  end;
  if not ReadCffIndex(Table, GlobalOffset, IsCff2, Outlines.GlobalSubroutines) then
    Exit;
  { The glyph programs, one a glyph. }
  if not FindDictOperands(TopDict, OperatorCharStrings, Operands) or (Operands.Count < 1) or
     (Operands.Values[0] <= 0) or
     not ReadCffIndex(Table, Trunc(Operands.Values[0]), IsCff2, Outlines.CharStrings) or
     (Outlines.CharStrings.Count < GlyphCount) or (Outlines.CharStrings.Count = 0) then
    Exit;
  if IsCff2 and FindDictOperands(TopDict, OperatorVariationStore, Operands) and (Operands.Count >= 1) and
     (Operands.Values[0] > 0) then
    if not ReadRegionCounts(Outlines, Trunc(Operands.Values[0])) then
      Exit;
  if IsCff2 or FindDictOperands(TopDict, OperatorRegistryOrderingSupplement, Operands) then
  begin
    { CID-keyed (or CFF2): font DICTs and the FDSelect. }
    if not FindDictOperands(TopDict, OperatorFontArray, Operands) or (Operands.Count < 1) or
       (Operands.Values[0] <= 0) or not ReadFontArray(Outlines, Trunc(Operands.Values[0])) then
      Exit;
    if FindDictOperands(TopDict, OperatorFontSelect, Operands) and (Operands.Count >= 1) and
       (Operands.Values[0] > 0) then
    begin
      Outlines.FontSelect := TablePart(Table, Trunc(Operands.Values[0]));
      if not Has(Outlines.FontSelect, 0, 1) then
        Exit;
      Outlines.FontSelectFormat := ReadByte(Outlines.FontSelect, 0);
      if not (Outlines.FontSelectFormat in [0, 3, 4]) then
        Exit;
    end
    else if Length(Outlines.LocalSubroutines) > 1 then
      Exit;
  end
  else
  begin
    SetLength(Outlines.LocalSubroutines, 1);
    SetLength(Outlines.DefaultVariationIndexes, 1);
    if not ReadPrivate(Table, TopDict, False, Outlines.LocalSubroutines[0], Unused) then
      Exit;
    Outlines.DefaultVariationIndexes[0] := 0;
  end;
  Outlines.Opened := True;
  Result := True;
end;

{ The font DICT Glyph uses (0 if the FDSelect does not say or is
  broken). }
function FontDictOf(const Outlines: TCffOutlines; Glyph: LongWord): LongInt;
var
  Select: TFontTable;
  RangeCount: LongWord;
  Low: LongWord;
  High: LongWord;
  Middle: LongWord;
  EntrySize: LongWord;
  FirstGlyph: LongWord;
  NextFirst: LongWord;
  Wide: Boolean;
  SentinelEnd: QWord;
begin
  Result := 0;
  Select := Outlines.FontSelect;
  if not Select.Present then
    Exit;
  case Outlines.FontSelectFormat of
    0:
      if Has(Select, 1 + QWord(Glyph), 1) then
        Result := ReadByte(Select, 1 + QWord(Glyph));
    3, 4:
      begin
        Wide := Outlines.FontSelectFormat = 4;
        if Wide then
        begin
          if not Has(Select, 1, 4) then
            Exit;
          RangeCount := ReadUnsigned32(Select, 1);
          EntrySize := 6;
        end
        else
        begin
          if not Has(Select, 1, 2) then
            Exit;
          RangeCount := ReadUnsigned16(Select, 1);
          EntrySize := 3;
        end;
        { The ranges, then the sentinel (the glyph count). }
        if Wide then
          SentinelEnd := 5 + QWord(RangeCount) * EntrySize + 4
        else
          SentinelEnd := 3 + QWord(RangeCount) * EntrySize + 2;
        if (RangeCount = 0) or not Has(Select, 0, SentinelEnd) then
          Exit;
        { Ranges by their first glyph: the last one starting at or before. }
        Low := 0;
        High := RangeCount;
        while High - Low > 1 do
        begin
          Middle := (Low + High) div 2;
          if Wide then
            FirstGlyph := ReadUnsigned32(Select, 5 + QWord(Middle) * EntrySize)
          else
            FirstGlyph := ReadUnsigned16(Select, 3 + QWord(Middle) * EntrySize);
          if FirstGlyph <= Glyph then
            Low := Middle
          else
            High := Middle;
        end;
        if Wide then
        begin
          FirstGlyph := ReadUnsigned32(Select, 5 + QWord(Low) * EntrySize);
          NextFirst := ReadUnsigned32(Select, 5 + QWord(Low + 1) * EntrySize);
          if (Glyph >= FirstGlyph) and (Glyph < NextFirst) then
            Result := ReadUnsigned16(Select, 5 + QWord(Low) * EntrySize + 4);
        end
        else
        begin
          FirstGlyph := ReadUnsigned16(Select, 3 + QWord(Low) * EntrySize);
          NextFirst := ReadUnsigned16(Select, 3 + QWord(Low + 1) * EntrySize);
          if (Glyph >= FirstGlyph) and (Glyph < NextFirst) then
            Result := ReadByte(Select, 3 + QWord(Low) * EntrySize + 2);
        end;
      end;
  end;
end;

function LoadCffOutline(const Outlines: TCffOutlines; Glyph: LongWord; out Outline: TGlyphOutline): Boolean;
var
  Context: TCharStringContext;
  FontDict: LongInt;
begin
  ClearOutline(Outline);
  Result := False;
  if not Outlines.Opened or (Glyph >= Outlines.CharStrings.Count) then
    Exit;
  FontDict := FontDictOf(Outlines, Glyph);
  if (FontDict < 0) or (FontDict >= Length(Outlines.LocalSubroutines)) then
    Exit;
  Context.GlobalSubroutines := Outlines.GlobalSubroutines;
  Context.LocalSubroutines := Outlines.LocalSubroutines[FontDict];
  Context.IsCff2 := Outlines.IsCff2;
  Context.RegionCounts := Outlines.RegionCounts;
  Context.DefaultVariationIndex := Outlines.DefaultVariationIndexes[FontDict];
  Result := RunCharString(CffIndexItem(Outlines.CharStrings, Glyph), Context, Outline);
end;

end.
