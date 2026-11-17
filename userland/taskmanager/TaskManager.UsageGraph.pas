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
  A graph of a history over time (TaskManager.History): how busy a
  processor was, how much memory was in use. It is a chart (Controls.
  Charts) of one area series that scrolls.

  In a sunken box on the field colour, a light grid (a line every
  quarter up, every ten samples back from the newest) under the
  history: the newest sample at the right edge, older ones to the left,
  as a line with the area under it lightly filled, both anti-aliased.
  The caption (what it shows and the newest value: "CPU 37%") sits at
  the top left, the chart's title inside the plot. With ShowScale the
  percentages are written up the left side. The series keeps the last
  HistoryLength samples and the X axis shows that window, so each
  Refresh adds only the samples that are new and the graph moves on.
  The pointer over it shows the value at the nearest sample.
}
unit TaskManager.UsageGraph;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Controls.Base,
  Controls.ChartSeries,
  Controls.ChartAxes,
  Controls.Charts,
  TaskManager.History;

type
  TUsageGraph = class(TChart)
  private
    FHistory: PUsageHistory;
    FUsage: TChartSeries;
    { The number of samples of the history the series has had. }
    FTaken: QWord;
    function GetLineColor: TColor;
    procedure SetLineColor(Value: TColor);
    function GetShowScale: Boolean;
    procedure SetShowScale(Value: Boolean);
    procedure SetHistory(Value: PUsageHistory);
    function FormatSamplesBack(Sender: TChartAxis; Value, Step: Double): string;
  public
    constructor Create(AParent: TControl); override;
    { Adds the samples the history has had since the last time. }
    procedure Refresh;
    property History: PUsageHistory read FHistory write SetHistory;
    property LineColor: TColor read GetLineColor write SetLineColor;
    property ShowScale: Boolean read GetShowScale write SetShowScale;
  end;

const
  ProcessorLineColor = $FF2F6DB5;
  MemoryLineColor = $FF8A3FB0;

implementation

uses
  SysUtils,
  Controls.ChartFormat,
  Controls.ChartModel;

const
  { Samples between the grid's vertical lines; percent between the
    level ones. }
  SamplesPerGridLine = 10;
  PercentPerGridLine = 25;

constructor TUsageGraph.Create(AParent: TControl);
begin
  inherited Create(AParent);
  BeginUpdate;
  TitlePlacement := TitleInside;
  LegendPosition := LegendNone;
  XAxis.Visible := False;
  XAxis.Window := HistoryLength - 1;
  XAxis.Step := SamplesPerGridLine;
  XAxis.CountsBack := True;
  XAxis.OnFormat := @FormatSamplesBack;
  YAxis.Visible := False;
  YAxis.SetRange(0, 100);
  YAxis.Step := PercentPerGridLine;
  YAxis.Format := ChartFormatPercent;
  FUsage := AddSeries('', SeriesArea);
  FUsage.MaxPoints := HistoryLength;
  FUsage.Color := ProcessorLineColor;
  EndUpdate;
end;

function TUsageGraph.FormatSamplesBack(Sender: TChartAxis; Value, Step: Double): string;
begin
  if Value < 0.5 then
    Exit('Now');
  Result := IntToStr(Round(Value)) + ' samples ago';
end;

procedure TUsageGraph.SetHistory(Value: PUsageHistory);
begin
  FHistory := Value;
  FUsage.Clear;
  FTaken := 0;
  Refresh;
end;

procedure TUsageGraph.Refresh;
var
  Fresh: QWord;
  Age: LongInt;
begin
  if FHistory = nil then
    Exit;
  Fresh := FHistory^.Total - FTaken;
  if Fresh = 0 then
    Exit;
  if Fresh > QWord(FHistory^.Count) then
    Fresh := FHistory^.Count;
  BeginUpdate;
  { Oldest first; each sample's X is its number in the history. }
  for Age := LongInt(Fresh) - 1 downto 0 do
    FUsage.AddPoint(FHistory^.Total - 1 - QWord(Age), SampleAt(FHistory^, Age) / 10);
  FTaken := FHistory^.Total;
  EndUpdate;
end;

function TUsageGraph.GetLineColor: TColor;
begin
  Result := FUsage.Color;
end;

procedure TUsageGraph.SetLineColor(Value: TColor);
begin
  FUsage.Color := Value;
end;

function TUsageGraph.GetShowScale: Boolean;
begin
  Result := YAxis.Visible;
end;

procedure TUsageGraph.SetShowScale(Value: Boolean);
begin
  YAxis.Visible := Value;
end;

end.
