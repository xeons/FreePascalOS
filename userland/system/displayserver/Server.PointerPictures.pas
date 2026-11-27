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
  The pointer's pictures: each shape as a cursor file in /lib/pointers
  (arrow.cur, text-beam.cur, hand.cur...; userland/data/icons draws them)
  holding it in several sizes with alpha, each with its hotspot.

  The picture for a screen is the one for its scale: 32 pixels across
  at 100 % (PointerBaseSize), so 40 at 125 %, 48 at 150 %, 64 at 200 %.
  The file's entry of that size is used; else the nearest larger one
  shrunk (or the largest grown) to it, its hotspot moved in proportion,
  made once and kept. A shape whose file is missing or unreadable is
  drawn from its pattern (Server.PointerShapes), as before.
}
unit Server.PointerPictures;

{$mode objfpc}
{$H+}

interface

uses
  Image.Model;

const
  { The pictures' size at 100 %. }
  PointerBaseSize = 32;

type
  TPointerPicture = record
    Image: TImage;
    HotspotX: LongInt;
    HotspotY: LongInt;
  end;

{ Reads every shape's cursor file; the number read. }
function LoadPointerPictures: LongInt;
{ Shape's picture at ScalePercent; False (Picture undefined) if the
  shape has none. The image stays this unit's. }
function PointerPictureFor(Shape: LongWord; ScalePercent: LongInt; out Picture: TPointerPicture): Boolean;
{ The size a picture has at ScalePercent. }
function PointerPictureSize(ScalePercent: LongInt): LongInt;

implementation

uses
  SysUtils,
  Windowing.Protocol,
  Image.Errors,
  Image.Files,
  Image.Resampling,
  Image.StandardCodecs,
  Image.Ico.Directory,
  Image.Ico.Reading,
  Server.PointerFiles;

type
  TShapePictures = record
    { The file's entries, decoded, with their hotspots. }
    Entries: array of TPointerPicture;
    { Pictures made for sizes the file does not have. }
    Made: array of TPointerPicture;
  end;

var
  Pictures: array[0..PointerShapeCount - 1] of TShapePictures;

function PointerPictureSize(ScalePercent: LongInt): LongInt;
begin
  Result := (PointerBaseSize * ScalePercent + 50) div 100;
  if Result < 8 then
    Result := 8;
end;

function ReadShapePictures(Shape: LongInt): Boolean;
var
  Data: TBytes;
  Directory: TIconDirectory;
  Index: LongInt;
  Count: LongInt;
begin
  Result := False;
  try
    Data := ReadFileBytes(string(PointerDirectory) + '/' + string(PointerFileNames[Shape]) + '.cur');
  except
    on Exception do
      Exit;
  end;
  if not LooksLikeIconFile(Data, IconTypeCursor) then
    Exit;
  try
    Directory := TIconDirectory.Create(Data);
  except
    on EImageError do
      Exit;
  end;
  try
    Count := 0;
    SetLength(Pictures[Shape].Entries, Directory.Count);
    for Index := 0 to Directory.Count - 1 do
    begin
      try
        Pictures[Shape].Entries[Count].Image := DecodeIconEntry(Directory, Index);
      except
        on EImageError do
          Continue;
      end;
      Pictures[Shape].Entries[Count].HotspotX := Directory.Entries[Index].HotspotX;
      Pictures[Shape].Entries[Count].HotspotY := Directory.Entries[Index].HotspotY;
      Inc(Count);
    end;
    SetLength(Pictures[Shape].Entries, Count);
    Result := Count > 0;
  finally
    Directory.Free;
  end;
end;

function LoadPointerPictures: LongInt;
var
  Shape: LongInt;
begin
  Result := 0;
  RegisterStandardImageCodecs;
  for Shape := 0 to PointerShapeCount - 1 do
    if ReadShapePictures(Shape) then
      Inc(Result);
end;

{ The entry to make Size from: that size, else the smallest larger,
  else the largest. }
function BestEntry(const Entries: array of TPointerPicture; Size: LongInt): LongInt;
var
  Index: LongInt;
  Side: LongInt;
  SmallestLarger: LongInt;
  Largest: LongInt;
begin
  SmallestLarger := -1;
  Largest := -1;
  for Index := 0 to High(Entries) do
  begin
    Side := Entries[Index].Image.Width;
    if Side = Size then
      Exit(Index);
    if (Side > Size) and ((SmallestLarger < 0) or (Side < Entries[SmallestLarger].Image.Width)) then
      SmallestLarger := Index;
    if (Largest < 0) or (Side > Entries[Largest].Image.Width) then
      Largest := Index;
  end;
  if SmallestLarger >= 0 then
    Result := SmallestLarger
  else
    Result := Largest;
end;

function PointerPictureFor(Shape: LongWord; ScalePercent: LongInt; out Picture: TPointerPicture): Boolean;
var
  Size: LongInt;
  Index: LongInt;
  Source: TPointerPicture;
begin
  Result := False;
  if (Shape >= PointerShapeCount) or (Length(Pictures[Shape].Entries) = 0) then
    Exit;
  Size := PointerPictureSize(ScalePercent);
  Source := Pictures[Shape].Entries[BestEntry(Pictures[Shape].Entries, Size)];
  if Source.Image.Width = Size then
  begin
    Picture := Source;
    Exit(True);
  end;
  for Index := 0 to High(Pictures[Shape].Made) do
    if Pictures[Shape].Made[Index].Image.Width = Size then
    begin
      Picture := Pictures[Shape].Made[Index];
      Exit(True);
    end;
  Picture.Image := ResampleImage(Source.Image, Size, Size, ResamplingMitchell);
  Picture.HotspotX := Source.HotspotX * Size div Source.Image.Width;
  Picture.HotspotY := Source.HotspotY * Size div Source.Image.Width;
  Index := Length(Pictures[Shape].Made);
  SetLength(Pictures[Shape].Made, Index + 1);
  Pictures[Shape].Made[Index] := Picture;
  Result := True;
end;

end.
