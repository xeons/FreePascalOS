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
  Zoom: how the picture's pixels map to the view's.

  A zoom is in thousandths (1000 is actual size: one image pixel to one
  pixel of the display, whatever its scale), from 125 (12.5%) to 8000
  (800%), stepping through ZoomLevels. The view shows the zoomed picture
  from Origin (where its top left is when not scrolled, a small margin
  into the view) scrolled by Scroll, both in view pixels. Image pixel P
  starts at view pixel P * Zoom / 1000 (rounded down), less the scroll,
  plus the origin; a view pixel shows the image pixel under its top
  left. Image coordinates are continuous (pixel P is [P, P + 1)), so
  tools get fractions at high zoom.

  The grid between pixels shows from 400%, when a pixel is four view
  pixels across or more.
}
unit Paint.ZoomMapping;

{$mode objfpc}
{$H+}

interface

const
  ActualSizeZoom = 1000;
  SmallestZoom = 125;
  LargestZoom = 8000;
  SmallestGridZoom = 4000;
  ZoomLevelCount = 11;
  ZoomLevels: array[0..ZoomLevelCount - 1] of LongInt = (125, 250, 333, 500, 667, 1000, 2000, 3000, 4000, 6000,
    8000);

type
  TViewMapping = record
    Zoom: LongInt;
    OriginX: LongInt;
    OriginY: LongInt;
    ScrollX: LongInt;
    ScrollY: LongInt;
  end;

function MakeViewMapping(Zoom, OriginX, OriginY, ScrollX, ScrollY: LongInt): TViewMapping;
{ The next level in, or out, from Zoom (Zoom itself at the end). }
function ZoomedIn(Zoom: LongInt): LongInt;
function ZoomedOut(Zoom: LongInt): LongInt;
{ Zoom kept within the smallest and largest. }
function ClampZoom(Zoom: LongInt): LongInt;
{ "12.5%", "100%", "33.3%". }
function ZoomText(Zoom: LongInt): string;
{ A length of Length image pixels at Zoom, in view pixels (rounded down,
  at least 1 for a length of at least 1). }
function ZoomedLength(Length, Zoom: LongInt): LongInt;
{ Where image coordinate Image (continuous) is in the view, and back. }
function ImageToViewX(const Mapping: TViewMapping; ImageX: Double): Double;
function ImageToViewY(const Mapping: TViewMapping; ImageY: Double): Double;
function ViewToImageX(const Mapping: TViewMapping; ViewX: Double): Double;
function ViewToImageY(const Mapping: TViewMapping; ViewY: Double): Double;
{ The first view pixel of image pixel column (or row) Pixel. }
function PixelStartX(const Mapping: TViewMapping; Pixel: LongInt): LongInt;
function PixelStartY(const Mapping: TViewMapping; Pixel: LongInt): LongInt;
{ The image pixel a view pixel shows (may be outside the image). }
function ImageColumnAt(const Mapping: TViewMapping; ViewX: LongInt): LongInt;
function ImageRowAt(const Mapping: TViewMapping; ViewY: LongInt): LongInt;
{ The scroll that keeps image coordinate ImageX under view pixel ViewX
  after zooming to NewZoom (for zooming at the pointer). }
function ScrollKeepingPoint(ImageX: Double; ViewX, Origin, NewZoom: LongInt): LongInt;
{ Scroll kept within 0 and how far the content (Content view pixels,
  margins included) reaches past a view of Visible pixels. }
function ClampScroll(Scroll, Content, Visible: LongInt): LongInt;
function GridShows(Zoom: LongInt): Boolean;

implementation

uses
  SysUtils,
  Math;

function MakeViewMapping(Zoom, OriginX, OriginY, ScrollX, ScrollY: LongInt): TViewMapping;
begin
  Result.Zoom := Zoom;
  Result.OriginX := OriginX;
  Result.OriginY := OriginY;
  Result.ScrollX := ScrollX;
  Result.ScrollY := ScrollY;
end;

function ClampZoom(Zoom: LongInt): LongInt;
begin
  Result := EnsureRange(Zoom, SmallestZoom, LargestZoom);
end;

function ZoomedIn(Zoom: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to ZoomLevelCount - 1 do
    if ZoomLevels[Index] > Zoom then
      Exit(ZoomLevels[Index]);
  Result := ClampZoom(Zoom);
end;

function ZoomedOut(Zoom: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := ZoomLevelCount - 1 downto 0 do
    if ZoomLevels[Index] < Zoom then
      Exit(ZoomLevels[Index]);
  Result := ClampZoom(Zoom);
end;

function ZoomText(Zoom: LongInt): string;
begin
  if Zoom mod 10 = 0 then
    Result := IntToStr(Zoom div 10) + '%'
  else
    Result := IntToStr(Zoom div 10) + '.' + IntToStr(Zoom mod 10) + '%';
end;

function ZoomedLength(Length, Zoom: LongInt): LongInt;
begin
  Result := LongInt((Int64(Length) * Zoom) div ActualSizeZoom);
  if (Result < 1) and (Length >= 1) then
    Result := 1;
end;

function ImageToViewX(const Mapping: TViewMapping; ImageX: Double): Double;
begin
  Result := ImageX * Mapping.Zoom / ActualSizeZoom - Mapping.ScrollX + Mapping.OriginX;
end;

function ImageToViewY(const Mapping: TViewMapping; ImageY: Double): Double;
begin
  Result := ImageY * Mapping.Zoom / ActualSizeZoom - Mapping.ScrollY + Mapping.OriginY;
end;

function ViewToImageX(const Mapping: TViewMapping; ViewX: Double): Double;
begin
  Result := (ViewX - Mapping.OriginX + Mapping.ScrollX) * ActualSizeZoom / Mapping.Zoom;
end;

function ViewToImageY(const Mapping: TViewMapping; ViewY: Double): Double;
begin
  Result := (ViewY - Mapping.OriginY + Mapping.ScrollY) * ActualSizeZoom / Mapping.Zoom;
end;

{ Floor division of a possibly negative numerator. }
function FloorDivide(Numerator: Int64; Denominator: Int64): LongInt;
begin
  if Numerator >= 0 then
    Result := LongInt(Numerator div Denominator)
  else
    Result := LongInt(-((-Numerator + Denominator - 1) div Denominator));
end;

function PixelStartX(const Mapping: TViewMapping; Pixel: LongInt): LongInt;
begin
  Result := FloorDivide(Int64(Pixel) * Mapping.Zoom, ActualSizeZoom) - Mapping.ScrollX + Mapping.OriginX;
end;

function PixelStartY(const Mapping: TViewMapping; Pixel: LongInt): LongInt;
begin
  Result := FloorDivide(Int64(Pixel) * Mapping.Zoom, ActualSizeZoom) - Mapping.ScrollY + Mapping.OriginY;
end;

{ The image pixel under the top left of zoomed position Zoomed. }
function PixelAtZoomed(Zoomed: Int64; Zoom: LongInt): LongInt;
begin
  Result := FloorDivide(Zoomed * ActualSizeZoom, Zoom);
end;

function ImageColumnAt(const Mapping: TViewMapping; ViewX: LongInt): LongInt;
begin
  Result := PixelAtZoomed(Int64(ViewX) - Mapping.OriginX + Mapping.ScrollX, Mapping.Zoom);
end;

function ImageRowAt(const Mapping: TViewMapping; ViewY: LongInt): LongInt;
begin
  Result := PixelAtZoomed(Int64(ViewY) - Mapping.OriginY + Mapping.ScrollY, Mapping.Zoom);
end;

function ScrollKeepingPoint(ImageX: Double; ViewX, Origin, NewZoom: LongInt): LongInt;
begin
  Result := Round(ImageX * NewZoom / ActualSizeZoom) - ViewX + Origin;
end;

function ClampScroll(Scroll, Content, Visible: LongInt): LongInt;
begin
  if Content <= Visible then
    Exit(0);
  Result := EnsureRange(Scroll, 0, Content - Visible);
end;

function GridShows(Zoom: LongInt): Boolean;
begin
  Result := Zoom >= SmallestGridZoom;
end;

end.
