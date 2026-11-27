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
{$pointermath on}

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

const
  { Bits of the fixed-point reciprocal of a box's size. }
  ReciprocalShift = 54;

{ 2^ReciprocalShift / Size rounded up. A box's sum (plus half of Size
  for rounding) is below 2^8 x Size; times this it errs by under
  2^8 x Size x Size / 2^ReciprocalShift, less than one for any Size
  below 2^23, so shifted down it is the mean exactly, with a multiply
  in place of a division. }
function ReciprocalOfSize(Size: LongInt): QWord;
begin
  Result := (QWord(1) shl ReciprocalShift + LongWord(Size) - 1) div LongWord(Size);
end;

{ One box blur along a row of Count values: each value becomes the mean
  of the Size values from Offset before it, rounded. Scratch has room
  for Count values with Size + 1 zeros either side (values beyond the
  row count as zero), so the window's ends need no checks. }
procedure BoxRow(Data: PByte; Count, Size, Offset: LongInt; Scratch: PByte);
var
  Index, Sum: LongInt;
  Reciprocal: QWord;
  Entering, Leaving: PByte;
begin
  Move(Data^, Scratch^, Count);
  Reciprocal := ReciprocalOfSize(Size);
  Sum := 0;
  { The window for value I covers I - Offset .. I - Offset + Size - 1. }
  for Index := -Offset to -Offset + Size - 2 do
    Inc(Sum, Scratch[Index]);
  Entering := Scratch - Offset + Size - 1;
  Leaving := Scratch - Offset;
  for Index := 0 to Count - 1 do
  begin
    Inc(Sum, Entering[Index]);
    Data[Index] := Byte((QWord(Sum + Size div 2) * Reciprocal) shr ReciprocalShift);
    Dec(Sum, Leaving[Index]);
  end;
end;

{ BoxRow down every column of a Width x Height plane at once: a running
  sum per column, the plane read a row at a time (column by column it
  would touch a new cache line for every value). Scratch has room for
  the plane with Size + 1 rows of zeros above and below; Sums for Width
  sums. }
procedure BoxColumns(Data: PByte; Width, Height, Size, Offset: LongInt; Scratch: PByte; Sums: PLongInt);
var
  Row, Column, Sum: LongInt;
  Reciprocal: QWord;
  Entering, Leaving, Output: PByte;
begin
  Move(Data^, Scratch^, Width * Height);
  Reciprocal := ReciprocalOfSize(Size);
  FillDWord(Sums^, Width, 0);
  for Row := -Offset to -Offset + Size - 2 do
    for Column := 0 to Width - 1 do
      Inc(Sums[Column], Scratch[Row * Width + Column]);
  for Row := 0 to Height - 1 do
  begin
    Entering := Scratch + (Row - Offset + Size - 1) * Width;
    Leaving := Scratch + (Row - Offset) * Width;
    Output := Data + Row * Width;
    for Column := 0 to Width - 1 do
    begin
      Sum := Sums[Column] + Entering[Column];
      Output[Column] := Byte((QWord(Sum + Size div 2) * Reciprocal) shr ReciprocalShift);
      Sums[Column] := Sum - Leaving[Column];
    end;
  end;
end;

{ The size and offset of each of the three boxes for a box of Size
  (BoxSize): three of Size when it is odd; when even, Size centred
  either way and one of Size + 1. }
procedure BoxesFor(Size: LongInt; out Sizes, Offsets: array of LongInt);
begin
  Sizes[0] := Size;
  Sizes[1] := Size;
  Offsets[0] := Size div 2;
  Offsets[2] := Size div 2;
  if Odd(Size) then
  begin
    Sizes[2] := Size;
    Offsets[1] := Size div 2;
  end
  else
  begin
    Sizes[2] := Size + 1;
    Offsets[1] := Size div 2 - 1;
  end;
end;

{ The three boxes along every row (Horizontal) or column. }
procedure BlurDirection(var Plane: TBlurPlane; Width, Height: LongInt; Sigma: Double; Horizontal: Boolean);
var
  Size, Line, Box, Margin: LongInt;
  Sizes, Offsets: array[0..2] of LongInt;
  Scratch: array of Byte;
  Sums: array of LongInt;
begin
  Size := BoxSize(Sigma);
  if Size < 2 then
    Exit;
  BoxesFor(Size, Sizes, Offsets);
  { Zeros either side, enough for the largest box (Size + 1); SetLength
    zeroes them and the boxes only write between. }
  Margin := Size + 2;
  Scratch := nil;
  if Horizontal then
  begin
    SetLength(Scratch, Width + 2 * Margin);
    for Line := 0 to Height - 1 do
      for Box := 0 to 2 do
        BoxRow(@Plane[Line * Width], Width, Sizes[Box], Offsets[Box], @Scratch[Margin]);
  end
  else
  begin
    SetLength(Scratch, (Height + 2 * Margin) * Width);
    Sums := nil;
    SetLength(Sums, Width);
    for Box := 0 to 2 do
      BoxColumns(@Plane[0], Width, Height, Sizes[Box], Offsets[Box], @Scratch[Margin * Width], @Sums[0]);
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
    Red[Index] := MultiplyChannels(RedOf(Color), A);
    Green[Index] := MultiplyChannels(GreenOf(Color), A);
    Blue[Index] := MultiplyChannels(BlueOf(Color), A);
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
