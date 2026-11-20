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
  file: URLs (Fetch leaves them to the implementation): the path of a
  URL whose host is empty or "localhost" (percent-decoded), the MIME
  type from the file name's extension, and for a folder an HTML index
  of its entries (folders first, then files, by name), so the browser
  can open local pages and walk the disk.
}
unit Web.Fetch.LocalFiles;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records;

{ The local path of a file: URL; False when it names another host. }
function LocalPathOfUrl(constref Url: TUrlRecord; out Path: string): Boolean;
{ The file: URL of a local path. }
function UrlOfLocalPath(const Path: string): string;
{ The MIME type a file name's extension suggests ('' when unknown). }
function MimeTypeForFileName(const FileName: string): string;
{ An HTML page listing a folder (Url: the folder's file: URL). }
function FolderIndexPage(const Path: string; constref Url: TUrlRecord): string;

implementation

uses
  Url.PercentEncoding;

function LocalPathOfUrl(constref Url: TUrlRecord; out Path: string): Boolean;
begin
  Path := '';
  if Url.Scheme <> 'file' then
    Exit(False);
  if not (Url.Host.Kind in [UrlHostNull, UrlHostEmpty]) and
     not ((Url.Host.Kind = UrlHostDomain) and (Url.Host.Name = 'localhost')) then
    Exit(False);
  Path := PercentDecode(Url.Path);
  if Path = '' then
    Path := '/';
  Result := True;
end;

function UrlOfLocalPath(const Path: string): string;
var
  Index: Integer;
begin
  Result := 'file://';
  for Index := 1 to Length(Path) do
    if Path[Index] in ['A'..'Z', 'a'..'z', '0'..'9', '/', '-', '.', '_', '~'] then
      Result := Result + Path[Index]
    else
      Result := Result + '%' + IntToHex(Ord(Path[Index]), 2);
end;

function MimeTypeForFileName(const FileName: string): string;
begin
  case LowerCase(ExtractFileExt(FileName)) of
    '.html', '.htm', '.shtml': Result := 'text/html';
    '.xhtml', '.xht': Result := 'application/xhtml+xml';
    '.xml': Result := 'text/xml';
    '.svg': Result := 'image/svg+xml';
    '.css': Result := 'text/css';
    '.js', '.mjs': Result := 'text/javascript';
    '.json': Result := 'application/json';
    '.txt', '.text', '.log', '.md', '.pas', '.inc', '.c', '.h', '.py', '.sh', '.conf', '.ini', '.csv':
      Result := 'text/plain';
    '.png': Result := 'image/png';
    '.jpg', '.jpeg', '.jpe': Result := 'image/jpeg';
    '.gif': Result := 'image/gif';
    '.bmp': Result := 'image/bmp';
    '.ico', '.cur': Result := 'image/x-icon';
    '.webp': Result := 'image/webp';
    '.tif', '.tiff': Result := 'image/tiff';
    '.jxl': Result := 'image/jxl';
    '.ttf': Result := 'font/ttf';
    '.otf': Result := 'font/otf';
    '.woff': Result := 'font/woff';
    '.woff2': Result := 'font/woff2';
    '.pdf': Result := 'application/pdf';
    '.wav': Result := 'audio/wav';
    '.mp3': Result := 'audio/mpeg';
    '.ogg': Result := 'audio/ogg';
  else
    Result := '';
  end;
end;

function EscapeHtml(const Text: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 1 to Length(Text) do
    case Text[Index] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
    else
      Result := Result + Text[Index];
    end;
end;

function FolderIndexPage(const Path: string; constref Url: TUrlRecord): string;
var
  Search: TSearchRec;
  Folders, Files: TStringList;
  Index: Integer;
  Base: string;
begin
  Folders := TStringList.Create;
  Files := TStringList.Create;
  try
    Folders.Sorted := True;
    Files.Sorted := True;
    Base := IncludeTrailingPathDelimiter(Path);
    if FindFirst(Base + '*', faAnyFile or faDirectory, Search) = 0 then
    begin
      repeat
        if (Search.Name = '.') or (Search.Name = '..') then
          Continue;
        if (Search.Attr and faDirectory) <> 0 then
          Folders.Add(Search.Name)
        else
          Files.Add(Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
    Result := '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Index of ' + EscapeHtml(Path) +
      '</title></head><body><h1>Index of ' + EscapeHtml(Path) + '</h1><ul>';
    if Path <> '/' then
      Result := Result + '<li><a href="..">..</a></li>';
    for Index := 0 to Folders.Count - 1 do
      Result := Result + '<li><a href="' + EscapeHtml(UrlOfLocalPath(Base + Folders[Index])) + '/">' +
        EscapeHtml(Folders[Index]) + '/</a></li>';
    for Index := 0 to Files.Count - 1 do
      Result := Result + '<li><a href="' + EscapeHtml(UrlOfLocalPath(Base + Files[Index])) + '">' +
        EscapeHtml(Files[Index]) + '</a></li>';
    Result := Result + '</ul></body></html>';
  finally
    Folders.Free;
    Files.Free;
  end;
end;

end.
