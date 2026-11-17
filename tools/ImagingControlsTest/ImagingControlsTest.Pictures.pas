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
  Pictures: an image list's choice of pixel size, a picture box's
  placement in every size mode, and the disabled and selected looks.
}
unit ImagingControlsTest.Pictures;

{$mode objfpc}
{$H+}

interface

procedure CheckImageSizes;
procedure CheckPictureGeometry;
procedure CheckImageEffects;

implementation

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Rectangles,
  Image.Model,
  Controls.ImageSizes,
  Controls.PictureGeometry,
  Controls.ImageEffects,
  ImagingControlsTest.Checks;

function Sizes(const Sides: array of LongInt): specialize TArray<TImagePixelSize>;
var
  Index: LongInt;
begin
  Result := nil;
  SetLength(Result, Length(Sides));
  for Index := 0 to High(Sides) do
    Result[Index] := MakeImagePixelSize(Sides[Index], Sides[Index]);
end;

function Square(Side: LongInt): TImagePixelSize;
begin
  Result := MakeImagePixelSize(Side, Side);
end;

procedure CheckImageSizes;
var
  Fitted: TImagePixelSize;
begin
  { 16, 24, 32 and 48 pixels of a 16 unit picture. }
  CheckEqual(BestImageSize(Sizes([16, 24, 32, 48]), Square(16)), 0, 'image size: exact at 100 %');
  CheckEqual(BestImageSize(Sizes([16, 24, 32, 48]), Square(24)), 1, 'image size: exact at 150 %');
  CheckEqual(BestImageSize(Sizes([16, 24, 32, 48]), Square(20)), 1, 'image size: nearest larger at 125 %');
  CheckEqual(BestImageSize(Sizes([32, 16, 48]), Square(28)), 0, 'image size: nearest larger, in any order');
  CheckEqual(BestImageSize(Sizes([16, 24]), Square(40)), 1, 'image size: the largest when none is large enough');
  CheckEqual(BestImageSize(Sizes([48, 16, 32]), Square(64)), 0, 'image size: the largest, in any order');
  CheckEqual(BestImageSize(Sizes([16]), Square(8)), 0, 'image size: a single size serves every size');
  CheckEqual(BestImageSize(Sizes([]), Square(16)), -1, 'image size: none to choose from');
  CheckEqual(BestImageSize([MakeImagePixelSize(32, 16), MakeImagePixelSize(16, 16)], MakeImagePixelSize(16, 16)), 1,
    'image size: the exact size before a larger one');
  Fitted := FitImagePixelSize(16, 16, 24, 20);
  Check((Fitted.Width = 20) and (Fitted.Height = 20), 'image size: a square fitted into a wide box');
  Fitted := FitImagePixelSize(32, 16, 24, 24);
  Check((Fitted.Width = 24) and (Fitted.Height = 12), 'image size: a wide picture fitted into a square box');
end;

function SameRectangle(const Actual: TRectangle; Left, Top, Width, Height: LongInt): Boolean;
begin
  Result := RectanglesAreEqual(Actual, MakeRectangle(Left, Top, Width, Height));
  if not Result then
    WriteLn('     got ', Actual.Left, ',', Actual.Top, ' ', RectangleWidth(Actual), 'x', RectangleHeight(Actual),
      ', expected ', Left, ',', Top, ' ', Width, 'x', Height);
end;

procedure CheckPictureGeometry;
begin
  { A 64 x 48 picture in a 200 x 150 box (the same proportions), and in
    a 100 x 100 box. }
  Check(SameRectangle(PicturePlacement(PictureSizeNormal, 64, 48, 200, 150), 0, 0, 64, 48),
    'picture box: normal at the top left');
  Check(SameRectangle(PicturePlacement(PictureSizeStretch, 64, 48, 100, 100), 0, 0, 100, 100),
    'picture box: stretched over the box');
  Check(SameRectangle(PicturePlacement(PictureSizeZoom, 64, 48, 200, 150), 0, 0, 200, 150),
    'picture box: zoomed up, the same proportions as the box');
  Check(SameRectangle(PicturePlacement(PictureSizeZoom, 64, 48, 100, 100), 0, 12, 100, 75),
    'picture box: zoomed into a square, centred down');
  Check(SameRectangle(PicturePlacement(PictureSizeZoom, 48, 64, 100, 100), 12, 0, 75, 100),
    'picture box: a tall picture zoomed, centred across');
  Check(SameRectangle(PicturePlacement(PictureSizeZoom, 640, 480, 100, 100), 0, 12, 100, 75),
    'picture box: zoomed down');
  Check(SameRectangle(PicturePlacement(PictureSizeCenter, 64, 48, 200, 150), 68, 51, 64, 48),
    'picture box: centred');
  Check(SameRectangle(PicturePlacement(PictureSizeCenter, 300, 200, 100, 100), -100, -50, 300, 200),
    'picture box: centred and larger than the box (cut off on every side)');
  Check(SameRectangle(PicturePlacement(PictureSizeAuto, 64, 48, 10, 10), 0, 0, 64, 48),
    'picture box: auto-size at its size');
  Check(RectangleIsEmpty(PicturePlacement(PictureSizeZoom, 64, 48, 0, 150)), 'picture box: an empty box');
  Check(RectangleIsEmpty(PicturePlacement(PictureSizeZoom, 0, 0, 200, 150)), 'picture box: no picture');
  Check(SameRectangle(PicturePlacement(PictureSizeZoom, 1000, 1, 50, 50), 0, 24, 50, 1),
    'picture box: a sliver zoomed keeps a pixel');
end;

procedure CheckImageEffects;
var
  Image: TImage;
  Greyed: TImage;
  Tinted: TImage;
  Pixel: TColor;
begin
  Pixel := GreyedColor($FFFF0000);
  Check((RedOf(Pixel) = GreenOf(Pixel)) and (GreenOf(Pixel) = BlueOf(Pixel)), 'greyed: a grey');
  CheckEqual(AlphaOf(Pixel), 128, 'greyed: half as opaque');
  CheckEqual(AlphaOf(GreyedColor($00123456)), 0, 'greyed: transparent stays transparent');
  Check(RedOf(GreyedColor($FFFFFFFF)) = 255, 'greyed: white stays white');
  Check(RedOf(GreyedColor($FF000000)) > 0, 'greyed: black is lightened');
  Pixel := TintedColor($80FFFFFF, $FF000000, 255);
  Check((Pixel and $00FFFFFF = 0) and (AlphaOf(Pixel) = $80), 'tinted: wholly the tint, the opacity kept');
  CheckEqual(TintedColor($FF336699, $FF000000, 0), $FF336699, 'tinted: no weight changes nothing');
  Image := TImage.Create(3, 2);
  try
    Image.Fill($FF2040A0);
    Image.SetPixel(1, 1, ColorTransparent);
    Greyed := GreyedImage(Image);
    Tinted := TintedImage(Image, $FF17375E, 96);
    try
      Check((Greyed.Width = 3) and (Greyed.Height = 2) and (Greyed.GetPixel(0, 0) = GreyedColor($FF2040A0)) and
        (AlphaOf(Greyed.GetPixel(1, 1)) = 0), 'greyed image: every pixel greyed');
      Check((Tinted.GetPixel(2, 1) = TintedColor($FF2040A0, $FF17375E, 96)) and (AlphaOf(Tinted.GetPixel(1, 1)) = 0),
        'tinted image: every pixel tinted');
    finally
      Greyed.Free;
      Tinted.Free;
    end;
  finally
    Image.Free;
  end;
end;

end.
