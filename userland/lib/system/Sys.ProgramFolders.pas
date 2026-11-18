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
  Where the graphical programs are installed: each in a folder of its
  own under /app (/app/notepad, /app/paint...), with its executable,
  its description (program.info) and maybe its own icons. The folder
  and the executable usually share the program's name, so notepad is
  /app/notepad/notepad.

  Programs are still started by name: FindProgramPath (Sys.Processes)
  looks here when the name is not in PATH. Reading the descriptions
  (names, categories, icons) is libconfiguration's
  (Configuration.ProgramFolders); this is only finding executables, so
  the lowest library can do it.
}
unit Sys.ProgramFolders;

{$mode objfpc}{$H+}

interface

const
  ProgramFoldersRoot = '/app';
  { The file in each folder that describes its program. }
  ProgramInfoFileName = 'program.info';

type
  TProgramFolderNames = array of string;

{ The executable Name in a program folder: /app/Name/Name if there is
  one, else the first /app/FOLDER/Name. False (and Path empty) if no
  folder has it. }
function FindInProgramFolders(const Name: string; out Path: string): Boolean;
{ The folder names under /app (none if it is missing). }
function ListProgramFolders: TProgramFolderNames;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files;

function IsRegularFile(const Path: string): Boolean;
var
  Information: TFileInformation;
begin
  Result := (GetFileInformation(PChar(Path), Information) = ErrorNone) and (Information.Kind = KindFile);
end;

function IsDotName(const Name: string): Boolean;
begin
  Result := (Name = '.') or (Name = '..');
end;

function ListProgramFolders: TProgramFolderNames;
var
  Handle: Int64;
  Entry: TDirectoryEntry;
  Name: string;
  Count: LongInt;
begin
  Result := nil;
  Count := 0;
  Handle := OpenFile(ProgramFoldersRoot, OpenRead);
  if Handle < 0 then
    Exit;
  while ReadDirectoryEntry(Handle, Entry) do
  begin
    Name := PChar(@Entry.Name[0]);
    if IsDotName(Name) or not IsDirectory(PChar(ProgramFoldersRoot + '/' + Name)) then
      Continue;
    if Count = Length(Result) then
      SetLength(Result, Count * 2 + 8);
    Result[Count] := Name;
    Inc(Count);
  end;
  CloseFile(Handle);
  SetLength(Result, Count);
end;

{ A name that can be an executable in a folder: no path, not the
  description file. }
function CanBeExecutableName(const Name: string): Boolean;
begin
  Result := (Name <> '') and (Pos('/', Name) = 0) and not IsDotName(Name) and (Name <> ProgramInfoFileName);
end;

function FindInProgramFolders(const Name: string; out Path: string): Boolean;
var
  Folders: TProgramFolderNames;
  Index: LongInt;
  Candidate: string;
begin
  Path := '';
  if not CanBeExecutableName(Name) then
    Exit(False);
  Candidate := ProgramFoldersRoot + '/' + Name + '/' + Name;
  if IsRegularFile(Candidate) then
  begin
    Path := Candidate;
    Exit(True);
  end;
  Folders := ListProgramFolders;
  for Index := 0 to High(Folders) do
  begin
    Candidate := ProgramFoldersRoot + '/' + Folders[Index] + '/' + Name;
    if IsRegularFile(Candidate) then
    begin
      Path := Candidate;
      Exit(True);
    end;
  end;
  Result := False;
end;

end.
