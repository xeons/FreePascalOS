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
  What a chart's numbers come to before anything is drawn: where each
  stacked point stands, how far the values reach, how bars share a
  category, and the angles of a pie's slices.

  Stacking: a stacked series stands on the stacked series of the same
  kind shown before it, point by point (positive and negative values
  stack apart, upwards and downwards from 0). Bars: every shown bar
  series that is not stacked has a place of its own in a category; the
  stacked ones share one place. A pie's slices start at the top and go
  clockwise, each as wide as its share of the total of the slices shown
  (negative values count as none).

  Plain arithmetic over the model, checked on the host (tools/ChartTest).
}
unit Controls.ChartValues;

{$mode objfpc}
{$H+}

interface

uses
  Controls.ChartSeries,
  Controls.ChartModel;

type
  TValueExtents = record
    XMinimum: Double;
    XMaximum: Double;
    YMinimum: Double;
    YMaximum: Double;
    { False when nothing is shown (the extents are then 0 to 1). }
    HasValues: Boolean;
  end;

  TPieSlice = record
    PointIndex: LongInt;
    { Degrees, 0 at the top, clockwise. }
    StartAngle: Double;
    SweepAngle: Double;
    { Of the total, 0 to 1. }
    Share: Double;
  end;
  TPieSlices = array of TPieSlice;

{ Where point PointIndex of series SeriesIndex starts and ends, stacked
  on the series before it (Base is 0 for a series not stacked). }
procedure StackedPoint(Model: TChartModel; SeriesIndex, PointIndex: LongInt; out Base, Top: Double);
function SeriesShown(Model: TChartModel; SeriesIndex: LongInt): Boolean;
{ The index of the first pie series shown, -1 if none (an XY chart). }
function ShownPieSeries(Model: TChartModel): LongInt;
function HasShownKind(Model: TChartModel; Kind: TChartSeriesKind): Boolean;
{ Whether every point of the series shown has a category name (an axis
  of names, not numbers); bars always have categories. }
function IsCategorical(Model: TChartModel): Boolean;
{ How far the shown series reach, stacks included. }
function ValueExtents(Model: TChartModel): TValueExtents;
{ How many places a category has for bars, and which one a series takes
  (-1 for a series that is not a shown bar series). }
function BarPlaceCount(Model: TChartModel): LongInt;
function BarPlaceOf(Model: TChartModel; SeriesIndex: LongInt): LongInt;
{ The category name at X, from the first shown series with a point
  there that has one; '' if none. }
function CategoryAt(Model: TChartModel; X: Double): string;
function PieTotal(Series: TChartSeries): Double;
{ The slices shown, in order. }
function PieSlicesOf(Series: TChartSeries): TPieSlices;
{ The angle (degrees, 0 at the top, clockwise) of (X, Y) seen from
  (CentreX, CentreY), with Y growing down. }
function AngleFromCentre(CentreX, CentreY, X, Y: Double): Double;
{ The slice whose angles hold Angle, -1 if none. }
function SliceAtAngle(const Slices: TPieSlices; Angle: Double): LongInt;

implementation

uses
  Math;

function SeriesShown(Model: TChartModel; SeriesIndex: LongInt): Boolean;
begin
  Result := Model[SeriesIndex].Visible;
end;

procedure StackedPoint(Model: TChartModel; SeriesIndex, PointIndex: LongInt; out Base, Top: Double);
var
  Series: TChartSeries;
  Other: TChartSeries;
  Index: LongInt;
  Value: Double;
  Below: Double;
  Above: Double;
begin
  Series := Model[SeriesIndex];
  Value := Series.Y[PointIndex];
  Base := 0;
  if Series.Stacked then
  begin
    Below := 0;
    Above := 0;
    for Index := 0 to SeriesIndex - 1 do
    begin
      Other := Model[Index];
      if not Other.Visible or not Other.Stacked or (Other.Kind <> Series.Kind) or (PointIndex >= Other.Count) then
        Continue;
      if Other.Y[PointIndex] >= 0 then
        Above := Above + Other.Y[PointIndex]
      else
        Below := Below + Other.Y[PointIndex];
    end;
    if Value >= 0 then
      Base := Above
    else
      Base := Below;
  end;
  Top := Base + Value;
end;

function ShownPieSeries(Model: TChartModel): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to Model.SeriesCount - 1 do
    if Model[Index].Visible and (Model[Index].Kind = SeriesPie) then
      Exit(Index);
  Result := -1;
end;

function HasShownKind(Model: TChartModel; Kind: TChartSeriesKind): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to Model.SeriesCount - 1 do
    if Model[Index].Visible and (Model[Index].Kind = Kind) then
      Exit(True);
  Result := False;
end;

function IsCategorical(Model: TChartModel): Boolean;
var
  Index: LongInt;
  Point: LongInt;
  Series: TChartSeries;
  Seen: Boolean;
begin
  if HasShownKind(Model, SeriesBar) then
    Exit(True);
  Seen := False;
  for Index := 0 to Model.SeriesCount - 1 do
  begin
    Series := Model[Index];
    if not Series.Visible then
      Continue;
    for Point := 0 to Series.Count - 1 do
    begin
      if Series.Points[Point].Text = '' then
        Exit(False);
      Seen := True;
    end;
  end;
  Result := Seen;
end;

procedure Widen(var Extents: TValueExtents; X, Y: Double);
begin
  if not Extents.HasValues then
  begin
    Extents.XMinimum := X;
    Extents.XMaximum := X;
    Extents.YMinimum := Y;
    Extents.YMaximum := Y;
    Extents.HasValues := True;
    Exit;
  end;
  Extents.XMinimum := Min(Extents.XMinimum, X);
  Extents.XMaximum := Max(Extents.XMaximum, X);
  Extents.YMinimum := Min(Extents.YMinimum, Y);
  Extents.YMaximum := Max(Extents.YMaximum, Y);
end;

function ValueExtents(Model: TChartModel): TValueExtents;
var
  Index: LongInt;
  Point: LongInt;
  Series: TChartSeries;
  Base: Double;
  Top: Double;
begin
  Result := Default(TValueExtents);
  for Index := 0 to Model.SeriesCount - 1 do
  begin
    Series := Model[Index];
    if not Series.Visible or (Series.Kind = SeriesPie) then
      Continue;
    for Point := 0 to Series.Count - 1 do
    begin
      StackedPoint(Model, Index, Point, Base, Top);
      Widen(Result, Series.X[Point], Top);
      { Stacks and bars stand on something: that is reached too. }
      if Series.Stacked or (Series.Kind = SeriesBar) then
        Widen(Result, Series.X[Point], Base);
    end;
  end;
  if not Result.HasValues then
  begin
    Result.XMaximum := 1;
    Result.YMaximum := 1;
  end;
end;

function BarPlaceCount(Model: TChartModel): LongInt;
var
  Index: LongInt;
  StackedSeen: Boolean;
begin
  Result := 0;
  StackedSeen := False;
  for Index := 0 to Model.SeriesCount - 1 do
    if Model[Index].Visible and (Model[Index].Kind = SeriesBar) then
    begin
      if not Model[Index].Stacked then
        Inc(Result)
      else if not StackedSeen then
      begin
        StackedSeen := True;
        Inc(Result);
      end;
    end;
end;

function BarPlaceOf(Model: TChartModel; SeriesIndex: LongInt): LongInt;
var
  Index: LongInt;
  StackedPlace: LongInt;
  Place: LongInt;
begin
  if not Model[SeriesIndex].Visible or (Model[SeriesIndex].Kind <> SeriesBar) then
    Exit(-1);
  Place := 0;
  StackedPlace := -1;
  for Index := 0 to SeriesIndex do
    if Model[Index].Visible and (Model[Index].Kind = SeriesBar) then
    begin
      if not Model[Index].Stacked then
      begin
        if Index = SeriesIndex then
          Exit(Place);
        Inc(Place);
      end
      else
      begin
        if StackedPlace < 0 then
        begin
          StackedPlace := Place;
          Inc(Place);
        end;
        if Index = SeriesIndex then
          Exit(StackedPlace);
      end;
    end;
  Result := -1;
end;

function CategoryAt(Model: TChartModel; X: Double): string;
var
  Index: LongInt;
  Point: LongInt;
  Series: TChartSeries;
begin
  for Index := 0 to Model.SeriesCount - 1 do
  begin
    Series := Model[Index];
    if not Series.Visible or (Series.Kind = SeriesPie) then
      Continue;
    Point := Series.NearestIndex(X);
    if (Point >= 0) and (Abs(Series.X[Point] - X) < 0.5) and (Series.Points[Point].Text <> '') then
      Exit(Series.Points[Point].Text);
  end;
  Result := '';
end;

function PieTotal(Series: TChartSeries): Double;
var
  Point: LongInt;
begin
  Result := 0;
  for Point := 0 to Series.Count - 1 do
    if not Series.Hidden[Point] and (Series.Y[Point] > 0) then
      Result := Result + Series.Y[Point];
end;

function PieSlicesOf(Series: TChartSeries): TPieSlices;
var
  Total: Double;
  Point: LongInt;
  Count: LongInt;
  Angle: Double;
begin
  Result := nil;
  Total := PieTotal(Series);
  if Total <= 0 then
    Exit;
  SetLength(Result, Series.Count);
  Count := 0;
  Angle := 0;
  for Point := 0 to Series.Count - 1 do
  begin
    if Series.Hidden[Point] or (Series.Y[Point] <= 0) then
      Continue;
    Result[Count].PointIndex := Point;
    Result[Count].Share := Series.Y[Point] / Total;
    Result[Count].StartAngle := Angle;
    Result[Count].SweepAngle := 360 * Result[Count].Share;
    Angle := Angle + Result[Count].SweepAngle;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function AngleFromCentre(CentreX, CentreY, X, Y: Double): Double;
begin
  if (X = CentreX) and (Y = CentreY) then
    Exit(0);
  { Up the screen is 0, to the right 90. }
  Result := ArcTan2(X - CentreX, CentreY - Y) * 180 / Pi;
  if Result < 0 then
    Result := Result + 360;
end;

function SliceAtAngle(const Slices: TPieSlices; Angle: Double): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Slices) do
    if (Angle >= Slices[Index].StartAngle) and (Angle < Slices[Index].StartAngle + Slices[Index].SweepAngle) then
      Exit(Index);
  { The very end of the last slice (rounding). }
  if (Length(Slices) > 0) and (Angle >= 360 - 1E-9) then
    Exit(High(Slices));
  Result := -1;
end;

end.
