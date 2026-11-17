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

  Each has the command that starts it (looked up in PATH), the caption
  shown, and the picture drawn for it. A program is started in a process
  group of its own, so it outlives the desktop and Ctrl-C on the console
  does not reach it; it inherits the desktop's standard handles. One
  that is not installed (or cannot start) is reported in a message box
  rather than failing silently.
}
unit Desktop.Programs;

{$mode objfpc}
{$H+}

interface

type
  TProgramPicture = (PictureFiles, PictureTerminal, PictureNotepad, PictureControlPanel, PictureControls,
    PictureSwatches, PictureDialogs, PictureTaskManager, PictureImageViewer, PictureCalculator,
    PictureVolumeControl);

  TDesktopProgram = record
    Command: string;
    Caption: string;
    Picture: TProgramPicture;
  end;

const
  DesktopProgramCount = 11;
  DesktopPrograms: array[0..DesktopProgramCount - 1] of TDesktopProgram = (
    (Command: 'files'; Caption: 'Files'; Picture: PictureFiles),
    (Command: 'terminal'; Caption: 'Terminal'; Picture: PictureTerminal),
    (Command: 'notepad'; Caption: 'Notepad'; Picture: PictureNotepad),
    (Command: 'controlpanel'; Caption: 'Control Panel'; Picture: PictureControlPanel),
    (Command: 'controlstour'; Caption: 'Controls tour'; Picture: PictureControls),
    (Command: 'controlsdemo'; Caption: 'Controls demo'; Picture: PictureSwatches),
    (Command: 'dialogtour'; Caption: 'Dialogs'; Picture: PictureDialogs),
    (Command: 'taskmanager'; Caption: 'Task Manager'; Picture: PictureTaskManager),
    (Command: 'imageviewer'; Caption: 'Image Viewer'; Picture: PictureImageViewer),
    (Command: 'calculator'; Caption: 'Calculator'; Picture: PictureCalculator),
    (Command: 'volumecontrol'; Caption: 'Volume Control'; Picture: PictureVolumeControl));

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
  Controls.MessageBoxes,
  Desktop.Report;

procedure ReportFailure(const Caption, Command, Reason: string);
begin
  Say('cannot start ' + Command);
  ShowMessageBox('Cannot start ' + Caption, Caption + ' (' + Command + ') ' + Reason, MessageOk, SignError);
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
  Arguments: TTextVector;
  Options: TProcessOptions;
  Process: Int64;
begin
  Result := False;
  ProcessId := 0;
  if not FindProgramPath(Command, FullPath) then
  begin
    ReportFailure(Caption, Command, 'is not installed.');
    Exit;
  end;
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
  Result := StartCommand(DesktopPrograms[Index].Command, '', DesktopPrograms[Index].Caption, ProcessId);
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
