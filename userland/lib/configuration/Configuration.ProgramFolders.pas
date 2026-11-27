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
  The installed graphical programs: every folder under /app, and under
  /usr/local/app (ported software's), with a program.info
  (Configuration.ProgramInfo) that describes a program whose executable
  is there. Folders that do not are left out (with why, for whoever
  lists them). A port's folder named like one of /app's is left out
  too: the system's own program keeps its name.

  The list is sorted as the Start menu shows it: by category
  (TProgramCategory's order), then by name. A program's icon is the
  folder's own (icons/NAME.ico, the theme's sizes in one file) when it
  has one, else the theme's icon of that name; ProgramIconName gives
  the one to ask Controls.IconFiles for (a full path for the folder's).

  Only the runtime library's files and folders (SysUtils), so it builds
  and is checked on the host too (tools/SettingsTest), over folders
  made for the test.
}
unit Configuration.ProgramFolders;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.ProgramInfo;

type
  TProgramList = array of TProgramInfo;

  TProgramFolderProblem = record
    Folder: string;
    Problem: string;
  end;
  TProgramFolderProblems = array of TProgramFolderProblem;

{ Reads the program in the folder at Path. False (Problems saying why)
  if it has no program.info, an invalid one, or not the executable it
  names. }
function ReadProgramFolder(const Path: string; out Info: TProgramInfo; out Problems: TStringArray): Boolean;
{ Every program under Root, sorted; the folders left out in Skipped. }
function DiscoverPrograms(const Root: string; out Skipped: TProgramFolderProblems): TProgramList;
function DiscoverPrograms(const Root: string = DefaultProgramFoldersRoot): TProgramList;
{ Every program under the roots, sorted; a folder named like one of an
  earlier root's is skipped. }
function DiscoverProgramsIn(const Roots: array of string; out Skipped: TProgramFolderProblems): TProgramList;
{ Every installed program: /app's and /usr/local/app's. }
function DiscoverInstalledPrograms(out Skipped: TProgramFolderProblems): TProgramList;
function DiscoverInstalledPrograms: TProgramList;
{ The programs that are not Hidden (for the menu and the desktop). }
function ShownPrograms(const List: TProgramList): TProgramList;
{ The index of the program with that executable or folder name; -1. }
function FindProgramByExecutable(const List: TProgramList; const Executable: string): Integer;
function FindProgramByFolder(const List: TProgramList; const FolderName: string): Integer;
{ The executable's full path (/app/notepad/notepad). }
function ProgramExecutablePath(const Info: TProgramInfo): string;
{ The folder's own icon file for the program's icon ('' if none). }
function ProgramOwnIconFile(const Info: TProgramInfo): string;
{ The icon to draw: the folder's icon file (a full path) if it has one,
  else the theme icon's name. }
function ProgramIconName(const Info: TProgramInfo): string;
{ Sorted by category, then name (case-insensitive), then folder. }
procedure SortPrograms(var List: TProgramList);
function CompareProgramOrder(const First, Second: TProgramInfo): Integer;

implementation

const
  IconFileExtension = '.ico';
  { Larger is not a program description. }
  MaximumInfoFileSize = 64 * 1024;

function ReadSmallTextFile(const Path: string; out Text: string): Boolean;
var
  Handle: THandle;
  Size: Int64;
  Count: LongInt;
begin
  Text := '';
  Handle := FileOpen(Path, fmOpenRead);
  if Handle = THandle(-1) then
    Exit(False);
  try
    Size := FileSeek(Handle, Int64(0), fsFromEnd);
    if (Size < 0) or (Size > MaximumInfoFileSize) then
      Exit(False);
    FileSeek(Handle, Int64(0), fsFromBeginning);
    SetLength(Text, Size);
    if Size > 0 then
    begin
      Count := FileRead(Handle, Text[1], Size);
      if Count < 0 then
        Exit(False);
      SetLength(Text, Count);
    end;
    Result := True;
  finally
    FileClose(Handle);
  end;
end;

procedure AddProblem(var Problems: TStringArray; const Text: string);
begin
  SetLength(Problems, Length(Problems) + 1);
  Problems[High(Problems)] := Text;
end;

function ReadProgramFolder(const Path: string; out Info: TProgramInfo; out Problems: TStringArray): Boolean;
var
  Folder: string;
  Text: string;
begin
  Folder := ExcludeTrailingPathDelimiter(Path);
  Info := Default(TProgramInfo);
  Problems := nil;
  if not ReadSmallTextFile(Folder + '/' + ProgramInfoFileName, Text) then
  begin
    AddProblem(Problems, 'no ' + ProgramInfoFileName);
    Exit(False);
  end;
  Result := ParseProgramInfo(Text, ExtractFileName(Folder), Info, Problems);
  Info.Folder := Folder;
  if Result and not FileExists(ProgramExecutablePath(Info)) then
  begin
    AddProblem(Problems, 'no executable ' + Info.Executable);
    Result := False;
  end;
end;

function DiscoverPrograms(const Root: string; out Skipped: TProgramFolderProblems): TProgramList;
var
  Search: TSearchRec;
  Folder: string;
  Info: TProgramInfo;
  Problems: TStringArray;
begin
  Result := nil;
  Skipped := nil;
  if FindFirst(ExcludeTrailingPathDelimiter(Root) + '/*', faAnyFile or faDirectory, Search) <> 0 then
    Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      Folder := ExcludeTrailingPathDelimiter(Root) + '/' + Search.Name;
      if not DirectoryExists(Folder) then
        Continue;
      if ReadProgramFolder(Folder, Info, Problems) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Info;
      end
      else
      begin
        SetLength(Skipped, Length(Skipped) + 1);
        Skipped[High(Skipped)].Folder := Folder;
        if Length(Problems) > 0 then
          Skipped[High(Skipped)].Problem := string.Join('; ', Problems)
        else
          Skipped[High(Skipped)].Problem := 'not a program';
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  SortPrograms(Result);
end;

function DiscoverPrograms(const Root: string): TProgramList;
var
  Skipped: TProgramFolderProblems;
begin
  Result := DiscoverPrograms(Root, Skipped);
end;

procedure AddSkipped(var Skipped: TProgramFolderProblems; const Folder, Problem: string);
begin
  SetLength(Skipped, Length(Skipped) + 1);
  Skipped[High(Skipped)].Folder := Folder;
  Skipped[High(Skipped)].Problem := Problem;
end;

function DiscoverProgramsIn(const Roots: array of string; out Skipped: TProgramFolderProblems): TProgramList;
var
  RootIndex, Index, Earlier: Integer;
  Found: TProgramList;
  RootSkipped: TProgramFolderProblems;
begin
  Result := nil;
  Skipped := nil;
  for RootIndex := 0 to High(Roots) do
  begin
    Found := DiscoverPrograms(Roots[RootIndex], RootSkipped);
    for Index := 0 to High(RootSkipped) do
      AddSkipped(Skipped, RootSkipped[Index].Folder, RootSkipped[Index].Problem);
    for Index := 0 to High(Found) do
    begin
      Earlier := FindProgramByFolder(Result, Found[Index].FolderName);
      if Earlier >= 0 then
        AddSkipped(Skipped, Found[Index].Folder, 'named like ' + Result[Earlier].Folder)
      else
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Found[Index];
      end;
    end;
  end;
  SortPrograms(Result);
end;

function DiscoverInstalledPrograms(out Skipped: TProgramFolderProblems): TProgramList;
begin
  Result := DiscoverProgramsIn([DefaultProgramFoldersRoot, PortProgramFoldersRoot], Skipped);
end;

function DiscoverInstalledPrograms: TProgramList;
var
  Skipped: TProgramFolderProblems;
begin
  Result := DiscoverInstalledPrograms(Skipped);
end;

function ShownPrograms(const List: TProgramList): TProgramList;
var
  Index: Integer;
begin
  Result := nil;
  for Index := 0 to High(List) do
    if not List[Index].Hidden then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := List[Index];
    end;
end;

function FindProgramByExecutable(const List: TProgramList; const Executable: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(List) do
    if List[Index].Executable = Executable then
      Exit(Index);
  Result := -1;
end;

function FindProgramByFolder(const List: TProgramList; const FolderName: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(List) do
    if List[Index].FolderName = FolderName then
      Exit(Index);
  Result := -1;
end;

function ProgramExecutablePath(const Info: TProgramInfo): string;
begin
  Result := Info.Folder + '/' + Info.Executable;
end;

function ProgramOwnIconFile(const Info: TProgramInfo): string;
begin
  Result := Info.Folder + '/' + ProgramIconFolderName + '/' + Info.Icon + IconFileExtension;
  if (Info.Folder = '') or not FileExists(Result) then
    Result := '';
end;

function ProgramIconName(const Info: TProgramInfo): string;
begin
  Result := ProgramOwnIconFile(Info);
  if Result = '' then
    Result := Info.Icon;
end;

function CompareProgramOrder(const First, Second: TProgramInfo): Integer;
begin
  Result := Ord(First.Category) - Ord(Second.Category);
  if Result = 0 then
    Result := CompareText(First.Name, Second.Name);
  if Result = 0 then
    Result := CompareStr(First.FolderName, Second.FolderName);
end;

{ Few programs: an insertion sort, stable. }
procedure SortPrograms(var List: TProgramList);
var
  Index: Integer;
  Place: Integer;
  Moving: TProgramInfo;
begin
  for Index := 1 to High(List) do
  begin
    Moving := List[Index];
    Place := Index;
    while (Place > 0) and (CompareProgramOrder(List[Place - 1], Moving) > 0) do
    begin
      List[Place] := List[Place - 1];
      Dec(Place);
    end;
    List[Place] := Moving;
  end;
end;

end.
