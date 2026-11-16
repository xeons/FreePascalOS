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
  imageinfo - describe image files

  imageinfo FILE...

  For each file prints its format (from its content, not its name), its
  size, the bits per pixel it is stored in, and what else it says:
  alpha, frames with their total time and loop count, the orientation
  it is meant to be seen in, the resolution, a colour profile:

    t.bmp: BMP, 2 x 1, 24 bits per pixel
    a.gif: GIF, 40 x 30, 4 bits per pixel, alpha, 5 frames, 0.42 s, 3 loops
}
program imageinfo;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Util.CommandLine,
  Util.Messages,
  Sys.Streams,
  Image.Errors,
  Image.Model,
  Image.Frames,
  Image.Files;

const
  Usage = 'Usage: imageinfo FILE...'#10 +
    'Describe image files: format, size, depth, frames and what else they say.'#10;

function AnimationText(Animation: TAnimatedImage): string;
var
  Hundredths: Int64;
begin
  Hundredths := (Animation.TotalDuration + 5) div 10;
  Result := Format(', %d frames, %d.%.2d s', [Animation.FrameCount, Hundredths div 100, Hundredths mod 100]);
  if Animation.FrameCount < 2 then
    Exit(', 1 frame');
  if Animation.LoopCount = 0 then
    Result := Result + ', looping'
  else if Animation.LoopCount = 1 then
    Result := Result + ', once'
  else
    Result := Result + Format(', %d loops', [Animation.LoopCount]);
end;

function Describe(const Path: string): Boolean;
var
  Image: TImage;
  Line: string;
begin
  try
    Image := LoadImage(Path);
  except
    on Error: EImageError do
    begin
      Report(Path + ': ' + Error.Message);
      Exit(False);
    end;
  end;
  try
    Line := Format('%s: %s, %d x %d, %d bits per pixel', [Path, Image.SourceFormatName, Image.Width, Image.Height,
      Image.SourceBitsPerPixel]);
    if Image.SourceHasAlpha then
      Line := Line + ', alpha';
    if Image is TAnimatedImage then
      Line := Line + AnimationText(TAnimatedImage(Image));
    if Image.Orientation <> OrientationNormal then
      Line := Line + Format(', orientation %d', [OrientationToExif(Image.Orientation)]);
    if Image.Resolution.HorizontalDpi > 0 then
      Line := Line + Format(', %d dpi', [Round(Image.Resolution.HorizontalDpi)]);
    if Length(Image.IccProfile) > 0 then
      Line := Line + Format(', colour profile of %d bytes', [Length(Image.IccProfile)]);
    PrintStringLine(Line);
  finally
    Image.Free;
  end;
  Result := True;
end;

var
  CommandLine: TCommandLine;
  Operand: string;
  Status: Integer;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('no files given');
  Status := 0;
  for Operand in CommandLine.Operands do
    if not Describe(Operand) then
      Status := 1;
  Halt(Status);
end.
