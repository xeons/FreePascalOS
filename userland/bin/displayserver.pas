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

  Takes the display and the input devices (the text console gives them
  up meanwhile), creates the port "display" (Windowing.Protocol) and
  serves the programs that connect: their windows, framed and stacked,
  composed with the pointer on the desktop, the input routed to them.
  Prints "displayserver: ready" once it serves, after saying how many of
  the pointer's shapes it read from /lib/pointers. Ends when told to
  (killed); the console gets the screen and keyboards back.

  --check-moves (for testing) draws the whole screen again after every
  window move and compares it with what copying the moved window's
  pixels left; it prints any difference, and a count after each drag
  of a title bar.

  The units are in userland/displayserver: Server.Theme (colours and
  metrics), Server.Screen (display and back buffer), Server.Cursor,
  Server.Windows (the window list), Server.Frames, Server.Composer,
  Server.Actions (what is done to windows), Server.Clients (the
  protocol), Server.Input and Server.Scale (changing the scale);
  Server.WindowMoves (copying a moved window), Server.TitleButtons and
  Server.DoubleClicks (title bars), Server.MouseSettings,
  Server.PointerShapes, Server.PointerFiles and Server.PointerAreas
  (the pointer's shapes).
}
program DisplayServer;

{$mode objfpc}

uses
  Abi.SystemCalls,
  Sys.Format,
  Sys.Objects,
  Sys.Streams,
  Util.Messages,
  Util.Options,
  Drawing.Rectangles,
  Windowing.Protocol,
  Server.Theme,
  Server.Screen,
  Server.Cursor,
  Server.Composer,
  Server.Clients,
  Server.Input,
  Server.Scale,
  Server.PointerFiles,
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
    RefreshPointerShape;
    Compose;
    CheckMovesAgainstFullRedraw;
  until False;
end;

procedure ReadOptions;
var
  Parser: TOptionParser;
  Code: Integer;
  OptionValue: PChar;
begin
  BeginOptions(Parser, [OptionDefinition(#0, 'check-moves', False, OptionCheckMoves)], Usage);
  while NextOption(Parser, Code, OptionValue) do
    if Code = OptionCheckMoves then
      CheckingMoves := True;
  if Parser.OperandCount > 0 then
    FailWithUsageHint('no operands are taken', []);
end;

begin
  ReadOptions;
  Error := OpenScreen;
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/display', []);
  SetUpScale(Display.ScalePercent, Display.Dpi);
  Error := OpenInput;
  if Error <> ErrorNone then
    FailWithError(1, Error, '/dev/events', []);
  Port := CreatePort(WindowingPortName);
  if Port < 0 then
    FailWithError(1, LongInt(-Port), 'the port %s', [ArgumentText(WindowingPortName)]);
  InitializeCursor(Display.Width, Display.Height, ScalePercent);
  PointerFilesRead := LoadPointerFiles;
  AddDamage(ScreenBounds);
  Compose;
  WriteFormatted(StandardOutput, 'displayserver: ready (%ux%u, %u DPI, scale %u%%)'#10,
    [ArgumentUnsigned(Display.Width), ArgumentUnsigned(Display.Height), ArgumentUnsigned(Dpi),
     ArgumentUnsigned(ScalePercent)]);
  WriteFormatted(StandardOutput, 'displayserver: %d of %d pointer shapes from %s'#10,
    [ArgumentNumber(PointerFilesRead), ArgumentNumber(PointerShapeCount), ArgumentText(PointerDirectory)]);
  FlushStream(StandardOutput);
  ServeForever;
  CloseInput;
  CloseScreen;
end.
