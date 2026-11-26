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
  Gaussian blurs approximated by three box blurs in a row, as Filter
  Effects' feGaussianBlur allows: a box of d = floor(s * 3 sqrt(2 pi) / 4
  + 0.5) pixels for a standard deviation s (three of d when d is odd;
  two of d and one of d + 1 when it is even), each a running sum along
  the rows and then the columns, so the cost does not grow with the
  radius. Pixels beyond the plane count as zero (transparent), so a
  plane for a shadow or a blurred layer needs BlurMargin pixels of room
  on every side.
}
unit Drawing.Blurring;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors;

type
  TBlurPlane = array of Byte;

{ How far a blur of standard deviation Sigma spreads (pixels, each side). }
function BlurMargin(Sigma: Double): LongInt;
{ Plane (Width x Height bytes, row by row) blurred in place, Sigma
  pixels across and down (either may be 0: no blur that way). }
procedure BlurPlane(var Plane: TBlurPlane; Width, Height: LongInt; SigmaX, SigmaY: Double);
{ Count colours (not premultiplied, Width x Height row by row) blurred
  in place: premultiplied, every channel blurred, then divided again. }
procedure BlurColors(Pixels: PLongWord; Width, Height: LongInt; Sigma: Double);

implementation

uses
  Math;

function BoxSize(Sigma: Double): LongInt;
begin
  if Sigma <= 0 then
    Exit(0);
  Result := Floor(Sigma * 3 * Sqrt(2 * Pi) / 4 + 0.5);
end;

function BlurMargin(Sigma: Double): LongInt;
begin
  Result := (BoxSize(Sigma) * 3) div 2 + 2;
end;

{ One box blur along a line of Count values Stride apart: each value
  becomes the mean of the Size values from Offset before it. Scratch
  holds Count values. }
procedure BoxLine(Data: PByte; Count, Stride, Size, Offset: LongInt; var Scratch: array of Byte);
var
  Index, Sum, Entering, Leaving: LongInt;
begin
  for Index := 0 to Count - 1 do
    Scratch[Index] := Data[Index * Stride];
  Sum := 0;
  { The window for value I covers I - Offset .. I - Offset + Size - 1. }
  for Index := -Offset to -Offset + Size - 2 do
    if (Index >= 0) and (Index < Count) then
      Inc(Sum, Scratch[Index]);
  for Index := 0 to Count - 1 do
  begin
    Entering := Index - Offset + Size - 1;
    if (Entering >= 0) and (Entering < Count) then
      Inc(Sum, Scratch[Entering]);
    Data[Index * Stride] := (Sum + Size div 2) div Size;
    Leaving := Index - Offset;
    if (Leaving >= 0) and (Leaving < Count) then
      Dec(Sum, Scratch[Leaving]);
  end;
end;

{ The three boxes along every row (Horizontal) or column. }
procedure BlurDirection(var Plane: TBlurPlane; Width, Height: LongInt; Sigma: Double; Horizontal: Boolean);
var
  Size, Line, Lines, Count, Stride: LongInt;
  Scratch: array of Byte;
  Start: PByte;
begin
  Size := BoxSize(Sigma);
  if Size < 2 then
    Exit;
  if Horizontal then
  begin
    Lines := Height;
    Count := Width;
    Stride := 1;
  end
  else
  begin
    Lines := Width;
    Count := Height;
    Stride := Width;
  end;
  Scratch := nil;
  SetLength(Scratch, Count);
  for Line := 0 to Lines - 1 do
  begin
    if Horizontal then
      Start := @Plane[Line * Width]
    else
      Start := @Plane[Line];
    if Odd(Size) then
    begin
      BoxLine(Start, Count, Stride, Size, Size div 2, Scratch);
      BoxLine(Start, Count, Stride, Size, Size div 2, Scratch);
      BoxLine(Start, Count, Stride, Size, Size div 2, Scratch);
    end
    else
    begin
      BoxLine(Start, Count, Stride, Size, Size div 2, Scratch);
      BoxLine(Start, Count, Stride, Size, Size div 2 - 1, Scratch);
      BoxLine(Start, Count, Stride, Size + 1, Size div 2, Scratch);
    end;
  end;
end;

procedure BlurPlane(var Plane: TBlurPlane; Width, Height: LongInt; SigmaX, SigmaY: Double);
begin
  if (Width <= 0) or (Height <= 0) then
    Exit;
  BlurDirection(Plane, Width, Height, SigmaX, True);
  BlurDirection(Plane, Width, Height, SigmaY, False);
end;

procedure BlurColors(Pixels: PLongWord; Width, Height: LongInt; Sigma: Double);
var
  Alpha, Red, Green, Blue: TBlurPlane;
  Index, Count: LongInt;
  Color: TColor;
  A: LongWord;
begin
  if (Width <= 0) or (Height <= 0) or (BoxSize(Sigma) < 2) then
    Exit;
  Count := Width * Height;
  Alpha := nil;
  Red := nil;
  Green := nil;
  Blue := nil;
  SetLength(Alpha, Count);
  SetLength(Red, Count);
  SetLength(Green, Count);
  SetLength(Blue, Count);
  for Index := 0 to Count - 1 do
  begin
    Color := Pixels[Index];
    A := AlphaOf(Color);
    Alpha[Index] := A;
    Red[Index] := (RedOf(Color) * A + 127) div 255;
    Green[Index] := (GreenOf(Color) * A + 127) div 255;
    Blue[Index] := (BlueOf(Color) * A + 127) div 255;
  end;
  BlurPlane(Alpha, Width, Height, Sigma, Sigma);
  BlurPlane(Red, Width, Height, Sigma, Sigma);
  BlurPlane(Green, Width, Height, Sigma, Sigma);
  BlurPlane(Blue, Width, Height, Sigma, Sigma);
  for Index := 0 to Count - 1 do
  begin
    A := Alpha[Index];
    if A = 0 then
      Pixels[Index] := ColorTransparent
    else
      Pixels[Index] := ArgbColor(A, Min(255, (Red[Index] * 255 + A div 2) div A),
        Min(255, (Green[Index] * 255 + A div 2) div A), Min(255, (Blue[Index] * 255 + A div 2) div A));
  end;
end;

end.
