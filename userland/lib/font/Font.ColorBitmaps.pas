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
  Colour bitmap glyphs: the "CBLC" and "CBDT" tables (Noto Color
  Emoji), pictures in PNG drawn instead of an outline.

  CBLC lists strikes, each a pixel size (ppem) with index subtables
  saying where in CBDT each of a run of glyphs' data is (index formats
  1 to 5: offsets of 32 or 16 bits, all one size with shared metrics,
  or sparse glyph lists). The data (image formats 17, 18 and 19) is the
  glyph's metrics at that size (its bearings: left of the pen, above
  the baseline) and a PNG.

  A glyph is drawn at a size from the strike nearest it (the smallest
  not smaller, else the largest), its picture decoded and scaled
  smoothly (Drawing.Scaling), its bearings scaled with it.

  libfont itself does not decode PNG: whoever draws colour glyphs (the
  toolkit, the web engine, with libimage) sets ColorBitmapDecoder; with
  none, a font's colour glyphs are not there (HasColorBitmap is False
  and text falls back to other fonts).
}
unit Font.ColorBitmaps;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Types,
  Font.FontData,
  Font.Outlines;

type
  TColorPixels = TLongWordDynArray;
  { Decodes a picture (PNG) into Width x Height colours, $AARRGGBB not
    premultiplied, row by row from the top. }
  TColorBitmapDecoder = function(const Data: TBytes; out Width, Height: LongInt; out Pixels: TColorPixels): Boolean;

  TColorStrike = record
    PixelsPerEm: LongInt;
    SubtablesOffset: QWord;
    SubtableCount: LongWord;
    FirstGlyph: LongWord;
    LastGlyph: LongWord;
  end;

  TColorBitmapTables = record
    Present: Boolean;
    Locations: TFontTable;
    Data: TFontTable;
    Strikes: array of TColorStrike;
  end;

var
  ColorBitmapDecoder: TColorBitmapDecoder = nil;

{ Reads CBLC's strikes; False (not Present) if there are none usable. }
function OpenColorBitmaps(const Locations, Data: TFontTable; out Tables: TColorBitmapTables): Boolean;
{ Whether Glyph has a picture (and there is a decoder to draw it). }
function HasColorBitmap(const Tables: TColorBitmapTables; Glyph: LongWord): Boolean;
{ Glyph's picture at PixelSize pixels to the em; False if it has none
  or it cannot be decoded. }
function RenderColorBitmap(const Tables: TColorBitmapTables; Glyph: LongWord; PixelSize: LongInt;
  out Bitmap: TGlyphBitmap): Boolean;

implementation

uses
  Math,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Scaling;

const
  StrikeRecordSize = 48;
  MaximumStrikes = 64;
  MaximumPictureSide = 1024;

type
  TBitmapPlace = record
    Offset: QWord;
    Length: QWord;
    ImageFormat: LongWord;
    { Metrics from an index subtable (formats 2 and 5, for image format
      19). }
    HasMetrics: Boolean;
    Height: LongInt;
    Width: LongInt;
    BearingX: LongInt;
    BearingY: LongInt;
  end;

function OpenColorBitmaps(const Locations, Data: TFontTable; out Tables: TColorBitmapTables): Boolean;
var
  StrikeCount: LongWord;
  Index: LongWord;
  Entry: QWord;
  Count: LongInt;
begin
  Result := False;
  Tables.Present := False;
  Tables.Locations := Locations;
  Tables.Data := Data;
  Tables.Strikes := nil;
  if not Has(Locations, 0, 8) or not Data.Present then
    Exit;
  StrikeCount := ReadUnsigned32(Locations, 4);
  if (StrikeCount = 0) or (StrikeCount > MaximumStrikes) or
     not Has(Locations, 8, StrikeRecordSize * QWord(StrikeCount)) then
    Exit;
  Count := 0;
  SetLength(Tables.Strikes, StrikeCount);
  for Index := 1 to StrikeCount do
  begin
    Entry := 8 + StrikeRecordSize * QWord(Index - 1);
    Tables.Strikes[Count].SubtablesOffset := ReadUnsigned32(Locations, Entry);
    Tables.Strikes[Count].SubtableCount := ReadUnsigned32(Locations, Entry + 8);
    Tables.Strikes[Count].FirstGlyph := ReadUnsigned16(Locations, Entry + 40);
    Tables.Strikes[Count].LastGlyph := ReadUnsigned16(Locations, Entry + 42);
    Tables.Strikes[Count].PixelsPerEm := ReadByte(Locations, Entry + 45);
    if (Tables.Strikes[Count].PixelsPerEm > 0) and
       Has(Locations, Tables.Strikes[Count].SubtablesOffset, 8 * QWord(Tables.Strikes[Count].SubtableCount)) then
      Inc(Count);
  end;
  SetLength(Tables.Strikes, Count);
  Tables.Present := Count > 0;
  Result := Tables.Present;
end;

{ The strike to draw PixelSize from: the smallest not smaller, else the
  largest; -1 if there is none. }
function StrikeFor(const Tables: TColorBitmapTables; PixelSize: LongInt): LongInt;
var
  Index: LongInt;
  Largest: LongInt;
begin
  Result := -1;
  Largest := -1;
  for Index := 0 to High(Tables.Strikes) do
  begin
    if (Largest < 0) or (Tables.Strikes[Index].PixelsPerEm > Tables.Strikes[Largest].PixelsPerEm) then
      Largest := Index;
    if (Tables.Strikes[Index].PixelsPerEm >= PixelSize) and
       ((Result < 0) or (Tables.Strikes[Index].PixelsPerEm < Tables.Strikes[Result].PixelsPerEm)) then
      Result := Index;
  end;
  if Result < 0 then
    Result := Largest;
end;

procedure ReadBigMetrics(const Table: TFontTable; Offset: QWord; var Place: TBitmapPlace);
begin
  Place.HasMetrics := True;
  Place.Height := ReadByte(Table, Offset);
  Place.Width := ReadByte(Table, Offset + 1);
  Place.BearingX := ShortInt(ReadByte(Table, Offset + 2));
  Place.BearingY := ShortInt(ReadByte(Table, Offset + 3));
end;

{ Where Glyph's data is in the strike: through the index subtable whose
  run holds it. }
function FindBitmap(const Tables: TColorBitmapTables; const Strike: TColorStrike; Glyph: LongWord;
  out Place: TBitmapPlace): Boolean;
var
  Locations: TFontTable;
  Subtable: LongWord;
  Entry: QWord;
  FirstGlyph: LongWord;
  LastGlyph: LongWord;
  Header: QWord;
  IndexFormat: LongWord;
  ImageOffset: QWord;
  Position: QWord;
  Start: QWord;
  Finish: QWord;
  ImageSize: QWord;
  GlyphCount: LongWord;
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
  Found: LongWord;
begin
  Result := False;
  FillChar(Place, SizeOf(Place), 0);
  if (Glyph < Strike.FirstGlyph) or (Glyph > Strike.LastGlyph) then
    Exit;
  Locations := Tables.Locations;
  for Subtable := 1 to Strike.SubtableCount do
  begin
    Entry := Strike.SubtablesOffset + 8 * QWord(Subtable - 1);
    FirstGlyph := ReadUnsigned16(Locations, Entry);
    LastGlyph := ReadUnsigned16(Locations, Entry + 2);
    if (Glyph < FirstGlyph) or (Glyph > LastGlyph) then
      Continue;
    Header := Strike.SubtablesOffset + ReadUnsigned32(Locations, Entry + 4);
    if not Has(Locations, Header, 8) then
      Exit;
    IndexFormat := ReadUnsigned16(Locations, Header);
    Place.ImageFormat := ReadUnsigned16(Locations, Header + 2);
    ImageOffset := ReadUnsigned32(Locations, Header + 4);
    Position := Header + 8;
    case IndexFormat of
      1, 3:
        begin
          if IndexFormat = 1 then
          begin
            if not Has(Locations, Position + 4 * QWord(Glyph - FirstGlyph), 8) then
              Exit;
            Start := ReadUnsigned32(Locations, Position + 4 * QWord(Glyph - FirstGlyph));
            Finish := ReadUnsigned32(Locations, Position + 4 * QWord(Glyph - FirstGlyph) + 4);
          end
          else
          begin
            if not Has(Locations, Position + 2 * QWord(Glyph - FirstGlyph), 4) then
              Exit;
            Start := ReadUnsigned16(Locations, Position + 2 * QWord(Glyph - FirstGlyph));
            Finish := ReadUnsigned16(Locations, Position + 2 * QWord(Glyph - FirstGlyph) + 2);
          end;
          if Finish <= Start then
            Exit;
          Place.Offset := ImageOffset + Start;
          Place.Length := Finish - Start;
        end;
      2:
        begin
          if not Has(Locations, Position, 12) then
            Exit;
          ImageSize := ReadUnsigned32(Locations, Position);
          ReadBigMetrics(Locations, Position + 4, Place);
          Place.Offset := ImageOffset + ImageSize * (Glyph - FirstGlyph);
          Place.Length := ImageSize;
        end;
      4:
        begin
          if not Has(Locations, Position, 4) then
            Exit;
          GlyphCount := ReadUnsigned32(Locations, Position);
          if not Has(Locations, Position + 4, 4 * (QWord(GlyphCount) + 1)) then
            Exit;
          Low := 0;
          High := LongInt(GlyphCount) - 1;
          while Low <= High do
          begin
            Middle := (Low + High) div 2;
            Found := ReadUnsigned16(Locations, Position + 4 + 4 * QWord(Middle));
            if Found = Glyph then
            begin
              Start := ReadUnsigned16(Locations, Position + 4 + 4 * QWord(Middle) + 2);
              Finish := ReadUnsigned16(Locations, Position + 4 + 4 * QWord(Middle + 1) + 2);
              if Finish <= Start then
                Exit;
              Place.Offset := ImageOffset + Start;
              Place.Length := Finish - Start;
              Break;
            end;
            if Found < Glyph then
              Low := Middle + 1
            else
              High := Middle - 1;
          end;
          if Place.Length = 0 then
            Exit;
        end;
      5:
        begin
          if not Has(Locations, Position, 16) then
            Exit;
          ImageSize := ReadUnsigned32(Locations, Position);
          ReadBigMetrics(Locations, Position + 4, Place);
          GlyphCount := ReadUnsigned32(Locations, Position + 12);
          if not Has(Locations, Position + 16, 2 * QWord(GlyphCount)) then
            Exit;
          Low := 0;
          High := LongInt(GlyphCount) - 1;
          while Low <= High do
          begin
            Middle := (Low + High) div 2;
            Found := ReadUnsigned16(Locations, Position + 16 + 2 * QWord(Middle));
            if Found = Glyph then
            begin
              Place.Offset := ImageOffset + ImageSize * QWord(Middle);
              Place.Length := ImageSize;
              Break;
            end;
            if Found < Glyph then
              Low := Middle + 1
            else
              High := Middle - 1;
          end;
          if Place.Length = 0 then
            Exit;
        end;
    else
      Exit;
    end;
    Result := Has(Tables.Data, Place.Offset, Place.Length) and (Place.ImageFormat in [17, 18, 19]);
    Exit;
  end;
end;

function HasColorBitmap(const Tables: TColorBitmapTables; Glyph: LongWord): Boolean;
var
  Place: TBitmapPlace;
  Strike: LongInt;
begin
  Result := False;
  if not Tables.Present or (ColorBitmapDecoder = nil) then
    Exit;
  Strike := StrikeFor(Tables, MaximumPictureSide);
  Result := (Strike >= 0) and FindBitmap(Tables, Tables.Strikes[Strike], Glyph, Place);
end;

{ The PNG of an image and its metrics. }
function ReadImage(const Tables: TColorBitmapTables; var Place: TBitmapPlace; out Picture: TBytes): Boolean;
var
  Data: TFontTable;
  Position: QWord;
  Length_: QWord;
begin
  Result := False;
  Picture := nil;
  Data := Tables.Data;
  Position := Place.Offset;
  case Place.ImageFormat of
    17:
      begin
        if Place.Length < 9 then
          Exit;
        Place.HasMetrics := True;
        Place.Height := ReadByte(Data, Position);
        Place.Width := ReadByte(Data, Position + 1);
        Place.BearingX := ShortInt(ReadByte(Data, Position + 2));
        Place.BearingY := ShortInt(ReadByte(Data, Position + 3));
        Position := Position + 5;
      end;
    18:
      begin
        if Place.Length < 12 then
          Exit;
        ReadBigMetrics(Data, Position, Place);
        Position := Position + 8;
      end;
    19:
      if not Place.HasMetrics or (Place.Length < 4) then
        Exit;
  end;
  Length_ := ReadUnsigned32(Data, Position);
  Position := Position + 4;
  if (Length_ = 0) or (Position + Length_ > Place.Offset + Place.Length) then
    Exit;
  SetLength(Picture, Length_);
  Move(Data.Data[Data.Start + Position], Picture[0], Length_);
  Result := True;
end;

function RenderColorBitmap(const Tables: TColorBitmapTables; Glyph: LongWord; PixelSize: LongInt;
  out Bitmap: TGlyphBitmap): Boolean;
var
  StrikeIndex: LongInt;
  Place: TBitmapPlace;
  Picture: TBytes;
  Pixels: TColorPixels;
  PictureWidth: LongInt;
  PictureHeight: LongInt;
  Scale: Double;
  Source: TSurface;
  Target: TSurface;
  Canvas: TCanvas;
begin
  Result := False;
  Bitmap.Left := 0;
  Bitmap.Top := 0;
  Bitmap.Width := 0;
  Bitmap.Height := 0;
  Bitmap.Coverage := nil;
  Bitmap.Colors := nil;
  if not Tables.Present or (ColorBitmapDecoder = nil) or (PixelSize < 1) then
    Exit;
  StrikeIndex := StrikeFor(Tables, PixelSize);
  if (StrikeIndex < 0) or not FindBitmap(Tables, Tables.Strikes[StrikeIndex], Glyph, Place) or
     not ReadImage(Tables, Place, Picture) then
    Exit;
  try
    if not ColorBitmapDecoder(Picture, PictureWidth, PictureHeight, Pixels) then
      Exit;
  except
    Exit;
  end;
  if (PictureWidth < 1) or (PictureHeight < 1) or (PictureWidth > MaximumPictureSide) or
     (PictureHeight > MaximumPictureSide) or (Length(Pixels) < PictureWidth * PictureHeight) then
    Exit;
  Scale := PixelSize / Tables.Strikes[StrikeIndex].PixelsPerEm;
  Bitmap.Width := Max(1, Round(PictureWidth * Scale));
  Bitmap.Height := Max(1, Round(PictureHeight * Scale));
  Bitmap.Left := Round(Place.BearingX * Scale);
  Bitmap.Top := -Round(Place.BearingY * Scale);
  SetLength(Bitmap.Colors, Bitmap.Width * Bitmap.Height);
  Source := SurfaceOnPixels(@Pixels[0], PictureWidth, PictureHeight, 4 * PictureWidth);
  Target := SurfaceOnPixels(@Bitmap.Colors[0], Bitmap.Width, Bitmap.Height, 4 * Bitmap.Width);
  BeginCanvas(Canvas, Target);
  DrawSurfaceScaled(Canvas, Source, SurfaceBounds(Source), SurfaceBounds(Target), False);
  Result := True;
end;

end.
