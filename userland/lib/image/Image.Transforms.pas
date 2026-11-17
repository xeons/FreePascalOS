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
  Whole images turned, mirrored, slanted and their colours inverted, as
  a paint program's Image menu does them.

  Turning makes a new image (a quarter turn swaps the sides; the
  resolution's two directions are swapped with them); mirroring and
  inverting change the image in place. Inverting turns each colour
  channel to 255 less itself and leaves alpha alone. Skewing slants the
  picture by an angle each way (degrees, -89 to 89): horizontally, each
  line moves sideways by its height times the angle's tangent (lines
  further down move right for a positive angle); then vertically, each
  column moves down by its place across times the tangent. The new
  image is as large as the slanted picture needs; the corners it
  uncovers take Background. Pixels are taken whole (the nearest), so a
  skewed drawing keeps its crisp edges.
}
unit Image.Transforms;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Drawing.Colors,
  Image.Model;

function RotateImageClockwise(Image: TImage): TImage;
function RotateImageAnticlockwise(Image: TImage): TImage;
function RotateImageHalfTurn(Image: TImage): TImage;
procedure FlipImageHorizontally(Image: TImage);
procedure FlipImageVertically(Image: TImage);
procedure InvertImageColors(Image: TImage);
function SkewImage(Image: TImage; HorizontalDegrees, VerticalDegrees: Double; Background: TColor): TImage;

implementation

uses
  Math;

const
  LargestSkew = 89;

{ A new image Width x Height with Image's properties, the resolution's
  directions swapped if SwapSides. }
function MadeLike(Image: TImage; Width, Height: LongInt; SwapSides: Boolean): TImage;
begin
  Result := TImage.Create(Width, Height);
  Result.CopyPropertiesFrom(Image);
  if SwapSides then
    Result.Resolution := MakeResolution(Image.Resolution.VerticalDpi, Image.Resolution.HorizontalDpi);
end;

function RotateImageClockwise(Image: TImage): TImage;
var
  X: LongInt;
  Y: LongInt;
  Source: PLongWord;
begin
  Result := MadeLike(Image, Image.Height, Image.Width, True);
  { Source (X, Y) goes to (Height - 1 - Y, X). }
  for Y := 0 to Image.Height - 1 do
  begin
    Source := Image.Line(Y);
    for X := 0 to Image.Width - 1 do
      Result.Line(X)[Image.Height - 1 - Y] := Source[X];
  end;
end;

function RotateImageAnticlockwise(Image: TImage): TImage;
var
  X: LongInt;
  Y: LongInt;
  Source: PLongWord;
begin
  Result := MadeLike(Image, Image.Height, Image.Width, True);
  { Source (X, Y) goes to (Y, Width - 1 - X). }
  for Y := 0 to Image.Height - 1 do
  begin
    Source := Image.Line(Y);
    for X := 0 to Image.Width - 1 do
      Result.Line(Image.Width - 1 - X)[Y] := Source[X];
  end;
end;

function RotateImageHalfTurn(Image: TImage): TImage;
var
  X: LongInt;
  Y: LongInt;
  Source: PLongWord;
  Target: PLongWord;
begin
  Result := MadeLike(Image, Image.Width, Image.Height, False);
  for Y := 0 to Image.Height - 1 do
  begin
    Source := Image.Line(Y);
    Target := Result.Line(Image.Height - 1 - Y);
    for X := 0 to Image.Width - 1 do
      Target[Image.Width - 1 - X] := Source[X];
  end;
end;

procedure FlipImageHorizontally(Image: TImage);
var
  Y: LongInt;
  Left: LongInt;
  Right: LongInt;
  Line: PLongWord;
  Kept: LongWord;
begin
  for Y := 0 to Image.Height - 1 do
  begin
    Line := Image.Line(Y);
    Left := 0;
    Right := Image.Width - 1;
    while Left < Right do
    begin
      Kept := Line[Left];
      Line[Left] := Line[Right];
      Line[Right] := Kept;
      Inc(Left);
      Dec(Right);
    end;
  end;
end;

procedure FlipImageVertically(Image: TImage);
var
  Top: LongInt;
  Bottom: LongInt;
  Kept: array of LongWord;
  LineBytes: PtrUInt;
begin
  Kept := nil;
  SetLength(Kept, Image.Width);
  if Image.Width = 0 then
    Exit;
  LineBytes := PtrUInt(Image.Width) * SizeOf(LongWord);
  Top := 0;
  Bottom := Image.Height - 1;
  while Top < Bottom do
  begin
    Move(Image.Line(Top)^, Kept[0], LineBytes);
    Move(Image.Line(Bottom)^, Image.Line(Top)^, LineBytes);
    Move(Kept[0], Image.Line(Bottom)^, LineBytes);
    Inc(Top);
    Dec(Bottom);
  end;
end;

procedure InvertImageColors(Image: TImage);
var
  Index: PtrUInt;
  Count: PtrUInt;
begin
  Count := PtrUInt(Image.Width) * PtrUInt(Image.Height);
  Index := 0;
  while Index < Count do
  begin
    Image.Pixels[Index] := Image.Pixels[Index] xor $00FFFFFF;
    Inc(Index);
  end;
end;

function SkewImage(Image: TImage; HorizontalDegrees, VerticalDegrees: Double; Background: TColor): TImage;
var
  ShearX: Double;
  ShearY: Double;
  Slanted: TImage;
  ExtraWidth: LongInt;
  ExtraHeight: LongInt;
  Offset: Double;
  X: LongInt;
  Y: LongInt;
  SourceX: LongInt;
  SourceY: LongInt;
begin
  HorizontalDegrees := EnsureRange(HorizontalDegrees, -LargestSkew, LargestSkew);
  VerticalDegrees := EnsureRange(VerticalDegrees, -LargestSkew, LargestSkew);
  ShearX := Tan(DegToRad(HorizontalDegrees));
  ShearY := Tan(DegToRad(VerticalDegrees));
  { Sideways first: line Y moves by Y * ShearX (from the top line). }
  ExtraWidth := Ceil(Abs(ShearX) * (Image.Height - 1) - 0.0001);
  if ExtraWidth < 0 then
    ExtraWidth := 0;
  CheckImageSize(Int64(Image.Width) + ExtraWidth, Image.Height);
  Slanted := MadeLike(Image, Image.Width + ExtraWidth, Image.Height, False);
  try
    Slanted.Fill(Background);
    for Y := 0 to Image.Height - 1 do
    begin
      if ShearX >= 0 then
        Offset := Y * ShearX
      else
        Offset := ExtraWidth + Y * ShearX;
      for X := 0 to Slanted.Width - 1 do
      begin
        SourceX := Floor(X - Offset + 0.5);
        if (SourceX >= 0) and (SourceX < Image.Width) then
          Slanted.Line(Y)[X] := Image.Line(Y)[SourceX];
      end;
    end;
    if ShearY = 0 then
    begin
      Result := Slanted;
      Slanted := nil;
      Exit;
    end;
    { Then down: column X moves by X * ShearY. }
    ExtraHeight := Ceil(Abs(ShearY) * (Slanted.Width - 1) - 0.0001);
    if ExtraHeight < 0 then
      ExtraHeight := 0;
    CheckImageSize(Slanted.Width, Int64(Slanted.Height) + ExtraHeight);
    Result := MadeLike(Image, Slanted.Width, Slanted.Height + ExtraHeight, False);
    Result.Fill(Background);
    for X := 0 to Slanted.Width - 1 do
    begin
      if ShearY >= 0 then
        Offset := X * ShearY
      else
        Offset := ExtraHeight + X * ShearY;
      for Y := 0 to Result.Height - 1 do
      begin
        SourceY := Floor(Y - Offset + 0.5);
        if (SourceY >= 0) and (SourceY < Slanted.Height) then
          Result.Line(Y)[X] := Slanted.Line(SourceY)[X];
      end;
    end;
  finally
    Slanted.Free;
  end;
end;

end.
