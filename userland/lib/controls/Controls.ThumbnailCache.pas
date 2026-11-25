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
  The thumbnails kept on disk, so a folder shown again does not read
  every picture again: ~/.cache/thumbnails/fpos/KEY.png, with KEY.size
  beside it holding the original's width and height. KEY is a 64-bit
  hash (FNV-1a) of the path, the modification time and the size, so a
  file that changes (or moves) gets a thumbnail of its own and the old
  one is just left unused. ClearThumbnailCache removes them all (the
  file manager's "clear" in its options).
}
unit Controls.ThumbnailCache;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Surfaces;

{ The cache's folder ('' without a home folder). }
function ThumbnailCacheFolder: string;
function ThumbnailCacheFile(const Path: string; ModificationTime: Int64; Size: QWord): string;
function ReadCachedThumbnail(const CacheFile: string; out Picture: TSurface;
  out OriginalWidth, OriginalHeight: LongInt): Boolean;
procedure WriteCachedThumbnail(const CacheFile: string; const Picture: TSurface; OriginalWidth,
  OriginalHeight: LongInt);
procedure ClearThumbnailCache;

implementation

uses
  SysUtils,
  Classes,
  Sys.Environment,
  Image.Model,
  Image.Codecs,
  Image.Files,
  Image.Surfaces;

const
  OffsetBasis = QWord($CBF29CE484222325);
  Prime = QWord($100000001B3);

function HashText(const Text: string): QWord;
var
  Index: LongInt;
begin
  Result := OffsetBasis;
  for Index := 1 to Length(Text) do
  begin
    Result := Result xor Ord(Text[Index]);
    {$push}{$overflowchecks off}{$rangechecks off}
    Result := Result * Prime;
    {$pop}
  end;
end;

function ThumbnailCacheFolder: string;
var
  Home: string;
begin
  Home := GetVariable('HOME');
  if Home = '' then
    Exit('');
  Result := IncludeTrailingPathDelimiter(Home) + '.cache/thumbnails/fpos';
end;

function ThumbnailCacheFile(const Path: string; ModificationTime: Int64; Size: QWord): string;
var
  Folder: string;
begin
  Folder := ThumbnailCacheFolder;
  if Folder = '' then
    Exit('');
  Result := Folder + '/' + IntToHex(HashText(Path + #0 + IntToStr(ModificationTime) + #0 + IntToStr(Size)), 16) +
    '.png';
end;

function SizeFileOf(const CacheFile: string): string;
begin
  Result := ChangeFileExt(CacheFile, '.size');
end;

function ReadCachedThumbnail(const CacheFile: string; out Picture: TSurface;
  out OriginalWidth, OriginalHeight: LongInt): Boolean;
var
  Loaded: TImage;
  Lines: TStringList;
  Parts: TStringArray;
begin
  Picture := Default(TSurface);
  OriginalWidth := 0;
  OriginalHeight := 0;
  Result := False;
  if (CacheFile = '') or not FileExists(CacheFile) or not FileExists(SizeFileOf(CacheFile)) then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(SizeFileOf(CacheFile));
      if Lines.Count < 1 then
        Exit;
      Parts := Lines[0].Split([' ']);
      if (Length(Parts) < 2) or not TryStrToInt(Parts[0], OriginalWidth) or
         not TryStrToInt(Parts[1], OriginalHeight) then
        Exit;
      Loaded := LoadImage(CacheFile);
      Picture := SurfaceTakingImage(Loaded);
      Result := True;
    except
      on Exception do
        Result := False;
    end;
  finally
    Lines.Free;
  end;
end;

procedure WriteCachedThumbnail(const CacheFile: string; const Picture: TSurface; OriginalWidth,
  OriginalHeight: LongInt);
var
  Copy: TImage;
  Lines: TStringList;
begin
  if (CacheFile = '') or (Picture.Pixels = nil) then
    Exit;
  Copy := nil;
  Lines := TStringList.Create;
  try
    try
      ForceDirectories(ExtractFileDir(CacheFile));
      Copy := ImageFromSurface(Picture);
      SaveImage(Copy, CacheFile, ImageFormatPng);
      Lines.Add(IntToStr(OriginalWidth) + ' ' + IntToStr(OriginalHeight));
      Lines.SaveToFile(SizeFileOf(CacheFile));
    except
      { A cache that cannot be written only means reading again. }
      on Exception do
        DeleteFile(CacheFile);
    end;
  finally
    Lines.Free;
    Copy.Free;
  end;
end;

procedure ClearThumbnailCache;
var
  Folder: string;
  Found: TSearchRec;
begin
  Folder := ThumbnailCacheFolder;
  if (Folder = '') or (FindFirst(Folder + '/*', faAnyFile, Found) <> 0) then
    Exit;
  repeat
    if (Found.Name <> '.') and (Found.Name <> '..') then
      DeleteFile(Folder + '/' + Found.Name);
  until FindNext(Found) <> 0;
  FindClose(Found);
end;

end.
