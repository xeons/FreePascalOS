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
  Paths as the file manager reasons about them, as text: whether one is
  inside another (a folder cannot be copied into itself), whether a
  name is hidden, a name's extension, and whether a name may be given
  to a file at all.

  Paths are absolute and clean (Controls.FileNames.CleanPath): no "."
  or "..", no slash at the end except "/" itself. Nothing here looks at
  the file system, so the host checks it (make files-test).
}
unit FileManager.Paths;

{$mode objfpc}
{$H+}

interface

{ True if Path is Folder or anything below it. }
function IsSameOrInside(const Path, Folder: string): Boolean;
{ A name starting with a dot is hidden unless hidden files are shown. }
function IsHiddenName(const Name: string): Boolean;
{ The extension in small letters, without the dot ("TXT" -> "txt");
  '' for none, and for a name whose only dot starts it (".profile"). }
function ExtensionOf(const Name: string): string;
{ Why Name cannot name a file ('' if it can): empty, "." or "..", or a
  slash or a zero byte in it, or longer than a name may be. }
function NameProblem(const Name: string): string;

implementation

uses
  SysUtils;

const
  { Bytes in a name (the file systems' common limit). }
  LongestName = 255;

function IsSameOrInside(const Path, Folder: string): Boolean;
begin
  if Path = Folder then
    Exit(True);
  if Folder = '/' then
    Exit((Path <> '') and (Path[1] = '/'));
  Result := (Length(Path) > Length(Folder)) and (Copy(Path, 1, Length(Folder)) = Folder) and
    (Path[Length(Folder) + 1] = '/');
end;

function IsHiddenName(const Name: string): Boolean;
begin
  Result := (Name <> '') and (Name[1] = '.');
end;

function ExtensionOf(const Name: string): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := Length(Name) downto 2 do
    if Name[Index] = '.' then
    begin
      Result := LowerCase(Copy(Name, Index + 1, Length(Name)));
      Exit;
    end;
end;

function NameProblem(const Name: string): string;
begin
  if Name = '' then
    Exit('A name cannot be empty.');
  if (Name = '.') or (Name = '..') then
    Exit('"' + Name + '" is not a name a file can have.');
  if Pos('/', Name) > 0 then
    Exit('A name cannot contain a slash (/).');
  if Pos(#0, Name) > 0 then
    Exit('A name cannot contain a zero byte.');
  if Length(Name) > LongestName then
    Exit('The name is too long.');
  Result := '';
end;

end.
