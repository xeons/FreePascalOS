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
  Starting programs for files: a program file itself, or Notepad with a
  file to open. Each starts in a process group of its own (so it
  outlives the file manager and Ctrl-C on a console does not reach it),
  in the file's folder, with the file manager's standard handles; one
  that cannot start is reported in a message box owned by the window.
}
unit FileManager.Launching;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ Runs the program at Path. }
function RunProgramFile(const Path: string; Owner: TWindow): Boolean;
{ Opens Path in Notepad. }
function OpenWithNotepad(const Path: string; Owner: TWindow): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes,
  Util.Commands,
  Controls.MessageBoxes,
  Controls.FileNames,
  FileManager.Output;

const
  NotepadCommand = 'notepad';

function Start(const ProgramPath, Argument: string): Boolean;
var
  Arguments: TTextVector;
  Options: TProcessOptions;
  Folder: string;
  Process: Int64;
begin
  if Argument <> '' then
    Arguments := TextVector([ProgramPath, Argument])
  else
    Arguments := TextVector([ProgramPath]);
  DefaultProcessOptions(Options);
  Options.GroupId := GroupNew;
  if Argument <> '' then
    Folder := ParentFolderOf(Argument)
  else
    Folder := ParentFolderOf(ProgramPath);
  Options.WorkingDirectory := PChar(Folder);
  Process := StartProgram(PChar(ProgramPath), @Arguments[0], Options);
  Result := Process >= 0;
  { Nobody waits for it. }
  if Result then
    CloseHandle(Process);
end;

function RunProgramFile(const Path: string; Owner: TWindow): Boolean;
begin
  Result := Start(Path, '');
  if Result then
    Say('started ' + Path)
  else
  begin
    Say('error cannot start ' + Path);
    ShowMessageBox('Files', LastPartOf(Path) + ' could not be started.', MessageOk, SignError, Owner);
  end;
end;

function OpenWithNotepad(const Path: string; Owner: TWindow): Boolean;
var
  NotepadPath: string;
begin
  Result := FindProgramPath(NotepadCommand, NotepadPath) and Start(NotepadPath, Path);
  if Result then
    Say('opened-with-notepad ' + Path)
  else
  begin
    Say('error cannot start notepad');
    ShowMessageBox('Files', 'Notepad could not be started to open ' + LastPartOf(Path) + '.', MessageOk, SignError,
      Owner);
  end;
end;

end.
