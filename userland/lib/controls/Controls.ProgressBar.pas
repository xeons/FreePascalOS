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
  Progress bars: how far along something is, as blocks filling a sunken
  well from the left.
}
unit Controls.ProgressBar;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base;

type
  TProgressBar = class(TControl)
  private
    FMinimum: LongInt;
    FMaximum: LongInt;
    FPosition: LongInt;
    procedure SetPosition(Value: LongInt);
    procedure SetMaximum(Value: LongInt);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    property Minimum: LongInt read FMinimum write FMinimum;
    property Maximum: LongInt read FMaximum write SetMaximum;
    property Position: LongInt read FPosition write SetPosition;
  end;

implementation

uses
  Drawing.Rectangles,
  Drawing.Bevels,
  Windowing.Theme,
  Windowing.Connection;

constructor TProgressBar.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FMaximum := 100;
end;

procedure TProgressBar.SetPosition(Value: LongInt);
begin
  if Value < FMinimum then
    Value := FMinimum;
  if Value > FMaximum then
    Value := FMaximum;
  if Value = FPosition then
    Exit;
  FPosition := Value;
  Invalidate;
  Changed;
end;

procedure TProgressBar.SetMaximum(Value: LongInt);
begin
  FMaximum := Value;
  SetPosition(FPosition);
  Invalidate;
end;

procedure TProgressBar.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Well: TRectangle;
  Filled: LongInt;
  BlockWidth: LongInt;
  Gap: LongInt;
  X: LongInt;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Face);
  DrawEdge(Canvas, Box, Theme.Shadow, Theme.Highlight);
  Well := InflateRectangle(Box, -Scaled(2));
  if FMaximum <= FMinimum then
    Exit;
  Filled := Int64(RectangleWidth(Well)) * (FPosition - FMinimum) div (FMaximum - FMinimum);
  BlockWidth := Scaled(8);
  Gap := Scaled(2);
  X := 0;
  while X < Filled do
  begin
    if X + BlockWidth > Filled then
      BlockWidth := Filled - X;
    FillRectangle(Canvas, MakeRectangle(Well.Left + X, Well.Top, BlockWidth, RectangleHeight(Well)), Theme.Selection);
    X := X + BlockWidth + Gap;
  end;
end;

end.
