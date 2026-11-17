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
  What a drag looks like: a small label below and right of the pointer,
  in the tooltip's colours, with a sign of what a drop here would do
  (a plus for a copy, an arrow for a move, a bent arrow for a link, a
  struck circle for nothing) and the few words the program gave for
  what is dragged. It follows the pointer and is drawn over the windows,
  under the pointer, at the scale of the display the pointer is on
  (sizes in logical units).
}
unit Server.DragFeedback;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas;

{ Shows the label (or moves it to the pointer, or changes it): Effect is
  a DropEffect* (0: nothing). }
procedure ShowDragFeedback(Effect: LongWord; const Description: string);
procedure HideDragFeedback;
procedure DrawDragFeedback(const Canvas: TCanvas);

implementation

uses
  Drawing.Colors,
  Drawing.Shapes,
  Font.Faces,
  Font.Text,
  Windowing.Theme,
  Windowing.Protocol,
  Server.Screen,
  Server.Desktop,
  Server.Cursor,
  Server.Composer;

const
  { Logical units. }
  OffsetX = 14;
  OffsetY = 22;
  SignSize = 14;
  Padding = 4;
  MaximumTextWidth = 220;
  MaximumCharacters = 40;
  NothingColor = $FFC0392B;
  CopyColor = $FF2E7D32;

var
  Visible: Boolean;
  Bounds: TRectangle;
  ShownEffect: LongWord;
  ShownText: string;
  { The scale it is drawn at (the pointer's display's). }
  ShownScale: LongWord;

function Metric(Value: LongInt): LongInt;
begin
  Result := LogicalToPixels(Value, ShownScale);
end;

function Face: PFontFace;
begin
  Result := NearestScreen(PointerX, PointerY)^.TitleFace;
end;

procedure ShowDragFeedback(Effect: LongWord; const Description: string);
var
  TextWidth: LongInt;
  Height: LongInt;
begin
  if Visible then
    AddDamage(Bounds);
  Visible := True;
  ShownEffect := Effect;
  ShownText := Copy(Description, 1, MaximumCharacters);
  ShownScale := NearestScreen(PointerX, PointerY)^.ScalePercent;
  TextWidth := 0;
  Height := Metric(SignSize);
  if (Face <> nil) and (ShownText <> '') then
  begin
    TextWidth := MeasureText(Face^, ShownText);
    if TextWidth > Metric(MaximumTextWidth) then
      TextWidth := Metric(MaximumTextWidth);
    if Face^.Height > Height then
      Height := Face^.Height;
  end;
  Bounds := MakeRectangle(PointerX + Metric(OffsetX), PointerY + Metric(OffsetY),
    Metric(SignSize) + 2 * Metric(Padding) + TextWidth, Height + 2 * Metric(Padding));
  if TextWidth > 0 then
    Bounds.Right := Bounds.Right + Metric(Padding);
  AddDamage(Bounds);
end;

procedure HideDragFeedback;
begin
  if Visible then
    AddDamage(Bounds);
  Visible := False;
end;

procedure DrawPlus(const Canvas: TCanvas; const Box: TRectangle);
var
  Thickness: LongInt;
  MiddleX: LongInt;
  MiddleY: LongInt;
begin
  Thickness := Metric(2);
  MiddleX := (Box.Left + Box.Right) div 2;
  MiddleY := (Box.Top + Box.Bottom) div 2;
  FillRectangle(Canvas, MakeRectangle(Box.Left + Metric(2), MiddleY - Thickness div 2, RectangleWidth(Box) - Metric(4),
    Thickness), CopyColor);
  FillRectangle(Canvas, MakeRectangle(MiddleX - Thickness div 2, Box.Top + Metric(2), Thickness,
    RectangleHeight(Box) - Metric(4)), CopyColor);
end;

procedure DrawArrow(const Canvas: TCanvas; const Box: TRectangle; Bent: Boolean);
var
  MiddleY: LongInt;
  Thickness: LongInt;
  Head: array[0..2] of TPoint;
  ShaftLeft: LongInt;
begin
  MiddleY := (Box.Top + Box.Bottom) div 2;
  Thickness := Metric(2);
  ShaftLeft := Box.Left + Metric(2);
  if Bent then
  begin
    { Up from the bottom left, then along to the head. }
    FillRectangle(Canvas, MakeRectangle(ShaftLeft, MiddleY, Thickness, Box.Bottom - Metric(2) - MiddleY),
      Theme.Selection);
    ShaftLeft := ShaftLeft + Thickness;
  end;
  FillRectangle(Canvas, MakeRectangle(ShaftLeft, MiddleY - Thickness div 2, Box.Right - Metric(6) - ShaftLeft,
    Thickness), Theme.Selection);
  Head[0].X := Box.Right - Metric(7);
  Head[0].Y := MiddleY - Metric(5);
  Head[1].X := Box.Right - Metric(1);
  Head[1].Y := MiddleY;
  Head[2].X := Box.Right - Metric(7);
  Head[2].Y := MiddleY + Metric(5);
  FillPolygon(Canvas, Head, Theme.Selection);
end;

procedure DrawNothing(const Canvas: TCanvas; const Box: TRectangle);
var
  Inset: LongInt;
begin
  Inset := Metric(1);
  DrawEllipseOutline(Canvas, InflateRectangle(Box, -Inset), NothingColor);
  DrawEllipseOutline(Canvas, InflateRectangle(Box, -Inset - 1), NothingColor);
  DrawLine(Canvas, Box.Left + Metric(3), Box.Bottom - Metric(4), Box.Right - Metric(4), Box.Top + Metric(3),
    NothingColor);
  DrawLine(Canvas, Box.Left + Metric(3) + 1, Box.Bottom - Metric(4), Box.Right - Metric(4), Box.Top + Metric(3) + 1,
    NothingColor);
end;

procedure DrawDragFeedback(const Canvas: TCanvas);
var
  Sign: TRectangle;
  TextClip: TCanvas;
  TextLeft: LongInt;
begin
  if not Visible then
    Exit;
  FillRectangle(Canvas, Bounds, Theme.Tooltip);
  DrawRectangleOutline(Canvas, Bounds, Theme.TooltipBorder);
  Sign := MakeRectangle(Bounds.Left + Metric(Padding), Bounds.Top + (RectangleHeight(Bounds) - Metric(SignSize)) div 2,
    Metric(SignSize), Metric(SignSize));
  if (ShownEffect and DropEffectMove) <> 0 then
    DrawArrow(Canvas, Sign, False)
  else if (ShownEffect and DropEffectCopy) <> 0 then
    DrawPlus(Canvas, Sign)
  else if (ShownEffect and DropEffectLink) <> 0 then
    DrawArrow(Canvas, Sign, True)
  else
    DrawNothing(Canvas, Sign);
  if (ShownText = '') or (Face = nil) then
    Exit;
  TextLeft := Sign.Right + Metric(Padding);
  TextClip := Canvas;
  NarrowCanvasClip(TextClip, MakeRectangle(TextLeft, Bounds.Top, Bounds.Right - Metric(Padding) - TextLeft,
    RectangleHeight(Bounds)));
  DrawText(TextClip, Face^, TextLeft, Bounds.Top + (RectangleHeight(Bounds) - Face^.Height) div 2, ShownText,
    Theme.TooltipText);
end;

end.
