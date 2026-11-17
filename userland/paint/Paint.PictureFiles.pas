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
  Pictures read from files and written to them, through libimage.

  Reading takes any format libimage reads, turned upright as its EXIF
  says and its colours converted to sRGB; an animation gives its first
  frame as it is seen. Writing goes in the format the name says
  (Paint.FileFormats), JPEG at the quality given and put on white first
  (it keeps no transparency). Problems come back as a sentence to show,
  not an exception.
}
unit Paint.PictureFiles;

{$mode objfpc}
{$H+}

interface

uses
  Image.Model,
  Image.Codecs;

{ Reads Path; True and the picture (the caller's), or False and why. }
function ReadPicture(const Path: string; out Picture: TImage; out Problem: string): Boolean;
{ Writes Picture to Path as Format; True, or False and why. }
function WritePicture(Picture: TImage; const Path: string; Format: TImageFormat; Quality: LongInt;
  out Problem: string): Boolean;

implementation

uses
  SysUtils,
  Drawing.Colors,
  Image.Errors,
  Image.Frames,
  Image.Compositing,
  Image.Files,
  Image.Areas,
  Paint.FileFormats;

function FirstFrame(Animation: TAnimatedImage): TImage;
var
  Compositor: TFrameCompositor;
begin
  Compositor := TFrameCompositor.Create(Animation);
  try
    Result := Compositor.RenderFrame(0).Clone;
  finally
    Compositor.Free;
  end;
end;

function ReadPicture(const Path: string; out Picture: TImage; out Problem: string): Boolean;
var
  Loaded: TImage;
begin
  Picture := nil;
  Problem := '';
  try
    Loaded := LoadImage(Path, [ImageLoadApplyOrientation, ImageLoadConvertToSrgb]);
  except
    on Error: Exception do
    begin
      Problem := Error.Message;
      Exit(False);
    end;
  end;
  if (Loaded is TAnimatedImage) and (TAnimatedImage(Loaded).FrameCount > 0) then
  begin
    try
      Picture := FirstFrame(TAnimatedImage(Loaded));
      Picture.CopyPropertiesFrom(Loaded);
    finally
      Loaded.Free;
    end;
  end
  else
    Picture := Loaded;
  Result := True;
end;

function WritePicture(Picture: TImage; const Path: string; Format: TImageFormat; Quality: LongInt;
  out Problem: string): Boolean;
var
  Written: TImage;
begin
  Problem := '';
  Written := Picture;
  try
    try
      if not FormatKeepsTransparency(Format) then
      begin
        Written := Picture.Clone;
        FlattenImageOnto(Written, ColorWhite);
      end;
      SaveImage(Written, Path, Format, Quality);
      Result := True;
    except
      on Error: Exception do
      begin
        Problem := Error.Message;
        Result := False;
      end;
    end;
  finally
    if Written <> Picture then
      Written.Free;
  end;
end;

end.
