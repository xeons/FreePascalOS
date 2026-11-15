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
  DrawingTest: libdrawing and libfont on the host, pixel by pixel.

    DrawingTest <font-directory> [sample.ppm]

  The font directory holds Terminus PSF files (uncompressed): ter-v16n.psf
  (PSF1, 8x16) and ter-v24n.psf (PSF2, 12x24) are drawn and compared with
  their bitmaps, and the sizes 12 to 32 are used for picking faces. Every
  check prints a line; the exit code is 1 if any failed. With a second
  argument a sample picture is written there (a PPM), for looking at.

  This is a host tool, built with the normal Free Pascal runtime library.
}
program DrawingTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Regions,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Shapes,
  Drawing.Bevels,
  Font.Psf,
  Font.Utf8,
  Font.Text;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[drawing] pass: ', Name)
  else
  begin
    WriteLn('[drawing] FAIL: ', Name);
    Inc(Failures);
  end;
end;

function ColorText(Color: TColor): string;
begin
  Result := '$' + IntToHex(Color, 8);
end;

procedure CheckColor(Name: string; Got, Expected: TColor);
begin
  if Got <> Expected then
    Name := Name + ' (got ' + ColorText(Got) + ', expected ' + ColorText(Expected) + ')';
  Check(Name, Got = Expected);
end;

{ Pixels of Surface equal to Color. }
function CountPixels(const Surface: TSurface; Color: TColor): Integer;
var
  X: Integer;
  Y: Integer;
begin
  Result := 0;
  for Y := 0 to Surface.Height - 1 do
    for X := 0 to Surface.Width - 1 do
      if GetSurfacePixel(Surface, X, Y) = Color then
        Inc(Result);
end;

function NewSurface(Width, Height: Integer; Fill: TColor): TSurface;
begin
  if not CreateSurface(Result, Width, Height, Fill) then
    raise Exception.Create('out of memory');
end;

{ --- Colours ----------------------------------------------------------------- }

procedure TestColors;
begin
  CheckColor('opaque colour replaces', BlendColors($FF102030, $FF405060), $FF405060);
  CheckColor('transparent colour leaves', BlendColors($FF102030, $00405060), $FF102030);
  CheckColor('half red over white', BlendColors($FFFFFFFF, $80FF0000), $FFFF7F7F);
  CheckColor('half red over nothing', BlendColors($00000000, $80FF0000), $80FF0000);
  CheckColor('half over half', BlendColors($800000FF, $80FF0000), $C0AA0055);
  CheckColor('mix halfway', MixColors($FF000000, $FFFFFFFF, 128), $FF808080);
  CheckColor('mix ends', MixColors($FF102030, $FF405060, 255), $FF405060);
  CheckColor('fade', FadeColor($FF123456, 128), $80123456);
  CheckColor('rgb', RgbColor($12, $34, $56), $FF123456);
end;

{ --- Rectangles and regions ---------------------------------------------------- }

procedure TestRectangles;
var
  Common: TRectangle;
begin
  Check('intersect', IntersectRectangles(MakeRectangle(0, 0, 10, 10), MakeRectangle(5, 5, 10, 10), Common) and
    RectanglesAreEqual(Common, MakeRectangle(5, 5, 5, 5)));
  Check('touching edges do not intersect',
    not IntersectRectangles(MakeRectangle(0, 0, 10, 10), MakeRectangle(10, 0, 5, 5), Common));
  Check('bounding', RectanglesAreEqual(BoundingRectangle(MakeRectangle(0, 0, 2, 2), MakeRectangle(5, 6, 1, 1)),
    MakeRectangle(0, 0, 6, 7)));
  Check('bounding ignores empty', RectanglesAreEqual(BoundingRectangle(MakeRectangle(3, 3, 0, 0),
    MakeRectangle(5, 6, 1, 1)), MakeRectangle(5, 6, 1, 1)));
  Check('contains', RectangleContains(MakeRectangle(0, 0, 10, 10), MakeRectangle(2, 2, 8, 8)) and
    not RectangleContains(MakeRectangle(0, 0, 10, 10), MakeRectangle(2, 2, 9, 8)));
end;

procedure TestRegions;
var
  Region: TRegion;
  Other: TRegion;
begin
  SetRegionToRectangle(Region, MakeRectangle(0, 0, 10, 10));
  SubtractRectangleFromRegion(Region, MakeRectangle(4, 4, 2, 2));
  Check('subtract a hole: area', RegionArea(Region) = 96);
  Check('subtract a hole: points', not RegionContainsPoint(Region, 4, 4) and RegionContainsPoint(Region, 3, 3) and
    RegionContainsPoint(Region, 6, 6) and not RegionContainsPoint(Region, 10, 0));
  AddRectangleToRegion(Region, MakeRectangle(5, 5, 10, 10));
  Check('add overlapping: area', RegionArea(Region) = 96 + 1 + 100 - 25);
  IntersectRegionWithRectangle(Region, MakeRectangle(0, 0, 5, 5));
  Check('intersect: area', RegionArea(Region) = 24);
  SetRegionToRectangle(Region, MakeRectangle(0, 0, 4, 4));
  SetRegionToRectangle(Other, MakeRectangle(2, 2, 4, 4));
  IntersectRegions(Region, Other);
  Check('intersect regions', (RegionArea(Region) = 4) and RectanglesAreEqual(RegionBounds(Region),
    MakeRectangle(2, 2, 2, 2)));
  SetRegionToRectangle(Region, MakeRectangle(0, 0, 4, 4));
  SubtractRegionFromRegion(Region, Other);
  Check('subtract regions', RegionArea(Region) = 12);
end;

{ --- Canvas -------------------------------------------------------------------- }

procedure TestFills;
var
  Surface: TSurface;
  Canvas: TCanvas;
begin
  Surface := NewSurface(20, 20, ColorBlack);
  BeginCanvas(Canvas, Surface);
  FillRectangle(Canvas, MakeRectangle(2, 3, 5, 4), $FFFF0000);
  Check('fill: inside', (GetSurfacePixel(Surface, 2, 3) = $FFFF0000) and (GetSurfacePixel(Surface, 6, 6) = $FFFF0000));
  Check('fill: right and bottom are outside', (GetSurfacePixel(Surface, 7, 6) = ColorBlack) and
    (GetSurfacePixel(Surface, 6, 7) = ColorBlack));
  Check('fill: count', CountPixels(Surface, $FFFF0000) = 20);
  FillRectangle(Canvas, MakeRectangle(-5, -5, 100, 100), $FF00FF00);
  Check('fill: off the surface is clipped', CountPixels(Surface, $FF00FF00) = 400);

  BeginCanvas(Canvas, Surface);
  NarrowCanvasClip(Canvas, MakeRectangle(0, 0, 4, 20));
  FillRectangle(Canvas, MakeRectangle(0, 0, 20, 20), $FF0000FF);
  Check('clip: only inside', CountPixels(Surface, $FF0000FF) = 80);

  BeginCanvas(Canvas, Surface);
  SetCanvasOrigin(Canvas, 5, 6);
  DrawPixel(Canvas, 0, 0, $FFFFFFFF);
  Check('origin', GetSurfacePixel(Surface, 5, 6) = $FFFFFFFF);

  FillRectangle(Canvas, MakeRectangle(-5, -6, 20, 20), ColorBlack);
  DrawRectangleOutline(Canvas, MakeRectangle(-5, -6, 10, 10), $FFFFFFFF);
  Check('outline', (CountPixels(Surface, $FFFFFFFF) = 36) and (GetSurfacePixel(Surface, 9, 9) = $FFFFFFFF) and
    (GetSurfacePixel(Surface, 8, 8) = ColorBlack));
  BeginCanvas(Canvas, Surface);
  FillRectangle(Canvas, MakeRectangle(0, 0, 20, 20), $FFFFFFFF);
  FillRectangle(Canvas, MakeRectangle(0, 0, 1, 1), $80FF0000);
  CheckColor('fill: translucent blends', GetSurfacePixel(Surface, 0, 0), $FFFF7F7F);
  FreeSurface(Surface);
end;

procedure TestLines;
var
  Surface: TSurface;
  Canvas: TCanvas;
  Expected: array[0..5] of TPoint;
  Index: Integer;
  Matches: Boolean;
begin
  Surface := NewSurface(10, 10, ColorBlack);
  BeginCanvas(Canvas, Surface);
  DrawLine(Canvas, 0, 0, 5, 2, ColorWhite);
  Expected[0] := MakePoint(0, 0);
  Expected[1] := MakePoint(1, 0);
  Expected[2] := MakePoint(2, 1);
  Expected[3] := MakePoint(3, 1);
  Expected[4] := MakePoint(4, 2);
  Expected[5] := MakePoint(5, 2);
  Matches := CountPixels(Surface, ColorWhite) = 6;
  for Index := 0 to 5 do
    Matches := Matches and (GetSurfacePixel(Surface, Expected[Index].X, Expected[Index].Y) = ColorWhite);
  Check('line: Bresenham pixels', Matches);
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  DrawLine(Canvas, 5, 2, 0, 0, ColorWhite);
  Matches := CountPixels(Surface, ColorWhite) = 6;
  for Index := 0 to 5 do
    Matches := Matches and (GetSurfacePixel(Surface, Expected[Index].X, Expected[Index].Y) = ColorWhite);
  Check('line: the same pixels backwards', Matches);
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  DrawLine(Canvas, 0, 9, 9, 0, ColorWhite);
  Check('line: diagonal', (CountPixels(Surface, ColorWhite) = 10) and (GetSurfacePixel(Surface, 4, 5) = ColorWhite));
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  DrawLine(Canvas, 3, 3, 3, 3, ColorWhite);
  Check('line: a point', CountPixels(Surface, ColorWhite) = 1);
  FreeSurface(Surface);
end;

procedure TestEllipses;
var
  Surface: TSurface;
  Canvas: TCanvas;
  X: Integer;
  Y: Integer;
  Symmetric: Boolean;
  RowZero: Boolean;
  Filled: Integer;
  OutlineInsideFill: Boolean;
  Fill: TSurface;
begin
  Surface := NewSurface(10, 10, ColorBlack);
  BeginCanvas(Canvas, Surface);
  FillEllipse(Canvas, MakeRectangle(0, 0, 10, 10), ColorWhite);
  Symmetric := True;
  for Y := 0 to 9 do
    for X := 0 to 9 do
      Symmetric := Symmetric and (GetSurfacePixel(Surface, X, Y) = GetSurfacePixel(Surface, 9 - X, Y)) and
        (GetSurfacePixel(Surface, X, Y) = GetSurfacePixel(Surface, X, 9 - Y)) and
        (GetSurfacePixel(Surface, X, Y) = GetSurfacePixel(Surface, Y, X));
  Check('ellipse: symmetric', Symmetric);
  RowZero := True;
  for X := 0 to 9 do
    RowZero := RowZero and ((GetSurfacePixel(Surface, X, 0) = ColorWhite) = ((X >= 3) and (X <= 6)));
  Check('ellipse: top row is pixels 3 to 6', RowZero);
  Check('ellipse: corners out, middle in', (GetSurfacePixel(Surface, 0, 0) = ColorBlack) and
    (GetSurfacePixel(Surface, 5, 5) = ColorWhite) and (GetSurfacePixel(Surface, 0, 5) = ColorWhite));
  Filled := CountPixels(Surface, ColorWhite);
  Fill := NewSurface(10, 10, ColorBlack);
  DrawSurface(Canvas, Surface, SurfaceBounds(Surface), 0, 0, False, 255);
  Move(Surface.Pixels^, Fill.Pixels^, 400);
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  DrawEllipseOutline(Canvas, MakeRectangle(0, 0, 10, 10), ColorWhite);
  OutlineInsideFill := True;
  for Y := 0 to 9 do
    for X := 0 to 9 do
      if GetSurfacePixel(Surface, X, Y) = ColorWhite then
        OutlineInsideFill := OutlineInsideFill and (GetSurfacePixel(Fill, X, Y) = ColorWhite);
  Check('ellipse outline: within the fill, thinner', OutlineInsideFill and
    (CountPixels(Surface, ColorWhite) < Filled) and (GetSurfacePixel(Surface, 5, 5) = ColorBlack) and
    (GetSurfacePixel(Surface, 3, 0) = ColorWhite));
  FreeSurface(Fill);
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  FillEllipse(Canvas, MakeRectangle(-5, -5, 10, 10), ColorWhite);
  Check('ellipse: across the edge is clipped', GetSurfacePixel(Surface, 0, 0) = ColorWhite);
  FreeSurface(Surface);
end;

procedure TestPolygons;
var
  Surface: TSurface;
  Canvas: TCanvas;
  Triangle: array[0..2] of TPoint;
begin
  Surface := NewSurface(12, 12, ColorBlack);
  BeginCanvas(Canvas, Surface);
  Triangle[0] := MakePoint(0, 0);
  Triangle[1] := MakePoint(10, 0);
  Triangle[2] := MakePoint(0, 10);
  FillPolygon(Canvas, Triangle, ColorWhite);
  Check('triangle: pixel centres inside (45)', CountPixels(Surface, ColorWhite) = 45);
  Check('triangle: edge pixels', (GetSurfacePixel(Surface, 8, 0) = ColorWhite) and
    (GetSurfacePixel(Surface, 9, 0) = ColorBlack) and (GetSurfacePixel(Surface, 0, 8) = ColorWhite) and
    (GetSurfacePixel(Surface, 0, 9) = ColorBlack));
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  Triangle[0] := MakePoint(2, 2);
  Triangle[1] := MakePoint(6, 2);
  Triangle[2] := MakePoint(6, 6);
  FillPolygon(Canvas, Triangle, ColorWhite);
  { Rows 2 to 5 from the diagonal to x = 5: 4 + 3 + 2 + 1. }
  Check('triangle 2: area', CountPixels(Surface, ColorWhite) = 10);
  FreeSurface(Surface);
end;

procedure TestCopies;
var
  Surface: TSurface;
  Source: TSurface;
  Canvas: TCanvas;
begin
  Surface := NewSurface(10, 10, ColorWhite);
  Source := NewSurface(4, 4, $80FF0000);
  SetSurfacePixel(Source, 0, 0, $FF00FF00);
  BeginCanvas(Canvas, Surface);
  DrawSurface(Canvas, Source, SurfaceBounds(Source), 2, 2, False, 255);
  CheckColor('copy: replaces', GetSurfacePixel(Surface, 3, 3), $80FF0000);
  CheckColor('copy: its corner', GetSurfacePixel(Surface, 2, 2), $FF00FF00);
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorWhite);
  DrawSurface(Canvas, Source, SurfaceBounds(Source), 2, 2, True, 255);
  CheckColor('blend: half red', GetSurfacePixel(Surface, 3, 3), $FFFF7F7F);
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorWhite);
  DrawSurface(Canvas, Source, MakeRectangle(1, 1, 3, 3), 8, 8, True, 255);
  Check('copy: part, clipped at the edge', (GetSurfacePixel(Surface, 8, 8) = $FFFF7F7F) and
    (GetSurfacePixel(Surface, 9, 9) = $FFFF7F7F) and (CountPixels(Surface, $FFFF7F7F) = 4));
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorWhite);
  DrawSurface(Canvas, Source, SurfaceBounds(Source), 0, 0, True, 0);
  Check('blend: opacity 0 leaves it', CountPixels(Surface, ColorWhite) = 100);
  SetSurfacePixel(Source, 1, 1, $FF123456);
  CopySurfaceSwappingRedAndBlue(Source, Surface);
  CheckColor('copy swapping red and blue', GetSurfacePixel(Surface, 1, 1), $FF563412);
  FreeSurface(Source);
  FreeSurface(Surface);
end;

procedure TestGradients;
var
  Surface: TSurface;
  Canvas: TCanvas;
begin
  Surface := NewSurface(2, 256, ColorBlack);
  BeginCanvas(Canvas, Surface);
  FillVerticalGradient(Canvas, SurfaceBounds(Surface), $FF000000, $FFFFFFFF);
  CheckColor('gradient: top', GetSurfacePixel(Surface, 0, 0), $FF000000);
  CheckColor('gradient: middle', GetSurfacePixel(Surface, 1, 128), $FF808080);
  CheckColor('gradient: bottom', GetSurfacePixel(Surface, 0, 255), $FFFFFFFF);
  FreeSurface(Surface);
  Surface := NewSurface(3, 1, ColorBlack);
  BeginCanvas(Canvas, Surface);
  FillHorizontalGradient(Canvas, SurfaceBounds(Surface), $FF000000, $FFFFFFFF);
  Check('horizontal gradient', (GetSurfacePixel(Surface, 0, 0) = $FF000000) and
    (GetSurfacePixel(Surface, 1, 0) = $FF808080) and (GetSurfacePixel(Surface, 2, 0) = $FFFFFFFF));
  FreeSurface(Surface);
end;

procedure TestBevels;
const
  OuterLight = $FF111111;
  InnerLight = $FF222222;
  InnerShade = $FF333333;
  OuterShade = $FF444444;
var
  Surface: TSurface;
  Canvas: TCanvas;
  Colors: TBevelColors;
begin
  Surface := NewSurface(10, 10, ColorBlack);
  BeginCanvas(Canvas, Surface);
  Colors := RaisedBevel(InnerLight, OuterLight, InnerShade, OuterShade);
  DrawBevel(Canvas, SurfaceBounds(Surface), Colors);
  CheckColor('bevel: top left', GetSurfacePixel(Surface, 0, 0), OuterLight);
  CheckColor('bevel: top right is shade', GetSurfacePixel(Surface, 9, 0), OuterShade);
  CheckColor('bevel: bottom left is shade', GetSurfacePixel(Surface, 0, 9), OuterShade);
  CheckColor('bevel: top edge', GetSurfacePixel(Surface, 5, 0), OuterLight);
  CheckColor('bevel: inner top left', GetSurfacePixel(Surface, 1, 1), InnerLight);
  CheckColor('bevel: inner right', GetSurfacePixel(Surface, 8, 5), InnerShade);
  CheckColor('bevel: inside untouched', GetSurfacePixel(Surface, 2, 2), ColorBlack);
  Colors := SunkenBevel(InnerLight, OuterLight, InnerShade, OuterShade);
  Check('sunken: the other way round', (Colors.OuterLight = InnerShade) and (Colors.OuterShade = InnerLight));
  FillRectangle(Canvas, SurfaceBounds(Surface), ColorBlack);
  DrawFocusFrame(Canvas, SurfaceBounds(Surface), ColorWhite);
  Check('focus frame: dots', (GetSurfacePixel(Surface, 0, 0) = ColorWhite) and
    (GetSurfacePixel(Surface, 1, 0) = ColorBlack) and (GetSurfacePixel(Surface, 2, 0) = ColorWhite) and
    (GetSurfacePixel(Surface, 0, 1) = ColorBlack) and (GetSurfacePixel(Surface, 0, 2) = ColorWhite) and
    (CountPixels(Surface, ColorWhite) = 18));
  FreeSurface(Surface);
end;

{ --- Fonts --------------------------------------------------------------------- }

function ReadFileBytes(Path: string; out Data: TBytes): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  Data := nil;
  if not FileExists(Path) then
    Exit;
  Stream := TFileStream.Create(Path, fmOpenRead);
  try
    SetLength(Data, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Data[0], Stream.Size);
    Result := True;
  finally
    Stream.Free;
  end;
end;

function LoadFace(Directory, Name: string; out Face: TFontFace): Boolean;
var
  Data: TBytes;
begin
  Result := ReadFileBytes(IncludeTrailingPathDelimiter(Directory) + Name, Data) and (Length(Data) > 0) and
    ParsePsfFont(@Data[0], Length(Data), Face);
end;

{ A PSF1 font made here: 256 glyphs of 2 rows, glyph N's rows N and
  255 - N; a table giving glyph 1 to U+263A and U+263B, and glyph 2 a
  sequence to skip, then 'B'. }
procedure TestSyntheticFont;
var
  Data: TBytes;
  Face: TFontFace;
  Position: Integer;
  Glyph: Integer;

  procedure Put16(Value: Word);
  begin
    Data[Position] := Byte(Value);
    Data[Position + 1] := Byte(Value shr 8);
    Inc(Position, 2);
  end;

begin
  SetLength(Data, 4 + 512 + 256 * 2 + 32);
  Data[0] := $36;
  Data[1] := $04;
  Data[2] := $02;
  Data[3] := 2;
  for Glyph := 0 to 255 do
  begin
    Data[4 + Glyph * 2] := Glyph;
    Data[5 + Glyph * 2] := 255 - Glyph;
  end;
  Position := 4 + 512;
  Put16($FFFF);
  Put16($263A);
  Put16($263B);
  Put16($FFFF);
  Put16($FFFE);
  Put16($0041);
  Put16($0301);
  Put16($FFFF);
  for Glyph := 3 to 255 do
    Put16($FFFF);
  SetLength(Data, Position);
  Check('PSF1: parsed', ParsePsfFont(@Data[0], Length(Data), Face) and (Face.Width = 8) and (Face.Height = 2) and
    (Face.GlyphCount = 256));
  Check('PSF1: table', (GlyphFor(Face, $263A) = 1) and (GlyphFor(Face, $263B) = 1) and
    not HasGlyphFor(Face, $41) and not HasGlyphFor(Face, $0301));
  Check('PSF1: rows', (GlyphRow(Face, 7, 0)^ = 7) and (GlyphRow(Face, 7, 1)^ = 248));
  Check('PSF1: truncated is refused', not ParsePsfFont(@Data[0], 100, Face));
end;

{ Draws CodePoint and compares every pixel with the glyph's bits. }
function GlyphDrawsExactly(const Face: TFontFace; CodePoint: LongWord): Boolean;
var
  Surface: TSurface;
  Canvas: TCanvas;
  Row: Integer;
  Column: Integer;
  Bits: PByte;
  Expected: TColor;
begin
  Surface := NewSurface(Face.Width + 2, Face.Height + 2, ColorBlack);
  BeginCanvas(Canvas, Surface);
  Result := DrawCharacter(Canvas, Face, 1, 1, CodePoint, ColorWhite) = Face.Width;
  for Row := 0 to Face.Height - 1 do
  begin
    Bits := GlyphRow(Face, GlyphFor(Face, CodePoint), Row);
    for Column := 0 to Face.Width - 1 do
    begin
      if (Bits[Column div 8] and ($80 shr (Column mod 8))) <> 0 then
        Expected := ColorWhite
      else
        Expected := ColorBlack;
      Result := Result and (GetSurfacePixel(Surface, Column + 1, Row + 1) = Expected);
    end;
  end;
  Result := Result and (CountPixels(Surface, ColorWhite) > 0);
  { The border stays clear. }
  for Column := 0 to Surface.Width - 1 do
    Result := Result and (GetSurfacePixel(Surface, Column, 0) = ColorBlack) and
      (GetSurfacePixel(Surface, Column, Surface.Height - 1) = ColorBlack);
  FreeSurface(Surface);
end;

procedure TestTerminus(Directory: string);
var
  Face: TFontFace;
  FontSet: TFontSet;
  Height: Integer;
  Selected: PFontFace;
  Name: string;
begin
  Check('PSF1 Terminus 8x16 loads', LoadFace(Directory, 'ter-v16n.psf', Face) and (Face.Width = 8) and
    (Face.Height = 16) and (Face.GlyphCount = 512));
  Check('8x16: A drawn exactly', GlyphDrawsExactly(Face, Ord('A')));
  Check('8x16: e acute drawn exactly', HasGlyphFor(Face, $E9) and GlyphDrawsExactly(Face, $E9));
  Check('8x16: euro sign', HasGlyphFor(Face, $20AC));
  Check('measure: ASCII', MeasureText(Face, 'Hello') = 40);
  Check('measure: UTF-8 counts characters', MeasureText(Face, 'caf'#$C3#$A9) = 32);
  Check('measure: control characters take no room', MeasureText(Face, 'a'#9'b') = 16);
  Check('PSF2 Terminus 12x24 loads', LoadFace(Directory, 'ter-v24n.psf', Face) and (Face.Width = 12) and
    (Face.Height = 24));
  Check('12x24: W drawn exactly (two bytes a row)', GlyphDrawsExactly(Face, Ord('W')));
  Check('12x24: a missing character draws the fallback', GlyphFor(Face, $1F600) = Face.FallbackGlyph);

  FontSet.Count := 0;
  for Height in [12, 14, 16, 18, 20, 22, 24, 28, 32] do
  begin
    for Name in ['n', 'b'] do
      if LoadFace(Directory, 'ter-v' + IntToStr(Height) + Name + '.psf', Face) then
      begin
        Face.Bold := Name = 'b';
        AddFace(FontSet, Face);
      end;
  end;
  Check('font set: 17 faces (no bold 12)', FontSet.Count = 17);
  Check('pixel heights', (PixelHeightFor(90, 96) = 12) and (PixelHeightFor(120, 96) = 16) and
    (PixelHeightFor(120, 144) = 24) and (PixelHeightFor(100, 96) = 13));
  Selected := SelectFace(FontSet, 90, 96, False);
  Check('9 points at 96 DPI: 12 pixels', (Selected <> nil) and (Selected^.Height = 12));
  Selected := SelectFace(FontSet, 100, 96, False);
  Check('10 points at 96 DPI: 12 pixels (not taller than asked)', (Selected <> nil) and (Selected^.Height = 12));
  Selected := SelectFace(FontSet, 120, 144, False);
  Check('12 points at 144 DPI: 24 pixels', (Selected <> nil) and (Selected^.Height = 24));
  Selected := SelectFace(FontSet, 60, 96, False);
  Check('too small: the smallest face', (Selected <> nil) and (Selected^.Height = 12));
  Selected := SelectFace(FontSet, 90, 96, True);
  Check('bold 9 points: smallest bold (14)', (Selected <> nil) and Selected^.Bold and (Selected^.Height = 14));
  Selected := SelectFace(FontSet, 240, 192, True);
  Check('bold 24 points at 192 DPI: 32 pixels', (Selected <> nil) and Selected^.Bold and (Selected^.Height = 32));
end;

procedure TestUtf8;
var
  Text: PChar;
  CodePoint: LongWord;
  Got: array of LongWord;
  Count: Integer;

  procedure Decode(Source: PChar);
  begin
    Count := 0;
    SetLength(Got, 16);
    Text := Source;
    while NextCharacter(Text, CodePoint) do
    begin
      Got[Count] := CodePoint;
      Inc(Count);
    end;
  end;

begin
  Decode('a'#$E2#$82#$AC'b');
  Check('UTF-8: euro', (Count = 3) and (Got[1] = $20AC));
  Decode(#$C3#$28);
  Check('UTF-8: bad continuation', (Count = 2) and (Got[0] = ReplacementCharacter) and (Got[1] = Ord('(')));
  Decode(#$E2#$82);
  Check('UTF-8: cut short at the end is one replacement', (Count = 1) and (Got[0] = ReplacementCharacter));
  Decode(#$E2#$82'x');
  Check('UTF-8: cut short, then more', (Count = 2) and (Got[0] = ReplacementCharacter) and (Got[1] = Ord('x')));
  Decode(#$C0#$80);
  Check('UTF-8: overlong', (Count = 1) and (Got[0] = ReplacementCharacter));
  Decode(#$ED#$A0#$80);
  Check('UTF-8: surrogate', (Count = 1) and (Got[0] = ReplacementCharacter));
  Decode(#$F0#$9F#$98#$80);
  Check('UTF-8: four bytes', (Count = 1) and (Got[0] = $1F600));
  Check('UTF-8: count', CharacterCount('h'#$C3#$A9'llo') = 5);
end;

{ --- A sample picture ------------------------------------------------------------ }

procedure WriteSample(Directory, Path: string);
const
  Face3D = $FFC8C4BC;
  Highlight = $FFFFFFFF;
  Shadow = $FF7C786F;
  DarkShadow = $FF34312C;
var
  Surface: TSurface;
  Canvas: TCanvas;
  Face: TFontFace;
  Bold: TFontFace;
  Output: TFileStream;
  Header: string;
  X: Integer;
  Y: Integer;
  Pixel: TColor;
  Triangle: array[0..2] of TPoint;
  Line: array of Byte;
begin
  Surface := NewSurface(320, 200, $FF3A6EA5);
  BeginCanvas(Canvas, Surface);
  FillRectangle(Canvas, MakeRectangle(20, 20, 280, 160), Face3D);
  DrawBevel(Canvas, MakeRectangle(20, 20, 280, 160), RaisedBevel(Highlight, Face3D, Shadow, DarkShadow));
  FillHorizontalGradient(Canvas, MakeRectangle(23, 23, 274, 18), $FF1C3F6E, $FF7FA6D6);
  if LoadFace(Directory, 'ter-v16b.psf', Bold) then
    DrawText(Canvas, Bold, 28, 24, 'Sample window', ColorWhite);
  FillRectangle(Canvas, MakeRectangle(40, 60, 120, 24), ColorWhite);
  DrawBevel(Canvas, MakeRectangle(40, 60, 120, 24), SunkenBevel(Highlight, Face3D, Shadow, DarkShadow));
  if LoadFace(Directory, 'ter-v16n.psf', Face) then
    DrawText(Canvas, Face, 45, 64, 'caf'#$C3#$A9' '#$E2#$82#$AC'5', ColorBlack);
  DrawBevel(Canvas, MakeRectangle(200, 140, 80, 26), RaisedBevel(Highlight, Face3D, Shadow, DarkShadow));
  DrawText(Canvas, Face, 224, 145, 'OK', ColorBlack);
  DrawFocusFrame(Canvas, MakeRectangle(204, 144, 72, 18), ColorBlack);
  FillEllipse(Canvas, MakeRectangle(180, 60, 40, 30), $C0D04040);
  DrawEllipseOutline(Canvas, MakeRectangle(180, 60, 40, 30), ColorBlack);
  Triangle[0] := MakePoint(240, 60);
  Triangle[1] := MakePoint(290, 70);
  Triangle[2] := MakePoint(250, 120);
  FillPolygon(Canvas, Triangle, $8040A040);
  DrawLine(Canvas, 40, 100, 160, 130, ColorBlack);
  Output := TFileStream.Create(Path, fmCreate);
  try
    Header := 'P6' + #10 + IntToStr(Surface.Width) + ' ' + IntToStr(Surface.Height) + #10 + '255' + #10;
    Output.WriteBuffer(Header[1], Length(Header));
    SetLength(Line, Surface.Width * 3);
    for Y := 0 to Surface.Height - 1 do
    begin
      for X := 0 to Surface.Width - 1 do
      begin
        Pixel := GetSurfacePixel(Surface, X, Y);
        Line[X * 3] := RedOf(Pixel);
        Line[X * 3 + 1] := GreenOf(Pixel);
        Line[X * 3 + 2] := BlueOf(Pixel);
      end;
      Output.WriteBuffer(Line[0], Length(Line));
    end;
  finally
    Output.Free;
  end;
  FreeSurface(Surface);
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: DrawingTest <font-directory> [sample.ppm]');
    Halt(2);
  end;
  TestColors;
  TestRectangles;
  TestRegions;
  TestFills;
  TestLines;
  TestEllipses;
  TestPolygons;
  TestCopies;
  TestGradients;
  TestBevels;
  TestSyntheticFont;
  TestTerminus(ParamStr(1));
  TestUtf8;
  if ParamCount >= 2 then
    WriteSample(ParamStr(1), ParamStr(2));
  WriteLn('[drawing] ', Checks - Failures, ' of ', Checks, ' checks passed');
  if Failures > 0 then
    Halt(1);
end.
