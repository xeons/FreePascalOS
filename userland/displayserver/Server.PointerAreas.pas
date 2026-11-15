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
  Which shape the pointer has where.

  Over a window's client area its program decides
  (RequestSetPointerShape): a shape for the whole of it (area 0), and
  shapes for up to MaximumPointerAreas rectangles of it, a higher area
  winning where they overlap (a text beam over an edit box, say). Over
  a frame the server decides: the resize arrows on the borders and
  corners of a window that can be resized, the arrow elsewhere.
  Everywhere else (the desktop) it is the arrow.
}
unit Server.PointerAreas;

{$mode objfpc}

interface

uses
  Drawing.Rectangles,
  Server.Windows,
  Server.Frames;

{ Area 0: the whole client area (Bounds unused); 1 to
  MaximumPointerAreas: Bounds (surface pixels; empty takes it away). }
procedure SetPointerArea(Window: PServerWindow; Area: LongWord; const Bounds: TRectangle; Shape: LongWord);
{ The shape at (X, Y) of the window's surface. }
function ClientPointerShape(Window: PServerWindow; X, Y: LongInt): LongWord;
{ The shape over a part of a frame (the arrow but for borders). }
function FramePointerShape(Area: THitArea): LongWord;

implementation

uses
  Windowing.Protocol;

procedure SetPointerArea(Window: PServerWindow; Area: LongWord; const Bounds: TRectangle; Shape: LongWord);
begin
  if Shape >= PointerShapeCount then
    Exit;
  if Area = 0 then
    Window^.PointerShape := Shape
  else if Area <= MaximumPointerAreas then
  begin
    Window^.PointerAreas[Area].Bounds := Bounds;
    Window^.PointerAreas[Area].Shape := Shape;
  end;
end;

function ClientPointerShape(Window: PServerWindow; X, Y: LongInt): LongWord;
var
  Area: LongInt;
begin
  for Area := MaximumPointerAreas downto 1 do
    if not RectangleIsEmpty(Window^.PointerAreas[Area].Bounds) and
       RectangleContainsPoint(Window^.PointerAreas[Area].Bounds, X, Y) then
      Exit(Window^.PointerAreas[Area].Shape);
  Result := Window^.PointerShape;
end;

function FramePointerShape(Area: THitArea): LongWord;
begin
  case Area of
    HitLeft, HitRight:
      Result := PointerResizeHorizontal;
    HitTop, HitBottom:
      Result := PointerResizeVertical;
    HitTopLeft, HitBottomRight:
      Result := PointerResizeDiagonalDown;
    HitTopRight, HitBottomLeft:
      Result := PointerResizeDiagonalUp;
  else
    Result := PointerArrow;
  end;
end;

end.
