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
  The mouse pointer: where it is, and its arrow.

  Pointing devices move it by motion (relative) or position (absolute,
  0-65535 across the whole desktop, every screen side by side) events;
  it is in desktop pixels and stays on the screens, going from one to
  the next across their shared edge. The arrow is drawn from a small
  pattern, each of its pixels a square of PointerScale pixels (the scale
  of the screen it is on, rounded to a whole number), so it is about the
  same size on every display.
}
unit Server.Cursor;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas;

var
  PointerX: LongInt;
  PointerY: LongInt;

{ In the middle of the first screen. }
procedure InitializeCursor;
{ The arrow's size for the scale of the screen it is on now (after a
  scale changed, or the screens moved: it is kept on them too). }
procedure FollowPointerScreen;
{ Moves by (DeltaX, DeltaY), or to an absolute position. }
procedure MovePointerBy(DeltaX, DeltaY: LongInt);
procedure MovePointerToPosition(X, Y: LongInt);
{ Where the arrow is drawn (its pixels), for knowing what to redraw. }
function CursorRectangle: TRectangle;
procedure DrawCursor(const Canvas: TCanvas);

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Server.Screen,
  Server.Desktop;

const
  { '#' outline, '.' fill, ' ' transparent; the tip is the top left. }
  ArrowWidth = 12;
  ArrowHeight = 19;
  Arrow: array[0..ArrowHeight - 1] of string[ArrowWidth] = (
    '#           ',
    '##          ',
    '#.#         ',
    '#..#        ',
    '#...#       ',
    '#....#      ',
    '#.....#     ',
    '#......#    ',
    '#.......#   ',
    '#........#  ',
    '#.........# ',
    '#......#####',
    '#...#..#    ',
    '#..# #..#   ',
    '#.#  #..#   ',
    '##    #..#  ',
    '#     #..#  ',
    '       #..# ',
    '        ##  ');
  OutlineColor = $FF000000;
  FillColor = $FFFFFFFF;

var
  PointerScale: LongInt;

procedure FollowPointerScreen;
begin
  KeepPointOnScreens(PointerX, PointerY);
  PointerScale := (LongInt(NearestScreen(PointerX, PointerY)^.ScalePercent) + 50) div 100;
  if PointerScale < 1 then
    PointerScale := 1;
end;

procedure InitializeCursor;
begin
  PointerX := (Screens[0].Bounds.Left + Screens[0].Bounds.Right) div 2;
  PointerY := (Screens[0].Bounds.Top + Screens[0].Bounds.Bottom) div 2;
  FollowPointerScreen;
end;

procedure MovePointerBy(DeltaX, DeltaY: LongInt);
begin
  PointerX := PointerX + DeltaX;
  PointerY := PointerY + DeltaY;
  FollowPointerScreen;
end;

procedure MovePointerToPosition(X, Y: LongInt);
begin
  { Rounded to the nearest pixel. }
  PointerX := DesktopBounds.Left + LongInt((Int64(X) * (RectangleWidth(DesktopBounds) - 1) + InputPositionMaximum div 2) div
    InputPositionMaximum);
  PointerY := DesktopBounds.Top + LongInt((Int64(Y) * (RectangleHeight(DesktopBounds) - 1) + InputPositionMaximum div 2) div
    InputPositionMaximum);
  FollowPointerScreen;
end;

function CursorRectangle: TRectangle;
begin
  Result := MakeRectangle(PointerX, PointerY, ArrowWidth * PointerScale, ArrowHeight * PointerScale);
end;

procedure DrawCursor(const Canvas: TCanvas);
var
  Row: LongInt;
  Column: LongInt;
  Color: TColor;
begin
  for Row := 0 to ArrowHeight - 1 do
    for Column := 1 to ArrowWidth do
    begin
      case Arrow[Row][Column] of
        '#': Color := OutlineColor;
        '.': Color := FillColor;
      else
        Continue;
      end;
      FillRectangle(Canvas, MakeRectangle(PointerX + (Column - 1) * PointerScale, PointerY + Row * PointerScale,
        PointerScale, PointerScale), Color);
    end;
end;

end.
