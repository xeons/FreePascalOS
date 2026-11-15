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

  displayserver

  Takes every display and the input devices (the text console gives
  them up meanwhile), creates the port "display" (Windowing.Protocol) and
  serves the programs that connect: their windows, framed and stacked,
  composed with the pointer on the desktop, the input routed to them.
  Prints a line for each display after the first, then
  "displayserver: ready" (with the first display's size, DPI and scale)
  once it serves. Ends when told to (killed); the console gets the
  screen and keyboards back, and each display the mode it had.

  The units are in userland/displayserver: Server.Theme (colours and
  metrics), Server.Screen (the displays and their back buffers),
  Server.Desktop (where they are, logical units and pixels),
  Server.Cursor,
  Server.Windows (the window list), Server.Frames, Server.Composer,
  Server.Actions (what is done to windows), Server.Clients (the
  protocol), Server.Input and Server.Scale (changing the scale).
}
program DisplayServer;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Format,
  Sys.Objects,
  Sys.Streams,
  Util.Messages,
  Drawing.Rectangles,
  Windowing.Protocol,
  Server.Screen,
  Server.Cursor,
  Server.Composer,
  Server.Clients,
  Server.Input,
  Server.Scale;

var
  Port: Int64;
  Error: LongInt;

procedure ServeForever;
var
  Handles: array[0..MaximumClients + 1] of Int64;
  Count: LongInt;
  Index: LongInt;
  Ready: Int64;
begin
  repeat
    Handles[0] := InputHandle;
    Handles[1] := Port;
    Count := 2;
    for Index := 0 to ClientCount - 1 do
    begin
      Handles[Count] := Clients[Index]^.Channel;
      Inc(Count);
    end;
    Ready := WaitForHandles(Slice(Handles, Count), InfiniteWait);
    if Ready = 0 then
      ProcessInput
    else if Ready = 1 then
      AcceptClients(Port)
    else if (Ready >= 2) and (Ready < Count) then
      ServeClient(Clients[Ready - 2])
    else if Ready = -ErrorInterrupted then
      Break;
    Compose;
  until False;
end;

procedure SayOtherScreens;
var
  Index: LongInt;
begin
  for Index := 1 to ScreenCount - 1 do
    WriteFormatted(StandardOutput, 'displayserver: display %d: %ux%u at %d,%d, %u DPI, scale %u%%'#10,
      [ArgumentNumber(Index), ArgumentUnsigned(Screens[Index].Device.Width),
       ArgumentUnsigned(Screens[Index].Device.Height), ArgumentNumber(Screens[Index].Bounds.Left),
       ArgumentNumber(Screens[Index].Bounds.Top), ArgumentUnsigned(Screens[Index].Dpi),
       ArgumentUnsigned(Screens[Index].ScalePercent)]);
end;

begin
  Error := OpenScreens;
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/display', []);
  SetUpScales;
  Error := OpenInput;
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/events', []);
  Port := CreatePort(WindowingPortName);
  if Port < 0 then
    FailWithError(1, LongInt(-Port), 'the port %s', [ArgumentText(WindowingPortName)]);
  InitializeCursor;
  AddDamage(DesktopBounds);
  Compose;
  SayOtherScreens;
  WriteFormatted(StandardOutput, 'displayserver: ready (%ux%u, %u DPI, scale %u%%)'#10,
    [ArgumentUnsigned(Screens[0].Device.Width), ArgumentUnsigned(Screens[0].Device.Height),
     ArgumentUnsigned(Screens[0].Dpi), ArgumentUnsigned(Screens[0].ScalePercent)]);
  FlushStream(StandardOutput);
  ServeForever;
  CloseInput;
  CloseScreens;
end.
