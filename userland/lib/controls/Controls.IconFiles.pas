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
  The icon theme's files: every icon of the system is an ICO file in
  /usr/share/icons named after it (folder.ico, file-text.ico,
  app-terminal.ico, action-save.ico...), holding the same picture at
  16, 20, 24, 32, 40, 48, 64 and 96 pixels (userland/icons draws them).

  An icon is wanted at a logical size (16 beside text, 32 above it) and
  a display scale, so at a pixel size (IconPixelSize). The picture for
  it is the entry of that size if the file has one, else the nearest
  larger one shrunk (Image.Resampling, Mitchell), else the largest grown
  (TIconDirectory.NearestEntry decides). Only the entries asked for are
  decoded, and whatever is made is kept: a file is read once, a size
  made once (until ForgetIconFiles). A name with no file is remembered
  too, so asking again costs nothing; the caller then draws its own
  picture (Controls.IconTheme keeps the drawn stock icons for that). A
  full path in place of a name is that icon file: a program's own icon
  in its folder (Configuration.ProgramFolders.ProgramIconName).

  No windows here (only libimage), so the host checks it on the real
  files (make icon-test).
}
unit Controls.IconFiles;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Image.Model,
  Image.Ico.Directory;

const
  DefaultIconDirectory = '/usr/share/icons';
  IconFileExtension = '.ico';

type
  TSizedPicture = record
    Size: LongInt;
    Picture: TImage;
  end;

  { One icon's file: its entries, decoded when first wanted, and the
    pictures made of them for other sizes. }
  TIconFile = class
  private
    FName: string;
    FDirectory: TIconDirectory;
    FDecoded: array of TImage;
    FSized: array of TSizedPicture;
    function DecodedEntry(Index: LongInt): TImage;
  public
    { Takes Directory (read from the icon's file). }
    constructor Create(const AName: string; Directory: TIconDirectory);
    destructor Destroy; override;
    { The entry drawn for PixelSize: that size, else the nearest larger,
      else the largest. }
    function EntryForSize(PixelSize: LongInt): LongInt;
    { The picture at exactly PixelSize x PixelSize (the file's own, kept
      by it); nil if the entry cannot be decoded. }
    function Picture(PixelSize: LongInt): TImage;
    function EntryCount: LongInt;
    function EntryWidth(Index: LongInt): LongInt;
    function EntryHeight(Index: LongInt): LongInt;
    property Name: string read FName;
  end;

{ Where the icon files are (DefaultIconDirectory unless changed, as the
  host test does); changing it forgets what was read. }
function IconDirectory: string;
procedure SetIconDirectory(const Path: string);
function IconFileName(const Name: string): string;
{ Icon Name's file, read once; nil if there is none or it is not an
  icon file. }
function FindIconFile(const Name: string): TIconFile;
function IconFileExists(const Name: string): Boolean;
{ LogicalSize units at Scale (1.0 for 100 %) in pixels, at least 1. }
function IconPixelSize(LogicalSize: LongInt; Scale: Double): LongInt;
{ Icon Name at exactly PixelSize pixels (kept here: do not free it);
  nil if it has no file. }
function IconPicture(const Name: string; PixelSize: LongInt): TImage;
{ The same at LogicalSize units and Scale. }
function LoadThemeIcon(const Name: string; LogicalSize: LongInt; Scale: Double): TImage;
{ Forgets every file read and picture made. }
procedure ForgetIconFiles;

implementation

uses
  Image.Errors,
  Image.Files,
  Image.Resampling,
  Image.StandardCodecs,
  Image.Ico.Reading;

var
  CurrentDirectory: string = DefaultIconDirectory;
  { Names to TIconFile (nil for a name with no file), sorted. }
  KnownIcons: TStringList = nil;

{ --- TIconFile ---------------------------------------------------------------- }

constructor TIconFile.Create(const AName: string; Directory: TIconDirectory);
begin
  inherited Create;
  FName := AName;
  FDirectory := Directory;
  SetLength(FDecoded, Directory.Count);
end;

destructor TIconFile.Destroy;
var
  Index: LongInt;
begin
  for Index := 0 to High(FDecoded) do
    FDecoded[Index].Free;
  for Index := 0 to High(FSized) do
    FSized[Index].Picture.Free;
  FDirectory.Free;
  inherited Destroy;
end;

function TIconFile.EntryCount: LongInt;
begin
  Result := FDirectory.Count;
end;

function TIconFile.EntryWidth(Index: LongInt): LongInt;
begin
  Result := FDirectory.Entries[Index].Width;
end;

function TIconFile.EntryHeight(Index: LongInt): LongInt;
begin
  Result := FDirectory.Entries[Index].Height;
end;

function TIconFile.EntryForSize(PixelSize: LongInt): LongInt;
begin
  Result := FDirectory.NearestEntry(PixelSize);
end;

function TIconFile.DecodedEntry(Index: LongInt): TImage;
begin
  if FDecoded[Index] = nil then
  begin
    RegisterStandardImageCodecs;
    try
      FDecoded[Index] := DecodeIconEntry(FDirectory, Index);
    except
      on EImageError do
        FDecoded[Index] := nil;
    end;
  end;
  Result := FDecoded[Index];
end;

function TIconFile.Picture(PixelSize: LongInt): TImage;
var
  Index: LongInt;
  Entry: LongInt;
  Source: TImage;
begin
  Result := nil;
  if PixelSize < 1 then
    Exit;
  Entry := EntryForSize(PixelSize);
  if Entry < 0 then
    Exit;
  Source := DecodedEntry(Entry);
  if Source = nil then
    Exit;
  if (Source.Width = PixelSize) and (Source.Height = PixelSize) then
    Exit(Source);
  for Index := 0 to High(FSized) do
    if FSized[Index].Size = PixelSize then
      Exit(FSized[Index].Picture);
  Result := ResampleImage(Source, PixelSize, PixelSize, ResamplingMitchell);
  Index := Length(FSized);
  SetLength(FSized, Index + 1);
  FSized[Index].Size := PixelSize;
  FSized[Index].Picture := Result;
end;

{ --- the theme's files ------------------------------------------------------------ }

function IconDirectory: string;
begin
  Result := CurrentDirectory;
end;

procedure SetIconDirectory(const Path: string);
begin
  ForgetIconFiles;
  CurrentDirectory := ExcludeTrailingPathDelimiter(Path);
end;

function IconFileName(const Name: string): string;
begin
  Result := CurrentDirectory + '/' + Name + IconFileExtension;
end;

{ The file of icon Name: the theme's, or Name itself when it is a full
  path (a program's own icon, Configuration.ProgramFolders); '' for a
  name that is neither. }
function IconSourceFile(const Name: string): string;
begin
  Result := '';
  if Name = '' then
    Exit;
  if Name[1] = '/' then
    Result := Name
  else if Pos('/', Name) = 0 then
    Result := IconFileName(Name);
end;

function ReadIconFile(const Name: string): TIconFile;
var
  Data: TBytes;
  Directory: TIconDirectory;
begin
  Result := nil;
  if IconSourceFile(Name) = '' then
    Exit;
  try
    Data := ReadFileBytes(IconSourceFile(Name));
  except
    on Exception do
      Exit;
  end;
  if not LooksLikeIconFile(Data, IconTypeIcon) then
    Exit;
  try
    Directory := TIconDirectory.Create(Data);
  except
    on EImageError do
      Exit;
  end;
  Result := TIconFile.Create(Name, Directory);
end;

function FindIconFile(const Name: string): TIconFile;
var
  Index: LongInt;
begin
  if KnownIcons = nil then
  begin
    KnownIcons := TStringList.Create;
    KnownIcons.Sorted := True;
    KnownIcons.CaseSensitive := True;
    KnownIcons.Duplicates := dupIgnore;
  end;
  if KnownIcons.Find(Name, Index) then
    Exit(TIconFile(KnownIcons.Objects[Index]));
  Result := ReadIconFile(Name);
  KnownIcons.AddObject(Name, Result);
end;

function IconFileExists(const Name: string): Boolean;
begin
  Result := FindIconFile(Name) <> nil;
end;

function IconPixelSize(LogicalSize: LongInt; Scale: Double): LongInt;
begin
  Result := Round(LogicalSize * Scale);
  if Result < 1 then
    Result := 1;
end;

function IconPicture(const Name: string; PixelSize: LongInt): TImage;
var
  IconFile: TIconFile;
begin
  Result := nil;
  IconFile := FindIconFile(Name);
  if IconFile <> nil then
    Result := IconFile.Picture(PixelSize);
end;

function LoadThemeIcon(const Name: string; LogicalSize: LongInt; Scale: Double): TImage;
begin
  Result := IconPicture(Name, IconPixelSize(LogicalSize, Scale));
end;

procedure ForgetIconFiles;
var
  Index: LongInt;
begin
  if KnownIcons = nil then
    Exit;
  for Index := 0 to KnownIcons.Count - 1 do
    KnownIcons.Objects[Index].Free;
  FreeAndNil(KnownIcons);
end;

finalization
  ForgetIconFiles;
end.
