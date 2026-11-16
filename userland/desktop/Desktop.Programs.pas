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
  TProgramPicture = (PictureTerminal, PictureNotepad, PictureControls, PictureSwatches, PictureDialogs,
    PictureControlPanel);

  TDesktopProgram = record
    Command: PChar;
    Caption: PChar;
    Picture: TProgramPicture;
  end;

const
  DesktopProgramCount = 6;
  DesktopPrograms: array[0..DesktopProgramCount - 1] of TDesktopProgram = (
    (Command: 'terminal'; Caption: 'Terminal'; Picture: PictureTerminal),
    (Command: 'notepad'; Caption: 'Notepad'; Picture: PictureNotepad),
    (Command: 'controlpanel'; Caption: 'Control Panel'; Picture: PictureControlPanel),
    (Command: 'controlstour'; Caption: 'Controls tour'; Picture: PictureControls),
    (Command: 'controlsdemo'; Caption: 'Controls demo'; Picture: PictureSwatches),
    (Command: 'dialogtour'; Caption: 'Dialogs'; Picture: PictureDialogs));

{ Starts DesktopPrograms[Index]; False (after saying why in a message
  box) if it could not be started. }
function StartDesktopProgram(Index: LongInt): Boolean;
{ Starts Command with one Argument (nil: none) in the same way; Caption
  names it in a message box if it cannot start. }
function StartCommand(Command, Argument: PChar; const Caption: string): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes,
  Controls.MessageBoxes,
  Desktop.Report;

const
  PathCapacity = 512;

procedure ReportFailure(const Caption, Command, Reason: string);
begin
  Say('cannot start ' + Command);
  ShowMessageBox('Cannot start ' + Caption, Caption + ' (' + Command + ') ' + Reason, MessageOk, SignError);
end;

function StartCommand(Command, Argument: PChar; const Caption: string): Boolean;
var
  FullPath: array[0..PathCapacity - 1] of Char;
  Arguments: array[0..2] of PChar;
  Options: TProcessOptions;
  Process: Int64;
begin
  Result := False;
  if not FindProgram(Command, @FullPath[0], PathCapacity) then
  begin
    ReportFailure(Caption, Command, 'is not installed.');
    Exit;
  end;
  Arguments[0] := Command;
  Arguments[1] := Argument;
  Arguments[2] := nil;
  DefaultProcessOptions(Options);
  Options.GroupId := GroupNew;
  Process := StartProgram(@FullPath[0], @Arguments[0], Options);
  if Process < 0 then
  begin
    ReportFailure(Caption, Command, 'could not be started.');
    Exit;
  end;
  { Nobody waits for it: the handle is not needed. }
  CloseHandle(Process);
  if Argument <> nil then
    Say('started ' + string(Command) + ' ' + string(Argument))
  else
    Say('started ' + string(Command));
  Result := True;
end;

function StartDesktopProgram(Index: LongInt): Boolean;
begin
  if (Index < 0) or (Index >= DesktopProgramCount) then
    Exit(False);
  Result := StartCommand(DesktopPrograms[Index].Command, nil, DesktopPrograms[Index].Caption);
end;

end.
