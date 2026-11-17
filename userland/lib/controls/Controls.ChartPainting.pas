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
  A whole chart drawn on a canvas: lays it out (Controls.ChartLayout),
  then the frame and background, the grid, the series or the pie, the
  axes, the legend, the title, and last what is under the pointer.

  It needs nothing of a window, so the chart control draws with it and
  a host test draws on a surface of its own (tools/ChartTest).
}
unit Controls.ChartPainting;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.ChartModel,
  Controls.ChartStyle,
  Controls.ChartLayout,
  Controls.ChartHitTesting;

{ Draws Model in Bounds (canvas coordinates) and returns the layout it
  used (for finding what is under the pointer). Hover is what to show
  as under the pointer (NoChartHit for nothing). }
procedure PaintChart(const Canvas: TCanvas; Model: TChartModel; const Style: TChartStyle; const Bounds: TRectangle;
  const Hover: TChartHit; out Layout: TChartLayout);

implementation

uses
  Drawing.Bevels,
  Controls.ChartLegend,
  Controls.ChartAxisPainting,
  Controls.ChartSeriesPainting,
  Controls.ChartPiePainting,
  Controls.ChartTooltip;

procedure PaintTitle(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout; const Style: TChartStyle);
var
  Width: LongInt;
  X: LongInt;
  TitleCanvas: TCanvas;
begin
  if (Model.Title = '') or RectangleIsEmpty(Layout.TitleBox) then
    Exit;
  TitleCanvas := Canvas;
  NarrowCanvasClip(TitleCanvas, Layout.TitleBox);
  Width := ChartTextWidth(Style.TitleFace, Model.Title);
  if Model.TitlePlacement = TitleAbove then
    X := Layout.TitleBox.Left + (RectangleWidth(Layout.TitleBox) - Width) div 2
  else
    X := Layout.TitleBox.Left;
  DrawChartText(TitleCanvas, Style.TitleFace, X, Layout.TitleBox.Top, Model.Title, Style.Foreground);
end;

procedure PaintChart(const Canvas: TCanvas; Model: TChartModel; const Style: TChartStyle; const Bounds: TRectangle;
  const Hover: TChartHit; out Layout: TChartLayout);
var
  HoverSeries: LongInt;
  HoverPoint: LongInt;
  HoverLegend: LongInt;
begin
  ComputeChartLayout(Model, Style, Bounds, Layout);
  if Model.Framed then
    DrawBevel(Canvas, Bounds, Style.Frame);
  FillRectangle(Canvas, Layout.Inner, Style.Background);
  HoverSeries := -1;
  HoverPoint := -1;
  HoverLegend := -1;
  if Hover.Kind in [HitBar, HitSlice] then
  begin
    HoverSeries := Hover.SeriesIndex;
    HoverPoint := Hover.PointIndex;
  end;
  if Hover.Kind = HitLegend then
    HoverLegend := Hover.LegendIndex;
  if Layout.IsPie then
  begin
    if HoverSeries <> Layout.PieSeries then
      HoverPoint := -1;
    PaintChartPie(Canvas, Model, Layout, Style, HoverPoint);
  end
  else
  begin
    PaintChartGrid(Canvas, Model, Layout, Style);
    PaintChartSeries(Canvas, Model, Layout, Style, HoverSeries, HoverPoint);
    PaintChartAxes(Canvas, Model, Layout, Style);
  end;
  if Model.LegendPosition <> LegendNone then
    PaintLegend(Canvas, Layout.Legend, Style, HoverLegend);
  PaintTitle(Canvas, Model, Layout, Style);
  PaintChartHover(Canvas, Model, Layout, Style, Hover);
end;

end.
