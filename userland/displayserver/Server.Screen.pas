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
  The screen: the display, and a back buffer everything is composed in.

  Composing happens in ordinary memory (reading video memory is slow,
  and a half drawn picture never shows); PresentRegion copies the parts
  that changed to the framebuffer, swapping red and blue for a display
  that keeps red in the low byte.
}
unit Server.Screen;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.Display,
  Drawing.Rectangles,
  Drawing.Regions,
  Drawing.Surfaces;

var
  Display: TDisplay;
  BackBuffer: TSurface;
  ScreenBounds: TRectangle;

{ ErrorNone or an error code. }
function OpenScreen: LongInt;
procedure CloseScreen;
procedure PresentRegion(const Region: TRegion);

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors;

function OpenScreen: LongInt;
begin
  Result := OpenDisplay(Display);
  if Result <> ErrorNone then
    Exit;
  if not CreateSurface(BackBuffer, Display.Width, Display.Height, ColorBlack) then
  begin
    CloseDisplay(Display);
    Exit(ErrorOutOfMemory);
  end;
  ScreenBounds := MakeRectangle(0, 0, Display.Width, Display.Height);
end;

procedure CloseScreen;
begin
  FreeSurface(BackBuffer);
  CloseDisplay(Display);
end;

procedure PresentRectangle(const Rectangle: TRectangle);
var
  Visible: TRectangle;
  Y: LongInt;
  X: LongInt;
  Source: PLongWord;
  Target: PLongWord;
  Pixel: LongWord;
begin
  if not IntersectRectangles(Rectangle, ScreenBounds, Visible) then
    Exit;
  for Y := Visible.Top to Visible.Bottom - 1 do
  begin
    Source := SurfaceLine(BackBuffer, Y);
    Target := PLongWord(PByte(Display.Pixels) + PtrUInt(Y) * Display.Pitch);
    if Display.Format = DisplayFormatBlueGreenRed then
      Move(Source[Visible.Left], Target[Visible.Left], RectangleWidth(Visible) * SizeOf(LongWord))
    else
      for X := Visible.Left to Visible.Right - 1 do
      begin
        Pixel := Source[X];
        Target[X] := (Pixel and $FF00FF00) or ((Pixel and $FF) shl 16) or ((Pixel shr 16) and $FF);
      end;
  end;
end;

procedure PresentRegion(const Region: TRegion);
var
  Index: LongInt;
begin
  for Index := 0 to Region.Count - 1 do
    PresentRectangle(Region.Rectangles[Index]);
end;

end.
