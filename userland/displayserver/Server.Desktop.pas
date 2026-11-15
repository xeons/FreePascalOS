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
  The desktop's two coordinate spaces, and which screen a point or a
  window is on.

  The server places everything in desktop pixels; programs give and are
  told places in logical units of the same desktop, where each screen
  has its own scale (Server.Screen lays out both). A point is turned
  from one to the other by the screen it is on (or the nearest one, for
  a point off every screen): its offset from that screen's top left is
  scaled by that screen's scale. Within a screen this is the plain
  conversion; across screens it is piecewise, so a place keeps meaning
  the same spot on the same screen whatever the other screens do.

  A window is on the screen that holds the middle of its frame (or the
  nearest): it is drawn, sized and told its scale by that screen's, even
  while part of it shows on another.
}
unit Server.Desktop;

{$mode objfpc}

interface

uses
  Server.Screen,
  Server.Windows;

{ The screen (X, Y) (desktop pixels) is on, or nil. }
function ScreenAt(X, Y: LongInt): PScreen;
{ The screen (X, Y) is on, or else the nearest. }
function NearestScreen(X, Y: LongInt): PScreen;
{ Moves (X, Y) onto the nearest screen if it is off them all. }
procedure KeepPointOnScreens(var X, Y: LongInt);
{ A place in logical units to desktop pixels, and back. }
procedure LogicalToDesktop(Left, Top: LongInt; out X, Y: LongInt);
procedure DesktopToLogical(X, Y: LongInt; out Left, Top: LongInt);
{ The screen the middle of the window's frame is on (or the nearest). }
function ScreenUnderWindow(Window: PServerWindow): PScreen;

implementation

uses
  Drawing.Rectangles,
  Windowing.Protocol;

function ScreenAt(X, Y: LongInt): PScreen;
var
  Index: LongInt;
begin
  for Index := 0 to ScreenCount - 1 do
    if RectangleContainsPoint(Screens[Index].Bounds, X, Y) then
      Exit(@Screens[Index]);
  Result := nil;
end;

{ How far (X, Y) is from Rectangle, squared (0 inside). }
function DistanceSquared(const Rectangle: TRectangle; X, Y: LongInt): Int64;
var
  DeltaX: Int64;
  DeltaY: Int64;
begin
  DeltaX := 0;
  DeltaY := 0;
  if X < Rectangle.Left then
    DeltaX := Rectangle.Left - X
  else if X >= Rectangle.Right then
    DeltaX := X - Rectangle.Right + 1;
  if Y < Rectangle.Top then
    DeltaY := Rectangle.Top - Y
  else if Y >= Rectangle.Bottom then
    DeltaY := Y - Rectangle.Bottom + 1;
  Result := DeltaX * DeltaX + DeltaY * DeltaY;
end;

{ The screen nearest (X, Y): by their logical bounds, or their pixels. }
function NearestOf(X, Y: LongInt; Logical: Boolean): PScreen;
var
  Index: LongInt;
  Distance: Int64;
  Best: Int64;
  Bounds: TRectangle;
begin
  Result := @Screens[0];
  Best := High(Int64);
  for Index := 0 to ScreenCount - 1 do
  begin
    if Logical then
      Bounds := Screens[Index].LogicalBounds
    else
      Bounds := Screens[Index].Bounds;
    Distance := DistanceSquared(Bounds, X, Y);
    if Distance < Best then
    begin
      Best := Distance;
      Result := @Screens[Index];
    end;
  end;
end;

function NearestScreen(X, Y: LongInt): PScreen;
begin
  Result := NearestOf(X, Y, False);
end;

function Clamped(Value, Low, High: LongInt): LongInt;
begin
  Result := Value;
  if Result < Low then
    Result := Low;
  if Result > High then
    Result := High;
end;

procedure KeepPointOnScreens(var X, Y: LongInt);
var
  Screen: PScreen;
begin
  Screen := NearestScreen(X, Y);
  X := Clamped(X, Screen^.Bounds.Left, Screen^.Bounds.Right - 1);
  Y := Clamped(Y, Screen^.Bounds.Top, Screen^.Bounds.Bottom - 1);
end;

procedure LogicalToDesktop(Left, Top: LongInt; out X, Y: LongInt);
var
  Screen: PScreen;
begin
  Screen := NearestOf(Left, Top, True);
  X := Screen^.Bounds.Left + LogicalToPixels(Left - Screen^.LogicalBounds.Left, Screen^.ScalePercent);
  Y := Screen^.Bounds.Top + LogicalToPixels(Top - Screen^.LogicalBounds.Top, Screen^.ScalePercent);
end;

procedure DesktopToLogical(X, Y: LongInt; out Left, Top: LongInt);
var
  Screen: PScreen;
begin
  Screen := NearestScreen(X, Y);
  Left := Screen^.LogicalBounds.Left + PixelsToLogical(X - Screen^.Bounds.Left, Screen^.ScalePercent);
  Top := Screen^.LogicalBounds.Top + PixelsToLogical(Y - Screen^.Bounds.Top, Screen^.ScalePercent);
end;

function ScreenUnderWindow(Window: PServerWindow): PScreen;
var
  Frame: TRectangle;
begin
  Frame := FrameRectangle(Window);
  Result := NearestScreen((Frame.Left + Frame.Right) div 2, (Frame.Top + Frame.Bottom) div 2);
end;

end.
