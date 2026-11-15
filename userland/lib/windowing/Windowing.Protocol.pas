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
  The display server's protocol: what programs and the display server
  say to each other over a channel.

  A program connects to the port WindowingPortName and sends
  RequestHello; the server answers EventWelcome with the screen's size,
  DPI and scale. Every message, either way, is one TWindowMessage; the
  fields a kind uses are listed with it.

  A window's contents are the program's to draw: in a section (shared
  memory) of SurfaceWidth x SurfaceHeight pixels ($AARRGGBB, a line
  after another), whose handle goes with RequestCreateWindow or
  RequestSetSurface. After drawing, the program sends RequestDamage with
  the rectangle it changed; the server puts it on the screen. The frame
  around it (title bar, borders, buttons) is the server's.

  Positions on the screen are in logical units (1/96 inch), turned into
  pixels with the scale (LogicalToPixels); sizes of surfaces and
  positions within a window are in pixels, which is what is drawn.

  A window can have an owner, another window of the same program: it
  stays above it. A disabled window (RequestEnableWindow) is never
  activated and gets no input; a click on it activates the window it
  owns instead (a modal dialog). The owner can be changed later
  (RequestSetOwner). When the scale changes every program hears
  EventScaleChanged and gives its windows new surfaces. A program hears
  when its window is shown or hidden, whoever did it
  (EventVisibilityChanged: its owner was hidden, or it was minimized).

  The pointer's shape over a window's client area is the program's to
  choose (RequestSetPointerShape: for the whole client area, or for up to
  MaximumPointerAreas rectangles of it); over the frame the server picks
  it (resize arrows on the borders). The mouse's settings (speed,
  acceleration, left-handed buttons) are the server's, read and changed
  with RequestGetMouseSettings and RequestSetMouseSettings.
}
unit Windowing.Protocol;

{$mode objfpc}

interface

const
  WindowingPortName: PChar = 'display';
  ProtocolVersion = 1;
  TitleCapacity = 96;

  { --- Requests: program to server ------------------------------------- }

  { Value: ProtocolVersion. Answered by EventWelcome. }
  RequestHello = 1;
  { Left, Top: where (logical units, the client area's top left);
    SurfaceWidth, SurfaceHeight: the client area's size in pixels; Flags:
    Window*; Text: the title; Code: the window that owns it (0: none),
    which it stays above. Handle: the surface's section. Answered by
    EventWindowCreated (Window: its number). It starts hidden. }
  RequestCreateWindow = 2;
  RequestDestroyWindow = 3;
  { Value: 1 to show (and activate, unless WindowNoActivate), 0 to hide. }
  RequestShowWindow = 4;
  { Left, Top: the client area's new place (logical units). }
  RequestMoveWindow = 5;
  { Text: the new title. }
  RequestSetTitle = 6;
  { SurfaceWidth, SurfaceHeight: a new surface for the window (after
    EventResized). Handle: its section. }
  RequestSetSurface = 7;
  { Left, Top, Width, Height: what changed, in surface pixels. }
  RequestDamage = 8;
  { Brings the window to the front and gives it the keyboard. }
  RequestActivate = 9;
  { Value 1: the window gets every pointer event until Value 0 (while a
    button is held on a control, say). }
  RequestSetCapture = 10;
  { Value 0: the window is disabled (not activated, no input: the owner
    of a modal dialog); 1: enabled again. }
  RequestEnableWindow = 11;
  { Window 0; Code: a new scale for the display in percent (100 to 400).
    Every program is told (EventScaleChanged). }
  RequestSetScale = 12;
  { Code: the window that owns it from now on (0: none), another window
    of the same program that is not owned by it. The server raises the
    window above its new owner if it was below. }
  RequestSetOwner = 13;
  { Code: Pointer*, the shape; Value: the area (0: the whole client
    area, 1 to MaximumPointerAreas: a rectangle of it, which wins over
    area 0 where it lies, a higher number over a lower); Left, Top,
    Width, Height: that rectangle in surface pixels (an empty one takes
    the area away). }
  RequestSetPointerShape = 14;
  { Window 0. Answered by EventMouseSettings. }
  RequestGetMouseSettings = 15;
  { Window 0; Code, Value, Flags as in EventMouseSettings: the new
    settings (any program may change them, as the display's settings
    would be; they last until the server ends). Answered by
    EventMouseSettings with what they are now. }
  RequestSetMouseSettings = 16;

  { --- Events: server to program ---------------------------------------- }

  { Width, Height: the screen in pixels; Value: its DPI; Code: its scale
    in percent. }
  EventWelcome = 101;
  { Window: the new window's number. }
  EventWindowCreated = 102;
  { Code: the key (scan code set 1, plus KeyCodeExtended), Value: 1
    pressed, 0 released; Character, Modifiers as in input events. }
  EventKey = 103;
  { Left, Top: the pointer in the window's surface (pixels); Code: the
    buttons held (bit N for button N); Modifiers: the keyboard's (as in
    input events), for every pointer event. }
  EventPointerMove = 104;
  { Left, Top as above; Code: the button; Value: 1 pressed, 0 released. }
  EventPointerButton = 105;
  { Value: wheel steps, positive away from the user. }
  EventWheel = 106;
  { The pointer went out of the window. }
  EventPointerLeave = 107;
  { SurfaceWidth, SurfaceHeight: the size the client area has now (the
    frame was dragged, or the window maximized): a new surface is due. }
  EventResized = 108;
  { Value: 1 the window is active (has the keyboard), 0 not any more. }
  EventActivated = 109;
  { The close button was pressed: the program decides. }
  EventCloseRequested = 110;
  { Left, Top: where the client area is now (logical units): the window
    was moved (by the user, or maximized). }
  EventMoved = 111;
  { Window 0. The display's scale changed: Width, Height: the screen in
    pixels; Value: its DPI now; Code: its scale in percent. Windows kept
    their places in logical units; each wants a new surface of its
    logical size at the new scale (RequestSetSurface). }
  EventScaleChanged = 112;
  { Value: 1 the window is shown now, 0 hidden: by the program, or by the
    server (hidden or shown with its owner, minimized). }
  EventVisibilityChanged = 113;
  { Window 0. Code: the speed, MinimumMouseSpeed to MaximumMouseSpeed
    (NormalMouseSpeed moves the pointer as far as the mouse says);
    Value: the acceleration, 0 (none) to MaximumMouseAcceleration;
    Flags: MouseLeftHanded if the left and right buttons are swapped. }
  EventMouseSettings = 114;

  { --- Window flags ----------------------------------------------------- }

  { A title bar and borders. }
  WindowFramed = $01;
  { The borders can be dragged and the window maximized. }
  WindowResizable = $02;
  { Above every other window (a taskbar). }
  WindowTopmost = $04;
  { Showing it, or clicking it, does not take the keyboard. }
  WindowNoActivate = $08;

  { --- Pointer shapes ---------------------------------------------------- }

  PointerArrow = 0;
  { Left and right (a vertical border). }
  PointerResizeHorizontal = 1;
  { Up and down (a horizontal border). }
  PointerResizeVertical = 2;
  { Top left and bottom right. }
  PointerResizeDiagonalDown = 3;
  { Top right and bottom left. }
  PointerResizeDiagonalUp = 4;
  { Where text is typed or selected. }
  PointerTextBeam = 5;
  { The program is busy. }
  PointerBusy = 6;
  PointerShapeCount = 7;
  { Areas of a window with a shape of their own (RequestSetPointerShape). }
  MaximumPointerAreas = 15;

  { --- Mouse settings ---------------------------------------------------- }

  MinimumMouseSpeed = 1;
  NormalMouseSpeed = 10;
  MaximumMouseSpeed = 20;
  MaximumMouseAcceleration = 10;
  MouseLeftHanded = $01;

type
  TWindowMessage = record
    Kind: LongWord;
    Window: LongWord;
    Left: LongInt;
    Top: LongInt;
    Width: LongInt;
    Height: LongInt;
    SurfaceWidth: LongInt;
    SurfaceHeight: LongInt;
    Code: LongWord;
    Value: LongInt;
    Character: LongWord;
    Modifiers: LongWord;
    Flags: LongWord;
    Reserved: LongWord;
    Text: array[0..TitleCapacity - 1] of Char;
  end;
  PWindowMessage = ^TWindowMessage;

{ A length in logical units in pixels at ScalePercent, rounded. }
function LogicalToPixels(Value: LongInt; ScalePercent: LongWord): LongInt;
function PixelsToLogical(Value: LongInt; ScalePercent: LongWord): LongInt;
{ A message of Kind for Window, every other field zero. }
function NewMessage(Kind, Window: LongWord): TWindowMessage;
{ Copies Text into the message (cut short if it does not fit). }
procedure SetMessageText(var Message: TWindowMessage; Text: PChar);

implementation

function LogicalToPixels(Value: LongInt; ScalePercent: LongWord): LongInt;
begin
  if Value >= 0 then
    Result := (Value * LongInt(ScalePercent) + 50) div 100
  else
    Result := -((-Value * LongInt(ScalePercent) + 50) div 100);
end;

function PixelsToLogical(Value: LongInt; ScalePercent: LongWord): LongInt;
begin
  if ScalePercent = 0 then
    Exit(Value);
  if Value >= 0 then
    Result := (Value * 100 + LongInt(ScalePercent) div 2) div LongInt(ScalePercent)
  else
    Result := -((-Value * 100 + LongInt(ScalePercent) div 2) div LongInt(ScalePercent));
end;

function NewMessage(Kind, Window: LongWord): TWindowMessage;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := Kind;
  Result.Window := Window;
end;

procedure SetMessageText(var Message: TWindowMessage; Text: PChar);
var
  Index: Integer;
begin
  Index := 0;
  if Text <> nil then
    while (Text[Index] <> #0) and (Index < TitleCapacity - 1) do
    begin
      Message.Text[Index] := Text[Index];
      Inc(Index);
    end;
  Message.Text[Index] := #0;
end;

end.
