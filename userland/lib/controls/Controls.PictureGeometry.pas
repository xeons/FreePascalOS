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
  Where a picture box (Controls.PictureBox) puts its picture, for each
  way of sizing it, apart from the control so that it can be tried on
  its own. Everything is in pixels: the picture's size is what it is
  shown at unscaled (its pixels at the display's scale), the box is the
  control.

  - Normal: at its size, at the top left (cut off at the right and
    bottom if larger).
  - Stretch: filling the box, proportions lost.
  - Zoom: as large as fits, proportions kept, centred (smaller or
    larger than it is).
  - Centre: at its size, centred (cut off on every side if larger).
  - AutoSize: at its size, at the top left; the box takes its size.
}
unit Controls.PictureGeometry;

{$mode objfpc}

interface

uses
  Drawing.Rectangles;

type
  TPictureSizeMode = (PictureSizeNormal, PictureSizeStretch, PictureSizeZoom, PictureSizeCenter, PictureSizeAuto);

{ Where the picture (PictureWidth x PictureHeight) goes in a box
  BoxWidth x BoxHeight: the rectangle (box pixels) it is drawn into, of
  the size it is drawn at. Empty if either is empty. }
function PicturePlacement(Mode: TPictureSizeMode; PictureWidth, PictureHeight, BoxWidth,
  BoxHeight: LongInt): TRectangle;

implementation

uses
  Controls.ImageSizes;

function PicturePlacement(Mode: TPictureSizeMode; PictureWidth, PictureHeight, BoxWidth,
  BoxHeight: LongInt): TRectangle;
var
  Fitted: TImagePixelSize;
begin
  Result := MakeRectangle(0, 0, 0, 0);
  if (PictureWidth <= 0) or (PictureHeight <= 0) or (BoxWidth <= 0) or (BoxHeight <= 0) then
    Exit;
  case Mode of
    PictureSizeStretch:
      Result := MakeRectangle(0, 0, BoxWidth, BoxHeight);
    PictureSizeZoom:
      begin
        Fitted := FitImagePixelSize(PictureWidth, PictureHeight, BoxWidth, BoxHeight);
        Result := MakeRectangle((BoxWidth - Fitted.Width) div 2, (BoxHeight - Fitted.Height) div 2, Fitted.Width,
          Fitted.Height);
      end;
    PictureSizeCenter:
      Result := MakeRectangle((BoxWidth - PictureWidth) div 2, (BoxHeight - PictureHeight) div 2, PictureWidth,
        PictureHeight);
  else
    Result := MakeRectangle(0, 0, PictureWidth, PictureHeight);
  end;
end;

end.
