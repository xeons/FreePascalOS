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
  Work areas: what of each screen is left for windows once the shell has
  kept strips of it for itself (a taskbar along the bottom).

  The shell gives a screen's work area as a rectangle in logical units;
  it is kept as the widths of the strips left at each edge, in logical
  units at the screen's scale (TScreen.Reserved), so the strips stay the
  same logical size when the scale or the mode changes, as the taskbar
  does. Maximized windows fill the work area (Server.Actions), and a new
  framed window is moved into it as far as it fits. When the shell ends
  every screen is whole again.
}
unit Server.WorkAreas;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Server.Screen,
  Server.Windows;

{ The screen's work area in desktop pixels. }
function WorkArea(Screen: PScreen): TRectangle;
{ The same in logical units of the desktop. }
function LogicalWorkArea(Screen: PScreen): TRectangle;
{ Makes Area (logical units of the desktop) the screen's work area (as
  much of it as is on the screen), and maximizes its maximized windows
  again. }
procedure SetWorkArea(Screen: PScreen; const Area: TRectangle);
{ Every screen whole again (the shell ended). }
procedure ClearWorkAreas;
{ Moves a new framed window into the work area of its screen, as far as
  it fits, if the shell keeps part of that screen. }
procedure PlaceWindowInWorkArea(Window: TServerWindow);

implementation

uses
  Windowing.Protocol,
  Server.Actions;

function HasReservedStrips(Screen: PScreen): Boolean;
begin
  Result := (Screen^.Reserved.Left > 0) or (Screen^.Reserved.Top > 0) or (Screen^.Reserved.Right > 0) or
    (Screen^.Reserved.Bottom > 0);
end;

{ Bounds less the strips (already in Bounds' units), never less than
  nothing (strips wider than a screen that shrank). }
function WithoutStrips(const Bounds: TRectangle; Left, Top, Right, Bottom: LongInt): TRectangle;
begin
  Result := Bounds;
  Result.Left := Result.Left + Left;
  Result.Top := Result.Top + Top;
  Result.Right := Result.Right - Right;
  Result.Bottom := Result.Bottom - Bottom;
  if Result.Right < Result.Left then
    Result.Right := Result.Left;
  if Result.Bottom < Result.Top then
    Result.Bottom := Result.Top;
end;

function WorkArea(Screen: PScreen): TRectangle;
begin
  Result := WithoutStrips(Screen^.Bounds, LogicalToPixels(Screen^.Reserved.Left, Screen^.ScalePercent),
    LogicalToPixels(Screen^.Reserved.Top, Screen^.ScalePercent),
    LogicalToPixels(Screen^.Reserved.Right, Screen^.ScalePercent),
    LogicalToPixels(Screen^.Reserved.Bottom, Screen^.ScalePercent));
end;

function LogicalWorkArea(Screen: PScreen): TRectangle;
begin
  Result := WithoutStrips(Screen^.LogicalBounds, Screen^.Reserved.Left, Screen^.Reserved.Top,
    Screen^.Reserved.Right, Screen^.Reserved.Bottom);
end;

function NotNegative(Value: LongInt): LongInt;
begin
  Result := Value;
  if Result < 0 then
    Result := 0;
end;

procedure MaximizeWindowsAgainOn(Screen: PScreen);
var
  Index: LongInt;
begin
  for Index := 0 to WindowCount - 1 do
    if Windows[Index].Maximized and (WindowScreen(Windows[Index]) = Screen) then
      MaximizeAgain(Windows[Index]);
end;

procedure SetWorkArea(Screen: PScreen; const Area: TRectangle);
var
  Logical: TRectangle;
  Reserved: TRectangle;
begin
  Logical := Screen^.LogicalBounds;
  Reserved.Left := NotNegative(Area.Left - Logical.Left);
  Reserved.Top := NotNegative(Area.Top - Logical.Top);
  Reserved.Right := NotNegative(Logical.Right - Area.Right);
  Reserved.Bottom := NotNegative(Logical.Bottom - Area.Bottom);
  if RectanglesAreEqual(Reserved, Screen^.Reserved) then
    Exit;
  Screen^.Reserved := Reserved;
  MaximizeWindowsAgainOn(Screen);
end;

procedure ClearWorkAreas;
var
  Index: LongInt;
begin
  for Index := 0 to ScreenCount - 1 do
    SetWorkArea(@Screens[Index], Screens[Index].LogicalBounds);
end;

procedure PlaceWindowInWorkArea(Window: TServerWindow);
var
  Screen: PScreen;
  Area: TRectangle;
  Frame: TRectangle;
  DeltaX: LongInt;
  DeltaY: LongInt;
begin
  if not IsFramed(Window) then
    Exit;
  Screen := WindowScreen(Window);
  if not HasReservedStrips(Screen) then
    Exit;
  Area := WorkArea(Screen);
  Frame := FrameRectangle(Window);
  DeltaX := 0;
  DeltaY := 0;
  { The far edges first, then the near ones: a window larger than the
    work area keeps its title bar in it. }
  if Frame.Right > Area.Right then
    DeltaX := Area.Right - Frame.Right;
  if Frame.Left + DeltaX < Area.Left then
    DeltaX := Area.Left - Frame.Left;
  if Frame.Bottom > Area.Bottom then
    DeltaY := Area.Bottom - Frame.Bottom;
  if Frame.Top + DeltaY < Area.Top then
    DeltaY := Area.Top - Frame.Top;
  if (DeltaX <> 0) or (DeltaY <> 0) then
    MoveWindowTo(Window, Window.ClientLeft + DeltaX, Window.ClientTop + DeltaY);
end;

end.
