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
  in a line list, so tools can sort them or walk a tree recursively.
}
unit Util.Directories;

{$mode objfpc}
{$pointermath on}

interface

uses
  Util.Input;

{ Returns 0 or an error code. Names are added to List (which the caller
  has begun and must free). }
function ListDirectory(Path: PChar; var List: TLineList): LongInt;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Memory,
  Util.Paths;

function ListDirectory(Path: PChar; var List: TLineList): LongInt;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Information: TFileInformation;
begin
  Handle := OpenFile(Path, OpenRead);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  if (GetHandleInformation(Handle, Information) = ErrorNone) and (Information.Kind <> KindDirectory) then
  begin
    CloseFile(Handle);
    Exit(ErrorNotDirectory);
  end;
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    if not IsDotEntry(@Entry.Name[0]) then
      AddLine(List, DuplicateText(@Entry.Name[0]));
  end;
  CloseFile(Handle);
  Result := ErrorNone;
end;

end.
