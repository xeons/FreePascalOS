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
  Everything a chart shows, apart from how it looks on the screen: its
  series, its two axes, its title, where its legend goes, and how bars
  and pies are laid out. The chart control (Controls.Charts) owns one
  and draws it (Controls.ChartPainting); a test draws one on a surface
  of its own.

  The X axis runs along the points (categories for bars), the Y axis
  is the values'. Bars lie on their side when Horizontal: the values
  then run across and the categories down. A chart with a pie series
  that is shown is a pie chart: the first such series is drawn, and
  the axes are not.

  Changes to the series, the axes or the settings are told through
  OnChange, once for each; BeginUpdate and EndUpdate gather a batch
  into one.
}
unit Controls.ChartModel;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.ChartSeries,
  Controls.ChartAxes;

type
  TChartLegendPosition = (LegendNone, LegendTop, LegendBottom, LegendLeft, LegendRight);
  { Above the plot, centred; or inside it at the top left, as a small
    graph's caption. }
  TChartTitlePlacement = (TitleAbove, TitleInside);
  TPieLabels = (PieLabelsNone, PieLabelsPercent, PieLabelsNames, PieLabelsNamesAndPercent);

  TChartModel = class
  private
    FSeries: TList;
    FXAxis: TChartAxis;
    FYAxis: TChartAxis;
    FTitle: string;
    FTitlePlacement: TChartTitlePlacement;
    FLegendPosition: TChartLegendPosition;
    FHorizontal: Boolean;
    FPieLabels: TPieLabels;
    FFramed: Boolean;
    FUpdateDepth: LongInt;
    FChangedDuringUpdate: Boolean;
    FOnChange: TChartChangeEvent;
    function GetSeries(Index: LongInt): TChartSeries;
    function GetSeriesCount: LongInt;
    procedure PartChanged(Sender: TObject);
    procedure SetTitle(const Value: string);
    procedure SetTitlePlacement(Value: TChartTitlePlacement);
    procedure SetLegendPosition(Value: TChartLegendPosition);
    procedure SetHorizontal(Value: Boolean);
    procedure SetPieLabels(Value: TPieLabels);
    procedure SetFramed(Value: Boolean);
  protected
    procedure Changed;
  public
    constructor Create;
    destructor Destroy; override;
    function AddSeries(const Name: string; Kind: TChartSeriesKind): TChartSeries;
    procedure RemoveSeries(Series: TChartSeries);
    procedure ClearSeries;
    function IndexOfSeries(Series: TChartSeries): LongInt;
    procedure BeginUpdate;
    procedure EndUpdate;
    property SeriesCount: LongInt read GetSeriesCount;
    property Series[Index: LongInt]: TChartSeries read GetSeries; default;
    property XAxis: TChartAxis read FXAxis;
    property YAxis: TChartAxis read FYAxis;
    property Title: string read FTitle write SetTitle;
    property TitlePlacement: TChartTitlePlacement read FTitlePlacement write SetTitlePlacement;
    property LegendPosition: TChartLegendPosition read FLegendPosition write SetLegendPosition;
    property Horizontal: Boolean read FHorizontal write SetHorizontal;
    property PieLabels: TPieLabels read FPieLabels write SetPieLabels;
    { In a sunken box on the field colour (as a list box); otherwise on
      the field colour alone. }
    property Framed: Boolean read FFramed write SetFramed;
    property OnChange: TChartChangeEvent read FOnChange write FOnChange;
  end;

implementation

constructor TChartModel.Create;
begin
  inherited Create;
  FSeries := TList.Create;
  FXAxis := TChartAxis.Create;
  FXAxis.IncludeZero := False;
  FXAxis.OnChange := @PartChanged;
  FYAxis := TChartAxis.Create;
  FYAxis.OnChange := @PartChanged;
  FLegendPosition := LegendRight;
  FPieLabels := PieLabelsPercent;
  FFramed := True;
end;

destructor TChartModel.Destroy;
var
  Index: LongInt;
begin
  for Index := 0 to FSeries.Count - 1 do
    TChartSeries(FSeries[Index]).Free;
  FSeries.Free;
  FXAxis.Free;
  FYAxis.Free;
  inherited Destroy;
end;

function TChartModel.GetSeries(Index: LongInt): TChartSeries;
begin
  Result := TChartSeries(FSeries[Index]);
end;

function TChartModel.GetSeriesCount: LongInt;
begin
  Result := FSeries.Count;
end;

function TChartModel.AddSeries(const Name: string; Kind: TChartSeriesKind): TChartSeries;
begin
  Result := TChartSeries.Create(Name, Kind);
  Result.OnChange := @PartChanged;
  FSeries.Add(Result);
  Changed;
end;

procedure TChartModel.RemoveSeries(Series: TChartSeries);
begin
  if FSeries.Remove(Series) >= 0 then
  begin
    Series.Free;
    Changed;
  end;
end;

procedure TChartModel.ClearSeries;
var
  Index: LongInt;
begin
  for Index := 0 to FSeries.Count - 1 do
    TChartSeries(FSeries[Index]).Free;
  FSeries.Clear;
  Changed;
end;

function TChartModel.IndexOfSeries(Series: TChartSeries): LongInt;
begin
  Result := FSeries.IndexOf(Series);
end;

procedure TChartModel.BeginUpdate;
begin
  Inc(FUpdateDepth);
end;

procedure TChartModel.EndUpdate;
begin
  if FUpdateDepth = 0 then
    Exit;
  Dec(FUpdateDepth);
  if (FUpdateDepth = 0) and FChangedDuringUpdate then
  begin
    FChangedDuringUpdate := False;
    Changed;
  end;
end;

procedure TChartModel.Changed;
begin
  if FUpdateDepth > 0 then
  begin
    FChangedDuringUpdate := True;
    Exit;
  end;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TChartModel.PartChanged(Sender: TObject);
begin
  Changed;
end;

procedure TChartModel.SetTitle(const Value: string);
begin
  FTitle := Value;
  Changed;
end;

procedure TChartModel.SetTitlePlacement(Value: TChartTitlePlacement);
begin
  FTitlePlacement := Value;
  Changed;
end;

procedure TChartModel.SetLegendPosition(Value: TChartLegendPosition);
begin
  FLegendPosition := Value;
  Changed;
end;

procedure TChartModel.SetHorizontal(Value: Boolean);
begin
  FHorizontal := Value;
  Changed;
end;

procedure TChartModel.SetPieLabels(Value: TPieLabels);
begin
  FPieLabels := Value;
  Changed;
end;

procedure TChartModel.SetFramed(Value: Boolean);
begin
  FFramed := Value;
  Changed;
end;

end.
