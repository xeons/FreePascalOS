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
  Box shadow masks: the coverage of a box's shadow (CSS Backgrounds 3,
  box-shadow), blurred, and kept for the next paint.

  The mask covers the shadow's area: its rounded rectangle (the box
  moved by the offset, grown or shrunk by the spread) is blurred with
  three box blurs of half the blur radius (close to the Gaussian the
  specification asks for), then cut by the box: an outer shadow shows
  only outside the box, an inset one only inside it, where it is the
  blurred coverage of everything around the shrunk shape.

  Everything is given relative to the mask's top left, so a shadow
  drawn again at a whole pixel offset (scrolled) finds the same mask.
  Masks are kept in a cache of a few megabytes, least recently used
  ones dropped first.
}
unit Web.Paint.ShadowCache;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Drawing.SmoothRoundedRectangles;

type
  { A shadow mask's geometry, device pixels: the key it is kept by. }
  TShadowGeometry = packed record
    { The mask's size, and the margin it has around the shadow's area. }
    Width, Height, Margin: LongInt;
    { The box, from the mask's top left. }
    BoxLeft, BoxTop, BoxRight, BoxBottom: Double;
    OffsetX, OffsetY, Spread: Double;
    { The box blur's radius. }
    BlurRadius: LongInt;
    Radii: TCornerRadii;
    Inset: Boolean;
  end;

{ The shadow's mask (Width x Height coverage bytes, row by row), from the
  cache or made now; owned by the cache, good until the next call. nil
  when it is too big to make. }
function ShadowMask(const Geometry: TShadowGeometry): PByte;

implementation

uses
  Math, Drawing.Rectangles, Drawing.Rasterizer, Web.Paint.PaintCaches;

const
  ShadowCacheBytes = 32 * 1024 * 1024;
  { The largest mask made (pixels). }
  MaximumMaskPixels = 16 * 1024 * 1024;

var
  Cache: TPaintCache = nil;

{ Values div Divisor, as a multiplication: Reciprocal = 2^40 / Divisor
  rounded up is exact for the sums of a box blur (below 2^20). }
const
  ReciprocalShift = 40;

function ReciprocalOf(Divisor: LongInt): QWord;
begin
  Result := (QWord(1) shl ReciprocalShift + QWord(Divisor) - 1) div QWord(Divisor);
end;

{ Three box blurs of Radius along the rows, then the columns; values
  past the edges count as 0 (the window is always 2 Radius + 1). }
procedure BoxBlur(Mask: PByte; Width, Height, Radius: LongInt);
var
  Temporary: array of Byte;
  X, Y, Sum, Pass: LongInt;
  Reciprocal: QWord;
  Line: PByte;
begin
  if Radius <= 0 then
    Exit;
  Reciprocal := ReciprocalOf(2 * Radius + 1);
  Temporary := nil;
  SetLength(Temporary, Width * Height);
  for Pass := 1 to 3 do
  begin
    for Y := 0 to Height - 1 do
    begin
      Line := @Mask[Y * Width];
      Sum := 0;
      for X := 0 to Min(Radius, Width - 1) do
        Inc(Sum, Line[X]);
      for X := 0 to Width - 1 do
      begin
        Temporary[Y * Width + X] := (QWord(Sum) * Reciprocal) shr ReciprocalShift;
        if X - Radius >= 0 then
          Dec(Sum, Line[X - Radius]);
        if X + Radius + 1 < Width then
          Inc(Sum, Line[X + Radius + 1]);
      end;
    end;
    for X := 0 to Width - 1 do
    begin
      Sum := 0;
      for Y := 0 to Min(Radius, Height - 1) do
        Inc(Sum, Temporary[Y * Width + X]);
      for Y := 0 to Height - 1 do
      begin
        Mask[Y * Width + X] := (QWord(Sum) * Reciprocal) shr ReciprocalShift;
        if Y - Radius >= 0 then
          Dec(Sum, Temporary[(Y - Radius) * Width + X]);
        if Y + Radius + 1 < Height then
          Inc(Sum, Temporary[(Y + Radius + 1) * Width + X]);
      end;
    end;
  end;
end;

procedure MakeShadowMask(const Geometry: TShadowGeometry; Mask: PByte);
var
  Shape, BoxShape: TCoverageShape;
  Area: TRectangle;
  BoxMask, ShadowCoverage: array of Byte;
  ShadowRadii: TCornerRadii;
  Index, Count, Corner: LongInt;
begin
  Count := Geometry.Width * Geometry.Height;
  Area := MakeRectangle(0, 0, Geometry.Width, Geometry.Height);
  with Geometry do
  begin
    BeginShape(BoxShape);
    AddShapeRoundedRectangleCorners(BoxShape, BoxLeft, BoxTop, BoxRight, BoxBottom, Radii, True);
    BoxMask := nil;
    SetLength(BoxMask, Count);
    ShapeCoverage(BoxShape, Area, BoxMask);
    BeginShape(Shape);
    if Inset then
    begin
      { The box minus the shadow's shape inside it. }
      AddShapeRoundedRectangleCorners(Shape, -Margin, -Margin, Width + Margin, Height + Margin,
        Default(TCornerRadii), True);
      AddShapeRoundedRectangleCorners(Shape, BoxLeft + OffsetX + Spread, BoxTop + OffsetY + Spread,
        BoxRight + OffsetX - Spread, BoxBottom + OffsetY - Spread, Radii, False);
    end
    else
    begin
      ShadowRadii := Radii;
      for Corner := 0 to 3 do
      begin
        ShadowRadii[Corner].X := Max(0, Radii[Corner].X + Spread);
        ShadowRadii[Corner].Y := Max(0, Radii[Corner].Y + Spread);
      end;
      AddShapeRoundedRectangleCorners(Shape, BoxLeft + OffsetX - Spread, BoxTop + OffsetY - Spread,
        BoxRight + OffsetX + Spread, BoxBottom + OffsetY + Spread, ShadowRadii, True);
    end;
    ShadowCoverage := nil;
    SetLength(ShadowCoverage, Count);
    ShapeCoverage(Shape, Area, ShadowCoverage);
    Move(ShadowCoverage[0], Mask^, Count);
    BoxBlur(Mask, Width, Height, BlurRadius);
    if Inset then
      for Index := 0 to Count - 1 do
        Mask[Index] := (LongWord(Mask[Index]) * BoxMask[Index]) div 255
    else
      for Index := 0 to Count - 1 do
        Mask[Index] := (LongWord(Mask[Index]) * (255 - BoxMask[Index])) div 255;
  end;
end;

function ShadowMask(const Geometry: TShadowGeometry): PByte;
var
  Entry: PPaintCacheEntry;
  Count: PtrUInt;
begin
  Result := nil;
  if (Geometry.Width <= 0) or (Geometry.Height <= 0) or
     (Int64(Geometry.Width) * Geometry.Height > MaximumMaskPixels) then
    Exit;
  if Cache = nil then
    Cache := TPaintCache.Create(ShadowCacheBytes);
  Entry := Cache.Find(Geometry, SizeOf(Geometry));
  if Entry <> nil then
    Exit(PByte(Entry^.Data));
  Count := PtrUInt(Geometry.Width) * PtrUInt(Geometry.Height);
  Result := GetMem(Count);
  if Result = nil then
    Exit;
  MakeShadowMask(Geometry, Result);
  { The largest mask fits in the cache: adding it drops older ones only. }
  Cache.Add(Geometry, SizeOf(Geometry), Result, Count, Geometry.Width, Geometry.Height);
end;

finalization
  Cache.Free;
end.
