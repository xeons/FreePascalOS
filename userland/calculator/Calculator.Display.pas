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
  The calculator's display: the expression built so far in small type
  above, the number in large type below, both at the right, in a field
  coloured like an edit box. A number too wide for the large type is
  shown smaller until it fits. Its preferred height is what the two
  lines need, so it sits at the top of the window with AutoSize.
}
unit Calculator.Display;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TCalculatorDisplay = class(TControl)
  private
    FExpression: string;
    FNumber: string;
    FMemoryShown: Boolean;
    procedure SetExpression(const Value: string);
    procedure SetNumber(const Value: string);
    procedure SetMemoryShown(Value: Boolean);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    function PreferredSize: TSize; override;
    property Expression: string read FExpression write SetExpression;
    property Number: string read FNumber write SetNumber;
    { An "M" at the left while memory holds a number. }
    property MemoryShown: Boolean read FMemoryShown write SetMemoryShown;
  end;

implementation

uses
  Drawing.Rectangles,
  Font.Faces,
  Windowing.Connection,
  Windowing.Theme,
  Windowing.Fonts,
  Controls.Text,
  Controls.LayoutRules;

const
  { Tenths of a point: the number's largest and smallest type. }
  LargestNumberSize = 240;
  SmallestNumberSize = 100;
  NumberSizeStep = 20;
  { Logical units. }
  Inset = 6;
  LineGap = 2;

constructor TCalculatorDisplay.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FNumber := '0';
end;

procedure TCalculatorDisplay.SetExpression(const Value: string);
begin
  if FExpression = Value then
    Exit;
  FExpression := Value;
  Invalidate;
end;

procedure TCalculatorDisplay.SetNumber(const Value: string);
begin
  if FNumber = Value then
    Exit;
  FNumber := Value;
  Invalidate;
end;

procedure TCalculatorDisplay.SetMemoryShown(Value: Boolean);
begin
  if FMemoryShown = Value then
    Exit;
  FMemoryShown := Value;
  Invalidate;
end;

{ Faces come at the display's scale, so heights here are pixels; the
  preferred size is logical units. }
function NumberFace(PointTenths: LongWord): PFontFace;
begin
  Result := FontFace(PointTenths, False);
  if Result = nil then
    Result := ControlFace;
end;

function TCalculatorDisplay.PreferredSize: TSize;
var
  Pixels: LongInt;
begin
  Pixels := TextHeight(ControlFace) + TextHeight(NumberFace(LargestNumberSize));
  Result := MakeSize(200, Unscaled(Pixels) + 2 * Inset + LineGap);
end;

procedure TCalculatorDisplay.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Inner: TRectangle;
  Size: LongWord;
  Face: PFontFace;
  SmallHeight: LongInt;
  NumberTop: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawRectangleOutline(Canvas, Box, Theme.Shadow);
  Inner := MakeRectangle(Scaled(Inset), Scaled(Inset), RectangleWidth(Box) - 2 * Scaled(Inset),
    RectangleHeight(Box) - 2 * Scaled(Inset));
  SmallHeight := TextHeight(ControlFace);
  DrawTextInBox(Canvas, ControlFace, FExpression, MakeRectangle(Inner.Left, Inner.Top, RectangleWidth(Inner),
    SmallHeight), AlignTextRight, Theme.DisabledText);
  if FMemoryShown then
    DrawTextInBox(Canvas, ControlFace, 'M', MakeRectangle(Inner.Left, Inner.Bottom - SmallHeight,
      Scaled(20), SmallHeight), AlignTextLeft, Theme.FieldText);
  Size := LargestNumberSize;
  Face := NumberFace(Size);
  while (Size > SmallestNumberSize) and (TextWidth(Face, FNumber) > RectangleWidth(Inner) - Scaled(20)) do
  begin
    Dec(Size, NumberSizeStep);
    Face := NumberFace(Size);
  end;
  NumberTop := Inner.Top + SmallHeight + Scaled(LineGap);
  DrawTextInBox(Canvas, Face, FNumber, MakeRectangle(Inner.Left, NumberTop, RectangleWidth(Inner),
    Inner.Bottom - NumberTop), AlignTextRight, Theme.FieldText);
end;

end.
