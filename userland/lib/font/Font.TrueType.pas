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
  TrueType fonts (.ttf, and OpenType fonts with TrueType outlines): a
  file of tables, listed at its start (a version, the table count, then
  a tag, checksum, offset and length for each).

  The tables read: "head" (units to the em, the weight bit, which loca
  format), "maxp" (the glyph count), "hhea" (the line: ascender,
  descender, gap; the widest advance; how many advances hmtx holds),
  "hmtx" (each glyph's advance; glyphs past the last share its
  advance), "loca" and "glyf" (outlines, Font.GlyphData), "cmap"
  (characters, Font.CharacterMaps), "OS/2" (the weight class, and the
  line when hhea gives none), "post" (the underline) and "kern" and
  "GPOS" (kerning, Font.Kerning). CFF outlines ("OTTO" fonts) and font
  collections are not read.

  Everything the font is opened with is checked first: every table
  listed inside the file, the required ones there and long enough, the
  numbers in reason, loca in order inside glyf, a Unicode character map.
  A font that fails any of it is refused (LoadTrueTypeFont gives nil).
  Glyph data and kerning are checked as they are read.
}
unit Font.TrueType;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Font.FontData,
  Font.Outlines,
  Font.GlyphData,
  Font.Kerning;

type
  TTrueTypeFont = class(TOutlineFont)
  private
    FData: TBytes;
    FLocations: TGlyphLocations;
    FMetrics: TFontTable;
    FAdvanceCount: LongWord;
    FKerning: TFontKerning;
    function Open: Boolean;
  public
    function AdvanceUnits(Glyph: LongWord): LongInt; override;
    function LoadOutline(Glyph: LongWord; out Outline: TGlyphOutline): Boolean; override;
    function KerningUnits(LeftGlyph, RightGlyph: LongWord): LongInt; override;
    function HasKerning: Boolean; override;
    { Each kerning table on its own (for tests). }
    function KernTableUnits(LeftGlyph, RightGlyph: LongWord): LongInt;
    function PositioningUnits(LeftGlyph, RightGlyph: LongWord): LongInt;
  end;

{ The font in Data; nil if it is not a TrueType font that can be used. }
function LoadTrueTypeFont(const Data: TBytes): TTrueTypeFont;
{ Only the table directory and head, as a file's first bytes would
  give: whether it looks like a TrueType font. }
function LooksLikeTrueType(Data: PByte; Length: PtrUInt): Boolean;

implementation

uses
  Font.CharacterMaps;

const
  VersionTrueType = $00010000;
  VersionApple = $74727565; { "true" }
  HeadMagic = $5F0F3CF5;
  MaximumTables = 256;
  MinimumUnitsPerEm = 16;
  MaximumUnitsPerEm = 16384;
  HeadSize = 54;
  HheaSize = 36;
  MaxpMinimumSize = 6;
  MacStyleBold = $0001;
  BoldWeightClass = 600;

type
  TTableDirectory = record
    Head: TFontTable;
    Hhea: TFontTable;
    Maxp: TFontTable;
    Hmtx: TFontTable;
    Loca: TFontTable;
    Glyf: TFontTable;
    Cmap: TFontTable;
    Os2: TFontTable;
    Post: TFontTable;
    Kern: TFontTable;
    Gpos: TFontTable;
  end;

function IsTrueTypeVersion(Version: LongWord): Boolean;
begin
  Result := (Version = VersionTrueType) or (Version = VersionApple);
end;

function LooksLikeTrueType(Data: PByte; Length: PtrUInt): Boolean;
var
  Version: LongWord;
begin
  Result := False;
  if (Data = nil) or (Length < 12) then
    Exit;
  Version := (LongWord(Data[0]) shl 24) or (LongWord(Data[1]) shl 16) or (LongWord(Data[2]) shl 8) or Data[3];
  Result := IsTrueTypeVersion(Version);
end;

{ Every table listed, each inside the file (or the file is refused). }
function ReadTableDirectory(const Data: TBytes; out Directory: TTableDirectory): Boolean;
var
  Whole: TFontTable;
  TableCount: LongWord;
  Index: LongWord;
  Entry: QWord;
  Tag: string;
  Table: TFontTable;
begin
  Result := False;
  Directory.Head := MissingTable;
  Directory.Hhea := MissingTable;
  Directory.Maxp := MissingTable;
  Directory.Hmtx := MissingTable;
  Directory.Loca := MissingTable;
  Directory.Glyf := MissingTable;
  Directory.Cmap := MissingTable;
  Directory.Os2 := MissingTable;
  Directory.Post := MissingTable;
  Directory.Kern := MissingTable;
  Directory.Gpos := MissingTable;
  Whole := FontTableAt(Data, 0, Length(Data));
  if not Has(Whole, 0, 12) or not IsTrueTypeVersion(ReadUnsigned32(Whole, 0)) then
    Exit;
  TableCount := ReadUnsigned16(Whole, 4);
  if (TableCount = 0) or (TableCount > MaximumTables) or not Has(Whole, 12, 16 * QWord(TableCount)) then
    Exit;
  for Index := 1 to TableCount do
  begin
    Entry := 12 + 16 * QWord(Index - 1);
    Tag := ReadTag(Whole, Entry);
    Table := FontTableAt(Data, ReadUnsigned32(Whole, Entry + 8), ReadUnsigned32(Whole, Entry + 12));
    if not Table.Present then
      Exit;
    { The first of a tag counts. }
    if (Tag = 'head') and not Directory.Head.Present then
      Directory.Head := Table
    else if (Tag = 'hhea') and not Directory.Hhea.Present then
      Directory.Hhea := Table
    else if (Tag = 'maxp') and not Directory.Maxp.Present then
      Directory.Maxp := Table
    else if (Tag = 'hmtx') and not Directory.Hmtx.Present then
      Directory.Hmtx := Table
    else if (Tag = 'loca') and not Directory.Loca.Present then
      Directory.Loca := Table
    else if (Tag = 'glyf') and not Directory.Glyf.Present then
      Directory.Glyf := Table
    else if (Tag = 'cmap') and not Directory.Cmap.Present then
      Directory.Cmap := Table
    else if (Tag = 'OS/2') and not Directory.Os2.Present then
      Directory.Os2 := Table
    else if (Tag = 'post') and not Directory.Post.Present then
      Directory.Post := Table
    else if (Tag = 'kern') and not Directory.Kern.Present then
      Directory.Kern := Table
    else if (Tag = 'GPOS') and not Directory.Gpos.Present then
      Directory.Gpos := Table;
  end;
  Result := Directory.Head.Present and Directory.Hhea.Present and Directory.Maxp.Present and
    Directory.Hmtx.Present and Directory.Loca.Present and Directory.Glyf.Present and Directory.Cmap.Present;
end;

function TTrueTypeFont.Open: Boolean;
var
  Directory: TTableDirectory;
  LocaFormat: LongInt;
  WeightClass: LongWord;
begin
  Result := False;
  if not ReadTableDirectory(FData, Directory) then
    Exit;
  { head }
  if not Has(Directory.Head, 0, HeadSize) or (ReadUnsigned32(Directory.Head, 12) <> HeadMagic) then
    Exit;
  FUnitsPerEm := ReadUnsigned16(Directory.Head, 18);
  LocaFormat := ReadSigned16(Directory.Head, 50);
  if (FUnitsPerEm < MinimumUnitsPerEm) or (FUnitsPerEm > MaximumUnitsPerEm) or (LocaFormat < 0) or
     (LocaFormat > 1) then
    Exit;
  FBold := (ReadUnsigned16(Directory.Head, 44) and MacStyleBold) <> 0;
  { maxp }
  if not Has(Directory.Maxp, 0, MaxpMinimumSize) then
    Exit;
  FGlyphCount := ReadUnsigned16(Directory.Maxp, 4);
  if FGlyphCount = 0 then
    Exit;
  { hhea and hmtx }
  if not Has(Directory.Hhea, 0, HheaSize) then
    Exit;
  FAscender := ReadSigned16(Directory.Hhea, 4);
  FDescender := -ReadSigned16(Directory.Hhea, 6);
  FLineGap := ReadSigned16(Directory.Hhea, 8);
  FMaximumAdvance := ReadUnsigned16(Directory.Hhea, 10);
  FAdvanceCount := ReadUnsigned16(Directory.Hhea, 34);
  if (FAdvanceCount = 0) or (FAdvanceCount > FGlyphCount) or
     not Has(Directory.Hmtx, 0, 4 * QWord(FAdvanceCount) + 2 * QWord(FGlyphCount - FAdvanceCount)) then
    Exit;
  FMetrics := Directory.Hmtx;
  { OS/2: the weight, and the line if hhea has none. }
  if Has(Directory.Os2, 0, 6) then
  begin
    WeightClass := ReadUnsigned16(Directory.Os2, 4);
    if WeightClass >= BoldWeightClass then
      FBold := True;
    if (FAscender = 0) and (FDescender = 0) and Has(Directory.Os2, 0, 74) then
    begin
      FAscender := ReadSigned16(Directory.Os2, 68);
      FDescender := -ReadSigned16(Directory.Os2, 70);
      FLineGap := ReadSigned16(Directory.Os2, 72);
    end;
  end;
  if (FAscender <= 0) or (FDescender < 0) or (FAscender + FDescender > 4 * FUnitsPerEm) or (FLineGap < 0) then
    Exit;
  { post: the underline, its position the centre of the line upwards. }
  FUnderlinePosition := 0;
  FUnderlineThickness := 0;
  if Has(Directory.Post, 0, 12) then
  begin
    FUnderlineThickness := ReadSigned16(Directory.Post, 10);
    FUnderlinePosition := -ReadSigned16(Directory.Post, 8) - FUnderlineThickness div 2;
    if (FUnderlineThickness <= 0) or (FUnderlineThickness > FUnitsPerEm) then
    begin
      FUnderlineThickness := 0;
      FUnderlinePosition := 0;
    end;
  end;
  { loca and glyf }
  FLocations.Glyf := Directory.Glyf;
  FLocations.Loca := Directory.Loca;
  FLocations.LongOffsets := LocaFormat = 1;
  FLocations.GlyphCount := FGlyphCount;
  if not CheckGlyphLocations(FLocations) then
    Exit;
  { cmap }
  if not ReadCharacterMap(Directory.Cmap, FGlyphCount, FMappings) then
    Exit;
  ReadKerningTables(Directory.Kern, Directory.Gpos, FKerning);
  Result := True;
end;

function TTrueTypeFont.AdvanceUnits(Glyph: LongWord): LongInt;
begin
  if Glyph >= FGlyphCount then
    Exit(0);
  if Glyph >= FAdvanceCount then
    Glyph := FAdvanceCount - 1;
  Result := ReadUnsigned16(FMetrics, 4 * QWord(Glyph));
end;

function TTrueTypeFont.LoadOutline(Glyph: LongWord; out Outline: TGlyphOutline): Boolean;
begin
  Result := ReadGlyphOutline(FLocations, Glyph, Outline);
end;

function TTrueTypeFont.KerningUnits(LeftGlyph, RightGlyph: LongWord): LongInt;
begin
  Result := KerningAdjustment(FKerning, LeftGlyph, RightGlyph);
end;

function TTrueTypeFont.HasKerning: Boolean;
begin
  Result := KerningIsKnown(FKerning);
end;

function TTrueTypeFont.KernTableUnits(LeftGlyph, RightGlyph: LongWord): LongInt;
begin
  Result := KernTableAdjustment(FKerning, LeftGlyph, RightGlyph);
end;

function TTrueTypeFont.PositioningUnits(LeftGlyph, RightGlyph: LongWord): LongInt;
begin
  Result := PositioningAdjustment(FKerning, LeftGlyph, RightGlyph);
end;

function LoadTrueTypeFont(const Data: TBytes): TTrueTypeFont;
begin
  Result := TTrueTypeFont.Create;
  Result.FData := Data;
  if not Result.Open then
    FreeAndNil(Result);
end;

end.
