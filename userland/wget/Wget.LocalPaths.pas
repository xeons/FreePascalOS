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
  Where a recursive wget keeps what it fetches, as GNU wget does: a
  folder per host ("10.0.2.102", "host:8080" for another port than the
  scheme's), then the URL's path, its segments decoded; a path ending
  in "/" gets index.html, and a query stays in the name
  ("list.cgi?page=2"). -P puts it all under a folder; -nH leaves the
  host's folder out, -nd every folder.

  RelativeLink gives the link from one such file to another, for
  converting links (-k): "host/a/b.html" to "host/c.png" is "../c.png".

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Wget.LocalPaths;

{$mode objfpc}
{$H+}

interface

uses
  Wget.Urls;

type
  TLocalLayout = record
    { -P: '' or a folder. }
    Prefix: string;
    { -nH, -nd. }
    NoHostFolder: Boolean;
    NoFolders: Boolean;
  end;

{ The file a URL is kept in. }
function LocalPathFor(constref Url: TUrl; constref Layout: TLocalLayout): string;
{ The link from the file FromPath to the file ToPath (both as
  LocalPathFor gives them). }
function RelativeLink(const FromPath, ToPath: string): string;
{ The folder part of a path ("a/b/c.html" -> "a/b"; '' for none). }
function FolderOf(const Path: string): string;

implementation

uses
  SysUtils;

const
  IndexName = 'index.html';

function HostFolder(constref Url: TUrl): string;
begin
  Result := Url.Host;
  if Url.Port <> DefaultPort(Url.Scheme) then
    Result := Result + ':' + IntToStr(Url.Port);
end;

{ A segment that cannot name something else: "." and ".." kept as text. }
function SafeSegment(const Segment: string): string;
begin
  Result := DecodeFileName(Segment);
  if (Result = '.') or (Result = '..') then
    Result := StringReplace(Result, '.', '%2E', [rfReplaceAll]);
end;

function LocalPathFor(constref Url: TUrl; constref Layout: TLocalLayout): string;
var
  Path, Query: string;
  QueryStart: Integer;
  Segments: TStringArray;
  Index: Integer;
begin
  Path := Url.Path;
  Query := '';
  QueryStart := Pos('?', Path);
  if QueryStart > 0 then
  begin
    Query := Copy(Path, QueryStart, MaxInt);
    SetLength(Path, QueryStart - 1);
  end;
  if (Path = '') or (Path[Length(Path)] = '/') then
    Path := Path + IndexName;
  Result := '';
  if not Layout.NoHostFolder and not Layout.NoFolders then
    Result := HostFolder(Url);
  Segments := Path.Split(['/']);
  for Index := 0 to High(Segments) do
    if (Segments[Index] <> '') and (not Layout.NoFolders or (Index = High(Segments))) then
    begin
      if Result <> '' then
        Result := Result + '/';
      Result := Result + SafeSegment(Segments[Index]);
    end;
  Result := Result + StringReplace(Query, '/', '%2F', [rfReplaceAll]);
  if Layout.Prefix <> '' then
  begin
    if Layout.Prefix[Length(Layout.Prefix)] = '/' then
      Result := Layout.Prefix + Result
    else
      Result := Layout.Prefix + '/' + Result;
  end;
end;

function FolderOf(const Path: string): string;
var
  Slash: Integer;
begin
  Slash := Length(Path);
  while (Slash > 0) and (Path[Slash] <> '/') do
    Dec(Slash);
  if Slash = 0 then
    Result := ''
  else
    Result := Copy(Path, 1, Slash - 1);
end;

function RelativeLink(const FromPath, ToPath: string): string;
var
  FromParts, ToParts: TStringArray;
  Common, Index: Integer;
begin
  FromParts := FolderOf(FromPath).Split(['/']);
  if FolderOf(FromPath) = '' then
    FromParts := nil;
  ToParts := ToPath.Split(['/']);
  Common := 0;
  { The folders both share (the last part of ToPath is its file). }
  while (Common < Length(FromParts)) and (Common < Length(ToParts) - 1) and
        (FromParts[Common] = ToParts[Common]) do
    Inc(Common);
  Result := '';
  for Index := Common to High(FromParts) do
    Result := Result + '../';
  for Index := Common to High(ToParts) do
  begin
    Result := Result + ToParts[Index];
    if Index < High(ToParts) then
      Result := Result + '/';
  end;
end;

end.
