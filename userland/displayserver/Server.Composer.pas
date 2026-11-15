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
  Composing: putting the desktop, the windows and the pointer together.

  What needs drawing again is collected as a region (AddDamage: a window
  moved, a program drew, the pointer moved). Compose draws only that, in
  the back buffer: the desktop, then each visible window from the bottom
  up (its frame, then its surface), then the pointer, all clipped to the
  damage, so what lies under a window is covered by it; then the damaged
  parts go to the screen. Pixels put right in the back buffer some other
  way (a moved window's, copied: Server.WindowMoves) go to the screen
  with them (AddPresentOnly).
}
unit Server.Composer;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Regions,
  Server.Windows;

var
  { The window with the keyboard (its title bar is drawn active). }
  ActiveWindow: PServerWindow;
  { While a frame is dragged to a new size: the outline of where it
    will be. }
  OutlineVisible: Boolean;
  Outline: TRectangle;

procedure AddDamage(const Rectangle: TRectangle);
procedure DamageWindow(Window: PServerWindow);
function HasDamage: Boolean;
{ What needs drawing again now (a copy of it). }
procedure CopyDamage(out Region: TRegion);
{ Pixels already right in the back buffer that the screen does not show
  yet: Compose puts them on it. }
procedure AddPresentOnly(const Region: TRegion);
procedure Compose;

implementation

uses
  Windowing.Theme,
  Drawing.Canvas,
  Server.Theme,
  Server.Screen,
  Server.Frames,
  Server.Cursor;

var
  Damage: TRegion;
  PresentOnly: TRegion;

procedure AddDamage(const Rectangle: TRectangle);
var
  Visible: TRectangle;
begin
  if IntersectRectangles(Rectangle, ScreenBounds, Visible) then
    AddRectangleToRegion(Damage, Visible);
end;

procedure DamageWindow(Window: PServerWindow);
begin
  AddDamage(FrameRectangle(Window));
end;

function HasDamage: Boolean;
begin
  Result := not RegionIsEmpty(Damage);
end;

procedure CopyDamage(out Region: TRegion);
begin
  CopyRegion(Damage, Region);
end;

procedure AddPresentOnly(const Region: TRegion);
begin
  AddRegionToRegion(PresentOnly, Region);
end;

procedure Compose;
var
  Canvas: TCanvas;
  Index: LongInt;
  Window: PServerWindow;
begin
  if not RegionIsEmpty(PresentOnly) then
  begin
    PresentRegion(PresentOnly);
    ClearRegion(PresentOnly);
  end;
  if RegionIsEmpty(Damage) then
    Exit;
  BeginCanvas(Canvas, BackBuffer);
  SetCanvasClip(Canvas, Damage);
  FillRectangle(Canvas, ScreenBounds, Theme.Desktop);
  for Index := 0 to WindowCount - 1 do
  begin
    Window := Windows[Index];
    if not Window^.Visible then
      Continue;
    if IsFramed(Window) then
      DrawFrame(Canvas, Window, Window = ActiveWindow);
    if Window^.Surface.Pixels <> nil then
      DrawSurface(Canvas, Window^.Surface, MakeRectangle(0, 0, Window^.Surface.Width, Window^.Surface.Height),
        Window^.ClientLeft, Window^.ClientTop, False, 255);
  end;
  if OutlineVisible then
  begin
    DrawRectangleOutline(Canvas, Outline, Theme.DarkShadow);
    DrawRectangleOutline(Canvas, InflateRectangle(Outline, -1), Theme.Highlight);
  end;
  DrawCursor(Canvas);
  PresentRegion(Damage);
  ClearRegion(Damage);
end;

end.
