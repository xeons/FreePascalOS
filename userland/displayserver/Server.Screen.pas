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
  The screens: every display, its place on the desktop, and a back
  buffer for each that it is composed in.

  The displays are opened in order (/dev/display, the console's, then
  /dev/display1...) and laid out side by side, left to right, tops in
  line: a desktop in pixels, where each screen has its rectangle
  (Bounds), and the same in logical units, where each has its pixel
  size at its own scale (LogicalBounds). Windows, the pointer and
  everything drawn are placed in desktop pixels; programs see logical
  units (Server.Desktop converts).

  Composing happens in ordinary memory (reading video memory is slow,
  and a half drawn picture never shows); PresentScreenRegion copies the
  parts that changed to the screen's framebuffer, swapping red and blue
  for a display that keeps red in the low byte.
}
unit Server.Screen;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.Display,
  Font.Faces,
  Drawing.Rectangles,
  Drawing.Regions,
  Drawing.Surfaces;

const
  MaximumScreens = 8;

type
  PScreen = ^TScreen;
  TScreen = record
    Number: LongInt;
    Device: TDisplay;
    { The size of Device, in desktop pixels from its top left. }
    BackBuffer: TSurface;
    { Its place on the desktop: in pixels, and in logical units. }
    Bounds: TRectangle;
    LogicalBounds: TRectangle;
    { The scale and DPI it is used at, which may be the user's choice. }
    ScalePercent: LongWord;
    Dpi: LongWord;
    { What the display itself has at its mode: other scales are against
      these. }
    NativeScalePercent: LongWord;
    NativeDpi: LongWord;
    { The title bars' font at its DPI. }
    TitleFace: PFontFace;
  end;

var
  Screens: array[0..MaximumScreens - 1] of TScreen;
  ScreenCount: LongInt;
  { Every screen's pixels together (the rectangle around them). }
  DesktopBounds: TRectangle;

{ Opens every display (the first must open); ErrorNone or an error code. }
function OpenScreens: LongInt;
procedure CloseScreens;
{ The screen numbered Number, or nil. }
function ScreenByNumber(Number: LongInt): PScreen;
{ Lays the screens out side by side again (after a scale or a mode
  changed). }
procedure ArrangeScreens;
{ Sets the display to Width x Height and gives it a back buffer of that
  size; the caller arranges the screens again. ErrorNone or an error. }
function SetScreenMode(Screen: PScreen; Width, Height: LongInt): LongInt;
{ Copies the part of Region (desktop pixels) on Screen to its display. }
procedure PresentScreenRegion(Screen: PScreen; const Region: TRegion);

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Windowing.Protocol;

function OpenScreen(Number: LongInt): LongInt;
var
  Screen: PScreen;
begin
  Screen := @Screens[ScreenCount];
  FillChar(Screen^, SizeOf(Screen^), 0);
  Screen^.Number := Number;
  Result := OpenDisplay(Screen^.Device, Number);
  if Result <> ErrorNone then
    Exit;
  if not CreateSurface(Screen^.BackBuffer, Screen^.Device.Width, Screen^.Device.Height, ColorBlack) then
  begin
    CloseDisplay(Screen^.Device);
    Exit(ErrorOutOfMemory);
  end;
  Screen^.NativeScalePercent := Screen^.Device.ScalePercent;
  Screen^.NativeDpi := Screen^.Device.Dpi;
  Screen^.ScalePercent := Screen^.NativeScalePercent;
  Screen^.Dpi := Screen^.NativeDpi;
  Inc(ScreenCount);
end;

function OpenScreens: LongInt;
begin
  ScreenCount := 0;
  Result := OpenScreen(0);
  if Result <> ErrorNone then
    Exit;
  { The others until one is missing (or taken by another program). }
  while (ScreenCount < MaximumScreens) and (OpenScreen(ScreenCount) = ErrorNone) do
    ;
  ArrangeScreens;
end;

procedure CloseScreens;
var
  Index: LongInt;
begin
  for Index := 0 to ScreenCount - 1 do
  begin
    FreeSurface(Screens[Index].BackBuffer);
    CloseDisplay(Screens[Index].Device);
  end;
  ScreenCount := 0;
end;

function ScreenByNumber(Number: LongInt): PScreen;
begin
  if (Number < 0) or (Number >= ScreenCount) then
    Exit(nil);
  Result := @Screens[Number];
end;

procedure ArrangeScreens;
var
  Index: LongInt;
  PixelLeft: LongInt;
  LogicalLeft: LongInt;
  Screen: PScreen;
begin
  PixelLeft := 0;
  LogicalLeft := 0;
  for Index := 0 to ScreenCount - 1 do
  begin
    Screen := @Screens[Index];
    Screen^.Bounds := MakeRectangle(PixelLeft, 0, Screen^.Device.Width, Screen^.Device.Height);
    Screen^.LogicalBounds := MakeRectangle(LogicalLeft, 0, PixelsToLogical(Screen^.Device.Width, Screen^.ScalePercent),
      PixelsToLogical(Screen^.Device.Height, Screen^.ScalePercent));
    PixelLeft := Screen^.Bounds.Right;
    LogicalLeft := Screen^.LogicalBounds.Right;
    if Index = 0 then
      DesktopBounds := Screen^.Bounds
    else
      DesktopBounds := BoundingRectangle(DesktopBounds, Screen^.Bounds);
  end;
end;

function SetScreenMode(Screen: PScreen; Width, Height: LongInt): LongInt;
var
  NewBuffer: TSurface;
begin
  if (Width <= 0) or (Height <= 0) then
    Exit(ErrorInvalidArgument);
  if not CreateSurface(NewBuffer, Width, Height, ColorBlack) then
    Exit(ErrorOutOfMemory);
  Result := SetDisplayMode(Screen^.Device, Width, Height);
  if (Result <> ErrorNone) or (Screen^.Device.Pixels = nil) then
  begin
    FreeSurface(NewBuffer);
    if Result = ErrorNone then
      Result := ErrorIo;
    Exit;
  end;
  FreeSurface(Screen^.BackBuffer);
  Screen^.BackBuffer := NewBuffer;
  Screen^.NativeScalePercent := Screen^.Device.ScalePercent;
  Screen^.NativeDpi := Screen^.Device.Dpi;
end;

procedure PresentRectangle(Screen: PScreen; const Rectangle: TRectangle);
var
  Visible: TRectangle;
  Y: LongInt;
  X: LongInt;
  Source: PLongWord;
  Target: PLongWord;
  Pixel: LongWord;
begin
  if not IntersectRectangles(Rectangle, Screen^.Bounds, Visible) then
    Exit;
  { From desktop pixels to the screen's own. }
  Visible := OffsetRectangle(Visible, -Screen^.Bounds.Left, -Screen^.Bounds.Top);
  for Y := Visible.Top to Visible.Bottom - 1 do
  begin
    Source := SurfaceLine(Screen^.BackBuffer, Y);
    Target := PLongWord(PByte(Screen^.Device.Pixels) + PtrUInt(Y) * Screen^.Device.Pitch);
    if Screen^.Device.Format = DisplayFormatBlueGreenRed then
      Move(Source[Visible.Left], Target[Visible.Left], RectangleWidth(Visible) * SizeOf(LongWord))
    else
      for X := Visible.Left to Visible.Right - 1 do
      begin
        Pixel := Source[X];
        Target[X] := (Pixel and $FF00FF00) or ((Pixel and $FF) shl 16) or ((Pixel shr 16) and $FF);
      end;
  end;
end;

procedure PresentScreenRegion(Screen: PScreen; const Region: TRegion);
var
  Index: LongInt;
begin
  for Index := 0 to Region.Count - 1 do
    PresentRectangle(Screen, Region.Rectangles[Index]);
end;

end.
