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
  Coverage fonts (.cvf): anti-aliased bitmap fonts, one pixel size
  each, with glyphs of their own widths and kerning pairs, rendered
  beforehand (by any tool) so that only their coverage is blended here.
  The system's own proportional fonts are TrueType now (Font.TrueType,
  rendered at any size); coverage fonts remain readable in a family.

  All numbers are little-endian. A 40 byte header: magic "CVF1", the
  header size, flags (bit 0 bold), the pixel size (the em), the line
  height, the ascent, the underline's top and thickness, the glyph and
  kerning pair counts, and the offsets of the glyph table, the kerning
  table and the coverage data, and that data's size. Glyph entries (20
  bytes, by code point, strictly increasing): code point, bitmap
  offset, advance, left bearing, top, width, height. Kerning entries
  (12 bytes, by left then right code point, strictly increasing): the
  two code points and the adjustment. Bitmaps are a byte a pixel.

  The file is checked through and through before any of it is used:
  every table and bitmap inside the file, sizes within reason, tables
  in order. A file that is not right gives no face at all.
}
unit Font.Coverage;

{$mode objfpc}
{$pointermath on}

interface

uses
  Font.Faces;

{ Reads a coverage font from Data (Length bytes). }
function ParseCoverageFont(Data: PByte; Length: PtrUInt; out Face: TFontFace): Boolean;
{ Only the header: the face's pixel size and weight. Length may be just
  the start of the file (the 40 byte header). }
function ReadCoverageFontSummary(Data: PByte; Length: PtrUInt; out Size: LongInt; out Bold: Boolean): Boolean;

implementation

const
  CoverageMagic = $31465643; { "CVF1" }
  CoverageHeaderSize = 40;
  GlyphEntrySize = 20;
  KerningEntrySize = 12;
  FlagBold = $0001;
  { Limits no real font comes near; past them a file is broken. }
  MaximumPixelSize = 1024;
  MaximumGlyphDimension = 4096;
  MaximumGlyphs = 65536;
  MaximumKerningPairs = 1000000;

type
  TCoverageHeader = record
    HeaderSize: LongWord;
    Flags: LongWord;
    PixelSize: LongInt;
    LineHeight: LongInt;
    Ascent: LongInt;
    UnderlineTop: LongInt;
    UnderlineThickness: LongInt;
    GlyphCount: LongWord;
    KerningCount: LongWord;
    GlyphTableOffset: LongWord;
    KerningTableOffset: LongWord;
    CoverageOffset: LongWord;
    CoverageSize: LongWord;
  end;

function ReadWord(Data: PByte): LongWord;
begin
  Result := Data[0] or (LongWord(Data[1]) shl 8);
end;

function ReadSignedWord(Data: PByte): LongInt;
begin
  Result := SmallInt(Word(ReadWord(Data)));
end;

function ReadLongWord(Data: PByte): LongWord;
begin
  Result := Data[0] or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or (LongWord(Data[3]) shl 24);
end;

{ Whether Count entries of EntrySize bytes from Offset lie in the file. }
function TableFits(Offset, Count, EntrySize: QWord; Length: PtrUInt): Boolean;
begin
  Result := (Offset <= Length) and (Count * EntrySize <= Length - Offset);
end;

function ReadHeader(Data: PByte; Length: PtrUInt; out Header: TCoverageHeader): Boolean;
begin
  Result := False;
  FillChar(Header, SizeOf(Header), 0);
  if (Data = nil) or (Length < CoverageHeaderSize) or (ReadLongWord(Data) <> CoverageMagic) then
    Exit;
  Header.HeaderSize := ReadWord(Data + 4);
  Header.Flags := ReadWord(Data + 6);
  Header.PixelSize := ReadWord(Data + 8);
  Header.LineHeight := ReadWord(Data + 10);
  Header.Ascent := ReadSignedWord(Data + 12);
  Header.UnderlineTop := ReadSignedWord(Data + 14);
  Header.UnderlineThickness := ReadWord(Data + 16);
  Header.GlyphCount := ReadWord(Data + 18);
  Header.KerningCount := ReadLongWord(Data + 20);
  Header.GlyphTableOffset := ReadLongWord(Data + 24);
  Header.KerningTableOffset := ReadLongWord(Data + 28);
  Header.CoverageOffset := ReadLongWord(Data + 32);
  Header.CoverageSize := ReadLongWord(Data + 36);
  Result := (Header.HeaderSize >= CoverageHeaderSize) and (Header.PixelSize > 0) and
    (Header.PixelSize <= MaximumPixelSize) and (Header.LineHeight > 0) and
    (Header.LineHeight <= 2 * MaximumPixelSize) and (Abs(Header.Ascent) <= 2 * MaximumPixelSize) and
    (Abs(Header.UnderlineTop) <= 2 * MaximumPixelSize) and (Header.UnderlineThickness <= MaximumPixelSize) and
    (Header.GlyphCount > 0) and (Header.GlyphCount <= MaximumGlyphs) and
    (Header.KerningCount <= MaximumKerningPairs);
end;

function ReadCoverageFontSummary(Data: PByte; Length: PtrUInt; out Size: LongInt; out Bold: Boolean): Boolean;
var
  Header: TCoverageHeader;
begin
  Size := 0;
  Bold := False;
  Result := ReadHeader(Data, Length, Header);
  if Result then
  begin
    Size := Header.PixelSize;
    Bold := (Header.Flags and FlagBold) <> 0;
  end;
end;

{ The glyph table into Face, each bitmap checked to lie in the coverage
  data and the code points checked to increase. }
function ReadGlyphs(Data: PByte; const Header: TCoverageHeader; var Face: TFontFace): Boolean;
var
  Index: LongWord;
  Entry: PByte;
  CodePoint: LongWord;
  PreviousCodePoint: LongWord;
  Glyph: TGlyph;
begin
  Result := False;
  SetLength(Face.Glyphs, Header.GlyphCount);
  PreviousCodePoint := 0;
  for Index := 0 to Header.GlyphCount - 1 do
  begin
    Entry := Data + Header.GlyphTableOffset + Index * GlyphEntrySize;
    CodePoint := ReadLongWord(Entry);
    if (Index > 0) and (CodePoint <= PreviousCodePoint) then
      Exit;
    PreviousCodePoint := CodePoint;
    Glyph.BitmapOffset := ReadLongWord(Entry + 4);
    Glyph.Advance := ReadSignedWord(Entry + 8);
    Glyph.LeftBearing := ReadSignedWord(Entry + 10);
    Glyph.Top := ReadSignedWord(Entry + 12);
    Glyph.Width := ReadWord(Entry + 14);
    Glyph.Height := ReadWord(Entry + 16);
    if (Glyph.Width > MaximumGlyphDimension) or (Glyph.Height > MaximumGlyphDimension) or
       not TableFits(Glyph.BitmapOffset, QWord(Glyph.Width) * QWord(Glyph.Height), 1, Header.CoverageSize) then
      Exit;
    Face.Glyphs[Index] := Glyph;
    if Glyph.Advance > Face.Width then
      Face.Width := Glyph.Advance;
    AddMapping(Face, CodePoint, Index);
  end;
  Result := True;
end;

function ReadKerning(Data: PByte; const Header: TCoverageHeader; var Face: TFontFace): Boolean;
var
  Index: LongWord;
  Entry: PByte;
  Pair: TKerningPair;
  Previous: TKerningPair;
begin
  Result := False;
  if Header.KerningCount = 0 then
    Exit(True);
  SetLength(Face.Kerning, Header.KerningCount);
  Previous.Left := 0;
  Previous.Right := 0;
  for Index := 0 to Header.KerningCount - 1 do
  begin
    Entry := Data + Header.KerningTableOffset + Index * KerningEntrySize;
    Pair.Left := ReadLongWord(Entry);
    Pair.Right := ReadLongWord(Entry + 4);
    Pair.Adjustment := ReadSignedWord(Entry + 8);
    if (Index > 0) and ((Pair.Left < Previous.Left) or ((Pair.Left = Previous.Left) and
       (Pair.Right <= Previous.Right))) then
      Exit;
    Face.Kerning[Index] := Pair;
    Previous := Pair;
  end;
  Face.KerningCount := Header.KerningCount;
  Result := True;
end;

function ParseCoverageFont(Data: PByte; Length: PtrUInt; out Face: TFontFace): Boolean;
var
  Header: TCoverageHeader;
begin
  Result := False;
  ClearFace(Face);
  if not ReadHeader(Data, Length, Header) then
    Exit;
  if not TableFits(Header.GlyphTableOffset, Header.GlyphCount, GlyphEntrySize, Length) or
     not TableFits(Header.KerningTableOffset, Header.KerningCount, KerningEntrySize, Length) or
     not TableFits(Header.CoverageOffset, Header.CoverageSize, 1, Length) then
    Exit;
  Face.Format := GlyphCoverage;
  Face.Size := Header.PixelSize;
  Face.Bold := (Header.Flags and FlagBold) <> 0;
  Face.Height := Header.LineHeight;
  Face.Ascent := Header.Ascent;
  Face.UnderlineTop := Header.UnderlineTop;
  Face.UnderlineThickness := Header.UnderlineThickness;
  if Face.UnderlineThickness < 1 then
    Face.UnderlineThickness := 1;
  Face.GlyphCount := Header.GlyphCount;
  if not ReadGlyphs(Data, Header, Face) or not ReadKerning(Data, Header, Face) then
  begin
    ClearFace(Face);
    Exit;
  end;
  SetLength(Face.Bitmaps, Header.CoverageSize);
  if Header.CoverageSize > 0 then
    Move(Data[Header.CoverageOffset], Face.Bitmaps[0], Header.CoverageSize);
  FinishMap(Face);
  Face.Loaded := True;
  Result := True;
end;

end.
