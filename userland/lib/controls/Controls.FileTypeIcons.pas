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
  Which stock icon a file or folder shows, from its name alone: a
  file's extension (txt and the like a text page, png a picture, wav a
  note, zip an archive, ttf a letter A...), and the folders whose names
  say what they hold (Documents, Pictures, Music, Videos, Downloads,
  Projects, Public, Templates: folders with that emblem). Names are
  compared without regard to case.
}
unit Controls.FileTypeIcons;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Icons;

{ The icon of a file named Name (its extension's kind), Fallback when the
  extension says nothing (a plain file, a program...). }
function IconForFileName(const Name: string; Fallback: TStockIcon): TStockIcon;
{ The icon of a folder named Name: a folder with an emblem, or the
  plain folder. }
function IconForFolderName(const Name: string): TStockIcon;

implementation

uses
  SysUtils;

type
  TExtensionIcon = record
    Extension: string;
    Icon: TStockIcon;
  end;

  TFolderIcon = record
    Name: string;
    Icon: TStockIcon;
  end;

const
  ExtensionIcons: array[0..63] of TExtensionIcon = (
    (Extension: 'txt'; Icon: StockIconDocument), (Extension: 'text'; Icon: StockIconDocument),
    (Extension: 'md'; Icon: StockIconDocument), (Extension: 'log'; Icon: StockIconDocument),
    (Extension: 'pas'; Icon: StockIconDocument), (Extension: 'pp'; Icon: StockIconDocument),
    (Extension: 'inc'; Icon: StockIconDocument), (Extension: 'c'; Icon: StockIconDocument),
    (Extension: 'h'; Icon: StockIconDocument), (Extension: 'sh'; Icon: StockIconDocument),
    (Extension: 'py'; Icon: StockIconDocument), (Extension: 'json'; Icon: StockIconDocument),
    (Extension: 'xml'; Icon: StockIconDocument), (Extension: 'html'; Icon: StockIconDocument),
    (Extension: 'css'; Icon: StockIconDocument), (Extension: 'js'; Icon: StockIconDocument),
    (Extension: 'conf'; Icon: StockIconSettingsFile), (Extension: 'cfg'; Icon: StockIconSettingsFile),
    (Extension: 'ini'; Icon: StockIconSettingsFile), (Extension: 'settings'; Icon: StockIconSettingsFile),
    (Extension: 'service'; Icon: StockIconSettingsFile), (Extension: 'rtf'; Icon: StockIconRichDocument),
    (Extension: 'doc'; Icon: StockIconRichDocument), (Extension: 'docx'; Icon: StockIconRichDocument),
    (Extension: 'odt'; Icon: StockIconRichDocument), (Extension: 'csv'; Icon: StockIconSpreadsheet),
    (Extension: 'tsv'; Icon: StockIconSpreadsheet), (Extension: 'xls'; Icon: StockIconSpreadsheet),
    (Extension: 'xlsx'; Icon: StockIconSpreadsheet), (Extension: 'ods'; Icon: StockIconSpreadsheet),
    (Extension: 'ppt'; Icon: StockIconPresentation), (Extension: 'pptx'; Icon: StockIconPresentation),
    (Extension: 'odp'; Icon: StockIconPresentation), (Extension: 'pdf'; Icon: StockIconPdf),
    (Extension: 'png'; Icon: StockIconImage), (Extension: 'jpg'; Icon: StockIconImage),
    (Extension: 'jpeg'; Icon: StockIconImage), (Extension: 'gif'; Icon: StockIconImage),
    (Extension: 'bmp'; Icon: StockIconImage), (Extension: 'tif'; Icon: StockIconImage),
    (Extension: 'tiff'; Icon: StockIconImage), (Extension: 'webp'; Icon: StockIconImage),
    (Extension: 'jxl'; Icon: StockIconImage), (Extension: 'ico'; Icon: StockIconImage),
    (Extension: 'cur'; Icon: StockIconImage), (Extension: 'wav'; Icon: StockIconAudio),
    (Extension: 'mp3'; Icon: StockIconAudio), (Extension: 'ogg'; Icon: StockIconAudio),
    (Extension: 'flac'; Icon: StockIconAudio), (Extension: 'mp4'; Icon: StockIconVideo),
    (Extension: 'mkv'; Icon: StockIconVideo), (Extension: 'avi'; Icon: StockIconVideo),
    (Extension: 'webm'; Icon: StockIconVideo), (Extension: 'zip'; Icon: StockIconArchive),
    (Extension: 'gz'; Icon: StockIconArchive), (Extension: 'tgz'; Icon: StockIconArchive),
    (Extension: 'tar'; Icon: StockIconArchive), (Extension: 'xz'; Icon: StockIconArchive),
    (Extension: 'bz2'; Icon: StockIconArchive), (Extension: '7z'; Icon: StockIconArchive),
    (Extension: 'ttf'; Icon: StockIconFont), (Extension: 'otf'; Icon: StockIconFont),
    (Extension: 'psf'; Icon: StockIconFont), (Extension: 'iso'; Icon: StockIconOpticalDisk));

  FolderIcons: array[0..8] of TFolderIcon = (
    (Name: 'documents'; Icon: StockIconFolderDocuments), (Name: 'pictures'; Icon: StockIconFolderPictures),
    (Name: 'music'; Icon: StockIconFolderMusic), (Name: 'videos'; Icon: StockIconFolderVideos),
    (Name: 'downloads'; Icon: StockIconFolderDownloads), (Name: 'projects'; Icon: StockIconFolderProjects),
    (Name: 'public'; Icon: StockIconFolderPublic), (Name: 'templates'; Icon: StockIconFolderTemplates),
    (Name: 'archives'; Icon: StockIconFolderCompressed));

{ The text after the last dot, in small letters ('' for none, or for a
  name that only starts with a dot). }
function LowerExtension(const Name: string): string;
var
  Index: LongInt;
begin
  Result := '';
  Index := Length(Name);
  while (Index > 1) and (Name[Index] <> '.') do
    Dec(Index);
  if (Index > 1) and (Index < Length(Name)) then
    Result := LowerCase(Copy(Name, Index + 1, Length(Name) - Index));
end;

function IconForFileName(const Name: string; Fallback: TStockIcon): TStockIcon;
var
  Extension: string;
  Index: LongInt;
begin
  Result := Fallback;
  Extension := LowerExtension(Name);
  if Extension = '' then
    Exit;
  for Index := Low(ExtensionIcons) to High(ExtensionIcons) do
    if ExtensionIcons[Index].Extension = Extension then
      Exit(ExtensionIcons[Index].Icon);
end;

function IconForFolderName(const Name: string): TStockIcon;
var
  Lower: string;
  Index: LongInt;
begin
  Result := StockIconFolder;
  Lower := LowerCase(Name);
  for Index := Low(FolderIcons) to High(FolderIcons) do
    if FolderIcons[Index].Name = Lower then
      Exit(FolderIcons[Index].Icon);
end;

end.
