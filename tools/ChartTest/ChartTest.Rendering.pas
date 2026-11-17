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
  Charts drawn on surfaces and looked at pixel by pixel: the axes' lines
  and the grid, how far bars reach, the colour of a pie's slice at a
  known angle, the gap an exploded slice leaves, a doughnut's hole, a
  line's row, and what is under the pointer. Drawn without fonts (the
  text is left out), so the pixels do not depend on any.
}
unit ChartTest.Rendering;

{$mode objfpc}
{$H+}

interface

procedure TestChartRendering;

implementation

uses
  SysUtils,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Drawing.Rasterizer,
  Drawing.SmoothArcs,
  Controls.ChartSeries,
  Controls.ChartModel,
  Controls.ChartStyle,
  Controls.ChartPalette,
  Controls.ChartLayout,
  Controls.ChartHitTesting,
  Controls.ChartPainting,
  ChartTest.Checks;

const
  White = $FFFFFFFF;

type
  TDrawnChart = record
    Surface: TSurface;
    Layout: TChartLayout;
    Style: TChartStyle;
  end;

function DrawChart(Model: TChartModel; Width, Height: LongInt; ScalePercent: LongWord): TDrawnChart;
var
  Canvas: TCanvas;
begin
  Result.Style := PlainChartStyle(ScalePercent, nil, nil);
  CreateSurface(Result.Surface, Width, Height, White);
  BeginCanvas(Canvas, Result.Surface);
  PaintChart(Canvas, Model, Result.Style, MakeRectangle(0, 0, Width, Height), NoChartHit, Result.Layout);
end;

function PixelAt(const Drawn: TDrawnChart; X, Y: Double): TColor;
begin
  Result := GetSurfacePixel(Drawn.Surface, Trunc(X), Trunc(Y));
end;

function NewBarModel: TChartModel;
var
  Series: TChartSeries;
begin
  Result := TChartModel.Create;
  Result.Framed := False;
  Result.LegendPosition := LegendNone;
  Result.YAxis.SetRange(0, 20);
  Series := Result.AddSeries('bars', SeriesBar);
  Series.AddCategoryValue('A', 10);
  Series.AddCategoryValue('B', 20);
end;

procedure TestBars;
var
  Model: TChartModel;
  Drawn: TDrawnChart;
  Short: TRectangle;
  Tall: TRectangle;
  Color: TColor;
  Middle: LongInt;
  Row: LongInt;
  Hit: TChartHit;
begin
  Model := NewBarModel;
  try
    Drawn := DrawChart(Model, 200, 150, 100);
    Color := ChartPaletteColor(0, White);
    Short := BarRectangle(Model, Drawn.Layout, Drawn.Style, 0, 0);
    Tall := BarRectangle(Model, Drawn.Layout, Drawn.Style, 0, 1);
    Check('bars have room', (RectangleWidth(Drawn.Layout.Plot) > 100) and (RectangleHeight(Drawn.Layout.Plot) > 100));
    CheckNumber('the tallest bar reaches the top', Tall.Top, Drawn.Layout.Plot.Top);
    CheckNumber('bars stand on the bottom', Short.Bottom, Drawn.Layout.Plot.Bottom);
    Middle := (Drawn.Layout.Plot.Top + Drawn.Layout.Plot.Bottom + 1) div 2;
    Check('half the value is half the height', Abs(Short.Top - Middle) <= 1);
    Check('a bar is three quarters of its category',
      Abs(RectangleWidth(Short) - RectangleWidth(Drawn.Layout.Plot) * 3 / 8) <= 1.5);
    CheckColor('inside the bar', PixelAt(Drawn, (Short.Left + Short.Right) / 2, Short.Top + 3), Color);
    CheckColor('the bar ends at its top', PixelAt(Drawn, (Short.Left + Short.Right) / 2, Short.Top - 2), White);
    CheckColor('first column of the bar', PixelAt(Drawn, Short.Left, Short.Top + 3), Color);
    CheckColor('left of the bar', PixelAt(Drawn, Short.Left - 1, Short.Top + 3), White);
    CheckColor('the value axis line', PixelAt(Drawn, Drawn.Layout.Plot.Left, Drawn.Layout.Plot.Top + 3),
      Drawn.Style.AxisLine);
    CheckColor('the X axis line', PixelAt(Drawn, Short.Left + 2, Drawn.Layout.Plot.Bottom - 1), Drawn.Style.AxisLine);
    { The ticks are 0, 5, 10, 15, 20: a grid line at 5 between the bars. }
    Row := Round(ValuePixel(Drawn.Layout, 5));
    CheckColor('a grid line between the bars', PixelAt(Drawn, Drawn.Layout.Plot.Left + 3, Row), Drawn.Style.Grid);
    CheckColor('the bar covers the grid', PixelAt(Drawn, (Short.Left + Short.Right) / 2, Row), Color);
    Hit := HitTestChart(Model, Drawn.Layout, Drawn.Style, (Tall.Left + Tall.Right) div 2, Tall.Top + 5);
    Check('the pointer over a bar finds it', (Hit.Kind = HitBar) and (Hit.SeriesIndex = 0) and (Hit.PointIndex = 1));
    Hit := HitTestChart(Model, Drawn.Layout, Drawn.Style, (Short.Left + Short.Right) div 2, Short.Top - 5);
    Check('above a bar is no bar', Hit.Kind <> HitBar);
    FreeSurface(Drawn.Surface);
    Drawn := DrawChart(Model, 200, 150, 200);
    CheckColor('a thick axis at 200%', PixelAt(Drawn, Drawn.Layout.Plot.Left + 1, Drawn.Layout.Plot.Top + 6),
      Drawn.Style.AxisLine);
    Check('two pixels thick, no more', PixelAt(Drawn, Drawn.Layout.Plot.Left + 2, Drawn.Layout.Plot.Top + 6) <>
      Drawn.Style.AxisLine);
    FreeSurface(Drawn.Surface);
  finally
    Model.Free;
  end;
end;

procedure TestStackedHorizontalBars;
var
  Model: TChartModel;
  Drawn: TDrawnChart;
  Lower: TRectangle;
  Upper: TRectangle;
  Halfway: Double;
begin
  Model := TChartModel.Create;
  try
    Model.Framed := False;
    Model.LegendPosition := LegendNone;
    Model.Horizontal := True;
    Model.YAxis.SetRange(0, 10);
    Model.AddSeries('a', SeriesBar).Stacked := True;
    Model.AddSeries('b', SeriesBar).Stacked := True;
    Model[0].AddCategoryValue('Only', 5);
    Model[1].AddCategoryValue('Only', 5);
    Drawn := DrawChart(Model, 200, 120, 100);
    Lower := BarRectangle(Model, Drawn.Layout, Drawn.Style, 0, 0);
    Upper := BarRectangle(Model, Drawn.Layout, Drawn.Style, 1, 0);
    CheckNumber('a lying bar starts at the left', Lower.Left, Drawn.Layout.Plot.Left);
    CheckNumber('stacked bars meet', Upper.Left, Lower.Right);
    CheckNumber('the stack reaches the right', Upper.Right, Drawn.Layout.Plot.Right);
    CheckNumber('stacked bars share a row', Upper.Top, Lower.Top);
    Halfway := (Lower.Top + Lower.Bottom) / 2;
    CheckColor('the lower part', PixelAt(Drawn, Lower.Left + 3, Halfway), ChartPaletteColor(0, White));
    CheckColor('the upper part', PixelAt(Drawn, Upper.Right - 3, Halfway), ChartPaletteColor(1, White));
    FreeSurface(Drawn.Surface);
  finally
    Model.Free;
  end;
end;

function NewPieModel: TChartModel;
var
  Series: TChartSeries;
begin
  Result := TChartModel.Create;
  Result.Framed := False;
  Result.LegendPosition := LegendNone;
  Result.PieLabels := PieLabelsNone;
  Series := Result.AddSeries('pie', SeriesPie);
  Series.AddCategoryValue('a', 1);
  Series.AddCategoryValue('b', 1);
  Series.AddCategoryValue('c', 2);
end;

function PiePixel(const Drawn: TDrawnChart; Angle, Distance: Double): TColor;
var
  Point: TPrecisePoint;
begin
  Point := PointOnCircle(Drawn.Layout.PieCentreX, Drawn.Layout.PieCentreY, Distance, Angle);
  Result := PixelAt(Drawn, Point.X, Point.Y);
end;

procedure TestPie;
var
  Model: TChartModel;
  Drawn: TDrawnChart;
  Radius: Double;
  Hit: TChartHit;
  Point: TPrecisePoint;
begin
  Model := NewPieModel;
  try
    Drawn := DrawChart(Model, 200, 200, 100);
    Radius := Drawn.Layout.PieRadius;
    Check('the pie fills its room', Radius > 80);
    CheckColor('slice a at 45 degrees', PiePixel(Drawn, 45, Radius / 2), ChartPaletteColor(0, White));
    CheckColor('slice b at 135 degrees', PiePixel(Drawn, 135, Radius / 2), ChartPaletteColor(1, White));
    CheckColor('slice c at 270 degrees', PiePixel(Drawn, 270, Radius / 2), ChartPaletteColor(2, White));
    CheckColor('slice c near its edge', PiePixel(Drawn, 200, Radius - 3), ChartPaletteColor(2, White));
    CheckColor('outside the pie', PiePixel(Drawn, 45, Radius + 3), White);
    Point := PointOnCircle(Drawn.Layout.PieCentreX, Drawn.Layout.PieCentreY, Radius / 2, 135);
    Hit := HitTestChart(Model, Drawn.Layout, Drawn.Style, Trunc(Point.X), Trunc(Point.Y));
    Check('the pointer over slice b finds it', (Hit.Kind = HitSlice) and (Hit.PointIndex = 1));
    FreeSurface(Drawn.Surface);
    Model[0].ExplodedIndex := 2;
    Drawn := DrawChart(Model, 200, 200, 100);
    { Slice c moved left: just left of the centre is no slice now. }
    CheckColor('the exploded slice leaves a gap', PiePixel(Drawn, 270, 3), White);
    CheckColor('the exploded slice is out', PiePixel(Drawn, 270, Drawn.Layout.PieRadius + 4),
      ChartPaletteColor(2, White));
    FreeSurface(Drawn.Surface);
    Model[0].ExplodedIndex := -1;
    Model[0].HoleRatio := 0.5;
    Drawn := DrawChart(Model, 200, 200, 100);
    CheckColor('a doughnut has a hole', PiePixel(Drawn, 0, 0), White);
    CheckColor('a doughnut ring', PiePixel(Drawn, 45, Drawn.Layout.PieRadius * 0.75), ChartPaletteColor(0, White));
    Hit := HitTestChart(Model, Drawn.Layout, Drawn.Style, Round(Drawn.Layout.PieCentreX),
      Round(Drawn.Layout.PieCentreY));
    Check('the hole is no slice', Hit.Kind = HitNothing);
    FreeSurface(Drawn.Surface);
  finally
    Model.Free;
  end;
end;

function NewLineModel(Kind: TChartSeriesKind): TChartModel;
var
  Series: TChartSeries;
  X: LongInt;
begin
  Result := TChartModel.Create;
  Result.Framed := False;
  Result.LegendPosition := LegendNone;
  Result.XAxis.Visible := False;
  Result.XAxis.ShowGrid := False;
  Result.YAxis.Visible := False;
  Result.YAxis.ShowGrid := False;
  Result.YAxis.SetRange(0, 10);
  Series := Result.AddSeries('line', Kind);
  for X := 0 to 10 do
    Series.AddPoint(X, 5);
end;

procedure TestLines;
var
  Model: TChartModel;
  Drawn: TDrawnChart;
  Color: TColor;
  Hit: TChartHit;
begin
  Model := NewLineModel(SeriesLine);
  try
    Drawn := DrawChart(Model, 101, 101, 100);
    Color := ChartPaletteColor(0, White);
    CheckNumber('nothing outside the plot: it fills the chart', RectangleWidth(Drawn.Layout.Plot), 101);
    CheckNear('5 of 0 to 10 is the middle row', ValuePixel(Drawn.Layout, 5), 50);
    CheckColor('the line on its row', PixelAt(Drawn, 50, 50), Color);
    CheckColor('clear below the line', PixelAt(Drawn, 50, 52), White);
    CheckColor('clear above the line', PixelAt(Drawn, 50, 48), White);
    Hit := HitTestChart(Model, Drawn.Layout, Drawn.Style, 31, 20);
    Check('the pointer finds the nearest point', (Hit.Kind = HitPoint) and (Hit.PointIndex = 3));
    CheckNear('the crosshair stands at its X', Hit.X, 3);
    FreeSurface(Drawn.Surface);
  finally
    Model.Free;
  end;
  Model := NewLineModel(SeriesArea);
  try
    Drawn := DrawChart(Model, 101, 101, 100);
    Color := ChartPaletteColor(0, White);
    CheckColor('an area is filled lightly', PixelAt(Drawn, 50, 80), BlendColors(White, WithAlpha(Color, 56)));
    CheckColor('nothing over the area', PixelAt(Drawn, 50, 20), White);
    CheckColor('the area has its line', PixelAt(Drawn, 50, 50), Color);
    FreeSurface(Drawn.Surface);
  finally
    Model.Free;
  end;
end;

procedure TestLegendAndFrame;
var
  Model: TChartModel;
  Drawn: TDrawnChart;
  Item: TRectangle;
  Hit: TChartHit;
begin
  Model := NewBarModel;
  try
    Model.AddSeries('more', SeriesBar).AddCategoryValue('A', 4);
    Model.LegendPosition := LegendRight;
    Model.Framed := True;
    Drawn := DrawChart(Model, 240, 150, 100);
    CheckNumber('a legend entry for each series', Length(Drawn.Layout.Legend), 2);
    Item := Drawn.Layout.Legend[1].Box;
    Check('the legend is right of the plot', Item.Left >= Drawn.Layout.Plot.Right);
    CheckColor('the legend swatch', PixelAt(Drawn, Item.Left + 2, (Item.Top + Item.Bottom) div 2),
      ChartPaletteColor(1, White));
    Hit := HitTestChart(Model, Drawn.Layout, Drawn.Style, Item.Left + 2, (Item.Top + Item.Bottom) div 2);
    Check('the pointer over a legend entry finds it', (Hit.Kind = HitLegend) and (Hit.LegendIndex = 1) and
      (Hit.SeriesIndex = 1));
    CheckColor('the frame''s outer shadow', PixelAt(Drawn, 5, 0), Drawn.Style.Frame.OuterLight);
    FreeSurface(Drawn.Surface);
    Model[1].Visible := False;
    Drawn := DrawChart(Model, 240, 150, 100);
    Item := Drawn.Layout.Legend[1].Box;
    CheckColor('a hidden series'' swatch is hollow', PixelAt(Drawn, Item.Left + 4, (Item.Top + Item.Bottom) div 2),
      White);
    FreeSurface(Drawn.Surface);
  finally
    Model.Free;
  end;
end;

procedure TestChartRendering;
begin
  TestBars;
  TestStackedHorizontalBars;
  TestPie;
  TestLines;
  TestLegendAndFrame;
end;

end.
