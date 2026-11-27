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
  The arithmetic of Image > Resize: a new size given in percent of the
  old one or in pixels, and the other side following when the
  proportions are kept. A side is at least one pixel.
}
unit Paint.ResizeMath;

{$mode objfpc}
{$H+}

interface

type
  TResizeUnit = (ResizeByPercent, ResizeByPixels);

{ The size the picture (Width x Height) takes for Horizontal and
  Vertical in Units. }
procedure ResizedSize(Width, Height: LongInt; Units: TResizeUnit; Horizontal, Vertical: LongInt;
  out NewWidth, NewHeight: LongInt);
{ The vertical value that keeps the proportions when the horizontal one
  is Horizontal (and the other way round). }
function MatchingVertical(Width, Height: LongInt; Units: TResizeUnit; Horizontal: LongInt): LongInt;
function MatchingHorizontal(Width, Height: LongInt; Units: TResizeUnit; Vertical: LongInt): LongInt;

implementation

uses
  Math;

procedure ResizedSize(Width, Height: LongInt; Units: TResizeUnit; Horizontal, Vertical: LongInt;
  out NewWidth, NewHeight: LongInt);
begin
  if Units = ResizeByPercent then
  begin
    NewWidth := Round(Int64(Width) * Horizontal / 100);
    NewHeight := Round(Int64(Height) * Vertical / 100);
  end
  else
  begin
    NewWidth := Horizontal;
    NewHeight := Vertical;
  end;
  NewWidth := Max(1, NewWidth);
  NewHeight := Max(1, NewHeight);
end;

function MatchingVertical(Width, Height: LongInt; Units: TResizeUnit; Horizontal: LongInt): LongInt;
begin
  if (Units = ResizeByPercent) or (Width <= 0) then
    Exit(Horizontal);
  Result := Max(1, Round(Int64(Horizontal) * Height / Width));
end;

function MatchingHorizontal(Width, Height: LongInt; Units: TResizeUnit; Vertical: LongInt): LongInt;
begin
  if (Units = ResizeByPercent) or (Height <= 0) then
    Exit(Vertical);
  Result := Max(1, Round(Int64(Vertical) * Width / Height));
end;

end.
