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
  How two screenshots differ, as wptrunner measures it: the pixels whose
  red, green or blue differ, and the largest difference of one channel
  (alpha is not compared: screenshots are opaque). Pixels outside the
  smaller of two different sizes all count as different, by 255.
}
unit WptRun.PixelDifference;

{$mode objfpc}
{$H+}

interface

uses
  Image.Model;

type
  TPixelDifference = record
    DifferentPixels: Int64;
    MaxChannelDifference: Integer;
  end;

function ComparePixels(Left, Right: TImage): TPixelDifference;

implementation

function ChannelDifference(Left, Right: LongWord; Shift: Integer): Integer;
begin
  Result := Abs(Integer((Left shr Shift) and $FF) - Integer((Right shr Shift) and $FF));
end;

function ComparePixels(Left, Right: TImage): TPixelDifference;
var
  X, Y, Width, Height, Channel, Difference, Largest: Integer;
  LeftLine, RightLine: PLongWord;
begin
  Result := Default(TPixelDifference);
  Width := Left.Width;
  if Right.Width < Width then
    Width := Right.Width;
  Height := Left.Height;
  if Right.Height < Height then
    Height := Right.Height;
  for Y := 0 to Height - 1 do
  begin
    LeftLine := Left.Line(Y);
    RightLine := Right.Line(Y);
    for X := 0 to Width - 1 do
    begin
      if (LeftLine[X] and $FFFFFF) = (RightLine[X] and $FFFFFF) then
        Continue;
      Largest := 0;
      for Channel := 0 to 2 do
      begin
        Difference := ChannelDifference(LeftLine[X], RightLine[X], Channel * 8);
        if Difference > Largest then
          Largest := Difference;
      end;
      Inc(Result.DifferentPixels);
      if Largest > Result.MaxChannelDifference then
        Result.MaxChannelDifference := Largest;
    end;
  end;
  if (Left.Width <> Right.Width) or (Left.Height <> Right.Height) then
  begin
    Inc(Result.DifferentPixels, Int64(Left.Width) * Left.Height + Int64(Right.Width) * Right.Height -
      2 * Int64(Width) * Height);
    Result.MaxChannelDifference := 255;
  end;
end;

end.
