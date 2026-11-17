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
  What is under a point of a chart (its own pixels), from the layout it
  was last drawn with: a legend entry, a pie's slice, a bar, or - over
  the plot of lines and areas - the points nearest the pointer's X (the
  crosshair snaps to them). The chart control asks on every move of the
  pointer and repaints only when the answer changes.
}
unit Controls.ChartHitTesting;

{$mode objfpc}
{$H+}

interface

uses
  Controls.ChartModel,
  Controls.ChartStyle,
  Controls.ChartLayout;

type
  TChartHitKind = (HitNothing, HitLegend, HitSlice, HitBar, HitPoint);

  TChartHit = record
    Kind: TChartHitKind;
    SeriesIndex: LongInt;
    PointIndex: LongInt;
    LegendIndex: LongInt;
    { For HitPoint: the X the crosshair stands at. }
    X: Double;
  end;

function NoChartHit: TChartHit;
function HitTestChart(Model: TChartModel; const Layout: TChartLayout; const Style: TChartStyle;
  X, Y: LongInt): TChartHit;
function ChartHitsEqual(const First, Second: TChartHit): Boolean;

implementation

uses
  Drawing.Rectangles,
  Controls.ChartSeries,
  Controls.ChartValues,
  Controls.ChartLegend,
  Controls.ChartPiePainting;

function NoChartHit: TChartHit;
begin
  Result.Kind := HitNothing;
  Result.SeriesIndex := -1;
  Result.PointIndex := -1;
  Result.LegendIndex := -1;
  Result.X := 0;
end;

function ChartHitsEqual(const First, Second: TChartHit): Boolean;
begin
  Result := (First.Kind = Second.Kind) and (First.SeriesIndex = Second.SeriesIndex) and
    (First.PointIndex = Second.PointIndex) and (First.LegendIndex = Second.LegendIndex) and (First.X = Second.X);
end;

function HitSliceAt(Model: TChartModel; const Layout: TChartLayout; X, Y: LongInt; var Hit: TChartHit): Boolean;
var
  Index: LongInt;
  CentreX: Double;
  CentreY: Double;
  PointX: Double;
  PointY: Double;
  Distance: Double;
  Angle: Double;
  Slice: TPieSlice;
begin
  { Pixel (X, Y)'s centre, in the rasterizer's coordinates. }
  PointX := X + 0.5;
  PointY := Y + 0.5;
  for Index := 0 to High(Layout.Slices) do
  begin
    SliceCentre(Model, Layout, Index, CentreX, CentreY);
    Distance := Sqrt(Sqr(PointX - CentreX) + Sqr(PointY - CentreY));
    if (Distance > Layout.PieRadius) or (Distance < Layout.PieInnerRadius) then
      Continue;
    Angle := AngleFromCentre(CentreX, CentreY, PointX, PointY);
    Slice := Layout.Slices[Index];
    if (Angle >= Slice.StartAngle) and (Angle < Slice.StartAngle + Slice.SweepAngle) then
    begin
      Hit.Kind := HitSlice;
      Hit.SeriesIndex := Layout.PieSeries;
      Hit.PointIndex := Slice.PointIndex;
      Exit(True);
    end;
  end;
  Result := False;
end;

function HitBarAt(Model: TChartModel; const Layout: TChartLayout; const Style: TChartStyle; X, Y: LongInt;
  var Hit: TChartHit): Boolean;
var
  SeriesIndex: LongInt;
  Point: LongInt;
  Series: TChartSeries;
begin
  for SeriesIndex := Model.SeriesCount - 1 downto 0 do
  begin
    Series := Model[SeriesIndex];
    if not Series.Visible or (Series.Kind <> SeriesBar) then
      Continue;
    for Point := 0 to Series.Count - 1 do
      if RectangleContainsPoint(BarRectangle(Model, Layout, Style, SeriesIndex, Point), X, Y) then
      begin
        Hit.Kind := HitBar;
        Hit.SeriesIndex := SeriesIndex;
        Hit.PointIndex := Point;
        Exit(True);
      end;
  end;
  Result := False;
end;

function HitPointAt(Model: TChartModel; const Layout: TChartLayout; X, Y: LongInt; var Hit: TChartHit): Boolean;
var
  SeriesIndex: LongInt;
  Series: TChartSeries;
  Position: Double;
  Point: LongInt;
begin
  Position := PositionAt(Layout, X, Y);
  for SeriesIndex := 0 to Model.SeriesCount - 1 do
  begin
    Series := Model[SeriesIndex];
    if not Series.Visible or not (Series.Kind in [SeriesLine, SeriesArea]) or (Series.Count = 0) then
      Continue;
    Point := Series.NearestIndex(Position);
    Hit.Kind := HitPoint;
    Hit.SeriesIndex := SeriesIndex;
    Hit.PointIndex := Point;
    Hit.X := Series.X[Point];
    Exit(True);
  end;
  Result := False;
end;

function HitTestChart(Model: TChartModel; const Layout: TChartLayout; const Style: TChartStyle;
  X, Y: LongInt): TChartHit;
var
  LegendIndex: LongInt;
begin
  Result := NoChartHit;
  LegendIndex := LegendItemAt(Layout.Legend, X, Y);
  if LegendIndex >= 0 then
  begin
    Result.Kind := HitLegend;
    Result.LegendIndex := LegendIndex;
    Result.SeriesIndex := Layout.Legend[LegendIndex].SeriesIndex;
    Result.PointIndex := Layout.Legend[LegendIndex].PointIndex;
    Exit;
  end;
  if Layout.IsPie then
  begin
    HitSliceAt(Model, Layout, X, Y, Result);
    Exit;
  end;
  if not RectangleContainsPoint(Layout.Plot, X, Y) then
    Exit;
  if HitBarAt(Model, Layout, Style, X, Y, Result) then
    Exit;
  HitPointAt(Model, Layout, X, Y, Result);
end;

end.
