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
  A chart's grid and axes: grid lines at the ticks under the series,
  then over them the axes' lines along the plot's left and bottom edges,
  the tick labels (the value axis' beside its ticks, the X axis' centred
  under them, every so many categories when names would crowd) and the
  axes' titles. Lines are whole pixels, a logical unit thick, so they
  stay crisp at every scale.
}
unit Controls.ChartAxisPainting;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.ChartModel,
  Controls.ChartStyle,
  Controls.ChartLayout;

procedure PaintChartGrid(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle);
procedure PaintChartAxes(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle);

implementation

uses
  Math,
  Drawing.Rectangles,
  Controls.ChartScale;

const
  { Logical units. }
  LabelGap = 5;

function LineThickness(const Style: TChartStyle): LongInt;
begin
  Result := ChartPixels(Style, 1);
end;

{ A line across the plot at Pixel along an axis: level for the value
  axis (upright when Horizontal), upright for the X axis. }
procedure DrawLineAcross(const Canvas: TCanvas; const Layout: TChartLayout; const Style: TChartStyle; Pixel: Double;
  Level: Boolean);
var
  Position: LongInt;
  Thickness: LongInt;
begin
  Thickness := LineThickness(Style);
  Position := Floor(Pixel + 0.5) - (Thickness - 1) div 2;
  if Level then
    FillRectangle(Canvas, MakeRectangle(Layout.Plot.Left, Position, RectangleWidth(Layout.Plot), Thickness),
      Style.Grid)
  else
    FillRectangle(Canvas, MakeRectangle(Position, Layout.Plot.Top, Thickness, RectangleHeight(Layout.Plot)),
      Style.Grid);
end;

procedure PaintChartGrid(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle);
var
  Tick: LongInt;
begin
  if Layout.IsPie or RectangleIsEmpty(Layout.Plot) then
    Exit;
  if Model.YAxis.ShowGrid then
    for Tick := 0 to TickCount(Layout.YRange) - 1 do
      DrawLineAcross(Canvas, Layout, Style, ValuePixel(Layout, TickAt(Layout.YRange, Tick)), not Layout.Horizontal);
  { Categories need no lines between them: the bars' gaps show them. }
  if Model.XAxis.ShowGrid and not Layout.Categorical then
    for Tick := 0 to TickCount(Layout.XRange) - 1 do
      DrawLineAcross(Canvas, Layout, Style, PositionPixel(Layout, TickAt(Layout.XRange, Tick)), Layout.Horizontal);
end;

{ A label right-aligned against the plot's left edge, centred on Pixel
  (a row). }
procedure DrawLeftLabel(const Canvas: TCanvas; const Layout: TChartLayout; const Style: TChartStyle;
  const Text: string; Pixel: Double);
var
  Width: LongInt;
  Y: LongInt;
begin
  Width := ChartTextWidth(Style.LabelFace, Text);
  Y := Floor(Pixel + 0.5) - ChartTextHeight(Style.LabelFace) div 2;
  DrawChartText(Canvas, Style.LabelFace, Layout.Plot.Left - ChartPixels(Style, LabelGap) - Width, Y, Text,
    Style.QuietText);
end;

{ A label under the plot, centred on Pixel (a column), kept within the
  chart. }
procedure DrawBottomLabel(const Canvas: TCanvas; const Layout: TChartLayout; const Style: TChartStyle;
  const Text: string; Pixel: Double);
var
  Width: LongInt;
  X: LongInt;
begin
  Width := ChartTextWidth(Style.LabelFace, Text);
  X := Floor(Pixel + 0.5) - Width div 2;
  if X + Width > Layout.Inner.Right then
    X := Layout.Inner.Right - Width;
  if X < Layout.Inner.Left then
    X := Layout.Inner.Left;
  DrawChartText(Canvas, Style.LabelFace, X, Layout.Plot.Bottom + ChartPixels(Style, LabelGap), Text, Style.QuietText);
end;

procedure PaintValueLabels(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle);
var
  Tick: LongInt;
  Value: Double;
  Text: string;
begin
  for Tick := 0 to TickCount(Layout.YRange) - 1 do
  begin
    Value := TickAt(Layout.YRange, Tick);
    Text := Model.YAxis.TickLabel(Layout.YRange, Value);
    if Layout.Horizontal then
      DrawBottomLabel(Canvas, Layout, Style, Text, ValuePixel(Layout, Value))
    else
      DrawLeftLabel(Canvas, Layout, Style, Text, ValuePixel(Layout, Value));
  end;
end;

procedure PaintPositionLabels(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle);
var
  Tick: LongInt;
  Count: LongInt;
  Value: Double;
  Text: string;
begin
  Count := TickCount(Layout.XRange);
  for Tick := 0 to Count - 1 do
  begin
    if Layout.Categorical and (Tick mod Layout.CategoryStride <> 0) then
      Continue;
    Value := TickAt(Layout.XRange, Tick);
    Text := PositionLabel(Model, Layout, Value);
    if Layout.Horizontal then
      DrawLeftLabel(Canvas, Layout, Style, Text, PositionPixel(Layout, Value))
    else
      DrawBottomLabel(Canvas, Layout, Style, Text, PositionPixel(Layout, Value));
  end;
end;

procedure PaintChartAxes(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle);
var
  LeftVisible: Boolean;
  BottomVisible: Boolean;
  Thickness: LongInt;
  LeftTitle: string;
  BottomTitle: string;
  Width: LongInt;
begin
  if Layout.IsPie or RectangleIsEmpty(Layout.Plot) then
    Exit;
  if Layout.Horizontal then
  begin
    LeftVisible := Model.XAxis.Visible;
    BottomVisible := Model.YAxis.Visible;
    LeftTitle := Model.XAxis.Title;
    BottomTitle := Model.YAxis.Title;
  end
  else
  begin
    LeftVisible := Model.YAxis.Visible;
    BottomVisible := Model.XAxis.Visible;
    LeftTitle := Model.YAxis.Title;
    BottomTitle := Model.XAxis.Title;
  end;
  Thickness := LineThickness(Style);
  if LeftVisible then
    FillRectangle(Canvas, MakeRectangle(Layout.Plot.Left, Layout.Plot.Top, Thickness, RectangleHeight(Layout.Plot)),
      Style.AxisLine);
  if BottomVisible then
    FillRectangle(Canvas, MakeRectangle(Layout.Plot.Left, Layout.Plot.Bottom - Thickness, RectangleWidth(Layout.Plot),
      Thickness), Style.AxisLine);
  if Model.YAxis.Visible then
    PaintValueLabels(Canvas, Model, Layout, Style);
  if Model.XAxis.Visible then
    PaintPositionLabels(Canvas, Model, Layout, Style);
  if LeftVisible and not RectangleIsEmpty(Layout.LeftTitleBox) then
    DrawChartText(Canvas, Style.LabelFace, Layout.LeftTitleBox.Left, Layout.LeftTitleBox.Top, LeftTitle,
      Style.QuietText);
  if BottomVisible and not RectangleIsEmpty(Layout.BottomTitleBox) then
  begin
    Width := ChartTextWidth(Style.LabelFace, BottomTitle);
    DrawChartText(Canvas, Style.LabelFace, Layout.Plot.Left + (RectangleWidth(Layout.Plot) - Width) div 2,
      Layout.BottomTitleBox.Top, BottomTitle, Style.QuietText);
  end;
end;

end.
