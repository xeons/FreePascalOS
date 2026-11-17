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
  An XY chart's series: areas first (filled down to their base, lightly
  where they stand alone, more strongly where they stack, so the bands
  read), then bars (solid, in their places in each category), then the
  lines over them, the areas' edges among them, with their markers.

  Lines and fills are anti-aliased (libdrawing's rasterizer), the line
  as wide as the series says at the chart's scale. A stepped series goes
  level to the next point's X, then straight up or down to it.
}
unit Controls.ChartSeriesPainting;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Controls.ChartModel,
  Controls.ChartStyle,
  Controls.ChartLayout;

{ HoverSeries and HoverPoint pick a bar to draw lit (-1: none). }
procedure PaintChartSeries(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; HoverSeries, HoverPoint: LongInt);
{ A marker: a dot of Color ringed with the background. }
procedure PaintMarker(const Canvas: TCanvas; const Style: TChartStyle; X, Y: Double; Color: TColor);

implementation

uses
  Math,
  Drawing.Rectangles,
  Drawing.Rasterizer,
  Drawing.SmoothLines,
  Drawing.SmoothShapes,
  Controls.ChartSeries,
  Controls.ChartValues;

const
  AloneAreaAlpha = 56;
  StackedAreaAlpha = 170;
  { Logical units. }
  MarkerRadius = 3.0;
  MarkerRing = 1.5;
  { Lit bars go this far towards white. }
  HoverLightening = 70;

type
  TPixelPoints = array of TPrecisePoint;

{ The series' points on the screen (centre coordinates), at their tops
  (Tops) or their bases; stepped series get the corners between. }
function SeriesPixels(Model: TChartModel; const Layout: TChartLayout; SeriesIndex: LongInt;
  Tops: Boolean): TPixelPoints;
var
  Series: TChartSeries;
  Point: LongInt;
  Count: LongInt;
  Base: Double;
  Top: Double;
  Value: Double;
  PreviousValue: Double;
  PixelX: Double;
  PixelY: Double;
begin
  Series := Model[SeriesIndex];
  Result := nil;
  SetLength(Result, 2 * Series.Count);
  Count := 0;
  PreviousValue := 0;
  for Point := 0 to Series.Count - 1 do
  begin
    StackedPoint(Model, SeriesIndex, Point, Base, Top);
    if Tops then
      Value := Top
    else if Series.Stacked then
      Value := Base
    else
      { Down to 0, or to the range's edge when 0 is outside it. }
      Value := Min(Max(0, Layout.YRange.Minimum), Layout.YRange.Maximum);
    if Series.Stepped and (Point > 0) then
    begin
      PointPixel(Layout, Series.X[Point], PreviousValue, PixelX, PixelY);
      Result[Count] := PrecisePoint(PixelX, PixelY);
      Inc(Count);
    end;
    PointPixel(Layout, Series.X[Point], Value, PixelX, PixelY);
    Result[Count] := PrecisePoint(PixelX, PixelY);
    Inc(Count);
    PreviousValue := Value;
  end;
  SetLength(Result, Count);
end;

procedure PaintArea(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; SeriesIndex: LongInt);
var
  Tops: TPixelPoints;
  Bases: TPixelPoints;
  Outline: TPixelPoints;
  Index: LongInt;
  Alpha: Byte;
begin
  Tops := SeriesPixels(Model, Layout, SeriesIndex, True);
  Bases := SeriesPixels(Model, Layout, SeriesIndex, False);
  if Length(Tops) < 2 then
    Exit;
  { Along the tops, back along the bases; centre coordinates to the
    rasterizer's (half a pixel on). }
  Outline := nil;
  SetLength(Outline, Length(Tops) + Length(Bases));
  for Index := 0 to High(Tops) do
    Outline[Index] := PrecisePoint(Tops[Index].X + 0.5, Tops[Index].Y + 0.5);
  for Index := 0 to High(Bases) do
    Outline[Length(Tops) + Index] := PrecisePoint(Bases[High(Bases) - Index].X + 0.5,
      Bases[High(Bases) - Index].Y + 0.5);
  if Model[SeriesIndex].Stacked then
    Alpha := StackedAreaAlpha
  else
    Alpha := AloneAreaAlpha;
  FillSmoothPolygon(Canvas, Outline, WithAlpha(SeriesColor(Model, SeriesIndex, Style), Alpha));
end;

procedure PaintMarker(const Canvas: TCanvas; const Style: TChartStyle; X, Y: Double; Color: TColor);
var
  Shape: TCoverageShape;
  Radius: Double;
begin
  Radius := ChartPixelsExact(Style, MarkerRadius);
  BeginShape(Shape);
  AddShapeEllipse(Shape, X + 0.5, Y + 0.5, Radius + ChartPixelsExact(Style, MarkerRing),
    Radius + ChartPixelsExact(Style, MarkerRing), True);
  FillShape(Canvas, Shape, Style.Background);
  BeginShape(Shape);
  AddShapeEllipse(Shape, X + 0.5, Y + 0.5, Radius, Radius, True);
  FillShape(Canvas, Shape, Color);
end;

procedure PaintLine(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; SeriesIndex: LongInt);
var
  Series: TChartSeries;
  Tops: TPixelPoints;
  Color: TColor;
  Point: LongInt;
  PixelX: Double;
  PixelY: Double;
  Base: Double;
  Top: Double;
begin
  Series := Model[SeriesIndex];
  Color := SeriesColor(Model, SeriesIndex, Style);
  Tops := SeriesPixels(Model, Layout, SeriesIndex, True);
  DrawSmoothPolyline(Canvas, Tops, ChartPixelsExact(Style, Series.LineWidth), Color);
  if not Series.ShowMarkers then
    Exit;
  for Point := 0 to Series.Count - 1 do
  begin
    StackedPoint(Model, SeriesIndex, Point, Base, Top);
    PointPixel(Layout, Series.X[Point], Top, PixelX, PixelY);
    PaintMarker(Canvas, Style, PixelX, PixelY, Color);
  end;
end;

procedure PaintBars(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; SeriesIndex, HoverSeries, HoverPoint: LongInt);
var
  Series: TChartSeries;
  Point: LongInt;
  Color: TColor;
  Bar: TRectangle;
begin
  Series := Model[SeriesIndex];
  Color := SeriesColor(Model, SeriesIndex, Style);
  for Point := 0 to Series.Count - 1 do
  begin
    Bar := BarRectangle(Model, Layout, Style, SeriesIndex, Point);
    if (SeriesIndex = HoverSeries) and (Point = HoverPoint) then
      FillRectangle(Canvas, Bar, MixColors(Color, $FFFFFFFF, HoverLightening))
    else
      FillRectangle(Canvas, Bar, Color);
  end;
end;

procedure PaintChartSeries(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; HoverSeries, HoverPoint: LongInt);
var
  Index: LongInt;
  Series: TChartSeries;
  PlotCanvas: TCanvas;
  Room: LongInt;
begin
  if Layout.IsPie or RectangleIsEmpty(Layout.Plot) then
    Exit;
  { Fills stay in the plot; lines and markers may reach a little past
    its edges (a line at the top value is cut in half otherwise). }
  PlotCanvas := Canvas;
  NarrowCanvasClip(PlotCanvas, Layout.Plot);
  for Index := 0 to Model.SeriesCount - 1 do
  begin
    Series := Model[Index];
    if Series.Visible and (Series.Kind = SeriesArea) then
      PaintArea(PlotCanvas, Model, Layout, Style, Index);
  end;
  for Index := 0 to Model.SeriesCount - 1 do
  begin
    Series := Model[Index];
    if Series.Visible and (Series.Kind = SeriesBar) then
      PaintBars(PlotCanvas, Model, Layout, Style, Index, HoverSeries, HoverPoint);
  end;
  PlotCanvas := Canvas;
  Room := ChartPixels(Style, Ceil(MarkerRadius + MarkerRing));
  NarrowCanvasClip(PlotCanvas, InflateRectangle(Layout.Plot, Room));
  NarrowCanvasClip(PlotCanvas, Layout.Inner);
  for Index := 0 to Model.SeriesCount - 1 do
  begin
    Series := Model[Index];
    if Series.Visible and (Series.Kind in [SeriesLine, SeriesArea]) then
      PaintLine(PlotCanvas, Model, Layout, Style, Index);
  end;
end;

end.
