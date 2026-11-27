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
  What the image viewer's properties panel says about the image shown,
  as names and values: the file (name, folder, size), the format and
  how it was stored (size, bits per pixel, alpha), an animation's frames,
  time and loops, a TIFF's pages, the orientation and resolution the file
  gives, its colour profile and what colour management did with it, and
  every metadata entry the decoder found (comments, software, EXIF date,
  compression...), the same facts imageinfo prints.
}
unit ImageViewer.Properties;

{$mode objfpc}
{$H+}

interface

uses
  Image.Model;

type
  TImageProperty = record
    Name: string;
    Value: string;
  end;

  TImageProperties = array of TImageProperty;

  { What colour management did when the image was read. }
  TColorHandling = (ColorHandlingOff, ColorHandlingDone, ColorHandlingNotNeeded, ColorHandlingApproximate,
    ColorHandlingUnsupported);

const
  { For the program's output. }
  ColorHandlingWords: array[TColorHandling] of string = ('off', 'converted', 'not-needed', 'approximate',
    'unsupported');

function DescribeImage(Image: TImage; const Path: string; FileSize: Int64;
  Handling: TColorHandling): TImageProperties;
function ColorHandlingOf(Conversion: TColorConversionResult): TColorHandling;
{ "1.5 MiB", "312 KiB", "900 bytes". }
function FileSizeText(Size: Int64): string;

implementation

uses
  SysUtils,
  Image.Metadata,
  Image.Frames,
  Image.ColorProfiles;

const
  ColorHandlingTexts: array[TColorHandling] of string = ('Off (shown as stored)', 'Converted to sRGB',
    'sRGB already (nothing to convert)', 'Converted to sRGB (approximately)', 'Profile not usable (shown as stored)');

function ColorHandlingOf(Conversion: TColorConversionResult): TColorHandling;
begin
  case Conversion of
    ColorConversionDone: Result := ColorHandlingDone;
    ColorConversionApproximate: Result := ColorHandlingApproximate;
    ColorConversionUnsupported: Result := ColorHandlingUnsupported;
  else
    Result := ColorHandlingNotNeeded;
  end;
end;

function FileSizeText(Size: Int64): string;
begin
  if Size < 1024 then
    Result := IntToStr(Size) + ' bytes'
  else if Size < 1024 * 1024 then
    Result := IntToStr((Size + 512) div 1024) + ' KiB'
  else
    Result := Format('%d.%d MiB', [Size div (1024 * 1024), (Size mod (1024 * 1024)) * 10 div (1024 * 1024)]);
end;

procedure Add(var Properties: TImageProperties; const Name, Value: string);
begin
  SetLength(Properties, Length(Properties) + 1);
  Properties[High(Properties)].Name := Name;
  Properties[High(Properties)].Value := Value;
end;

function LoopText(Animation: TAnimatedImage): string;
begin
  case Animation.LoopCount of
    0: Result := 'for ever';
    1: Result := 'once';
  else
    Result := IntToStr(Animation.LoopCount) + ' times';
  end;
end;

procedure AddAnimation(var Properties: TImageProperties; Animation: TAnimatedImage);
var
  Hundredths: Int64;
begin
  Add(Properties, 'Frames', IntToStr(Animation.FrameCount));
  if Animation.FrameCount < 2 then
    Exit;
  Hundredths := (Animation.TotalDuration + 5) div 10;
  Add(Properties, 'Duration', Format('%d.%.2d s', [Hundredths div 100, Hundredths mod 100]));
  Add(Properties, 'Plays', LoopText(Animation));
end;

function DescribeImage(Image: TImage; const Path: string; FileSize: Int64;
  Handling: TColorHandling): TImageProperties;
var
  Index: LongInt;
begin
  Result := nil;
  Add(Result, 'File', ExtractFileName(Path));
  Add(Result, 'Folder', ExtractFileDir(Path));
  if FileSize >= 0 then
    Add(Result, 'File size', FileSizeText(FileSize));
  Add(Result, 'Format', Image.SourceFormatName);
  Add(Result, 'Size', Format('%d x %d pixels', [Image.Width, Image.Height]));
  Add(Result, 'Bits per pixel', IntToStr(Image.SourceBitsPerPixel));
  if Image.SourceHasAlpha then
    Add(Result, 'Transparency', 'alpha')
  else
    Add(Result, 'Transparency', 'none');
  if Image is TAnimatedImage then
    AddAnimation(Result, TAnimatedImage(Image));
  if Image.Orientation <> OrientationNormal then
    Add(Result, 'Orientation', 'EXIF ' + IntToStr(OrientationToExif(Image.Orientation)));
  if Image.Resolution.HorizontalDpi > 0 then
    Add(Result, 'Resolution', Format('%d x %d dpi', [Round(Image.Resolution.HorizontalDpi),
      Round(Image.Resolution.VerticalDpi)]));
  if Length(Image.IccProfile) > 0 then
    Add(Result, 'Colour profile', DescribeColorProfile(Image.IccProfile))
  else
    Add(Result, 'Colour profile', 'none');
  Add(Result, 'Colour management', ColorHandlingTexts[Handling]);
  for Index := 0 to Image.Metadata.Count - 1 do
    Add(Result, Image.Metadata.Keys[Index], Image.Metadata.Values[Index]);
end;

end.
