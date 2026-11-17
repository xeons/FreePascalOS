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
  The chart control: lines, areas, bars and pies, with axes, a legend
  and a title, drawn from a model (Controls.ChartModel) in the theme's
  colours at the window's scale.

    Chart := TChart.Create(Page);
    Chart.Title := 'Visitors';
    Series := Chart.AddSeries('Mon', SeriesBar);
    Series.AddCategoryValue('Morning', 12);

  Series and axes are objects of their own (Controls.ChartSeries,
  Controls.ChartAxes); a change to any of them repaints the chart. For a
  graph that scrolls, give the series MaxPoints and the X axis a Window
  and add a point at every look: only the chart's own rectangle is
  repainted, and painting costs as many steps as there are points.

  The pointer over the plot shows a crosshair at the nearest point and
  a tooltip of the values there (over a bar or a slice, its value);
  clicking a legend entry hides or shows its series (or slice), and
  tells OnSeriesToggled and, as a change, the parent.

  Everything is drawn by Controls.ChartPainting, which needs nothing of
  a window: the same code draws on the host in tools/ChartTest.
}
unit Controls.Charts;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.ChartSeries,
  Controls.ChartAxes,
  Controls.ChartModel,
  Controls.ChartStyle,
  Controls.ChartLayout,
  Controls.ChartHitTesting;

type
  TChart = class;

  { SeriesIndex's series, or its slice PointIndex (-1 for a series),
    was hidden or shown from the legend. }
  TChartToggleEvent = procedure(Sender: TChart; SeriesIndex, PointIndex: LongInt) of object;

  TChart = class(TControl)
  private
    FModel: TChartModel;
    FLayout: TChartLayout;
    FStyle: TChartStyle;
    FPainted: Boolean;
    FHover: TChartHit;
    FShowTooltips: Boolean;
    FOnSeriesToggled: TChartToggleEvent;
    procedure ModelChanged(Sender: TObject);
    function GetSeries(Index: LongInt): TChartSeries;
    function GetSeriesCount: LongInt;
    function GetXAxis: TChartAxis;
    function GetYAxis: TChartAxis;
    function GetTitle: string;
    procedure SetTitle(const Value: string);
    function GetTitlePlacement: TChartTitlePlacement;
    procedure SetTitlePlacement(Value: TChartTitlePlacement);
    function GetLegendPosition: TChartLegendPosition;
    procedure SetLegendPosition(Value: TChartLegendPosition);
    function GetHorizontal: Boolean;
    procedure SetHorizontal(Value: Boolean);
    function GetPieLabels: TPieLabels;
    procedure SetPieLabels(Value: TPieLabels);
    function GetFramed: Boolean;
    procedure SetFramed(Value: Boolean);
    procedure SetShowTooltips(Value: Boolean);
    procedure SetHover(const Hit: TChartHit);
    procedure ToggleLegendItem(const Hit: TChartHit);
  protected
    procedure Paint(var Canvas: TCanvas); override;
    procedure PointerMove(X, Y: LongInt; Buttons: LongWord); override;
    procedure PointerLeave; override;
    procedure PointerUp(X, Y: LongInt; Button: LongWord); override;
  public
    constructor Create(AParent: TControl); override;
    destructor Destroy; override;
    function AddSeries(const Name: string; Kind: TChartSeriesKind): TChartSeries;
    procedure RemoveSeries(Series: TChartSeries);
    procedure ClearSeries;
    { Gathers changes into one repaint. }
    procedure BeginUpdate;
    procedure EndUpdate;
    { The style the chart is drawn with now (the theme's, at the
      window's scale). }
    function CurrentStyle: TChartStyle;
    property Model: TChartModel read FModel;
    property SeriesCount: LongInt read GetSeriesCount;
    property Series[Index: LongInt]: TChartSeries read GetSeries;
    property XAxis: TChartAxis read GetXAxis;
    property YAxis: TChartAxis read GetYAxis;
    property Title: string read GetTitle write SetTitle;
    property TitlePlacement: TChartTitlePlacement read GetTitlePlacement write SetTitlePlacement;
    property LegendPosition: TChartLegendPosition read GetLegendPosition write SetLegendPosition;
    property Horizontal: Boolean read GetHorizontal write SetHorizontal;
    property PieLabels: TPieLabels read GetPieLabels write SetPieLabels;
    property Framed: Boolean read GetFramed write SetFramed;
    property ShowTooltips: Boolean read FShowTooltips write SetShowTooltips;
    { The layout of the last paint (pixels, the chart's own). }
    property Layout: TChartLayout read FLayout;
    property OnSeriesToggled: TChartToggleEvent read FOnSeriesToggled write FOnSeriesToggled;
  end;

implementation

uses
  Abi.SystemCalls,
  Drawing.Colors,
  Drawing.Rectangles,
  Windowing.Theme,
  Windowing.Fonts,
  Windowing.Connection,
  Controls.ChartPainting;

const
  { The labels' size against the interface's text, in tenths of a
    point. }
  LabelPointsSmaller = 10;

constructor TChart.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FModel := TChartModel.Create;
  FModel.OnChange := @ModelChanged;
  FHover := NoChartHit;
  FShowTooltips := True;
end;

destructor TChart.Destroy;
begin
  FModel.Free;
  inherited Destroy;
end;

procedure TChart.ModelChanged(Sender: TObject);
begin
  Invalidate;
end;

function TChart.CurrentStyle: TChartStyle;
var
  Points: LongWord;
begin
  Result.ScalePercent := DisplayScale;
  Result.Background := Theme.Field;
  Result.Foreground := Theme.FieldText;
  Result.QuietText := MixColors(Theme.Field, Theme.FieldText, 190);
  Result.Grid := MixColors(Theme.Field, Theme.FieldText, 30);
  Result.AxisLine := MixColors(Theme.Field, Theme.FieldText, 120);
  Result.Tooltip := Theme.Tooltip;
  Result.TooltipText := Theme.TooltipText;
  Result.Frame := SunkenThemeBevel;
  Points := Theme.TextPoints;
  if Points > 2 * LabelPointsSmaller then
    Points := Points - LabelPointsSmaller;
  Result.LabelFace := FontFace(Points, False);
  { A title above stands out in bold; one inside the plot is a caption
    in the interface's text. }
  if FModel.TitlePlacement = TitleAbove then
    Result.TitleFace := BoldTextFace
  else
    Result.TitleFace := TextFace;
end;

procedure TChart.Paint(var Canvas: TCanvas);
var
  Shown: TChartHit;
begin
  FStyle := CurrentStyle;
  Shown := FHover;
  if not FShowTooltips and (Shown.Kind <> HitLegend) then
    Shown := NoChartHit;
  PaintChart(Canvas, FModel, FStyle, MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds)),
    Shown, FLayout);
  FPainted := True;
end;

procedure TChart.SetHover(const Hit: TChartHit);
begin
  if ChartHitsEqual(Hit, FHover) then
    Exit;
  FHover := Hit;
  Invalidate;
end;

procedure TChart.PointerMove(X, Y: LongInt; Buttons: LongWord);
begin
  if not FPainted then
    Exit;
  SetHover(HitTestChart(FModel, FLayout, FStyle, X, Y));
end;

procedure TChart.PointerLeave;
begin
  SetHover(NoChartHit);
end;

procedure TChart.ToggleLegendItem(const Hit: TChartHit);
var
  Target: TChartSeries;
begin
  if (Hit.SeriesIndex < 0) or (Hit.SeriesIndex >= FModel.SeriesCount) then
    Exit;
  Target := FModel[Hit.SeriesIndex];
  if Hit.PointIndex >= 0 then
  begin
    if Hit.PointIndex >= Target.Count then
      Exit;
    Target.Hidden[Hit.PointIndex] := not Target.Hidden[Hit.PointIndex];
  end
  else
    Target.Visible := not Target.Visible;
  if Assigned(FOnSeriesToggled) then
    FOnSeriesToggled(Self, Hit.SeriesIndex, Hit.PointIndex);
  Changed;
end;

procedure TChart.PointerUp(X, Y: LongInt; Button: LongWord);
var
  Hit: TChartHit;
begin
  if (Button <> ButtonLeft) or not FPainted then
    Exit;
  Hit := HitTestChart(FModel, FLayout, FStyle, X, Y);
  if Hit.Kind = HitLegend then
    ToggleLegendItem(Hit);
end;

function TChart.AddSeries(const Name: string; Kind: TChartSeriesKind): TChartSeries;
begin
  Result := FModel.AddSeries(Name, Kind);
end;

procedure TChart.RemoveSeries(Series: TChartSeries);
begin
  FHover := NoChartHit;
  FModel.RemoveSeries(Series);
end;

procedure TChart.ClearSeries;
begin
  FHover := NoChartHit;
  FModel.ClearSeries;
end;

procedure TChart.BeginUpdate;
begin
  FModel.BeginUpdate;
end;

procedure TChart.EndUpdate;
begin
  FModel.EndUpdate;
end;

function TChart.GetSeries(Index: LongInt): TChartSeries;
begin
  Result := FModel[Index];
end;

function TChart.GetSeriesCount: LongInt;
begin
  Result := FModel.SeriesCount;
end;

function TChart.GetXAxis: TChartAxis;
begin
  Result := FModel.XAxis;
end;

function TChart.GetYAxis: TChartAxis;
begin
  Result := FModel.YAxis;
end;

function TChart.GetTitle: string;
begin
  Result := FModel.Title;
end;

procedure TChart.SetTitle(const Value: string);
begin
  if FModel.Title <> Value then
    FModel.Title := Value;
end;

function TChart.GetTitlePlacement: TChartTitlePlacement;
begin
  Result := FModel.TitlePlacement;
end;

procedure TChart.SetTitlePlacement(Value: TChartTitlePlacement);
begin
  FModel.TitlePlacement := Value;
end;

function TChart.GetLegendPosition: TChartLegendPosition;
begin
  Result := FModel.LegendPosition;
end;

procedure TChart.SetLegendPosition(Value: TChartLegendPosition);
begin
  FModel.LegendPosition := Value;
end;

function TChart.GetHorizontal: Boolean;
begin
  Result := FModel.Horizontal;
end;

procedure TChart.SetHorizontal(Value: Boolean);
begin
  FModel.Horizontal := Value;
end;

function TChart.GetPieLabels: TPieLabels;
begin
  Result := FModel.PieLabels;
end;

procedure TChart.SetPieLabels(Value: TPieLabels);
begin
  FModel.PieLabels := Value;
end;

function TChart.GetFramed: Boolean;
begin
  Result := FModel.Framed;
end;

procedure TChart.SetFramed(Value: Boolean);
begin
  FModel.Framed := Value;
end;

procedure TChart.SetShowTooltips(Value: Boolean);
begin
  FShowTooltips := Value;
  Invalidate;
end;

end.
