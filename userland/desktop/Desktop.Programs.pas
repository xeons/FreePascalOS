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
  The programs the desktop offers, as icons and in the Start menu, and
  starting them.

  They are the installed programs' folders under /app, each described
  by its program.info (Configuration.ProgramFolders): the name shown,
  a description, a category, an icon and the executable. Hidden ones
  are left out; the rest are in the menu's order, by category, then by
  name. Each is known by its executable's name (Command: notepad), as
  it is started and reported ("started notepad").

  A program is started in a process group of its own, so it outlives
  the desktop and Ctrl-C on the console does not reach it; it inherits
  the desktop's standard handles. One that is not installed (or cannot
  start) is reported in a message box rather than failing silently.
}
unit Desktop.Programs;

{$mode objfpc}
{$H+}

interface

uses
  Configuration.ProgramInfo;

type
  TDesktopProgram = record
    { The executable's name, as started (notepad). }
    Command: string;
    { Its full path (/app/notepad/notepad). }
    Path: string;
    Caption: string;
    Description: string;
    Category: TProgramCategory;
    { The icon to draw: the folder's own icon file, or the theme's
      icon of that name (Controls.IconFiles takes both). }
    IconName: string;
    { The theme's name for it (app-text-editor), even when the folder
      has its own picture, for the pictures drawn without the theme. }
    ThemeIconName: string;
  end;

var
  DesktopPrograms: array of TDesktopProgram;

{ Reads the installed programs again (the desktop does once, starting). }
procedure LoadDesktopPrograms;
function DesktopProgramCount: LongInt;
{ Starts DesktopPrograms[Index]; False (after saying why in a message
  box) if it could not be started. ProcessId is the started program's. }
function StartDesktopProgram(Index: LongInt): Boolean;
function StartDesktopProgram(Index: LongInt; out ProcessId: QWord): Boolean;
{ The index of the program started by Command, or -1. }
function IndexOfDesktopProgram(const Command: string): LongInt;
{ Starts Command with one Argument ('': none) in the same way; Caption
  names it in a message box if it cannot start. ProcessId is the started
  program's. }
function StartCommand(const Command, Argument, Caption: string): Boolean;
function StartCommand(const Command, Argument, Caption: string; out ProcessId: QWord): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes,
  Util.Commands,
  Configuration.ProgramFolders,
  Controls.MessageBoxes,
  Desktop.Report;

function DesktopProgramFrom(const Info: TProgramInfo): TDesktopProgram;
begin
  Result.Command := Info.Executable;
  Result.Path := ProgramExecutablePath(Info);
  Result.Caption := Info.Name;
  Result.Description := Info.Description;
  Result.Category := Info.Category;
  Result.IconName := ProgramIconName(Info);
  Result.ThemeIconName := Info.Icon;
end;

procedure LoadDesktopPrograms;
var
  Found: TProgramList;
  Skipped: TProgramFolderProblems;
  Index: LongInt;
begin
  Found := ShownPrograms(DiscoverPrograms(DefaultProgramFoldersRoot, Skipped));
  for Index := 0 to High(Skipped) do
    Say('skipped program folder ' + Skipped[Index].Folder + ': ' + Skipped[Index].Problem);
  SetLength(DesktopPrograms, Length(Found));
  for Index := 0 to High(Found) do
    DesktopPrograms[Index] := DesktopProgramFrom(Found[Index]);
  Say('programs ' + IntToStr(Length(DesktopPrograms)));
end;

function DesktopProgramCount: LongInt;
begin
  Result := Length(DesktopPrograms);
end;

procedure ReportFailure(const Caption, Command, Reason: string);
begin
  Say('cannot start ' + Command);
  ShowMessageBox('Cannot start ' + Caption, Caption + ' (' + Command + ') ' + Reason, MessageOk, SignError);
end;

{ Starts the program at FullPath as Command, with Argument. }
function StartProgramFile(const FullPath, Command, Argument, Caption: string; out ProcessId: QWord): Boolean;
var
  Arguments: TTextVector;
  Options: TProcessOptions;
  Process: Int64;
begin
  Result := False;
  ProcessId := 0;
  if Argument <> '' then
    Arguments := TextVector([Command, Argument])
  else
    Arguments := TextVector([Command]);
  DefaultProcessOptions(Options);
  Options.GroupId := GroupNew;
  Process := StartProgram(PChar(FullPath), @Arguments[0], Options);
  if Process < 0 then
  begin
    ReportFailure(Caption, Command, 'could not be started.');
    Exit;
  end;
  ProcessId := QWord(ProcessIdOf(Process));
  { Nobody waits for it: the handle is not needed. }
  CloseHandle(Process);
  if Argument <> '' then
    Say('started ' + Command + ' ' + Argument)
  else
    Say('started ' + Command);
  Result := True;
end;

function StartCommand(const Command, Argument, Caption: string): Boolean;
var
  ProcessId: QWord;
begin
  Result := StartCommand(Command, Argument, Caption, ProcessId);
end;

function StartCommand(const Command, Argument, Caption: string; out ProcessId: QWord): Boolean;
var
  FullPath: string;
begin
  ProcessId := 0;
  { In PATH, else in its program folder (Sys.ProgramFolders). }
  if not FindProgramPath(Command, FullPath) then
  begin
    ReportFailure(Caption, Command, 'is not installed.');
    Exit(False);
  end;
  Result := StartProgramFile(FullPath, Command, Argument, Caption, ProcessId);
end;

function StartDesktopProgram(Index: LongInt): Boolean;
var
  ProcessId: QWord;
begin
  Result := StartDesktopProgram(Index, ProcessId);
end;

function StartDesktopProgram(Index: LongInt; out ProcessId: QWord): Boolean;
begin
  ProcessId := 0;
  if (Index < 0) or (Index >= DesktopProgramCount) then
    Exit(False);
  Result := StartProgramFile(DesktopPrograms[Index].Path, DesktopPrograms[Index].Command, '',
    DesktopPrograms[Index].Caption, ProcessId);
end;

function IndexOfDesktopProgram(const Command: string): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to DesktopProgramCount - 1 do
    if DesktopPrograms[Index].Command = Command then
      Exit(Index);
  Result := -1;
end;

end.
