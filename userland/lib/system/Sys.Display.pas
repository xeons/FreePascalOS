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
  The display: its framebuffer, size, pixel format and DPI.

  OpenDisplay opens /dev/display, which takes the screen from the text
  console until CloseDisplay (or the program's end) gives it back, reads
  what the display is like and maps its framebuffer into the program.
  Only one program has the display at a time (ErrorBusy otherwise).

  Pixels are LongWords, Pitch bytes from one line to the next; Format
  says where red and blue are. Dpi and ScalePercent are for sizing what
  is drawn: a 12 point font is 12 * Dpi / 72 pixels high.
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
  end;

{ Returns ErrorNone or an error code (ErrorBusy: another program has
  the display; ErrorNotFound: there is none). }
function OpenDisplay(out Display: TDisplay): LongInt;
procedure CloseDisplay(var Display: TDisplay);
{ The display's pixel value for a colour given as $RRGGBB. }
function DisplayPixel(const Display: TDisplay; Color: LongWord): LongWord;

implementation

uses
  Runtime.Memory,
  Sys.Kernel,
  Sys.Errors;

const
  DisplayPath: PChar = '/dev/display';

function OpenDisplay(out Display: TDisplay): LongInt;
var
  Value: Int64;
  Address: Int64;
begin
  ZeroMemory(@Display, SizeOf(Display));
  Display.Handle := KernelOpen(DisplayPath, OpenRead or OpenWrite);
  if Display.Handle < 0 then
    Exit(ErrorCodeOf(Display.Handle));
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
  Address := KernelMapHandle(Display.Handle, 0, QWord(Display.Pitch) * Display.Height);
  if Address < 0 then
  begin
    KernelClose(Display.Handle);
    Display.Handle := -1;
    Exit(ErrorCodeOf(Address));
  end;
  Display.Pixels := PLongWord(Address);
  Result := ErrorNone;
end;

procedure CloseDisplay(var Display: TDisplay);
begin
  if Display.Pixels <> nil then
    KernelFreeMemory(Display.Pixels);
  if Display.Handle >= 0 then
    KernelClose(Display.Handle);
  Display.Pixels := nil;
  Display.Handle := -1;
end;

function DisplayPixel(const Display: TDisplay; Color: LongWord): LongWord;
begin
  if Display.Format = DisplayFormatRedGreenBlue then
    Result := ((Color and $FF) shl 16) or (Color and $FF00) or ((Color shr 16) and $FF)
  else
    Result := Color and $FFFFFF;
end;

end.
