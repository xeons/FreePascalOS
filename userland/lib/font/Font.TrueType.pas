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
  TrueType and OpenType fonts (.ttf, .otf, and collections of them,
  .ttc): a file of tables, listed at its start (a version, the table
  count, then a tag, checksum, offset and length for each). A
  collection ("ttcf") is several such directories, one a face, sharing
  tables; LoadTrueTypeFont takes a face's index (FontFaceCount says how
  many there are).

  The tables read: "head" (units to the em, the weight bit, which loca
  format), "maxp" (the glyph count), "hhea" (the line: ascender,
  descender, gap; the widest advance; how many advances hmtx holds),
  "hmtx" (each glyph's advance; glyphs past the last share its
  advance), the outlines: "loca" and "glyf" (TrueType's quadratic
  ones, Font.GlyphData), or "CFF " or "CFF2" (PostScript's cubic ones,
  Font.CffOutlines; "OTTO" fonts), "CBLC" and "CBDT" (colour bitmaps,
  Font.ColorBitmaps: Noto Color Emoji has nothing else), "cmap"
  (characters and variation sequences, Font.CharacterMaps), "OS/2"
  (the weight class, and the line when hhea gives none), "post" (the
  underline) and "kern" and "GPOS" (kerning, Font.Kerning). A variable
  font is drawn as its default instance: glyf and CFF2 hold it, and the
  variation tables (fvar, gvar, HVAR, ...) are not needed for it.

  Everything the font is opened with is checked first: every table
  listed inside the file, the required ones there and long enough, the
  numbers in reason, loca in order inside glyf (or a CFF table that
  opens), a Unicode character map.
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
  Font.CffOutlines,
  Font.ColorBitmaps,
  Font.Kerning;

type
  TOutlineKind = (QuadraticOutlines, CffOutlines, BitmapsOnly);

  TTrueTypeFont = class(TOutlineFont)
  private
    FData: TBytes;
    FFaceIndex: LongInt;
    FKind: TOutlineKind;
    FLocations: TGlyphLocations;
    FCff: TCffOutlines;
    FColorBitmaps: TColorBitmapTables;
    FVariationSequences: TFontTable;
    FMetrics: TFontTable;
    FAdvanceCount: LongWord;
    FKerning: TFontKerning;
    FWeightClass: LongInt;
    FItalic: Boolean;
    function Open: Boolean;
    function LeftSideBearingUnits(Glyph: LongWord): LongInt;
    function GetHasColorBitmaps: Boolean;
  public
    function AdvanceUnits(Glyph: LongWord): LongInt; override;
    function LoadOutline(Glyph: LongWord; out Outline: TGlyphOutline): Boolean; override;
    function KerningUnits(LeftGlyph, RightGlyph: LongWord): LongInt; override;
    function HasKerning: Boolean; override;
    function HasColorGlyph(Glyph: LongWord): Boolean; override;
    function RenderColorGlyph(Glyph: LongWord; PixelSize: LongInt; out Bitmap: TGlyphBitmap): Boolean; override;
    function GlyphOfVariation(CodePoint, Selector: LongWord): LongWord; override;
    function CanDraw: Boolean; override;
    { What its glyphs are: TrueType or CFF outlines, or only colour
      bitmaps. }
    property Kind: TOutlineKind read FKind;
    property HasColorBitmaps: Boolean read GetHasColorBitmaps;
    { OS/2's weight class (400 regular, 700 bold) and the italic bit. }
    property WeightClass: LongInt read FWeightClass;
    property Italic: Boolean read FItalic;
    property FaceIndex: LongInt read FFaceIndex;
    { Each kerning table on its own (for tests). }
    function KernTableUnits(LeftGlyph, RightGlyph: LongWord): LongInt;
    function PositioningUnits(LeftGlyph, RightGlyph: LongWord): LongInt;
  end;

{ The font in Data (face FaceIndex of a collection); nil if it is not a
  font that can be used. }
function LoadTrueTypeFont(const Data: TBytes; FaceIndex: LongInt = 0): TTrueTypeFont;
{ How many faces the file holds: 1 for a single font, a collection's
  count, 0 if it is neither. }
function FontFaceCount(const Data: TBytes): LongInt;
{ Where face FaceIndex's table directory starts (0 for a single font);
  False if Data has no such face. }
function FaceDirectoryOffset(const Data: TBytes; FaceIndex: LongInt; out Offset: QWord): Boolean;
{ Only the first bytes of a file: whether it looks like a TrueType or
  OpenType font or a collection of them. }
function LooksLikeTrueType(Data: PByte; Length: PtrUInt): Boolean;
{ Whether the version at a directory's start is a single font's
  (TrueType, Apple's, or "OTTO"), and whether it is a collection's. }
function IsTrueTypeVersion(Version: LongWord): Boolean;
function IsCollectionVersion(Version: LongWord): Boolean;

implementation

uses
  Font.CharacterMaps;

const
  VersionTrueType = $00010000;
  VersionApple = $74727565; { "true" }
  VersionOpenType = $4F54544F; { "OTTO" }
  VersionCollection = $74746366; { "ttcf" }
  MaximumCollectionFaces = 256;
  FsSelectionItalic = $0001;
  MacStyleItalic = $0002;
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
    Cff: TFontTable;
    Cff2: TFontTable;
    Cblc: TFontTable;
    Cbdt: TFontTable;
  end;

function IsTrueTypeVersion(Version: LongWord): Boolean;
begin
  Result := (Version = VersionTrueType) or (Version = VersionApple) or (Version = VersionOpenType);
end;

function IsCollectionVersion(Version: LongWord): Boolean;
begin
  Result := Version = VersionCollection;
end;

function FontFaceCount(const Data: TBytes): LongInt;
var
  Whole: TFontTable;
  Version: LongWord;
begin
  Result := 0;
  Whole := FontTableAt(Data, 0, Length(Data));
  if not Has(Whole, 0, 12) then
    Exit;
  Version := ReadUnsigned32(Whole, 0);
  if IsTrueTypeVersion(Version) then
    Exit(1);
  if Version <> VersionCollection then
    Exit;
  if (ReadUnsigned32(Whole, 8) > MaximumCollectionFaces) or not Has(Whole, 12, 4 * QWord(ReadUnsigned32(Whole, 8))) then
    Exit;
  Result := ReadUnsigned32(Whole, 8);
end;

function FaceDirectoryOffset(const Data: TBytes; FaceIndex: LongInt; out Offset: QWord): Boolean;
var
  Whole: TFontTable;
begin
  Offset := 0;
  Result := False;
  if (FaceIndex < 0) or (FaceIndex >= FontFaceCount(Data)) then
    Exit;
  Whole := FontTableAt(Data, 0, Length(Data));
  if ReadUnsigned32(Whole, 0) = VersionCollection then
    Offset := ReadUnsigned32(Whole, 12 + 4 * QWord(FaceIndex));
  Result := True;
end;

function LooksLikeTrueType(Data: PByte; Length: PtrUInt): Boolean;
var
  Version: LongWord;
begin
  Result := False;
  if (Data = nil) or (Length < 12) then
    Exit;
  Version := (LongWord(Data[0]) shl 24) or (LongWord(Data[1]) shl 16) or (LongWord(Data[2]) shl 8) or Data[3];
  Result := IsTrueTypeVersion(Version) or (Version = VersionCollection);
end;

{ Every table listed, each inside the file (or the file is refused). }
function ReadTableDirectory(const Data: TBytes; FaceIndex: LongInt; out Directory: TTableDirectory): Boolean;
var
  Whole: TFontTable;
  Base: QWord;
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
  Directory.Cff := MissingTable;
  Directory.Cff2 := MissingTable;
  Directory.Cblc := MissingTable;
  Directory.Cbdt := MissingTable;
  Whole := FontTableAt(Data, 0, Length(Data));
  if not FaceDirectoryOffset(Data, FaceIndex, Base) or not Has(Whole, Base, 12) or
     not IsTrueTypeVersion(ReadUnsigned32(Whole, Base)) then
    Exit;
  TableCount := ReadUnsigned16(Whole, Base + 4);
  if (TableCount = 0) or (TableCount > MaximumTables) or not Has(Whole, Base + 12, 16 * QWord(TableCount)) then
    Exit;
  for Index := 1 to TableCount do
  begin
    Entry := Base + 12 + 16 * QWord(Index - 1);
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
      Directory.Gpos := Table
    else if (Tag = 'CFF ') and not Directory.Cff.Present then
      Directory.Cff := Table
    else if (Tag = 'CFF2') and not Directory.Cff2.Present then
      Directory.Cff2 := Table
    else if (Tag = 'CBLC') and not Directory.Cblc.Present then
      Directory.Cblc := Table
    else if (Tag = 'CBDT') and not Directory.Cbdt.Present then
      Directory.Cbdt := Table;
  end;
  Result := Directory.Head.Present and Directory.Hhea.Present and Directory.Maxp.Present and
    Directory.Hmtx.Present and Directory.Cmap.Present and
    ((Directory.Loca.Present and Directory.Glyf.Present) or Directory.Cff.Present or Directory.Cff2.Present or
    (Directory.Cblc.Present and Directory.Cbdt.Present));
end;

function TTrueTypeFont.Open: Boolean;
var
  Directory: TTableDirectory;
  LocaFormat: LongInt;
  Os2Weight: LongWord;
begin
  Result := False;
  if not ReadTableDirectory(FData, FFaceIndex, Directory) then
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
  FItalic := (ReadUnsigned16(Directory.Head, 44) and MacStyleItalic) <> 0;
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
  FWeightClass := 400;
  if FBold then
    FWeightClass := 700;
  if Has(Directory.Os2, 0, 6) then
  begin
    Os2Weight := ReadUnsigned16(Directory.Os2, 4);
    if (Os2Weight >= 1) and (Os2Weight <= 1000) then
      FWeightClass := Os2Weight;
    if Os2Weight >= BoldWeightClass then
      FBold := True;
    if Has(Directory.Os2, 62, 2) and ((ReadUnsigned16(Directory.Os2, 62) and FsSelectionItalic) <> 0) then
      FItalic := True;
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
  { The outlines: loca and glyf, else CFF or CFF2, else colour bitmaps
    alone. }
  OpenColorBitmaps(Directory.Cblc, Directory.Cbdt, FColorBitmaps);
  if Directory.Loca.Present and Directory.Glyf.Present then
  begin
    FKind := QuadraticOutlines;
    FLocations.Glyf := Directory.Glyf;
    FLocations.Loca := Directory.Loca;
    FLocations.LongOffsets := LocaFormat = 1;
    FLocations.GlyphCount := FGlyphCount;
    if not CheckGlyphLocations(FLocations) then
      Exit;
  end
  else if Directory.Cff2.Present or Directory.Cff.Present then
  begin
    FKind := CffOutlines;
    if Directory.Cff2.Present then
    begin
      if not OpenCffOutlines(Directory.Cff2, True, FGlyphCount, FCff) then
        Exit;
    end
    else if not OpenCffOutlines(Directory.Cff, False, FGlyphCount, FCff) then
      Exit;
  end
  else
  begin
    FKind := BitmapsOnly;
    if not FColorBitmaps.Present then
      Exit;
  end;
  { cmap }
  if not ReadCharacterMap(Directory.Cmap, FGlyphCount, FMappings) then
    Exit;
  FVariationSequences := FindVariationSequences(Directory.Cmap);
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

{ hmtx's left side bearing: from the long entries, then the array of
  bearings alone for the glyphs past them. }
function TTrueTypeFont.LeftSideBearingUnits(Glyph: LongWord): LongInt;
begin
  if Glyph < FAdvanceCount then
    Result := ReadSigned16(FMetrics, 4 * QWord(Glyph) + 2)
  else
    Result := ReadSigned16(FMetrics, 4 * QWord(FAdvanceCount) + 2 * QWord(Glyph - FAdvanceCount));
end;

{ The outline is placed so that its left edge (the header's xMin) falls
  at hmtx's left side bearing, as FreeType places it; in a well made
  font the two are equal and nothing moves. }
function TTrueTypeFont.LoadOutline(Glyph: LongWord; out Outline: TGlyphOutline): Boolean;
var
  BoxLeft: LongInt;
  Shift: LongInt;
  Index: LongInt;
begin
  case FKind of
    CffOutlines:
      Exit(LoadCffOutline(FCff, Glyph, Outline));
    BitmapsOnly:
      begin
        ClearOutline(Outline);
        Exit(False);
      end;
  end;
  Result := ReadGlyphOutline(FLocations, Glyph, Outline);
  if not Result or not ReadGlyphBoxLeft(FLocations, Glyph, BoxLeft) then
    Exit;
  Shift := LeftSideBearingUnits(Glyph) - BoxLeft;
  if Shift = 0 then
    Exit;
  for Index := 0 to Outline.PointCount - 1 do
    Outline.Points[Index].X := Outline.Points[Index].X + Shift;
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

function TTrueTypeFont.GetHasColorBitmaps: Boolean;
begin
  Result := FColorBitmaps.Present;
end;

function TTrueTypeFont.HasColorGlyph(Glyph: LongWord): Boolean;
begin
  Result := FColorBitmaps.Present and HasColorBitmap(FColorBitmaps, Glyph);
end;

function TTrueTypeFont.RenderColorGlyph(Glyph: LongWord; PixelSize: LongInt; out Bitmap: TGlyphBitmap): Boolean;
begin
  Result := RenderColorBitmap(FColorBitmaps, Glyph, PixelSize, Bitmap);
end;

function TTrueTypeFont.GlyphOfVariation(CodePoint, Selector: LongWord): LongWord;
begin
  if not FVariationSequences.Present or not VariationGlyph(FVariationSequences, CodePoint, Selector, Result) or
     (Result = 0) or (Result >= FGlyphCount) then
    Result := GlyphOf(CodePoint);
end;

function TTrueTypeFont.CanDraw: Boolean;
begin
  Result := (FKind <> BitmapsOnly) or (ColorBitmapDecoder <> nil);
end;

function LoadTrueTypeFont(const Data: TBytes; FaceIndex: LongInt): TTrueTypeFont;
begin
  Result := TTrueTypeFont.Create;
  Result.FData := Data;
  Result.FFaceIndex := FaceIndex;
  if not Result.Open then
    FreeAndNil(Result);
end;

end.
