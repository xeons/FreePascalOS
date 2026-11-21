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
  What kind of thing a file is, told by its name's extension: a
  picture, music, a video, a document, text or code, a web page, an
  archive, a program, or something else; and the media type ("image/
  png") the extension stands for.

  The kinds are what search's "kind:" and the Filter menu choose by,
  what the gallery collects (pictures) and what the preview pane shows
  a file with. Plain text logic, checked on the host (make files-test).
}
unit FileManager.FileKinds;

{$mode objfpc}
{$H+}

interface

type
  TFileKind = (FileKindFolder, FileKindPicture, FileKindMusic, FileKindVideo, FileKindDocument, FileKindText,
    FileKindWebPage, FileKindArchive, FileKindProgram, FileKindOther);
  TFileKinds = set of TFileKind;

const
  FileKindNames: array[TFileKind] of string = ('folder', 'picture', 'music', 'video', 'document', 'text',
    'webpage', 'archive', 'program', 'other');
  FileKindTitles: array[TFileKind] of string = ('Folders', 'Pictures', 'Music', 'Videos', 'Documents', 'Text',
    'Web pages', 'Compressed', 'Programs', 'Other');

{ The kind of a file named Name (not a folder: the caller knows those). }
function FileKindOfName(const Name: string): TFileKind;
function FileKindOfExtension(const Extension: string): TFileKind;
{ The kind a word of search ("image", "photo", "music", "doc"...)
  stands for; False if none. }
function FileKindNamed(const Word: string; out Kind: TFileKind): Boolean;
{ The media type of an extension ('application/octet-stream' if not
  known). }
function MimeTypeOfExtension(const Extension: string): string;
{ Whether files of these extensions can be shown as thumbnails
  (pictures libimage reads, SVG drawings). }
function HasThumbnail(const Extension: string): Boolean;
{ Whether the extension is a ZIP or tar archive the file manager can
  browse as a folder. }
function IsBrowsableArchiveExtension(const Name: string): Boolean;

implementation

uses
  SysUtils,
  FileManager.Paths;

type
  TExtensionEntry = record
    Extension: string;
    Kind: TFileKind;
    MimeType: string;
  end;

const
  KnownExtensions: array[0..69] of TExtensionEntry = (
    (Extension: 'png'; Kind: FileKindPicture; MimeType: 'image/png'),
    (Extension: 'jpg'; Kind: FileKindPicture; MimeType: 'image/jpeg'),
    (Extension: 'jpeg'; Kind: FileKindPicture; MimeType: 'image/jpeg'),
    (Extension: 'gif'; Kind: FileKindPicture; MimeType: 'image/gif'),
    (Extension: 'webp'; Kind: FileKindPicture; MimeType: 'image/webp'),
    (Extension: 'bmp'; Kind: FileKindPicture; MimeType: 'image/bmp'),
    (Extension: 'ico'; Kind: FileKindPicture; MimeType: 'image/x-icon'),
    (Extension: 'svg'; Kind: FileKindPicture; MimeType: 'image/svg+xml'),
    (Extension: 'jxl'; Kind: FileKindPicture; MimeType: 'image/jxl'),
    (Extension: 'tif'; Kind: FileKindPicture; MimeType: 'image/tiff'),
    (Extension: 'tiff'; Kind: FileKindPicture; MimeType: 'image/tiff'),
    (Extension: 'wav'; Kind: FileKindMusic; MimeType: 'audio/wav'),
    (Extension: 'mp3'; Kind: FileKindMusic; MimeType: 'audio/mpeg'),
    (Extension: 'ogg'; Kind: FileKindMusic; MimeType: 'audio/ogg'),
    (Extension: 'flac'; Kind: FileKindMusic; MimeType: 'audio/flac'),
    (Extension: 'opus'; Kind: FileKindMusic; MimeType: 'audio/opus'),
    (Extension: 'm4a'; Kind: FileKindMusic; MimeType: 'audio/mp4'),
    (Extension: 'mp4'; Kind: FileKindVideo; MimeType: 'video/mp4'),
    (Extension: 'mkv'; Kind: FileKindVideo; MimeType: 'video/x-matroska'),
    (Extension: 'webm'; Kind: FileKindVideo; MimeType: 'video/webm'),
    (Extension: 'avi'; Kind: FileKindVideo; MimeType: 'video/x-msvideo'),
    (Extension: 'mov'; Kind: FileKindVideo; MimeType: 'video/quicktime'),
    (Extension: 'pdf'; Kind: FileKindDocument; MimeType: 'application/pdf'),
    (Extension: 'odt'; Kind: FileKindDocument; MimeType: 'application/vnd.oasis.opendocument.text'),
    (Extension: 'ods'; Kind: FileKindDocument; MimeType: 'application/vnd.oasis.opendocument.spreadsheet'),
    (Extension: 'odp'; Kind: FileKindDocument; MimeType: 'application/vnd.oasis.opendocument.presentation'),
    (Extension: 'rtf'; Kind: FileKindDocument; MimeType: 'application/rtf'),
    (Extension: 'epub'; Kind: FileKindDocument; MimeType: 'application/epub+zip'),
    (Extension: 'txt'; Kind: FileKindText; MimeType: 'text/plain'),
    (Extension: 'text'; Kind: FileKindText; MimeType: 'text/plain'),
    (Extension: 'md'; Kind: FileKindText; MimeType: 'text/markdown'),
    (Extension: 'log'; Kind: FileKindText; MimeType: 'text/plain'),
    (Extension: 'ini'; Kind: FileKindText; MimeType: 'text/plain'),
    (Extension: 'conf'; Kind: FileKindText; MimeType: 'text/plain'),
    (Extension: 'cfg'; Kind: FileKindText; MimeType: 'text/plain'),
    (Extension: 'info'; Kind: FileKindText; MimeType: 'text/plain'),
    (Extension: 'json'; Kind: FileKindText; MimeType: 'application/json'),
    (Extension: 'xml'; Kind: FileKindText; MimeType: 'application/xml'),
    (Extension: 'csv'; Kind: FileKindText; MimeType: 'text/csv'),
    (Extension: 'pas'; Kind: FileKindText; MimeType: 'text/x-pascal'),
    (Extension: 'pp'; Kind: FileKindText; MimeType: 'text/x-pascal'),
    (Extension: 'inc'; Kind: FileKindText; MimeType: 'text/x-pascal'),
    (Extension: 'c'; Kind: FileKindText; MimeType: 'text/x-c'),
    (Extension: 'h'; Kind: FileKindText; MimeType: 'text/x-c'),
    (Extension: 'cpp'; Kind: FileKindText; MimeType: 'text/x-c++'),
    (Extension: 'py'; Kind: FileKindText; MimeType: 'text/x-python'),
    (Extension: 'sh'; Kind: FileKindText; MimeType: 'application/x-shellscript'),
    (Extension: 'js'; Kind: FileKindText; MimeType: 'text/javascript'),
    (Extension: 'css'; Kind: FileKindText; MimeType: 'text/css'),
    (Extension: 'yaml'; Kind: FileKindText; MimeType: 'application/yaml'),
    (Extension: 'yml'; Kind: FileKindText; MimeType: 'application/yaml'),
    (Extension: 'toml'; Kind: FileKindText; MimeType: 'application/toml'),
    (Extension: 'mk'; Kind: FileKindText; MimeType: 'text/x-makefile'),
    (Extension: 's'; Kind: FileKindText; MimeType: 'text/x-asm'),
    (Extension: 'asm'; Kind: FileKindText; MimeType: 'text/x-asm'),
    (Extension: 'html'; Kind: FileKindWebPage; MimeType: 'text/html'),
    (Extension: 'htm'; Kind: FileKindWebPage; MimeType: 'text/html'),
    (Extension: 'xhtml'; Kind: FileKindWebPage; MimeType: 'application/xhtml+xml'),
    (Extension: 'zip'; Kind: FileKindArchive; MimeType: 'application/zip'),
    (Extension: 'tar'; Kind: FileKindArchive; MimeType: 'application/x-tar'),
    (Extension: 'tgz'; Kind: FileKindArchive; MimeType: 'application/gzip'),
    (Extension: 'gz'; Kind: FileKindArchive; MimeType: 'application/gzip'),
    (Extension: 'xz'; Kind: FileKindArchive; MimeType: 'application/x-xz'),
    (Extension: 'zst'; Kind: FileKindArchive; MimeType: 'application/zstd'),
    (Extension: '7z'; Kind: FileKindArchive; MimeType: 'application/x-7z-compressed'),
    (Extension: 'elf'; Kind: FileKindProgram; MimeType: 'application/x-executable'),
    (Extension: 'so'; Kind: FileKindProgram; MimeType: 'application/x-sharedlib'),
    (Extension: 'ttf'; Kind: FileKindOther; MimeType: 'font/ttf'),
    (Extension: 'otf'; Kind: FileKindOther; MimeType: 'font/otf'),
    (Extension: 'psf'; Kind: FileKindOther; MimeType: 'application/x-font-psf'));

  { Words search's "kind:" takes for each kind. }
  KindWords: array[0..21] of record
    Word: string;
    Kind: TFileKind;
  end = (
    (Word: 'folder'; Kind: FileKindFolder), (Word: 'folders'; Kind: FileKindFolder),
    (Word: 'picture'; Kind: FileKindPicture), (Word: 'pictures'; Kind: FileKindPicture),
    (Word: 'image'; Kind: FileKindPicture), (Word: 'photo'; Kind: FileKindPicture),
    (Word: 'music'; Kind: FileKindMusic), (Word: 'audio'; Kind: FileKindMusic),
    (Word: 'video'; Kind: FileKindVideo), (Word: 'movie'; Kind: FileKindVideo),
    (Word: 'document'; Kind: FileKindDocument), (Word: 'doc'; Kind: FileKindDocument),
    (Word: 'text'; Kind: FileKindText), (Word: 'code'; Kind: FileKindText),
    (Word: 'webpage'; Kind: FileKindWebPage), (Word: 'web'; Kind: FileKindWebPage),
    (Word: 'archive'; Kind: FileKindArchive), (Word: 'compressed'; Kind: FileKindArchive),
    (Word: 'zip'; Kind: FileKindArchive), (Word: 'program'; Kind: FileKindProgram),
    (Word: 'app'; Kind: FileKindProgram), (Word: 'other'; Kind: FileKindOther));

function FindExtension(const Extension: string): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(KnownExtensions) do
    if KnownExtensions[Index].Extension = Extension then
      Exit(Index);
  Result := -1;
end;

function FileKindOfExtension(const Extension: string): TFileKind;
var
  Index: LongInt;
begin
  Index := FindExtension(LowerCase(Extension));
  if Index < 0 then
    Exit(FileKindOther);
  Result := KnownExtensions[Index].Kind;
end;

function FileKindOfName(const Name: string): TFileKind;
begin
  Result := FileKindOfExtension(ExtensionOf(Name));
end;

function FileKindNamed(const Word: string; out Kind: TFileKind): Boolean;
var
  Index: LongInt;
  Lowered: string;
begin
  Lowered := LowerCase(Word);
  for Index := 0 to High(KindWords) do
    if KindWords[Index].Word = Lowered then
    begin
      Kind := KindWords[Index].Kind;
      Exit(True);
    end;
  Kind := FileKindOther;
  Result := False;
end;

function MimeTypeOfExtension(const Extension: string): string;
var
  Index: LongInt;
begin
  Index := FindExtension(LowerCase(Extension));
  if Index < 0 then
    Exit('application/octet-stream');
  Result := KnownExtensions[Index].MimeType;
end;

function HasThumbnail(const Extension: string): Boolean;
var
  Lowered: string;
begin
  Lowered := LowerCase(Extension);
  Result := (FileKindOfExtension(Lowered) = FileKindPicture);
end;

function IsBrowsableArchiveExtension(const Name: string): Boolean;
var
  Lowered: string;
  Extension: string;
begin
  Lowered := LowerCase(Name);
  Extension := ExtensionOf(Lowered);
  Result := (Extension = 'zip') or (Extension = 'tar') or (Extension = 'tgz') or
    ((Extension = 'gz') and (Copy(Lowered, Length(Lowered) - 6, 7) = '.tar.gz'));
end;

end.
