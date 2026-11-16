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
  desktop - the desktop shell: wallpaper, icons and the taskbar

  desktop [-w IMAGE]

  Becomes the display server's shell (one runs at a time) and shows a
  desktop on every display (a drawn wallpaper; on the first, an icon for
  each program: a double click or Enter starts it) and a taskbar along
  the bottom of the first display: the Start menu (the programs, Log
  off and Shut down, through the session manager that started it), a
  button for each window of the other programs (a click
  activates it, or minimizes it if it is active; a right click offers
  Restore, Minimize, Maximize and Close), the notification area and a
  clock (HH:MM, UTC: the system has no time zone yet). Maximized windows
  stop above the taskbar. -w names a wallpaper image, kept for when
  images can be read (libimage); until then the drawn design shows.

  Prints what happens, a line each:

    place NAME X Y        where NAME is on the screen (pixels): start,
                          start-COMMAND, start-logoff and start-shutdown
                          (when the menu opens), icon-COMMAND, task-TITLE,
                          context-ITEM (a button's menu), clock,
                          notification-N
    task N STATE TITLE    a window of another program is new or changed
                          (STATE: shown, active, minimized, hidden)
    task-gone N           that window is gone
    started COMMAND       a program was started (cannot start COMMAND:
                          it is not installed)
    menu TEXT             a Start menu item was chosen
    context ITEM          a task button's menu item was chosen
    clock HH:MM           the time the clock shows now
    notification N TEXT   a notification icon is shown (notification-gone N)
    tooltip TEXT          a notification icon's tooltip is shown
    asking shut down      Shut down asks first (then shut down cancelled,
                          or shutting down)
    asking log off        Log off asks first (then log off cancelled, or
                          logging off)
    desktop: asked to end (REASON)
                          the desktop was asked to end (log-off,
                          shutdown, ...) and ends

  The units are in userland/desktop: Desktop.Shell (putting it
  together), Desktop.DesktopWindow and Desktop.Wallpaper (the desktop),
  Desktop.Programs (what it offers and starting it), Desktop.Taskbar,
  Desktop.StartButton, Desktop.StartMenu, Desktop.TaskButtons,
  Desktop.WindowList, Desktop.NotificationArea and Desktop.Clock (the
  taskbar), Desktop.Shapes, Desktop.ProgramPictures and
  Desktop.SmallPictures (the pictures), Desktop.Report (what it prints).
}
program DesktopShell;

{$mode objfpc}
{$H+}

uses
  Abi.SystemCalls,
  Util.Messages,
  Util.Options,
  Windowing.Connection,
  Windowing.Windows,
  Windowing.Shell,
  Desktop.Wallpaper,
  Desktop.Report,
  Desktop.Shell;

const
  Usage: PChar = 'Usage: desktop [-w IMAGE]'#10 +
    'Show the desktop and the taskbar (the display server''s shell).'#10 +
    '  -w IMAGE  a wallpaper image (shown once images can be read)'#10;
  OptionWallpaper = 1;

procedure ReadOptions;
var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
begin
  BeginOptions(Parser, [OptionDefinition('w', 'wallpaper', True, OptionWallpaper)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    if Code = OptionWallpaper then
      WallpaperImagePath := OptionValue;
  if Parser.OperandCount > 0 then
    FailWithUsageHint('no operands are taken', []);
end;

var
  Error: LongInt;
  Shell: TShell;
begin
  ReadOptions;
  Error := ConnectToDisplay;
  if Error <> ErrorNone then
    FailWithError(1, Error, 'the display server', []);
  if not RegisterAsShell then
    Fail(1, 'another shell is running', []);
  { The desktop's windows never close by themselves; it runs until the
    display server goes. }
  QuitWhenLastWindowCloses := False;
  Shell := TShell.Create;
  Say('desktop: ready');
  RunMessageLoop;
  Shell.Free;
end.
