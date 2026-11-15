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

  A face keeps its own copy of the glyphs and a table from code points
  to glyphs, sorted for looking up. Without a Unicode table, glyph N is
  code point N.
}
unit Font.Psf;

{$mode objfpc}
{$pointermath on}

interface

type
  TCodePointGlyph = record
    CodePoint: LongWord;
    Glyph: LongWord;
  end;

  TFontFace = record
    Width: LongInt;
    Height: LongInt;
    BytesPerRow: LongInt;
    GlyphCount: LongWord;
    { GlyphCount glyphs, Height * BytesPerRow bytes each. }
    Glyphs: array of Byte;
    { Sorted by code point. }
    Map: array of TCodePointGlyph;
    MapCount: LongInt;
    { What is drawn for a character the face lacks. }
    FallbackGlyph: LongWord;
    Bold: Boolean;
  end;
  PFontFace = ^TFontFace;

{ Reads a PSF1 or PSF2 font from Data (Length bytes). }
function ParsePsfFont(Data: PByte; Length: PtrUInt; out Face: TFontFace): Boolean;
{ The glyph for CodePoint, or the fallback. }
function GlyphFor(const Face: TFontFace; CodePoint: LongWord): LongWord;
function HasGlyphFor(const Face: TFontFace; CodePoint: LongWord): Boolean;
{ The glyph's row Row (0 at the top): BytesPerRow bytes, leftmost pixel
  in the top bit of the first. }
function GlyphRow(const Face: TFontFace; Glyph: LongWord; Row: LongInt): PByte;

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
  ReplacementCharacter = $FFFD;
  QuestionMark = Ord('?');

function ReadLongWord(Data: PByte): LongWord;
begin
  Result := Data[0] or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16) or (LongWord(Data[3]) shl 24);
end;

procedure AddMapping(var Face: TFontFace; CodePoint, Glyph: LongWord);
begin
  if Face.MapCount = System.Length(Face.Map) then
    SetLength(Face.Map, 2 * Face.MapCount + 256);
  Face.Map[Face.MapCount].CodePoint := CodePoint;
  Face.Map[Face.MapCount].Glyph := Glyph;
  Inc(Face.MapCount);
end;

{ Sorts the map by code point (a font's table is nearly in order, so
  insertion sort is quick) and drops repeated code points, keeping the
  first glyph given. }
procedure SortMap(var Face: TFontFace);
var
  Index: LongInt;
  Sorted: LongInt;
  Entry: TCodePointGlyph;
  Kept: LongInt;
begin
  for Index := 1 to Face.MapCount - 1 do
  begin
    Entry := Face.Map[Index];
    Sorted := Index - 1;
    while (Sorted >= 0) and (Face.Map[Sorted].CodePoint > Entry.CodePoint) do
    begin
      Face.Map[Sorted + 1] := Face.Map[Sorted];
      Dec(Sorted);
    end;
    Face.Map[Sorted + 1] := Entry;
  end;
  Kept := 0;
  for Index := 0 to Face.MapCount - 1 do
    if (Kept = 0) or (Face.Map[Kept - 1].CodePoint <> Face.Map[Index].CodePoint) then
    begin
      Face.Map[Kept] := Face.Map[Index];
      Inc(Kept);
    end;
  Face.MapCount := Kept;
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

function ParsePsfFont(Data: PByte; Length: PtrUInt; out Face: TFontFace): Boolean;
var
  Mode: Byte;
  HeaderSize: PtrUInt;
  BytesPerGlyph: PtrUInt;
  GlyphBytes: PtrUInt;
  HasTable: Boolean;
  IsPsf1: Boolean;
begin
  Result := False;
  Face.Width := 0;
  Face.Height := 0;
  Face.BytesPerRow := 0;
  Face.GlyphCount := 0;
  Face.Glyphs := nil;
  Face.Map := nil;
  Face.MapCount := 0;
  Face.FallbackGlyph := 0;
  Face.Bold := False;
  if (Data = nil) or (Length < Psf1HeaderSize) then
    Exit;
  IsPsf1 := (Data[0] = Psf1Magic0) and (Data[1] = Psf1Magic1);
  if IsPsf1 then
  begin
    Mode := Data[2];
    Face.Height := Data[3];
    Face.Width := 8;
    Face.BytesPerRow := 1;
    if (Mode and Psf1Mode512) <> 0 then
      Face.GlyphCount := 512
    else
      Face.GlyphCount := 256;
    HeaderSize := Psf1HeaderSize;
    BytesPerGlyph := PtrUInt(Face.Height);
    HasTable := (Mode and (Psf1ModeHasTable or Psf1ModeHasSequences)) <> 0;
  end
  else
  begin
    if (Length < Psf2HeaderSize) or (ReadLongWord(Data) <> Psf2Magic) then
      Exit;
    HeaderSize := ReadLongWord(Data + 8);
    HasTable := (ReadLongWord(Data + 12) and Psf2HasTable) <> 0;
    Face.GlyphCount := ReadLongWord(Data + 16);
    BytesPerGlyph := ReadLongWord(Data + 20);
    Face.Height := LongInt(ReadLongWord(Data + 24));
    Face.Width := LongInt(ReadLongWord(Data + 28));
    Face.BytesPerRow := (Face.Width + 7) div 8;
    if BytesPerGlyph <> PtrUInt(Face.BytesPerRow * Face.Height) then
      Exit;
  end;
  if (Face.Width <= 0) or (Face.Height <= 0) or (Face.GlyphCount = 0) then
    Exit;
  GlyphBytes := Face.GlyphCount * BytesPerGlyph;
  if (HeaderSize > Length) or (GlyphBytes > Length - HeaderSize) then
    Exit;
  SetLength(Face.Glyphs, GlyphBytes);
  Move(Data[HeaderSize], Face.Glyphs[0], GlyphBytes);
  if not HasTable then
    MapGlyphsToThemselves(Face)
  else if IsPsf1 then
    ReadPsf1Table(Face, Data + HeaderSize + GlyphBytes, Length - HeaderSize - GlyphBytes)
  else
    ReadPsf2Table(Face, Data + HeaderSize + GlyphBytes, Length - HeaderSize - GlyphBytes);
  SortMap(Face);
  if HasGlyphFor(Face, ReplacementCharacter) then
    Face.FallbackGlyph := GlyphFor(Face, ReplacementCharacter)
  else if HasGlyphFor(Face, QuestionMark) then
    Face.FallbackGlyph := GlyphFor(Face, QuestionMark);
  Result := True;
end;

{ The map entry for CodePoint, or -1. }
function FindMapping(const Face: TFontFace; CodePoint: LongWord): LongInt;
var
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
begin
  Low := 0;
  High := Face.MapCount - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if Face.Map[Middle].CodePoint = CodePoint then
      Exit(Middle);
    if Face.Map[Middle].CodePoint < CodePoint then
      Low := Middle + 1
    else
      High := Middle - 1;
  end;
  Result := -1;
end;

function HasGlyphFor(const Face: TFontFace; CodePoint: LongWord): Boolean;
begin
  Result := FindMapping(Face, CodePoint) >= 0;
end;

function GlyphFor(const Face: TFontFace; CodePoint: LongWord): LongWord;
var
  Index: LongInt;
begin
  Index := FindMapping(Face, CodePoint);
  if Index < 0 then
    Result := Face.FallbackGlyph
  else
    Result := Face.Map[Index].Glyph;
end;

function GlyphRow(const Face: TFontFace; Glyph: LongWord; Row: LongInt): PByte;
begin
  if Glyph >= Face.GlyphCount then
    Glyph := Face.FallbackGlyph;
  Result := @Face.Glyphs[(PtrUInt(Glyph) * PtrUInt(Face.Height) + PtrUInt(Row)) * PtrUInt(Face.BytesPerRow)];
end;

end.
