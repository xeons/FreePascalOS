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
  Image sizes: which of the pixel sizes an image list has of a picture
  serves a wanted size best (Controls.ImageList), apart from the
  pictures so that it can be tried on its own.

  The best is the wanted size exactly; else the smallest larger one
  (shrinking loses less than enlarging); else the largest there is.
  Sizes are compared by the larger of width and height.
}
unit Controls.ImageSizes;

{$mode objfpc}

interface

type
  TImagePixelSize = record
    Width: LongInt;
    Height: LongInt;
  end;

{ The index in Sizes of the best size for Wanted; -1 if Sizes is empty. }
function BestImageSize(const Sizes: array of TImagePixelSize; const Wanted: TImagePixelSize): LongInt;
function MakeImagePixelSize(Width, Height: LongInt): TImagePixelSize;
{ Width x Height fitted into BoxWidth x BoxHeight, proportions kept
  (larger or smaller), at least 1 x 1. }
function FitImagePixelSize(Width, Height, BoxWidth, BoxHeight: LongInt): TImagePixelSize;

implementation

function MakeImagePixelSize(Width, Height: LongInt): TImagePixelSize;
begin
  Result.Width := Width;
  Result.Height := Height;
end;

function LargerSide(const Size: TImagePixelSize): LongInt;
begin
  Result := Size.Width;
  if Size.Height > Result then
    Result := Size.Height;
end;

function BestImageSize(const Sizes: array of TImagePixelSize; const Wanted: TImagePixelSize): LongInt;
var
  Index: LongInt;
  Side: LongInt;
  WantedSide: LongInt;
  SmallestLarger: LongInt;
  Largest: LongInt;
begin
  Result := -1;
  SmallestLarger := -1;
  Largest := -1;
  WantedSide := LargerSide(Wanted);
  for Index := 0 to High(Sizes) do
  begin
    if (Sizes[Index].Width = Wanted.Width) and (Sizes[Index].Height = Wanted.Height) then
      Exit(Index);
    Side := LargerSide(Sizes[Index]);
    if (Side >= WantedSide) and ((SmallestLarger < 0) or (Side < LargerSide(Sizes[SmallestLarger]))) then
      SmallestLarger := Index;
    if (Largest < 0) or (Side > LargerSide(Sizes[Largest])) then
      Largest := Index;
  end;
  if SmallestLarger >= 0 then
    Result := SmallestLarger
  else
    Result := Largest;
end;

function FitImagePixelSize(Width, Height, BoxWidth, BoxHeight: LongInt): TImagePixelSize;
begin
  Result := MakeImagePixelSize(BoxWidth, BoxHeight);
  if (Width <= 0) or (Height <= 0) then
    Exit;
  { Wider than the box in proportion: the width fills it. }
  if Int64(Width) * BoxHeight >= Int64(Height) * BoxWidth then
    Result.Height := (Int64(Height) * BoxWidth + Width div 2) div Width
  else
    Result.Width := (Int64(Width) * BoxHeight + Height div 2) div Height;
  if Result.Width < 1 then
    Result.Width := 1;
  if Result.Height < 1 then
    Result.Height := 1;
end;

end.
