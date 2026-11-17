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
  The chart's plain logic: nice ticks and ranges, the formats of values,
  series that slide, stacking, bars' places, pie angles, axes' windows
  and the model's change notices.
}
unit ChartTest.Logic;

{$mode objfpc}
{$H+}

interface

procedure TestChartLogic;

implementation

uses
  SysUtils,
  Controls.ChartScale,
  Controls.ChartFormat,
  Controls.ChartSeries,
  Controls.ChartAxes,
  Controls.ChartModel,
  Controls.ChartValues,
  Controls.ChartPalette,
  ChartTest.Checks;

const
  Mebibyte = 1024.0 * 1024;
  Gibibyte = 1024.0 * Mebibyte;

procedure TestNiceSteps;
begin
  CheckNear('nice step 0.7', NiceStep(0.7), 1);
  CheckNear('nice step 1', NiceStep(1), 1);
  CheckNear('nice step 1.2', NiceStep(1.2), 2);
  CheckNear('nice step 2.5', NiceStep(2.5), 5);
  CheckNear('nice step 7', NiceStep(7), 10);
  CheckNear('nice step 0.03', NiceStep(0.03), 0.05);
  CheckNear('nice step 120', NiceStep(120), 200);
  CheckNear('nice step 20000', NiceStep(20000), 20000);
  CheckNear('binary step 300 B', BinaryNiceStep(300), 500);
  CheckNear('binary step 300 MiB', BinaryNiceStep(300 * Mebibyte), 500 * Mebibyte);
  CheckNear('binary step 700 MiB is 1 GiB', BinaryNiceStep(700 * Mebibyte), Gibibyte);
  CheckNear('binary step 3 KiB', BinaryNiceStep(3 * 1024), 5 * 1024);
  CheckNear('time step 40 s', TimeNiceStep(40), 60);
  CheckNear('time step 4 min', TimeNiceStep(240), 300);
  CheckNear('time step 2.5 h', TimeNiceStep(9000), 10800);
  CheckNear('time step 3 days', TimeNiceStep(3 * 86400), 5 * 86400);
  CheckNear('time step 0.3 s', TimeNiceStep(0.3), 0.5);
  CheckNear('step for 100 in 4', StepFor(100, 4, TickBaseDecimal), 50);
  CheckNear('step for 100 in 5', StepFor(100, 5, TickBaseDecimal), 20);
  CheckNumber('decimals for 0.25', DecimalsForStep(0.25), 2);
  CheckNumber('decimals for 5', DecimalsForStep(5), 0);
  CheckNumber('decimals for 0.1', DecimalsForStep(0.1), 1);
  CheckNumber('decimals for 2.5', DecimalsForStep(2.5), 1);
end;

procedure TestRanges;
var
  Range: TAxisRange;
begin
  Range := AutoRange(3, 97, 5, True, TickBaseDecimal);
  CheckNear('auto 3..97 from', Range.Minimum, 0);
  CheckNear('auto 3..97 to', Range.Maximum, 100);
  CheckNear('auto 3..97 step', Range.Step, 20);
  CheckNumber('auto 3..97 ticks', TickCount(Range), 6);
  CheckNear('auto 3..97 third tick', TickAt(Range, 2), 40);
  Range := AutoRange(12, 18, 5, False, TickBaseDecimal);
  CheckNear('auto 12..18 without zero from', Range.Minimum, 12);
  CheckNear('auto 12..18 to', Range.Maximum, 18);
  CheckNear('auto 12..18 step', Range.Step, 2);
  Range := AutoRange(-3, 7, 5, True, TickBaseDecimal);
  Check('auto -3..7 holds the data', (Range.Minimum <= -3) and (Range.Maximum >= 7));
  Check('auto -3..7 within the ticks asked', (Range.Maximum - Range.Minimum) / Range.Step <= 5 + 1E-9);
  CheckNear('auto -3..7 zero is a tick', Frac(Range.Minimum / Range.Step), 0);
  Range := AutoRange(5, 5, 5, False, TickBaseDecimal);
  Check('auto of one value is around it', (Range.Minimum < 5) and (Range.Maximum > 5));
  Range := AutoRange(0, 0, 5, True, TickBaseDecimal);
  CheckNear('auto of nothing is 0..1', Range.Maximum, 1);
  Range := AutoRange(0, 900 * Mebibyte, 4, True, TickBaseBinary);
  CheckNear('auto bytes step', Range.Step, 500 * Mebibyte);
  CheckNear('auto bytes to', Range.Maximum, 1000 * Mebibyte);
  Range := FixedRange(0, 100, 4, TickBaseDecimal);
  CheckNear('fixed 0..100 keeps its ends', Range.Maximum, 100);
  CheckNear('fixed 0..100 step', Range.Step, 50);
  Range := MakeRange(0.05, 0.95, 0.1);
  CheckNumber('ticks of 0.05..0.95 by 0.1', TickCount(Range), 9);
  CheckNear('first tick of 0.05..0.95', TickAt(Range, 0), 0.1);
  Range := MakeRange(65, 95, 10);
  Range.Origin := 95;
  CheckNumber('ticks counted from the end', TickCount(Range), 4);
  CheckNear('first tick counted from the end', TickAt(Range, 0), 65);
  Range := MakeRange(-1, 1, 0.5);
  CheckText('zero tick is plain 0', FormatChartNumber(TickAt(Range, 2), Range.Step), '0.0');
  CheckNear('map to pixels', MapToPixels(25, 0, 100, 100, 0), 75);
  CheckNear('map from pixels', MapFromPixels(75, 0, 100, 100, 0), 25);
end;

procedure TestFormats;
begin
  CheckText('number by a step of 0.5', FormatChartNumber(2.5, 0.5), '2.5');
  CheckText('whole number by a step of 0.5', FormatChartNumber(2, 0.5), '2.0');
  CheckText('number by a step of 1', FormatChartNumber(3, 1), '3');
  CheckText('number alone', FormatChartNumber(0.1 + 0.2, 0), '0.3');
  CheckText('negative zero', FormatChartNumber(-0.0001, 1), '0');
  CheckText('percent', FormatChartPercent(25, 25), '25%');
  CheckText('bytes 0', FormatChartBytes(0, 0), '0 B');
  CheckText('bytes 512', FormatChartBytes(512, 0), '512 B');
  CheckText('bytes 1536', FormatChartBytes(1536, 0), '1.5 KiB');
  CheckText('bytes 256 MiB by 128 MiB', FormatChartBytes(256 * Mebibyte, 128 * Mebibyte), '256 MiB');
  CheckText('bytes 1.5 GiB by 512 MiB', FormatChartBytes(1.5 * Gibibyte, 512 * Mebibyte), '1.5 GiB');
  CheckText('bytes 1 GiB by 512 MiB', FormatChartBytes(Gibibyte, 512 * Mebibyte), '1 GiB');
  CheckText('duration 45', FormatChartDuration(45, 15), '45 s');
  CheckText('duration 120', FormatChartDuration(120, 60), '2 min');
  CheckText('duration 90', FormatChartDuration(90, 30), '1 min 30 s');
  CheckText('duration 7200', FormatChartDuration(7200, 3600), '2 h');
  CheckText('duration 2.5', FormatChartDuration(2.5, 0.5), '2.5 s');
  CheckText('share a quarter', FormatShare(0.25), '25%');
  CheckText('share small', FormatShare(0.025), '2.5%');
  CheckText('share nothing', FormatShare(0), '0%');
  CheckText('value format bytes', FormatChartValue(ChartFormatBytes, 2048, 1024), '2 KiB');
end;

procedure TestSeries;
var
  Series: TChartSeries;
  Index: LongInt;
begin
  Series := TChartSeries.Create('s', SeriesLine);
  try
    Series.MaxPoints := 3;
    for Index := 0 to 4 do
      Series.AddPoint(Index, Index * 10);
    CheckNumber('sliding series keeps MaxPoints', Series.Count, 3);
    CheckNear('sliding series oldest X', Series.X[0], 2);
    CheckNear('sliding series newest Y', Series.Y[2], 40);
    Series.AddValue(99);
    CheckNear('add value goes on from the last X', Series.LastX, 5);
    Series.MaxPoints := 60;
    for Index := 6 to 1005 do
      Series.AddPoint(Index, Index);
    CheckNumber('long run keeps 60', Series.Count, 60);
    CheckNear('long run oldest X', Series.X[0], 946);
    CheckNear('long run newest X', Series.X[59], 1005);
    CheckNumber('nearest index of 950.4', Series.NearestIndex(950.4), 4);
    CheckNumber('nearest index before the start', Series.NearestIndex(-5), 0);
    CheckNumber('nearest index past the end', Series.NearestIndex(5000), 59);
    Series.Clear;
    Series.AddCategoryValue('A', 1);
    Series.AddCategoryValue('B', 2);
    CheckNear('category X follows', Series.X[1], 1);
    CheckText('category text', Series.Points[1].Text, 'B');
  finally
    Series.Free;
  end;
end;

procedure TestStacking;
var
  Model: TChartModel;
  First: TChartSeries;
  Second: TChartSeries;
  Third: TChartSeries;
  Base: Double;
  Top: Double;
  Extents: TValueExtents;
begin
  Model := TChartModel.Create;
  try
    First := Model.AddSeries('a', SeriesArea);
    Second := Model.AddSeries('b', SeriesArea);
    Third := Model.AddSeries('c', SeriesArea);
    First.Stacked := True;
    Second.Stacked := True;
    Third.Stacked := True;
    First.AddPoint(0, 1);
    First.AddPoint(1, 2);
    Second.AddPoint(0, 3);
    Second.AddPoint(1, -4);
    Third.AddPoint(0, 5);
    Third.AddPoint(1, 6);
    StackedPoint(Model, 2, 0, Base, Top);
    CheckNear('third stacked base', Base, 4);
    CheckNear('third stacked top', Top, 9);
    StackedPoint(Model, 1, 1, Base, Top);
    CheckNear('negative stacks down from 0', Base, 0);
    CheckNear('negative stack top', Top, -4);
    StackedPoint(Model, 2, 1, Base, Top);
    CheckNear('positive skips the negative', Base, 2);
    Second.Visible := False;
    StackedPoint(Model, 2, 0, Base, Top);
    CheckNear('hidden series leaves the stack', Base, 1);
    Second.Visible := True;
    Extents := ValueExtents(Model);
    CheckNear('stacked extents top', Extents.YMaximum, 9);
    CheckNear('stacked extents bottom', Extents.YMinimum, -4);
    CheckNear('stacked extents X', Extents.XMaximum, 1);
    Third.Stacked := False;
    StackedPoint(Model, 2, 0, Base, Top);
    CheckNear('unstacked stands on 0', Base, 0);
  finally
    Model.Free;
  end;
end;

procedure TestBars;
var
  Model: TChartModel;
  Index: LongInt;
begin
  Model := TChartModel.Create;
  try
    Model.AddSeries('a', SeriesBar);
    Model.AddSeries('b', SeriesBar).Stacked := True;
    Model.AddSeries('c', SeriesLine);
    Model.AddSeries('d', SeriesBar).Stacked := True;
    Model.AddSeries('e', SeriesBar);
    for Index := 0 to Model.SeriesCount - 1 do
      Model[Index].AddCategoryValue('Q1', Index + 1);
    CheckNumber('bar places', BarPlaceCount(Model), 3);
    CheckNumber('first bar place', BarPlaceOf(Model, 0), 0);
    CheckNumber('stacked bars share a place', BarPlaceOf(Model, 1), 1);
    CheckNumber('stacked bars share a place again', BarPlaceOf(Model, 3), 1);
    CheckNumber('a line has no bar place', BarPlaceOf(Model, 2), -1);
    CheckNumber('last bar place', BarPlaceOf(Model, 4), 2);
    Check('bars make categories', IsCategorical(Model));
    CheckText('category at 0', CategoryAt(Model, 0), 'Q1');
    Model[0].Visible := False;
    CheckNumber('hidden bars give up their place', BarPlaceOf(Model, 4), 1);
  finally
    Model.Free;
  end;
end;

procedure TestPies;
var
  Series: TChartSeries;
  Slices: TPieSlices;
begin
  Series := TChartSeries.Create('pie', SeriesPie);
  try
    Series.AddCategoryValue('a', 1);
    Series.AddCategoryValue('b', 1);
    Series.AddCategoryValue('c', 2);
    Series.AddCategoryValue('negative', -5);
    Slices := PieSlicesOf(Series);
    CheckNumber('slices (negative left out)', Length(Slices), 3);
    CheckNear('first slice start', Slices[0].StartAngle, 0);
    CheckNear('first slice sweep', Slices[0].SweepAngle, 90);
    CheckNear('second slice start', Slices[1].StartAngle, 90);
    CheckNear('third slice sweep', Slices[2].SweepAngle, 180);
    CheckNear('third slice share', Slices[2].Share, 0.5);
    CheckNumber('slice at 45', SliceAtAngle(Slices, 45), 0);
    CheckNumber('slice at 135', SliceAtAngle(Slices, 135), 1);
    CheckNumber('slice at 359.9', SliceAtAngle(Slices, 359.9), 2);
    Series.Hidden[2] := True;
    Slices := PieSlicesOf(Series);
    CheckNumber('hidden slice left out', Length(Slices), 2);
    CheckNear('the rest share the pie', Slices[1].SweepAngle, 180);
  finally
    Series.Free;
  end;
  CheckNear('angle up', AngleFromCentre(10, 10, 10, 0), 0);
  CheckNear('angle right', AngleFromCentre(10, 10, 20, 10), 90);
  CheckNear('angle down', AngleFromCentre(10, 10, 10, 20), 180);
  CheckNear('angle left', AngleFromCentre(10, 10, 0, 10), 270);
end;

procedure TestAxes;
var
  Axis: TChartAxis;
  Range: TAxisRange;
begin
  Axis := TChartAxis.Create;
  try
    Axis.Window := 30;
    Axis.Step := 10;
    Axis.CountsBack := True;
    Axis.Format := ChartFormatDuration;
    Range := Axis.ResolveRange(0, 95, 5);
    CheckNear('window from', Range.Minimum, 65);
    CheckNear('window to', Range.Maximum, 95);
    CheckNear('window ticks from the newest', TickAt(Range, 0), 65);
    CheckText('counted back label of the oldest', Axis.TickLabel(Range, 65), '30 s');
    CheckText('counted back label of the newest', Axis.TickLabel(Range, 95), '0 s');
    Axis.Window := 0;
    Axis.Step := 0;
    Axis.CountsBack := False;
    Axis.SetRange(0, 100);
    Range := Axis.ResolveRange(3, 300, 4);
    CheckNear('fixed range ignores the data', Range.Maximum, 100);
    Axis.Step := 25;
    Range := Axis.ResolveRange(3, 300, 10);
    CheckNear('fixed step', Range.Step, 25);
    Axis.AutoRange := True;
    Axis.Step := 0;
    Axis.Format := ChartFormatPercent;
    Range := Axis.ResolveRange(0, 37, 4);
    CheckNear('automatic range', Range.Maximum, 40);
    CheckText('percent label', Axis.TickLabel(Range, 20), '20%');
    Range := Axis.ResolvePositionRange(3, 97, 5);
    CheckNear('an X range runs from the first value', Range.Minimum, 3);
    CheckNear('an X range runs to the last value', Range.Maximum, 97);
    CheckNear('an X range has nice ticks', TickAt(Range, 0), 20);
  finally
    Axis.Free;
  end;
end;

type
  TChangeCounter = class
    Count: LongInt;
    procedure Changed(Sender: TObject);
  end;

procedure TChangeCounter.Changed(Sender: TObject);
begin
  Inc(Count);
end;

procedure TestModelChanges;
var
  Model: TChartModel;
  Counter: TChangeCounter;
  Series: TChartSeries;
begin
  Model := TChartModel.Create;
  Counter := TChangeCounter.Create;
  try
    Model.OnChange := @Counter.Changed;
    Series := Model.AddSeries('s', SeriesLine);
    Series.AddPoint(0, 1);
    Model.YAxis.Title := 'Y';
    CheckNumber('every change is told', Counter.Count, 3);
    Counter.Count := 0;
    Model.BeginUpdate;
    Series.AddPoint(1, 2);
    Series.AddPoint(2, 3);
    Model.Title := 'T';
    Model.EndUpdate;
    CheckNumber('a batch is told once', Counter.Count, 1);
  finally
    Model.Free;
    Counter.Free;
  end;
end;

procedure TestPalette;
begin
  Check('palette colours differ', ChartPaletteColor(0, $FFFFFFFF) <> ChartPaletteColor(1, $FFFFFFFF));
  CheckColor('palette goes round', ChartPaletteColor(ChartPaletteSize, $FFFFFFFF), ChartPaletteColor(0, $FFFFFFFF));
  Check('lighter on a dark background',
    ColorBrightness(ChartPaletteColor(0, $FF202020)) > ColorBrightness(ChartPaletteColor(0, $FFFFFFFF)));
  CheckColor('white text on dark blue', ContrastingTextColor($FF17375E), $FFFFFFFF);
  CheckColor('black text on gold', ContrastingTextColor($FFF0D060), $FF000000);
end;

procedure TestChartLogic;
begin
  TestNiceSteps;
  TestRanges;
  TestFormats;
  TestSeries;
  TestStacking;
  TestBars;
  TestPies;
  TestAxes;
  TestModelChanges;
  TestPalette;
end;

end.
