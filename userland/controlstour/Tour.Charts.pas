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
  The controls tour's Charts page: one chart of each kind, two by two,
  filling the page, and a button under them that switches every chart
  to its other variant.

    a line chart that scrolls: a value every half second, the last 30
      on a time axis counted back from now (the variant: stepped, with
      markers)
    stacked areas of sizes in bytes, on an axis of KiB and MiB (the
      variant: not stacked)
    bars of three series by quarter, grouped (the variant: stacked, on
      their side)
    a pie with percentages and a slice drawn out (the variant: a
      doughnut with the slices' names and percentages beside it)

  Clicking a legend entry hides or shows its series; the page prints
  "chart toggled NAME 0|1" and "chart variant N" (0 or 1).
}
unit Tour.Charts;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Buttons,
  Controls.Timers,
  Controls.Charts;

type
  TChartsPage = class(TControl)
  private
    FLive: TChart;
    FAreas: TChart;
    FBars: TChart;
    FPie: TChart;
    FVariantButton: TButton;
    FVariant: LongInt;
    FTicks: LongInt;
    FTimer: TTimer;
    procedure TimerTicked(Sender: TTimer);
    procedure BuildLive;
    procedure BuildAreas;
    procedure BuildBars;
    procedure BuildPie;
    procedure VariantClicked(Sender: TControl);
    procedure SeriesToggled(Sender: TChart; SeriesIndex, PointIndex: LongInt);
    procedure ShowVariant;
  protected
    procedure Layout; override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    { A new value for the scrolling chart (every half second, while the
      page is shown). }
    procedure Tick;
    property Live: TChart read FLive;
    property VariantButton: TButton read FVariantButton;
  end;

implementation

uses
  SysUtils,
  Drawing.Rectangles,
  Windowing.Connection,
  Controls.ChartSeries,
  Controls.ChartModel,
  Controls.ChartFormat,
  Controls.ChartScale,
  Tour.Output;

const
  { Logical units. }
  Margin = 6;
  Gap = 6;
  ButtonWidth = 90;
  ButtonHeight = 23;
  LiveWindowSeconds = 15;
  TickMilliseconds = 500;
  Mebibyte = 1024 * 1024;

constructor TChartsPage.Create(AParent: TControl);
begin
  inherited Create(AParent);
  BuildLive;
  BuildAreas;
  BuildBars;
  BuildPie;
  FVariantButton := TButton.Create(Self);
  FVariantButton.Text := '&Variant';
  FVariantButton.OnClick := @VariantClicked;
  FTimer := TTimer.Create;
  FTimer.Interval := TickMilliseconds;
  FTimer.OnTimer := @TimerTicked;
end;

destructor TChartsPage.Destroy;
begin
  FTimer.Free;
  inherited Destroy;
end;

{ The live chart moves on only while its page is shown. }
procedure TChartsPage.TimerTicked(Sender: TTimer);
begin
  if (Parent <> nil) and Parent.Visible then
    Tick;
end;

{ The value the live chart shows at tick Tick: two waves together. }
function LiveValue(Tick: LongInt; Phase: Double): Double;
begin
  Result := 50 + 30 * Sin(Tick / 5 + Phase) + 12 * Sin(Tick / 1.7 + 2 * Phase);
end;

procedure TChartsPage.BuildLive;
var
  Series: TChartSeries;
  Step: LongInt;
begin
  FLive := TChart.Create(Self);
  FLive.BeginUpdate;
  FLive.Title := 'Live';
  FLive.LegendPosition := LegendRight;
  FLive.XAxis.Window := LiveWindowSeconds;
  FLive.XAxis.CountsBack := True;
  FLive.XAxis.Format := ChartFormatDuration;
  FLive.XAxis.TickBase := TickBaseTime;
  FLive.YAxis.SetRange(0, 100);
  FLive.YAxis.Format := ChartFormatPercent;
  Series := FLive.AddSeries('Busy', SeriesLine);
  Series.MaxPoints := 2 * LiveWindowSeconds + 1;
  Series := FLive.AddSeries('Waiting', SeriesLine);
  Series.MaxPoints := 2 * LiveWindowSeconds + 1;
  for Step := 0 to 2 * LiveWindowSeconds do
  begin
    FLive.Series[0].AddPoint(Step / 2, LiveValue(Step, 0));
    FLive.Series[1].AddPoint(Step / 2, LiveValue(Step, 2) * 0.6);
  end;
  FTicks := 2 * LiveWindowSeconds + 1;
  FLive.OnSeriesToggled := @SeriesToggled;
  FLive.EndUpdate;
end;

procedure TChartsPage.BuildAreas;
const
  Names: array[0..2] of string = ('Programs', 'Cache', 'Kernel');
  Sizes: array[0..2, 0..5] of LongInt = ((40, 55, 70, 62, 90, 84), (20, 35, 30, 48, 52, 60), (12, 12, 14, 13, 15, 15));
var
  Index: LongInt;
  Point: LongInt;
  Series: TChartSeries;
begin
  FAreas := TChart.Create(Self);
  FAreas.BeginUpdate;
  FAreas.Title := 'Memory';
  FAreas.LegendPosition := LegendRight;
  FAreas.XAxis.Format := ChartFormatDuration;
  FAreas.XAxis.TickBase := TickBaseTime;
  FAreas.YAxis.Format := ChartFormatBytes;
  FAreas.YAxis.TickBase := TickBaseBinary;
  for Index := 0 to High(Names) do
  begin
    Series := FAreas.AddSeries(Names[Index], SeriesArea);
    Series.Stacked := True;
    for Point := 0 to High(Sizes[Index]) do
      Series.AddPoint(Point * 60, Sizes[Index, Point] * Mebibyte);
  end;
  FAreas.OnSeriesToggled := @SeriesToggled;
  FAreas.EndUpdate;
end;

procedure TChartsPage.BuildBars;
const
  Names: array[0..2] of string = ('North', 'South', 'West');
  Quarters: array[0..3] of string = ('Q1', 'Q2', 'Q3', 'Q4');
  Sales: array[0..2, 0..3] of LongInt = ((12, 19, 15, 24), (8, 11, 17, 14), (5, 9, 7, 12));
var
  Index: LongInt;
  Quarter: LongInt;
  Series: TChartSeries;
begin
  FBars := TChart.Create(Self);
  FBars.BeginUpdate;
  FBars.Title := 'Sales';
  FBars.LegendPosition := LegendRight;
  for Index := 0 to High(Names) do
  begin
    Series := FBars.AddSeries(Names[Index], SeriesBar);
    for Quarter := 0 to High(Quarters) do
      Series.AddCategoryValue(Quarters[Quarter], Sales[Index, Quarter]);
  end;
  FBars.OnSeriesToggled := @SeriesToggled;
  FBars.EndUpdate;
end;

procedure TChartsPage.BuildPie;
var
  Series: TChartSeries;
begin
  FPie := TChart.Create(Self);
  FPie.BeginUpdate;
  FPie.Title := 'Disk';
  FPie.LegendPosition := LegendRight;
  FPie.PieLabels := PieLabelsPercent;
  Series := FPie.AddSeries('Disk', SeriesPie);
  Series.AddCategoryValue('Programs', 42);
  Series.AddCategoryValue('Pictures', 25);
  Series.AddCategoryValue('Music', 18);
  Series.AddCategoryValue('Free', 15);
  Series.ExplodedIndex := 1;
  FPie.OnSeriesToggled := @SeriesToggled;
  FPie.EndUpdate;
end;

procedure TChartsPage.ShowVariant;
var
  Index: LongInt;
  Other: Boolean;
begin
  Other := FVariant = 1;
  FLive.BeginUpdate;
  for Index := 0 to FLive.SeriesCount - 1 do
  begin
    FLive.Series[Index].Stepped := Other;
    FLive.Series[Index].ShowMarkers := Other;
  end;
  FLive.EndUpdate;
  FAreas.BeginUpdate;
  for Index := 0 to FAreas.SeriesCount - 1 do
    FAreas.Series[Index].Stacked := not Other;
  FAreas.EndUpdate;
  FBars.BeginUpdate;
  for Index := 0 to FBars.SeriesCount - 1 do
    FBars.Series[Index].Stacked := Other;
  FBars.Horizontal := Other;
  FBars.EndUpdate;
  FPie.BeginUpdate;
  if Other then
  begin
    FPie.Series[0].HoleRatio := 0.55;
    FPie.Series[0].ExplodedIndex := -1;
    FPie.PieLabels := PieLabelsNamesAndPercent;
    FPie.LegendPosition := LegendNone;
  end
  else
  begin
    FPie.Series[0].HoleRatio := 0;
    FPie.Series[0].ExplodedIndex := 1;
    FPie.PieLabels := PieLabelsPercent;
    FPie.LegendPosition := LegendRight;
  end;
  FPie.EndUpdate;
end;

procedure TChartsPage.VariantClicked(Sender: TControl);
begin
  FVariant := 1 - FVariant;
  ShowVariant;
  Say('chart variant ' + IntToStr(FVariant));
end;

procedure TChartsPage.SeriesToggled(Sender: TChart; SeriesIndex, PointIndex: LongInt);
var
  Series: TChartSeries;
begin
  Series := Sender.Series[SeriesIndex];
  if PointIndex >= 0 then
    Say('chart toggled ' + Series.Points[PointIndex].Text + ' ' + IntToStr(Ord(not Series.Hidden[PointIndex])))
  else
    Say('chart toggled ' + Series.Name + ' ' + IntToStr(Ord(Series.Visible)));
end;

procedure TChartsPage.Tick;
begin
  FLive.BeginUpdate;
  FLive.Series[0].AddPoint(FTicks / 2, LiveValue(FTicks, 0));
  FLive.Series[1].AddPoint(FTicks / 2, LiveValue(FTicks, 2) * 0.6);
  FLive.EndUpdate;
  Inc(FTicks);
end;

procedure TChartsPage.Layout;
var
  Width: LongInt;
  Height: LongInt;
  CellWidth: LongInt;
  CellHeight: LongInt;
begin
  Width := Unscaled(RectangleWidth(PixelBounds));
  Height := Unscaled(RectangleHeight(PixelBounds));
  CellWidth := (Width - 2 * Margin - Gap) div 2;
  CellHeight := (Height - 2 * Margin - 2 * Gap - ButtonHeight) div 2;
  FLive.AssignBounds(Margin, Margin, CellWidth, CellHeight);
  FAreas.AssignBounds(Margin + CellWidth + Gap, Margin, CellWidth, CellHeight);
  FBars.AssignBounds(Margin, Margin + CellHeight + Gap, CellWidth, CellHeight);
  FPie.AssignBounds(Margin + CellWidth + Gap, Margin + CellHeight + Gap, CellWidth, CellHeight);
  FVariantButton.AssignBounds(Width - Margin - ButtonWidth, Height - Margin - ButtonHeight, ButtonWidth,
    ButtonHeight);
  inherited Layout;
end;

end.
