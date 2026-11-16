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
  Turning an image upright: a camera stores its pixels as the sensor
  saw them and says in EXIF how to turn them (TImage.Orientation).
  OrientedImage makes a new image with the pixels turned and mirrored
  so it is seen as meant, its orientation normal; the resolution's two
  directions are swapped with the sides.
}
unit Image.Orientation;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Image.Model;

{ Image as it is meant to be seen (a new image; Image is unchanged). }
function OrientedImage(Image: TImage): TImage;
{ The width and height Image has once turned upright. }
procedure OrientedSize(Image: TImage; out Width, Height: LongInt);

implementation

procedure OrientedSize(Image: TImage; out Width, Height: LongInt);
begin
  if OrientationSwapsSides(Image.Orientation) then
  begin
    Width := Image.Height;
    Height := Image.Width;
  end
  else
  begin
    Width := Image.Width;
    Height := Image.Height;
  end;
end;

{ Where the pixel at (X, Y) of the result comes from in the stored
  picture of size Width x Height. }
procedure SourcePosition(Orientation: TImageOrientation; X, Y, Width, Height: LongInt;
  out SourceX, SourceY: LongInt);
begin
  case Orientation of
    OrientationMirrorHorizontal:
      begin
        SourceX := Width - 1 - X;
        SourceY := Y;
      end;
    OrientationRotate180:
      begin
        SourceX := Width - 1 - X;
        SourceY := Height - 1 - Y;
      end;
    OrientationMirrorVertical:
      begin
        SourceX := X;
        SourceY := Height - 1 - Y;
      end;
    OrientationTranspose:
      begin
        SourceX := Y;
        SourceY := X;
      end;
    OrientationRotate90:
      begin
        SourceX := Y;
        SourceY := Height - 1 - X;
      end;
    OrientationTransverse:
      begin
        SourceX := Width - 1 - Y;
        SourceY := Height - 1 - X;
      end;
    OrientationRotate270:
      begin
        SourceX := Width - 1 - Y;
        SourceY := X;
      end;
  else
    begin
      SourceX := X;
      SourceY := Y;
    end;
  end;
end;

function OrientedImage(Image: TImage): TImage;
var
  Width: LongInt;
  Height: LongInt;
  X: LongInt;
  Y: LongInt;
  SourceX: LongInt;
  SourceY: LongInt;
  TargetLine: PLongWord;
begin
  OrientedSize(Image, Width, Height);
  Result := TImage.Create(Width, Height);
  Result.CopyPropertiesFrom(Image);
  Result.Orientation := OrientationNormal;
  if OrientationSwapsSides(Image.Orientation) then
    Result.Resolution := MakeResolution(Image.Resolution.VerticalDpi, Image.Resolution.HorizontalDpi);
  for Y := 0 to Height - 1 do
  begin
    TargetLine := Result.Line(Y);
    for X := 0 to Width - 1 do
    begin
      SourcePosition(Image.Orientation, X, Y, Image.Width, Image.Height, SourceX, SourceY);
      TargetLine[X] := Image.Line(SourceY)[SourceX];
    end;
  end;
end;

end.
