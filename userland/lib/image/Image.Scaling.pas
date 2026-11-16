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
  Images made larger or smaller, through libdrawing's smooth scaling
  (Drawing.Scaling: area averaging when shrinking, so a thumbnail keeps
  every pixel's share; bilinear when growing; alpha weighted).

  ScaleImage makes an image of the size asked; ThumbnailImage one that
  fits in a box keeping the proportions (never larger than the image
  itself). Given a filter (Image.Resampling: box, triangle, Mitchell,
  Lanczos-3), both resample with it instead: separable passes on
  premultiplied colours, better for photographs, upwards and down.
}
unit Image.Scaling;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Drawing.Scaling,
  Image.Model,
  Image.Surfaces,
  Image.Resampling;

function ScaleImage(Image: TImage; NewWidth, NewHeight: LongInt): TImage;
function ScaleImage(Image: TImage; NewWidth, NewHeight: LongInt; Filter: TResamplingFilter): TImage;
{ The size Width x Height takes to fit in MaximumWidth x MaximumHeight,
  proportions kept, at least 1 x 1, never larger than it is. }
procedure FitSize(Width, Height, MaximumWidth, MaximumHeight: LongInt; out FittedWidth, FittedHeight: LongInt);
function ThumbnailImage(Image: TImage; MaximumWidth, MaximumHeight: LongInt): TImage;
function ThumbnailImage(Image: TImage; MaximumWidth, MaximumHeight: LongInt; Filter: TResamplingFilter): TImage;

implementation

function ScaleImage(Image: TImage; NewWidth, NewHeight: LongInt): TImage;
var
  Canvas: TCanvas;
begin
  Result := TImage.Create(NewWidth, NewHeight);
  try
    Result.CopyPropertiesFrom(Image);
    BeginCanvas(Canvas, ImageSurface(Result));
    DrawSurfaceScaled(Canvas, ImageSurface(Image), MakeRectangle(0, 0, Image.Width, Image.Height),
      MakeRectangle(0, 0, NewWidth, NewHeight), False);
  except
    Result.Free;
    raise;
  end;
end;

function ScaleImage(Image: TImage; NewWidth, NewHeight: LongInt; Filter: TResamplingFilter): TImage;
begin
  Result := ResampleImage(Image, NewWidth, NewHeight, Filter);
end;

procedure FitSize(Width, Height, MaximumWidth, MaximumHeight: LongInt; out FittedWidth, FittedHeight: LongInt);
begin
  FittedWidth := Width;
  FittedHeight := Height;
  if (Width <= 0) or (Height <= 0) then
    Exit;
  if FittedWidth > MaximumWidth then
  begin
    FittedWidth := MaximumWidth;
    FittedHeight := (Int64(Height) * MaximumWidth + Width div 2) div Width;
  end;
  if FittedHeight > MaximumHeight then
  begin
    FittedHeight := MaximumHeight;
    FittedWidth := (Int64(Width) * MaximumHeight + Height div 2) div Height;
  end;
  if FittedWidth < 1 then
    FittedWidth := 1;
  if FittedHeight < 1 then
    FittedHeight := 1;
end;

function ThumbnailImage(Image: TImage; MaximumWidth, MaximumHeight: LongInt): TImage;
var
  Width: LongInt;
  Height: LongInt;
begin
  FitSize(Image.Width, Image.Height, MaximumWidth, MaximumHeight, Width, Height);
  Result := ScaleImage(Image, Width, Height);
end;

function ThumbnailImage(Image: TImage; MaximumWidth, MaximumHeight: LongInt; Filter: TResamplingFilter): TImage;
var
  Width: LongInt;
  Height: LongInt;
begin
  FitSize(Image.Width, Image.Height, MaximumWidth, MaximumHeight, Width, Height);
  Result := ResampleImage(Image, Width, Height, Filter);
end;

end.
