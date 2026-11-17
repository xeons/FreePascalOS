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
  Window icons as images: pictures (TImage, libimage) turned into what
  the display server takes for a window's icon (Windowing.WindowIcons),
  and the pictures it describes turned back into images, for a
  taskbar or a task manager showing other windows' icons.

  An image larger than the server takes (MaximumIconSide) is shrunk
  first; images past the server's limits (more than
  MaximumIconPictures, or more than MaximumIconPictureBytes in all) are
  left out.
}
unit Controls.WindowIcons;

{$mode objfpc}
{$H+}

interface

uses
  Image.Model,
  Windowing.WindowIcons;

{ Images as icon pictures for the server (nil entries skipped). }
function IconPicturesOfImages(const Images: array of TImage): TIconPictures;
{ A described picture as a new image (the caller's); nil if empty. }
function ImageOfIconPicture(const Picture: TIconPicture): TImage;

implementation

uses
  Windowing.Protocol,
  Image.Resampling;

function PictureOfImage(Image: TImage): TIconPicture;
var
  Source: TImage;
  Side: LongInt;
  Width: LongInt;
  Height: LongInt;
begin
  Source := Image;
  Side := Image.Width;
  if Image.Height > Side then
    Side := Image.Height;
  if Side > MaximumIconSide then
  begin
    Width := Image.Width * MaximumIconSide div Side;
    Height := Image.Height * MaximumIconSide div Side;
    if Width < 1 then
      Width := 1;
    if Height < 1 then
      Height := 1;
    Source := ResampleImage(Image, Width, Height, ResamplingMitchell);
  end;
  Result.Width := Source.Width;
  Result.Height := Source.Height;
  SetLength(Result.Pixels, Source.Width * Source.Height);
  if Length(Result.Pixels) > 0 then
    Move(Source.Line(0)^, Result.Pixels[0], Length(Result.Pixels) * SizeOf(LongWord));
  if Source <> Image then
    Source.Free;
end;

function PictureBytes(const Picture: TIconPicture): LongInt;
begin
  Result := 8 + Picture.Width * Picture.Height * 4;
end;

function IconPicturesOfImages(const Images: array of TImage): TIconPictures;
var
  Index: LongInt;
  Count: LongInt;
  Total: LongInt;
  Picture: TIconPicture;
begin
  Result := nil;
  Count := 0;
  Total := 0;
  for Index := 0 to High(Images) do
  begin
    if (Images[Index] = nil) or (Images[Index].Width < 1) or (Images[Index].Height < 1) then
      Continue;
    if Count = MaximumIconPictures then
      Break;
    Picture := PictureOfImage(Images[Index]);
    if Total + PictureBytes(Picture) > MaximumIconPictureBytes then
      Continue;
    Total := Total + PictureBytes(Picture);
    SetLength(Result, Count + 1);
    Result[Count] := Picture;
    Inc(Count);
  end;
end;

function ImageOfIconPicture(const Picture: TIconPicture): TImage;
begin
  Result := nil;
  if (Picture.Width < 1) or (Picture.Height < 1) or (Length(Picture.Pixels) < Picture.Width * Picture.Height) then
    Exit;
  Result := TImage.Create(Picture.Width, Picture.Height);
  Move(Picture.Pixels[0], Result.Line(0)^, Picture.Width * Picture.Height * SizeOf(LongWord));
end;

end.
