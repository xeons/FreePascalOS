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
  The displays: their framebuffers, sizes, pixel formats, DPI and modes.

  OpenDisplay opens /dev/display (display 0, the console's) or another
  one (/dev/display1...), which takes the screen (from the text console,
  for the first) until CloseDisplay (or the program's end) gives it
  back, reads what the display is like and maps its framebuffer into
  the program. Only one program has a display at a time (ErrorBusy
  otherwise).

  The display's modes are listed by DisplayModeCount and DisplayModeAt;
  SetDisplayMode changes it, reads it again and maps the framebuffer
  anew. Closing gives back the mode it had when it was opened.

  Pixels are LongWords, Pitch bytes from one line to the next; Format
  says where red and blue are. Dpi and ScalePercent are for sizing what
  is drawn: a 12 point font is 12 * Dpi / 72 pixels high.

  Capabilities (DisplayCapability*) say what more the display does. On a
  display that needs flushing (virtio-gpu) what is drawn shows only once
  FlushDisplay names it; elsewhere FlushDisplay costs nothing, so a
  program calls it after drawing on any display. A display with a
  hardware cursor has its cursor image area mapped too (CursorPixels,
  DisplayCursorSize pixels square): SetDisplayCursorImage copies an image
  there and gives it to the device, MoveDisplayCursor and
  ShowDisplayCursor move and show it.
}
unit Sys.Display;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

type
  TDisplay = record
    Handle: Int64;
    Pixels: PLongWord;
    Width: LongWord;
    Height: LongWord;
    { Bytes per line. }
    Pitch: LongWord;
    { DisplayFormatBlueGreenRed or DisplayFormatRedGreenBlue. }
    Format: LongWord;
    Dpi: LongWord;
    ScalePercent: LongWord;
    WidthMillimetres: LongWord;
    HeightMillimetres: LongWord;
    { DisplayCapability*. }
    Capabilities: LongWord;
    { With DisplayCapabilityHardwareCursor: the cursor image area. }
    CursorPixels: PLongWord;
  end;

{ Returns ErrorNone or an error code (ErrorBusy: another program has
  the display; ErrorNotFound: there is none). Number 0 is the console's. }
function OpenDisplay(out Display: TDisplay; Number: LongInt = 0): LongInt;
procedure CloseDisplay(var Display: TDisplay);
function DisplayModeCount(const Display: TDisplay): LongInt;
{ The mode numbered Index (from 0, smallest first); False past the end. }
function DisplayModeAt(const Display: TDisplay; Index: LongInt; out Width, Height: LongWord): Boolean;
{ Sets the display to a mode of its list; ErrorNone or an error code
  (ErrorUnsupported: its mode cannot be changed). }
function SetDisplayMode(var Display: TDisplay; Width, Height: LongWord): LongInt;
{ The display's pixel value for a colour given as $RRGGBB. }
function DisplayPixel(const Display: TDisplay; Color: LongWord): LongWord;
{ Shows the rectangle drawn in the framebuffer (pixels, cut to the mode);
  ErrorNone or an error code. }
function FlushDisplay(const Display: TDisplay; X, Y, Width, Height: LongInt): LongInt;
function DisplayNeedsFlush(const Display: TDisplay): Boolean;
function DisplayHasHardwareCursor(const Display: TDisplay): Boolean;
{ Image: Width x Height pixels ($AARRGGBB, straight alpha, lines of
  Width), at most DisplayCursorSize square, put in the cursor's top left
  (the rest clear) with the hotspot at HotspotX, HotspotY. }
function SetDisplayCursorImage(const Display: TDisplay; Image: PLongWord; Width, Height, HotspotX,
  HotspotY: LongInt): LongInt;
{ The hotspot's place, pixels of the mode. }
function MoveDisplayCursor(const Display: TDisplay; X, Y: LongInt): LongInt;
function ShowDisplayCursor(const Display: TDisplay; Visible: Boolean): LongInt;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Kernel,
  Sys.Errors;

const
  DisplayPath: PChar = '/dev/display';

{ "/dev/display", then "/dev/display1"... }
procedure MakeDisplayPath(Number: LongInt; var Path: array of Char);
var
  Digits: TNumberText;
  Used: PtrUInt;
begin
  CopyText(@Path[0], DisplayPath, Length(Path));
  if Number <= 0 then
    Exit;
  Used := TextLength(@Path[0]);
  CopyText(@Path[Used], FormatDecimal(Number, Digits), PtrUInt(Length(Path)) - Used);
end;

{ Reads what the display is like now and maps its framebuffer. }
function ReadAndMap(var Display: TDisplay): LongInt;
var
  Value: Int64;
  Address: Int64;
begin
  Value := KernelControlHandle(Display.Handle, ControlDisplayGetSize, 0);
  Display.Width := LongWord(QWord(Value) and $FFFFFFFF);
  Display.Height := LongWord(QWord(Value) shr 32);
  Display.Pitch := LongWord(KernelControlHandle(Display.Handle, ControlDisplayGetPitch, 0));
  Display.Format := LongWord(KernelControlHandle(Display.Handle, ControlDisplayGetFormat, 0));
  Display.Dpi := LongWord(KernelControlHandle(Display.Handle, ControlDisplayGetDpi, 0));
  Display.ScalePercent := LongWord(KernelControlHandle(Display.Handle, ControlDisplayGetScale, 0));
  Value := KernelControlHandle(Display.Handle, ControlDisplayGetPhysicalSize, 0);
  Display.WidthMillimetres := LongWord(QWord(Value) and $FFFFFFFF);
  Display.HeightMillimetres := LongWord(QWord(Value) shr 32);
  Value := KernelControlHandle(Display.Handle, ControlDisplayGetCapabilities, 0);
  if Value < 0 then
    Value := 0;
  Display.Capabilities := LongWord(Value);
  Address := KernelMapHandle(Display.Handle, 0, QWord(Display.Pitch) * Display.Height);
  if Address < 0 then
    Exit(ErrorCodeOf(Address));
  Display.Pixels := PLongWord(Address);
  Result := ErrorNone;
end;

{ The cursor image area, once (it does not change with the mode). }
procedure MapCursorImage(var Display: TDisplay);
var
  Address: Int64;
begin
  if not DisplayHasHardwareCursor(Display) or (Display.CursorPixels <> nil) then
    Exit;
  Address := KernelMapHandle(Display.Handle, DisplayCursorImageOffset, DisplayCursorImageBytes);
  if Address < 0 then
    Display.Capabilities := Display.Capabilities and not LongWord(DisplayCapabilityHardwareCursor)
  else
    Display.CursorPixels := PLongWord(Address);
end;

function OpenDisplay(out Display: TDisplay; Number: LongInt): LongInt;
var
  Path: array[0..31] of Char;
begin
  ZeroMemory(@Display, SizeOf(Display));
  MakeDisplayPath(Number, Path);
  Display.Handle := KernelOpen(@Path[0], OpenRead or OpenWrite);
  if Display.Handle < 0 then
    Exit(ErrorCodeOf(Display.Handle));
  Result := ReadAndMap(Display);
  if Result <> ErrorNone then
  begin
    KernelClose(Display.Handle);
    Display.Handle := -1;
    Exit;
  end;
  MapCursorImage(Display);
end;

function DisplayModeCount(const Display: TDisplay): LongInt;
var
  Value: Int64;
begin
  Value := KernelControlHandle(Display.Handle, ControlDisplayGetModeCount, 0);
  if Value < 0 then
    Exit(0);
  Result := LongInt(Value);
end;

function DisplayModeAt(const Display: TDisplay; Index: LongInt; out Width, Height: LongWord): Boolean;
var
  Value: Int64;
begin
  Width := 0;
  Height := 0;
  if Index < 0 then
    Exit(False);
  Value := KernelControlHandle(Display.Handle, ControlDisplayGetMode, QWord(Index));
  if Value < 0 then
    Exit(False);
  Width := LongWord(QWord(Value) and $FFFFFFFF);
  Height := LongWord(QWord(Value) shr 32);
  Result := True;
end;

function SetDisplayMode(var Display: TDisplay; Width, Height: LongWord): LongInt;
var
  Value: Int64;
begin
  Value := KernelControlHandle(Display.Handle, ControlDisplaySetMode, QWord(Width) or (QWord(Height) shl 32));
  if Value < 0 then
    Exit(ErrorCodeOf(Value));
  { The old mapping is of the old size. }
  if Display.Pixels <> nil then
    KernelFreeMemory(Display.Pixels);
  Display.Pixels := nil;
  Result := ReadAndMap(Display);
  MapCursorImage(Display);
end;

procedure CloseDisplay(var Display: TDisplay);
begin
  if Display.Pixels <> nil then
    KernelFreeMemory(Display.Pixels);
  if Display.CursorPixels <> nil then
    KernelFreeMemory(Display.CursorPixels);
  if Display.Handle >= 0 then
    KernelClose(Display.Handle);
  Display.Pixels := nil;
  Display.CursorPixels := nil;
  Display.Handle := -1;
end;

function DisplayPixel(const Display: TDisplay; Color: LongWord): LongWord;
begin
  if Display.Format = DisplayFormatRedGreenBlue then
    Result := ((Color and $FF) shl 16) or (Color and $FF00) or ((Color shr 16) and $FF)
  else
    Result := Color and $FFFFFF;
end;

function DisplayNeedsFlush(const Display: TDisplay): Boolean;
begin
  Result := (Display.Capabilities and DisplayCapabilityNeedsFlush) <> 0;
end;

function DisplayHasHardwareCursor(const Display: TDisplay): Boolean;
begin
  Result := (Display.Capabilities and DisplayCapabilityHardwareCursor) <> 0;
end;

function ControlResult(Value: Int64): LongInt;
begin
  if Value < 0 then
    Exit(ErrorCodeOf(Value));
  Result := ErrorNone;
end;

function FlushDisplay(const Display: TDisplay; X, Y, Width, Height: LongInt): LongInt;
var
  Right: LongInt;
  Bottom: LongInt;
begin
  if not DisplayNeedsFlush(Display) then
    Exit(ErrorNone);
  Right := X + Width;
  Bottom := Y + Height;
  if X < 0 then
    X := 0;
  if Y < 0 then
    Y := 0;
  if Right > LongInt(Display.Width) then
    Right := LongInt(Display.Width);
  if Bottom > LongInt(Display.Height) then
    Bottom := LongInt(Display.Height);
  if (Right <= X) or (Bottom <= Y) then
    Exit(ErrorNone);
  Result := ControlResult(KernelControlHandle(Display.Handle, ControlDisplayFlush, QWord(X) or (QWord(Y) shl 16) or
    (QWord(Right - X) shl 32) or (QWord(Bottom - Y) shl 48)));
end;

function SetDisplayCursorImage(const Display: TDisplay; Image: PLongWord; Width, Height, HotspotX,
  HotspotY: LongInt): LongInt;
var
  Row: LongInt;
begin
  if (Display.CursorPixels = nil) or (Width < 0) or (Height < 0) or (Width > DisplayCursorSize) or
     (Height > DisplayCursorSize) then
    Exit(ErrorInvalidArgument);
  if (HotspotX < 0) or (HotspotY < 0) or (HotspotX >= DisplayCursorSize) or (HotspotY >= DisplayCursorSize) then
    Exit(ErrorInvalidArgument);
  ZeroMemory(Display.CursorPixels, DisplayCursorImageBytes);
  for Row := 0 to Height - 1 do
    CopyMemory(PByte(Display.CursorPixels) + PtrUInt(Row) * DisplayCursorSize * SizeOf(LongWord),
      PByte(Image) + PtrUInt(Row) * PtrUInt(Width) * SizeOf(LongWord), PtrUInt(Width) * SizeOf(LongWord));
  Result := ControlResult(KernelControlHandle(Display.Handle, ControlDisplaySetCursorImage,
    QWord(HotspotX) or (QWord(HotspotY) shl 16)));
end;

function MoveDisplayCursor(const Display: TDisplay; X, Y: LongInt): LongInt;
begin
  Result := ControlResult(KernelControlHandle(Display.Handle, ControlDisplayMoveCursor,
    QWord(LongWord(X)) or (QWord(LongWord(Y)) shl 32)));
end;

function ShowDisplayCursor(const Display: TDisplay; Visible: Boolean): LongInt;
begin
  Result := ControlResult(KernelControlHandle(Display.Handle, ControlDisplayShowCursor, Ord(Visible)));
end;

end.
