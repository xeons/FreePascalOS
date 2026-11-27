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
  The file formats Paint opens and saves, by the file's extension.

  Opening goes by the content (libimage picks the decoder from the first
  bytes), so any picture libimage reads opens whatever its name; the
  open dialog's filter lists them. Saving goes by the name the user
  gives: .png (also what a name without an extension gets), .bmp, .jpg
  or .jpeg, .gif, .tif or .tiff and .webp. JPEG is lossy and asks for a
  quality, and keeps no transparency, so a picture saved as JPEG is
  first put on white.
}
unit Paint.FileFormats;

{$mode objfpc}
{$H+}

interface

uses
  Image.Codecs;

const
  OpenFilter = '*.png;*.bmp;*.jpg;*.jpeg;*.gif;*.tif;*.tiff;*.webp;*.ico;*.jxl';
  SaveFilter = '*.png;*.bmp;*.jpg;*.jpeg;*.gif;*.tif;*.tiff;*.webp';
  DefaultExtension = '.png';
  DefaultJpegQuality = 90;

{ The format a file named Path is saved in (ImageFormatUnknown for an
  extension Paint does not save). }
function SaveFormatForPath(const Path: string): TImageFormat;
{ Path, with DefaultExtension added if its last part has no extension. }
function PathWithDefaultExtension(const Path: string): string;
function FormatIsLossy(Format: TImageFormat): Boolean;
function FormatKeepsTransparency(Format: TImageFormat): Boolean;
{ The extension of a path's last part, lower case, with its dot ('' if
  none). }
function ExtensionOf(const Path: string): string;

implementation

uses
  SysUtils;

function ExtensionOf(const Path: string): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := Length(Path) downto 1 do
  begin
    if Path[Index] = '/' then
      Exit;
    if Path[Index] = '.' then
    begin
      { A name that starts with a dot (".hidden") has no extension. }
      if (Index = 1) or (Path[Index - 1] = '/') then
        Exit;
      Exit(LowerCase(Copy(Path, Index, Length(Path) - Index + 1)));
    end;
  end;
end;

function SaveFormatForPath(const Path: string): TImageFormat;
var
  Extension: string;
begin
  Extension := ExtensionOf(Path);
  if Extension = '.png' then
    Result := ImageFormatPng
  else if Extension = '.bmp' then
    Result := ImageFormatBmp
  else if (Extension = '.jpg') or (Extension = '.jpeg') then
    Result := ImageFormatJpeg
  else if Extension = '.gif' then
    Result := ImageFormatGif
  else if (Extension = '.tif') or (Extension = '.tiff') then
    Result := ImageFormatTiff
  else if Extension = '.webp' then
    Result := ImageFormatWebp
  else
    Result := ImageFormatUnknown;
end;

function PathWithDefaultExtension(const Path: string): string;
begin
  if ExtensionOf(Path) = '' then
    Result := Path + DefaultExtension
  else
    Result := Path;
end;

function FormatIsLossy(Format: TImageFormat): Boolean;
begin
  Result := Format = ImageFormatJpeg;
end;

function FormatKeepsTransparency(Format: TImageFormat): Boolean;
begin
  Result := Format <> ImageFormatJpeg;
end;

end.
