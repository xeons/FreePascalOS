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
  PC Screen Fonts (PSF1 and PSF2): bitmap fonts, one size each, every
  glyph the same width and height, as the text console uses.

  PSF1: magic 36 04, a mode byte (bit 0: 512 glyphs instead of 256; bit
  1 or 2: a Unicode table follows) and the height; glyphs are 8 pixels
  wide, one byte a row. Its Unicode table gives each glyph a list of
  16-bit code points ending in FFFF (FFFE starts sequences, skipped).

  PSF2: a 32 byte header (magic 72 B5 4A 86, version, header size,
  flags (bit 0: a Unicode table), glyph count, bytes a glyph, height,
  width); rows are (width + 7) div 8 bytes, leftmost pixel in the top
  bit. Its table gives each glyph UTF-8 code points ending in FF (FE
  starts sequences, skipped).

  The face (Font.Faces) keeps its own copy of the glyphs, as bits, every
  advance the font's width, and a table from code points to glyphs.
  Without a Unicode table, glyph N is code point N. The fonts carry no
  baseline: it is put three sixteenths of the height up from the bottom
  less a pixel, with the underline just under it, where Terminus's own
  underscore is.
}
unit Font.Psf;

{$mode objfpc}
{$pointermath on}

interface

uses
  Font.Faces;

{ Reads a PSF1 or PSF2 font from Data (Length bytes). }
function ParsePsfFont(Data: PByte; Length: PtrUInt; out Face: TFontFace): Boolean;
{ Only the header: the font's size (the em its height stands for, six
  sevenths of it). Length may be just the start of the file (32 bytes
  are enough). }
function ReadPsfSize(Data: PByte; Length: PtrUInt; out Size: LongInt): Boolean;

implementation

const
  Psf1Magic0 = $36;
  Psf1Magic1 = $04;
  Psf1Mode512 = $01;
  Psf1ModeHasTable = $02;
  Psf1ModeHasSequences = $04;
  Psf1HeaderSize = 4;
  Psf1TableEnd = $FFFF;
  Psf1SequenceStart = $FFFE;
  Psf2Magic = $864AB572;
  Psf2HeaderSize = 32;
  Psf2HasTable = $01;
  Psf2TableEnd = $FF;
  Psf2SequenceStart = $FE;
  MaximumPsfDimension = 256;
  MaximumPsfGlyphs = 65536;

function ReadLongWord(Data: PByte): LongWord;
begin
  Result := Data[0] or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or (LongWord(Data[3]) shl 24);
end;

procedure MapGlyphsToThemselves(var Face: TFontFace);
var
  Glyph: LongWord;
begin
  for Glyph := 0 to Face.GlyphCount - 1 do
    AddMapping(Face, Glyph, Glyph);
end;

{ PSF1's table: 16-bit code points per glyph. }
procedure ReadPsf1Table(var Face: TFontFace; Data: PByte; Length: PtrUInt);
var
  Position: PtrUInt;
  Glyph: LongWord;
  Value: LongWord;
  InSequence: Boolean;
begin
  Position := 0;
  Glyph := 0;
  InSequence := False;
  while (Position + 2 <= Length) and (Glyph < Face.GlyphCount) do
  begin
    Value := Data[Position] or (LongWord(Data[Position + 1]) shl 8);
    Position := Position + 2;
    if Value = Psf1TableEnd then
    begin
      Inc(Glyph);
      InSequence := False;
    end
    else if Value = Psf1SequenceStart then
      InSequence := True
    else if not InSequence then
      AddMapping(Face, Value, Glyph);
  end;
end;

{ One UTF-8 code point at Data[Position], advancing Position; False at
  a byte that does not start one. }
function ReadUtf8(Data: PByte; Length: PtrUInt; var Position: PtrUInt; out CodePoint: LongWord): Boolean;
var
  Lead: Byte;
  Extra: LongInt;
  Index: LongInt;
begin
  CodePoint := 0;
  Lead := Data[Position];
  if Lead < $80 then
  begin
    CodePoint := Lead;
    Extra := 0;
  end
  else if (Lead and $E0) = $C0 then
  begin
    CodePoint := Lead and $1F;
    Extra := 1;
  end
  else if (Lead and $F0) = $E0 then
  begin
    CodePoint := Lead and $0F;
    Extra := 2;
  end
  else if (Lead and $F8) = $F0 then
  begin
    CodePoint := Lead and $07;
    Extra := 3;
  end
  else
    Exit(False);
  if Position + 1 + PtrUInt(Extra) > Length then
    Exit(False);
  for Index := 1 to Extra do
    CodePoint := (CodePoint shl 6) or (Data[Position + PtrUInt(Index)] and $3F);
  Position := Position + 1 + PtrUInt(Extra);
  Result := True;
end;

{ PSF2's table: UTF-8 per glyph. }
procedure ReadPsf2Table(var Face: TFontFace; Data: PByte; Length: PtrUInt);
var
  Position: PtrUInt;
  Glyph: LongWord;
  CodePoint: LongWord;
  InSequence: Boolean;
begin
  Position := 0;
  Glyph := 0;
  InSequence := False;
  while (Position < Length) and (Glyph < Face.GlyphCount) do
  begin
    if Data[Position] = Psf2TableEnd then
    begin
      Inc(Glyph);
      InSequence := False;
      Inc(Position);
    end
    else if Data[Position] = Psf2SequenceStart then
    begin
      InSequence := True;
      Inc(Position);
    end
    else if ReadUtf8(Data, Length, Position, CodePoint) then
    begin
      if not InSequence then
        AddMapping(Face, CodePoint, Glyph);
    end
    else
      Inc(Position);
  end;
end;

{ The header of a PSF1 or PSF2 font: where the glyphs start, how many,
  their size and whether a Unicode table follows them. }
type
  TPsfHeader = record
    IsPsf1: Boolean;
    HeaderSize: PtrUInt;
    GlyphCount: LongWord;
    BytesPerGlyph: PtrUInt;
    Width: LongInt;
    Height: LongInt;
    HasTable: Boolean;
  end;

function ReadPsfHeader(Data: PByte; Length: PtrUInt; out Header: TPsfHeader): Boolean;
var
  Mode: Byte;
begin
  Result := False;
  FillChar(Header, SizeOf(Header), 0);
  if (Data = nil) or (Length < Psf1HeaderSize) then
    Exit;
  Header.IsPsf1 := (Data[0] = Psf1Magic0) and (Data[1] = Psf1Magic1);
  if Header.IsPsf1 then
  begin
    Mode := Data[2];
    Header.Height := Data[3];
    Header.Width := 8;
    if (Mode and Psf1Mode512) <> 0 then
      Header.GlyphCount := 512
    else
      Header.GlyphCount := 256;
    Header.HeaderSize := Psf1HeaderSize;
    Header.BytesPerGlyph := PtrUInt(Header.Height);
    Header.HasTable := (Mode and (Psf1ModeHasTable or Psf1ModeHasSequences)) <> 0;
  end
  else
  begin
    if (Length < Psf2HeaderSize) or (ReadLongWord(Data) <> Psf2Magic) then
      Exit;
    Header.HeaderSize := ReadLongWord(Data + 8);
    Header.HasTable := (ReadLongWord(Data + 12) and Psf2HasTable) <> 0;
    Header.GlyphCount := ReadLongWord(Data + 16);
    Header.BytesPerGlyph := ReadLongWord(Data + 20);
    { Sizes past these are no font: they would only overflow below. }
    if (ReadLongWord(Data + 24) > MaximumPsfDimension) or (ReadLongWord(Data + 28) > MaximumPsfDimension) or
       (Header.GlyphCount > MaximumPsfGlyphs) then
      Exit;
    Header.Height := LongInt(ReadLongWord(Data + 24));
    Header.Width := LongInt(ReadLongWord(Data + 28));
    if Header.BytesPerGlyph <> PtrUInt(((Header.Width + 7) div 8) * Header.Height) then
      Exit;
  end;
  Result := (Header.Width > 0) and (Header.Height > 0) and (Header.GlyphCount > 0);
end;

{ The em a bitmap font's height stands for: its cell holds the ascent
  and the descent, about seven sixths of the em (as a rendered font's
  line does), so faces of both kinds picked for one size match. }
function EmForHeight(Height: LongInt): LongInt;
begin
  Result := (Height * 6 + 3) div 7;
end;

function ReadPsfSize(Data: PByte; Length: PtrUInt; out Size: LongInt): Boolean;
var
  Header: TPsfHeader;
begin
  Size := 0;
  Result := ReadPsfHeader(Data, Length, Header);
  if Result then
    Size := EmForHeight(Header.Height);
end;

function ParsePsfFont(Data: PByte; Length: PtrUInt; out Face: TFontFace): Boolean;
var
  Header: TPsfHeader;
  GlyphBytes: PtrUInt;
  Glyph: LongWord;
begin
  Result := False;
  ClearFace(Face);
  if not ReadPsfHeader(Data, Length, Header) then
    Exit;
  GlyphBytes := Header.GlyphCount * Header.BytesPerGlyph;
  if (Header.HeaderSize > Length) or (GlyphBytes > Length - Header.HeaderSize) then
    Exit;
  Face.Format := GlyphBits;
  Face.Size := EmForHeight(Header.Height);
  Face.Height := Header.Height;
  Face.Width := Header.Width;
  Face.UnderlineTop := Header.Height - (3 * Header.Height) div 16;
  Face.UnderlineThickness := Header.Height div 16;
  if Face.UnderlineThickness < 1 then
    Face.UnderlineThickness := 1;
  Face.Ascent := Face.UnderlineTop - 1;
  Face.GlyphCount := Header.GlyphCount;
  SetLength(Face.Bitmaps, GlyphBytes);
  Move(Data[Header.HeaderSize], Face.Bitmaps[0], GlyphBytes);
  SetLength(Face.Glyphs, Header.GlyphCount);
  for Glyph := 0 to Header.GlyphCount - 1 do
  begin
    Face.Glyphs[Glyph].Advance := Header.Width;
    Face.Glyphs[Glyph].LeftBearing := 0;
    Face.Glyphs[Glyph].Top := 0;
    Face.Glyphs[Glyph].Width := Header.Width;
    Face.Glyphs[Glyph].Height := Header.Height;
    Face.Glyphs[Glyph].BitmapOffset := PtrUInt(Glyph) * Header.BytesPerGlyph;
  end;
  if not Header.HasTable then
    MapGlyphsToThemselves(Face)
  else if Header.IsPsf1 then
    ReadPsf1Table(Face, Data + Header.HeaderSize + GlyphBytes, Length - Header.HeaderSize - GlyphBytes)
  else
    ReadPsf2Table(Face, Data + Header.HeaderSize + GlyphBytes, Length - Header.HeaderSize - GlyphBytes);
  FinishMap(Face);
  Face.Loaded := True;
  Result := True;
end;

end.
