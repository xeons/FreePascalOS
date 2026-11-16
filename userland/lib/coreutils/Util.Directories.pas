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
  Reading whole directories.

  ListDirectory returns the names in a directory (without "." and "..")
  in a TStrings, so tools can sort them or walk a tree recursively.
}
unit Util.Directories;

{$mode objfpc}{$H+}

interface

uses
  Classes;

{ Returns 0 or an error code. Names are added to Names. }
function ListDirectory(const Path: string; Names: TStrings): LongInt;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Util.Paths;

function ListDirectory(const Path: string; Names: TStrings): LongInt;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Information: TFileInformation;
  Name: string;
begin
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  if (GetHandleInformation(Handle, Information) = ErrorNone) and (Information.Kind <> KindDirectory) then
  begin
    CloseFile(Handle);
    Exit(ErrorNotDirectory);
  end;
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    Name := PChar(@Entry.Name[0]);
    if not IsDotEntry(Name) then
      Names.Add(Name);
  end;
  CloseFile(Handle);
  Result := ErrorNone;
end;

end.
