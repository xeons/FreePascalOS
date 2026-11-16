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
  Images and libdrawing's surfaces. An image's pixels are a surface's
  pixels already (the same colours, no gap between lines), so:

  - ImageSurface: a surface on the image's pixels, nothing copied; it
    belongs to the image and is good while the image is (drawing on it
    changes the image).
  - SurfaceTakingImage: the pixels move to a surface of its own (freed
    with FreeSurface); nothing copied, the image is left empty.
  - ImageTakingSurface: a surface's pixels move to a new image when the
    surface owns them and has no gap between lines; otherwise they are
    copied and the surface freed. Either way the surface is left empty.
  - ImageFromSurface: a copy, the surface untouched.
}
unit Image.Surfaces;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Drawing.Surfaces,
  Image.Model;

function ImageSurface(Image: TImage): TSurface;
function SurfaceTakingImage(Image: TImage): TSurface;
function ImageTakingSurface(var Surface: TSurface): TImage;
function ImageFromSurface(const Surface: TSurface): TImage;

implementation

function ImageSurface(Image: TImage): TSurface;
begin
  Result := SurfaceOnPixels(Image.Pixels, Image.Width, Image.Height, Image.Width * SizeOf(LongWord));
end;

function SurfaceTakingImage(Image: TImage): TSurface;
var
  Width: LongInt;
  Height: LongInt;
begin
  Width := Image.Width;
  Height := Image.Height;
  Result := SurfaceOnPixels(Image.ReleasePixels, Width, Height, Width * SizeOf(LongWord));
  Result.OwnsPixels := Result.Pixels <> nil;
end;

function ImageFromSurface(const Surface: TSurface): TImage;
var
  Y: LongInt;
begin
  Result := TImage.Create(Surface.Width, Surface.Height);
  for Y := 0 to Surface.Height - 1 do
    Move(SurfaceLine(Surface, Y)^, Result.Line(Y)^, PtrUInt(Surface.Width) * SizeOf(LongWord));
end;

function ImageTakingSurface(var Surface: TSurface): TImage;
begin
  if Surface.OwnsPixels and (Surface.Stride = Surface.Width) and (Surface.Pixels <> nil) then
  begin
    Result := TImage.CreateAdopting(Surface.Pixels, Surface.Width, Surface.Height);
    Surface.OwnsPixels := False;
    FreeSurface(Surface);
    Exit;
  end;
  Result := ImageFromSurface(Surface);
  FreeSurface(Surface);
end;

end.
