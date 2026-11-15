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

  Takes the display and the input devices (the text console gives them
  up meanwhile), creates the port "display" (Windowing.Protocol) and
  serves the programs that connect: their windows, framed and stacked,
  composed with the pointer on the desktop, the input routed to them.
  Prints "displayserver: ready" once it serves. Ends when told to
  (killed); the console gets the screen and keyboards back.

  The units are in userland/displayserver: Server.Theme (colours and
  metrics), Server.Screen (display and back buffer), Server.Cursor,
  Server.Windows (the window list), Server.Frames, Server.Composer,
  Server.Actions (what is done to windows), Server.Clients (the
  protocol) and Server.Input.
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
  Font.Text,
  Font.Files,
  Windowing.Protocol,
  Server.Theme,
  Server.Screen,
  Server.Cursor,
  Server.Frames,
  Server.Composer,
  Server.Clients,
  Server.Input;

var
  Port: Int64;
  Fonts: TFontSet;
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

begin
  LoadDefaultTheme;
  Error := OpenScreen;
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/display', []);
  ScalePercent := Display.ScalePercent;
  Dpi := Display.Dpi;
  if LoadSystemFonts(Fonts) then
    TitleFace := SelectFace(Fonts, Theme.TitlePoints, Dpi, True);
  Error := OpenInput;
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/events', []);
  Port := CreatePort(WindowingPortName);
  if Port < 0 then
    FailWithError(1, LongInt(-Port), 'the port %s', [ArgumentText(WindowingPortName)]);
  InitializeCursor(Display.Width, Display.Height, ScalePercent);
  AddDamage(ScreenBounds);
  Compose;
  WriteFormatted(StandardOutput, 'displayserver: ready (%ux%u, %u DPI, scale %u%%)'#10,
    [ArgumentUnsigned(Display.Width), ArgumentUnsigned(Display.Height), ArgumentUnsigned(Dpi),
     ArgumentUnsigned(ScalePercent)]);
  FlushStream(StandardOutput);
  ServeForever;
  CloseInput;
  CloseScreen;
end.
