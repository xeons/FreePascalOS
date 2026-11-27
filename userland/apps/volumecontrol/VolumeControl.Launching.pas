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
  Starting the other sound programs from the volume control: the
  Control Panel's Sound page and the mixer itself (from the compact
  pop-up). Each starts in a process group of its own, as the desktop
  starts programs; one that cannot start is reported in a message box.
}
unit VolumeControl.Launching;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows;

{ Starts Command (looked up in PATH) with Argument ('' for none). }
function StartProgramCommand(const Command, Argument: string; Owner: TWindow): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Processes,
  Util.Commands,
  Controls.MessageBoxes,
  VolumeControl.Output;

function StartProgramCommand(const Command, Argument: string; Owner: TWindow): Boolean;
var
  FullPath: string;
  Arguments: TTextVector;
  Options: TProcessOptions;
  Process: Int64;
begin
  Result := False;
  if FindProgramPath(Command, FullPath) then
  begin
    if Argument <> '' then
      Arguments := TextVector([Command, Argument])
    else
      Arguments := TextVector([Command]);
    DefaultProcessOptions(Options);
    Options.GroupId := GroupNew;
    Process := StartProgram(PChar(FullPath), @Arguments[0], Options);
    Result := Process >= 0;
    if Result then
      CloseHandle(Process);
  end;
  if Result then
    Say('started ' + Command)
  else
    ShowMessageBox('Volume Control', Command + ' could not be started.', MessageOk, SignError, Owner);
end;

end.
