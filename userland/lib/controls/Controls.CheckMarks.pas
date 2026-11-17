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
  Check marks: the sunken box of a check box, empty, ticked or (for a
  check box with a third state) partly filled, drawn wherever one is
  wanted: check boxes, the items of a checked list box, the date picker.
}
unit Controls.CheckMarks;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas;

type
  { Mixed: some of what it stands for is checked, some not. }
  TCheckState = (CheckUnchecked, CheckChecked, CheckMixed);

{ The size of the box, pixels. }
function CheckMarkSize: LongInt;
{ The box in Box (square, CheckMarkSize), its mark for State; greyed
  when not Enabled. }
procedure DrawCheckMark(const Canvas: TCanvas; const Box: TRectangle; State: TCheckState; Enabled: Boolean);

implementation

uses
  Drawing.Bevels,
  Drawing.Shapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Painting;

function CheckMarkSize: LongInt;
begin
  Result := Scaled(13);
end;

procedure DrawTick(const Canvas: TCanvas; const Box: TRectangle; Color: TColor);
var
  Tick: TRectangle;
  Thickness: LongInt;
  Offset: LongInt;
begin
  { From the left middle down to a third across, then up to the top
    right; Thickness pixels thick. }
  Tick := InflateRectangle(Box, -Scaled(3));
  Thickness := Scaled(2);
  for Offset := 0 to Thickness - 1 do
  begin
    DrawLine(Canvas, Tick.Left, Tick.Top + RectangleHeight(Tick) div 2 + Offset,
      Tick.Left + RectangleWidth(Tick) div 3, Tick.Bottom - Thickness + Offset, Color);
    DrawLine(Canvas, Tick.Left + RectangleWidth(Tick) div 3, Tick.Bottom - Thickness + Offset,
      Tick.Right - 1, Tick.Top + Offset, Color);
  end;
end;

procedure DrawCheckMark(const Canvas: TCanvas; const Box: TRectangle; State: TCheckState; Enabled: Boolean);
var
  MarkColor: TColor;
begin
  if Enabled then
  begin
    FillRectangle(Canvas, Box, Theme.Field);
    MarkColor := Theme.FieldText;
  end
  else
  begin
    FillRectangle(Canvas, Box, Theme.Face);
    MarkColor := Theme.DisabledText;
  end;
  DrawSunkenBevel(Canvas, Box);
  case State of
    CheckChecked: DrawTick(Canvas, Box, MarkColor);
    CheckMixed: FillRectangle(Canvas, InflateRectangle(Box, -Scaled(4)), MarkColor);
  end;
end;

end.
