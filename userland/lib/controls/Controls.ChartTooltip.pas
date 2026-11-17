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
  What a chart shows of the thing under the pointer: over lines and
  areas a crosshair at the nearest X, a marker on every series' point
  there and a tooltip of their values; over a bar or a slice a tooltip
  of its value (the bar or slice itself is drawn lit). The tooltip is a
  box in the theme's tooltip colours beside the point it describes, kept
  inside the chart: a header (the X or the category) and a line for each
  value, with the series' colour.
}
unit Controls.ChartTooltip;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.ChartModel,
  Controls.ChartStyle,
  Controls.ChartLayout,
  Controls.ChartHitTesting;

procedure PaintChartHover(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; const Hit: TChartHit);

implementation

uses
  Math,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Rasterizer,
  Drawing.SmoothArcs,
  Controls.ChartSeries,
  Controls.ChartValues,
  Controls.ChartFormat,
  Controls.ChartSeriesPainting,
  Controls.ChartPiePainting;

const
  { Logical units. }
  Padding = 4;
  SwatchSize = 8;
  SwatchGap = 4;
  AnchorGap = 10;
  CrosshairAlpha = 150;

type
  TTooltipLine = record
    Text: string;
    { 0: a header, no swatch. }
    Color: TColor;
  end;
  TTooltipLines = array of TTooltipLine;

procedure AddLine(var Lines: TTooltipLines; const Text: string; Color: TColor);
begin
  SetLength(Lines, Length(Lines) + 1);
  Lines[High(Lines)].Text := Text;
  Lines[High(Lines)].Color := Color;
end;

function ValueText(Model: TChartModel; const Layout: TChartLayout; Value: Double): string;
begin
  Result := Model.YAxis.ValueText(Layout.YRange, Value);
end;

function PositionText(Model: TChartModel; const Layout: TChartLayout; X: Double): string;
begin
  if Layout.Categorical then
    Result := PositionLabel(Model, Layout, X)
  else
    Result := Model.XAxis.ValueText(Layout.XRange, X);
end;

procedure PaintTooltipBox(const Canvas: TCanvas; const Layout: TChartLayout; const Style: TChartStyle;
  const Lines: TTooltipLines; AnchorX, AnchorY: LongInt);
var
  Index: LongInt;
  Width: LongInt;
  LineWidth: LongInt;
  LineHeight: LongInt;
  Box: TRectangle;
  X: LongInt;
  Y: LongInt;
  Gap: LongInt;
  Swatch: LongInt;
begin
  if Length(Lines) = 0 then
    Exit;
  Swatch := ChartPixels(Style, SwatchSize) + ChartPixels(Style, SwatchGap);
  Width := 0;
  for Index := 0 to High(Lines) do
  begin
    LineWidth := ChartTextWidth(Style.LabelFace, Lines[Index].Text);
    if Lines[Index].Color <> 0 then
      LineWidth := LineWidth + Swatch;
    Width := Max(Width, LineWidth);
  end;
  LineHeight := Max(ChartTextHeight(Style.LabelFace), ChartPixels(Style, SwatchSize));
  Width := Width + 2 * ChartPixels(Style, Padding);
  Box := MakeRectangle(0, 0, Width, Length(Lines) * LineHeight + 2 * ChartPixels(Style, Padding));
  { Up and to the right of the anchor, or wherever it fits. }
  Gap := ChartPixels(Style, AnchorGap);
  X := AnchorX + Gap;
  if X + RectangleWidth(Box) > Layout.Inner.Right then
    X := AnchorX - Gap - RectangleWidth(Box);
  if X < Layout.Inner.Left then
    X := Layout.Inner.Left;
  Y := AnchorY - Gap - RectangleHeight(Box);
  if Y < Layout.Inner.Top then
    Y := AnchorY + Gap;
  if Y + RectangleHeight(Box) > Layout.Inner.Bottom then
    Y := Max(Layout.Inner.Top, Layout.Inner.Bottom - RectangleHeight(Box));
  Box := OffsetRectangle(Box, X, Y);
  FillRectangle(Canvas, Box, Style.Tooltip);
  DrawRectangleOutline(Canvas, Box, Style.AxisLine);
  Y := Box.Top + ChartPixels(Style, Padding);
  for Index := 0 to High(Lines) do
  begin
    X := Box.Left + ChartPixels(Style, Padding);
    if Lines[Index].Color <> 0 then
    begin
      FillRectangle(Canvas, MakeRectangle(X, Y + (LineHeight - ChartPixels(Style, SwatchSize)) div 2,
        ChartPixels(Style, SwatchSize), ChartPixels(Style, SwatchSize)), Lines[Index].Color);
      X := X + Swatch;
    end;
    DrawChartText(Canvas, Style.LabelFace, X, Y + (LineHeight - ChartTextHeight(Style.LabelFace)) div 2,
      Lines[Index].Text, Style.TooltipText);
    Y := Y + LineHeight;
  end;
end;

procedure PaintPointHover(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; const Hit: TChartHit);
var
  Lines: TTooltipLines;
  SeriesIndex: LongInt;
  Series: TChartSeries;
  Point: LongInt;
  Base: Double;
  Top: Double;
  PixelX: Double;
  PixelY: Double;
  AnchorX: Double;
  AnchorY: Double;
  Crosshair: Double;
  Thickness: LongInt;
  Color: TColor;
begin
  Lines := nil;
  AddLine(Lines, PositionText(Model, Layout, Hit.X), 0);
  Crosshair := PositionPixel(Layout, Hit.X);
  Thickness := ChartPixels(Style, 1);
  if Layout.Horizontal then
    FillRectangle(Canvas, MakeRectangle(Layout.Plot.Left, Floor(Crosshair + 0.5), RectangleWidth(Layout.Plot),
      Thickness), WithAlpha(Style.AxisLine, CrosshairAlpha))
  else
    FillRectangle(Canvas, MakeRectangle(Floor(Crosshair + 0.5), Layout.Plot.Top, Thickness,
      RectangleHeight(Layout.Plot)), WithAlpha(Style.AxisLine, CrosshairAlpha));
  AnchorX := Crosshair;
  AnchorY := (Layout.Plot.Top + Layout.Plot.Bottom) / 2;
  if Layout.Horizontal then
  begin
    AnchorX := (Layout.Plot.Left + Layout.Plot.Right) / 2;
    AnchorY := Crosshair;
  end;
  for SeriesIndex := 0 to Model.SeriesCount - 1 do
  begin
    Series := Model[SeriesIndex];
    if not Series.Visible or not (Series.Kind in [SeriesLine, SeriesArea]) then
      Continue;
    Point := Series.NearestIndex(Hit.X);
    if (Point < 0) or (Abs(Series.X[Point] - Hit.X) > 1E-9 * Max(1, Abs(Hit.X))) then
      Continue;
    Color := SeriesColor(Model, SeriesIndex, Style);
    StackedPoint(Model, SeriesIndex, Point, Base, Top);
    PointPixel(Layout, Series.X[Point], Top, PixelX, PixelY);
    PaintMarker(Canvas, Style, PixelX, PixelY, Color);
    if SeriesIndex = Hit.SeriesIndex then
    begin
      AnchorX := PixelX;
      AnchorY := PixelY;
    end;
    if Series.Name <> '' then
      AddLine(Lines, Series.Name + ': ' + ValueText(Model, Layout, Series.Y[Point]), Color)
    else
      AddLine(Lines, ValueText(Model, Layout, Series.Y[Point]), Color);
  end;
  PaintTooltipBox(Canvas, Layout, Style, Lines, Round(AnchorX), Round(AnchorY));
end;

procedure PaintBarHover(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; const Hit: TChartHit);
var
  Lines: TTooltipLines;
  Series: TChartSeries;
  Bar: TRectangle;
begin
  Series := Model[Hit.SeriesIndex];
  Lines := nil;
  AddLine(Lines, PositionText(Model, Layout, Series.X[Hit.PointIndex]), 0);
  AddLine(Lines, Series.Name + ': ' + ValueText(Model, Layout, Series.Y[Hit.PointIndex]),
    SeriesColor(Model, Hit.SeriesIndex, Style));
  Bar := BarRectangle(Model, Layout, Style, Hit.SeriesIndex, Hit.PointIndex);
  if Layout.Horizontal then
    PaintTooltipBox(Canvas, Layout, Style, Lines, Bar.Right, (Bar.Top + Bar.Bottom) div 2)
  else
    PaintTooltipBox(Canvas, Layout, Style, Lines, (Bar.Left + Bar.Right) div 2, Bar.Top);
end;

procedure PaintSliceHover(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; const Hit: TChartHit);
var
  Lines: TTooltipLines;
  Series: TChartSeries;
  Index: LongInt;
  CentreX: Double;
  CentreY: Double;
  Anchor: TPrecisePoint;
begin
  Series := Model[Hit.SeriesIndex];
  for Index := 0 to High(Layout.Slices) do
    if Layout.Slices[Index].PointIndex = Hit.PointIndex then
    begin
      Lines := nil;
      AddLine(Lines, Series.Points[Hit.PointIndex].Text, 0);
      AddLine(Lines, ValueText(Model, Layout, Series.Y[Hit.PointIndex]) + ' (' +
        FormatShare(Layout.Slices[Index].Share) + ')', SliceColor(Series, Hit.PointIndex, Style));
      SliceCentre(Model, Layout, Index, CentreX, CentreY);
      Anchor := PointOnCircle(CentreX, CentreY, (Layout.PieRadius + Layout.PieInnerRadius) / 2,
        Layout.Slices[Index].StartAngle + Layout.Slices[Index].SweepAngle / 2);
      PaintTooltipBox(Canvas, Layout, Style, Lines, Round(Anchor.X), Round(Anchor.Y));
      Exit;
    end;
end;

procedure PaintChartHover(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; const Hit: TChartHit);
var
  HoverCanvas: TCanvas;
begin
  { The data may have changed since the pointer moved. }
  if (Hit.SeriesIndex < 0) or (Hit.SeriesIndex >= Model.SeriesCount) then
    Exit;
  if (Hit.Kind in [HitBar, HitSlice]) and ((Hit.PointIndex < 0) or (Hit.PointIndex >= Model[Hit.SeriesIndex].Count)) then
    Exit;
  HoverCanvas := Canvas;
  NarrowCanvasClip(HoverCanvas, Layout.Inner);
  case Hit.Kind of
    HitPoint: PaintPointHover(HoverCanvas, Model, Layout, Style, Hit);
    HitBar: PaintBarHover(HoverCanvas, Model, Layout, Style, Hit);
    HitSlice: PaintSliceHover(HoverCanvas, Model, Layout, Style, Hit);
  end;
end;

end.
