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
  terminal - a terminal window running the shell

  terminal [-x LEFT] [-y TOP] [-e PROGRAM]

  Opens a window on the display server with a shell (or PROGRAM) on a
  pseudo-terminal of its own: a VT100/ANSI terminal of 25 rows of 80
  columns to start with, which follows the window's size. The size the
  window has when it closes is kept in the user's settings
  (Terminal/Rows, Terminal/Columns) for the next terminal to start at,
  and the text's size is Terminal/FontSize (tenths of a point, 110). Text is
  selected with the mouse and copied with Ctrl+Shift+C, pasted with
  Ctrl+Shift+V (or from the right click's menu); the wheel and
  Shift+Page Up/Down scroll back. Closing the window ends the shell;
  the shell ending closes the window. LEFT and TOP place the window
  (logical units; 100,80 if not given).

  Prints a line when the shell starts (its terminal, the size and where
  the window is), when the size changes, and when the shell ends.
}
program terminal;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Windowing.Connection,
  Windowing.Windows,
  Terminal.View,
  Terminal.Settings,
  Terminal.Window;

const
  Usage = 'Usage: terminal [-x LEFT] [-y TOP] [-e PROGRAM]'#10 +
    'Open a terminal window running the shell.'#10#10 +
    '  -x LEFT      where the window goes across (default 100)'#10 +
    '  -y TOP       and down (default 80)'#10 +
    '  -e PROGRAM   run PROGRAM instead of /bin/sh'#10;

  OptionLeft = 1;
  OptionTop = 2;
  OptionProgram = 3;
  DefaultShell = '/bin/sh';

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Left: LongInt;
  Top: LongInt;
  ProgramPath: string;
  Window: TTerminalWindow;
  Remembered: TTerminalSettings;
begin
  Left := 100;
  Top := 80;
  ProgramPath := DefaultShell;
  CommandLine := TCommandLine.Create([
    CommandOption('x', 'left', True, OptionLeft),
    CommandOption('y', 'top', True, OptionTop),
    CommandOption('e', 'execute', True, OptionProgram)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionLeft: Left := StrToIntDef(Value, Left);
      OptionTop: Top := StrToIntDef(Value, Top);
      OptionProgram: ProgramPath := Value;
    end;
  CommandLine.Free;
  if ConnectToDisplay <> ErrorNone then
    Fail(1, 'no display server');
  Remembered := RememberedTerminalSettings;
  TerminalPointTenths := Remembered.FontPointTenths;
  Window := TTerminalWindow.Create(Left, Top, Remembered.Rows, Remembered.Columns);
  Window.Show;
  if not Window.StartShell(ProgramPath) then
    Halt(1);
  RunMessageLoop;
end.
