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
  Paths as SFTP clients send them: relative ones are taken from the
  server's current directory (the user's home), REALPATH makes them
  absolute with "." and ".." worked out, and expand-path@openssh.com
  also turns a leading "~" or "~/" into the home directory.
}
unit Sftp.Paths;

{$mode objfpc}{$H+}

interface

{ The absolute form of Path, without ".", ".." or doubled slashes. }
function CanonicalPath(const Path: string): string;
{ The same after "~" and "~/..." become the home directory. }
function ExpandedPath(const Path: string): string;

implementation

uses
  SysUtils,
  Sys.Environment,
  Sys.Files;

function CurrentDirectory: string;
begin
  if CurrentDirectoryPath(Result) <> 0 then
    Result := '/';
end;

function CanonicalPath(const Path: string): string;
var
  Full: string;
  Parts: array of string;
  Count: Integer;
  Start, Index: Integer;
  Part: string;
begin
  if (Path <> '') and (Path[1] = '/') then
    Full := Path
  else
    Full := CurrentDirectory + '/' + Path;
  Parts := nil;
  Count := 0;
  Start := 1;
  for Index := 1 to Length(Full) + 1 do
    if (Index > Length(Full)) or (Full[Index] = '/') then
    begin
      Part := Copy(Full, Start, Index - Start);
      Start := Index + 1;
      if (Part = '') or (Part = '.') then
        Continue;
      if Part = '..' then
      begin
        if Count > 0 then
          Dec(Count);
        Continue;
      end;
      if Count >= Length(Parts) then
        SetLength(Parts, Count + 8);
      Parts[Count] := Part;
      Inc(Count);
    end;
  if Count = 0 then
    Exit('/');
  Result := '';
  for Index := 0 to Count - 1 do
    Result := Result + '/' + Parts[Index];
end;

function ExpandedPath(const Path: string): string;
var
  Home: string;
begin
  Home := GetVariable('HOME');
  if Home = '' then
    Home := '/';
  if Path = '~' then
    Result := CanonicalPath(Home)
  else if Copy(Path, 1, 2) = '~/' then
    Result := CanonicalPath(Home + '/' + Copy(Path, 3, MaxInt))
  else
    Result := CanonicalPath(Path);
end;

end.
