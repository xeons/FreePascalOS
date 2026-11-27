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
  The programs that open a file, from the program folders' program.info
  (read once: Configuration.ProgramFolders) through FileManager.
  TypeAssociations: those for its extension and media type, best first,
  and the one it opens with (the user's choice for the extension, kept
  in the settings, else the best).
}
unit FileManager.Handlers;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.ProgramInfo,
  Configuration.ProgramFolders;

function InstalledPrograms: TProgramList;
function HandlersForFile(const Path: string): TProgramList;
{ The program a double click opens the file with; False if none. }
function DefaultHandlerFor(const Path: string; out Info: TProgramInfo): Boolean;
{ Forgets the programs read (a program installed meanwhile). }
procedure ForgetInstalledPrograms;

implementation

uses
  SysUtils,
  FileManager.Paths,
  FileManager.FileKinds,
  FileManager.Settings,
  FileManager.TypeAssociations;

var
  Programs: TProgramList = nil;
  ProgramsRead: Boolean = False;

function InstalledPrograms: TProgramList;
begin
  if not ProgramsRead then
  begin
    Programs := DiscoverInstalledPrograms;
    ProgramsRead := True;
  end;
  Result := Programs;
end;

procedure ForgetInstalledPrograms;
begin
  Programs := nil;
  ProgramsRead := False;
end;

function HandlersForFile(const Path: string): TProgramList;
var
  Extension: string;
begin
  Extension := ExtensionOf(Path);
  Result := HandlersFor(InstalledPrograms, Extension, MimeTypeOfExtension(Extension));
end;

function DefaultHandlerFor(const Path: string; out Info: TProgramInfo): Boolean;
var
  Handlers: TProgramList;
  Index: LongInt;
begin
  Info := Default(TProgramInfo);
  Handlers := HandlersForFile(Path);
  Index := DefaultHandlerIndex(Handlers, ChosenProgramFor(ExtensionOf(Path)));
  Result := Index >= 0;
  if Result then
    Info := Handlers[Index];
end;

end.
