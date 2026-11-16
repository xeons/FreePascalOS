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
  displayserver - owns the screen and the input, and draws the windows
  of the programs that connect to it

  displayserver [--check-moves]

  Takes every display and the input devices (the text console gives
  them up meanwhile), creates the port "display" (Windowing.Protocol) and
  serves the programs that connect: their windows, framed and stacked,
  composed with the pointer on the desktop, the input routed to them.
  Gives each display the mode and scale the system's settings keep for
  it, and the mouse the system's settings (Server.RememberedSettings),
  with a line for each, and follows them while it runs
  (Server.LiveSettings): a display's mode or scale, and the mouse's and
  keyboards' settings, changed in the system's settings are applied at
  once. Prints a line for each display after the first, then
  "displayserver: ready" (with the first display's size, DPI and scale)
  once it serves, then how many of the pointer's shapes it read from
  /lib/pointers; started by the service manager, it tells it it is
  ready then (Sys.ServiceControl). Ends when told to (killed); the console gets the
  screen and keyboards back, and each display the mode it had.

  --check-moves (for testing) draws every screen again after every
  window move and compares it with what copying the moved window's
  pixels left; it prints any difference, and a count after each drag
  of a title bar.

  The units are in userland/displayserver: Server.Theme (colours and
  metrics), Server.Screen (the displays and their back buffers),
  Server.Desktop (where they are, logical units and pixels),
  Server.Cursor,
  Server.Windows (the window list), Server.Frames, Server.Composer,
  Server.Actions (what is done to windows), Server.Clients (the
  protocol), Server.Input and Server.Scale (changing the scale);
  Server.WindowMoves (copying a moved window), Server.TitleButtons and
  Server.DoubleClicks (title bars), Server.MouseSettings,
  Server.PointerShapes, Server.PointerFiles and Server.PointerAreas
  (the pointer's shapes); Server.WindowStates (minimizing and the
  shell's commands), Server.Shell (the shell's list of windows),
  Server.WorkAreas (what the taskbar leaves), Server.Notifications
  (the notification area's icons), Server.ScreenLock (the screen lock
  and the idle time), Server.RememberedSettings (what it keeps in the
  system's settings) and Server.LiveSettings (following them).
}
program DisplayServer;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Objects,
  Sys.ServiceControl,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Drawing.Rectangles,
  Windowing.Protocol,
  Server.Screen,
  Server.Cursor,
  Server.Composer,
  Server.Clients,
  Server.Input,
  Server.Scale,
  Server.Shell,
  Server.PointerFiles,
  Server.RememberedSettings,
  Server.LiveSettings,
  Server.WindowMoves;

const
  Usage: PChar = 'Usage: displayserver [--check-moves]'#10 +
    'Own the screen and the input, and draw the windows of the programs that connect.'#10;
  OptionCheckMoves = 1;

var
  Port: Int64;
  Error: LongInt;
  PointerFilesRead: LongInt;

procedure ServeForever;
var
  Handles: array[0..MaximumWaitHandles - 1] of Int64;
  Count: LongInt;
  Index: LongInt;
  Ready: Int64;
  ClientsEnd: LongInt;
begin
  repeat
    Handles[0] := InputHandle;
    Handles[1] := Port;
    Count := 2;
    for Index := 0 to ClientCount - 1 do
    begin
      Handles[Count] := Clients[Index].Channel;
      Inc(Count);
    end;
    ClientsEnd := Count;
    AddSettingsHandles(Handles, Count);
    Ready := WaitForHandles(Slice(Handles, Count), SettingsWaitTime);
    if Ready = 0 then
      ProcessInput
    else if Ready = 1 then
      AcceptClients(Port)
    else if (Ready >= 2) and (Ready < ClientsEnd) then
      ServeClient(Clients[Ready - 2])
    else if (Ready >= ClientsEnd) and (Ready < Count) then
      SettingsHandleReady(Handles[Ready])
    else if Ready = -ErrorInterrupted then
      Break;
    DeliverSettingsChanges;
    TellShellAboutWindows;
    RefreshPointerShape;
    Compose;
    CheckMovesAgainstFullRedraw;
  until False;
end;

procedure SayOtherScreens;
var
  Index: LongInt;
begin
  for Index := 1 to ScreenCount - 1 do
    WriteString(StandardOutput, Format('displayserver: display %d: %ux%u at %d,%d, %u DPI, scale %u%%'#10,
      [Index, Screens[Index].Device.Width, Screens[Index].Device.Height, Screens[Index].Bounds.Left,
       Screens[Index].Bounds.Top, Screens[Index].Dpi, Screens[Index].ScalePercent]));
end;

procedure ReadOptions;
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
begin
  CommandLine := TCommandLine.Create([CommandOption(#0, 'check-moves', False, OptionCheckMoves)], Usage);
  while CommandLine.NextOption(Code, Value) do
    if Code = OptionCheckMoves then
      CheckingMoves := True;
  if CommandLine.OperandCount > 0 then
    FailWithUsageHint('no operands are taken');
  CommandLine.Free;
end;

begin
  ReadOptions;
  Error := OpenScreens;
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/display');
  SetUpScales;
  Error := OpenInput;
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/events');
  Port := CreatePort(WindowingPortName);
  if Port < 0 then
    FailWithError(1, LongInt(-Port), Format('the port %s', [WindowingPortName]));
  InitializeCursor;
  PointerFilesRead := LoadPointerFiles;
  ApplyRememberedSettings;
  StartFollowingSettings;
  AddDamage(DesktopBounds);
  Compose;
  SayOtherScreens;
  WriteString(StandardOutput, Format('displayserver: ready (%ux%u, %u DPI, scale %u%%)'#10,
    [Screens[0].Device.Width, Screens[0].Device.Height, Screens[0].Dpi, Screens[0].ScalePercent]));
  WriteString(StandardOutput, Format('displayserver: %d of %d pointer shapes from %s'#10,
    [PointerFilesRead, PointerShapeCount, PointerDirectory]));
  FlushStream(StandardOutput);
  { Clients can connect now: the session waits for this (when the
    service manager started the server). }
  NotifyServiceReady;
  ServeForever;
  StopFollowingSettings;
  CloseInput;
  CloseScreens;
end.
