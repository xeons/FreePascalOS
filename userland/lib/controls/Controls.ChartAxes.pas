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
  A chart's axis: what range it shows, its ticks and how their labels
  read, its title, and whether it draws grid lines.

  The range is automatic (from the data, to nice ticks: Controls.
  ChartScale), fixed (Minimum to Maximum), or a window: the last Window
  units up to the newest value, for a graph that scrolls as points come.
  The step between ticks is nice unless Step fixes it. Labels are
  written in a format (a number, a percent, bytes, a duration) or by
  OnFormat; an axis that CountsBack labels each tick by how far it is
  from the newest value ("30 s" back), as a time axis of a scrolling
  graph does.
}
unit Controls.ChartAxes;

{$mode objfpc}
{$H+}

interface

uses
  Controls.ChartScale,
  Controls.ChartFormat,
  Controls.ChartSeries;

type
  TChartAxis = class;

  TChartAxisFormatEvent = function(Sender: TChartAxis; Value, Step: Double): string of object;

  TChartAxis = class
  private
    FTitle: string;
    FVisible: Boolean;
    FShowGrid: Boolean;
    FAutoRange: Boolean;
    FMinimum: Double;
    FMaximum: Double;
    FStep: Double;
    FWindow: Double;
    FIncludeZero: Boolean;
    FCountsBack: Boolean;
    FTickBase: TTickBase;
    FFormat: TChartValueFormat;
    FOnFormat: TChartAxisFormatEvent;
    FOnChange: TChartChangeEvent;
    procedure SetTitle(const Value: string);
    procedure SetVisible(Value: Boolean);
    procedure SetShowGrid(Value: Boolean);
    procedure SetAutoRange(Value: Boolean);
    procedure SetStep(Value: Double);
    procedure SetWindow(Value: Double);
    procedure SetIncludeZero(Value: Boolean);
    procedure SetCountsBack(Value: Boolean);
    procedure SetTickBase(Value: TTickBase);
    procedure SetFormat(Value: TChartValueFormat);
    procedure SetOnFormat(Value: TChartAxisFormatEvent);
  protected
    procedure Changed;
  public
    constructor Create;
    { A fixed range (AutoRange becomes False). }
    procedure SetRange(AMinimum, AMaximum: Double);
    { The range shown for data from DataMinimum to DataMaximum, with at
      most MaximumTicks steps. }
    function ResolveRange(DataMinimum, DataMaximum: Double; MaximumTicks: LongInt): TAxisRange;
    { A tick's label within Range. }
    function TickLabel(const Range: TAxisRange; Value: Double): string;
    { A value written alone (a tooltip), within Range for CountsBack. }
    function ValueText(const Range: TAxisRange; Value: Double): string;
    property Title: string read FTitle write SetTitle;
    { The axis line and labels. }
    property Visible: Boolean read FVisible write SetVisible;
    property ShowGrid: Boolean read FShowGrid write SetShowGrid;
    property AutoRange: Boolean read FAutoRange write SetAutoRange;
    property Minimum: Double read FMinimum;
    property Maximum: Double read FMaximum;
    { 0: a nice step for the room there is. }
    property Step: Double read FStep write SetStep;
    { Above 0: the range is the last Window units to the newest value. }
    property Window: Double read FWindow write SetWindow;
    { An automatic range reaches 0 (on by default: bars and areas stand
      on it). }
    property IncludeZero: Boolean read FIncludeZero write SetIncludeZero;
    property CountsBack: Boolean read FCountsBack write SetCountsBack;
    property TickBase: TTickBase read FTickBase write SetTickBase;
    property Format: TChartValueFormat read FFormat write SetFormat;
    property OnFormat: TChartAxisFormatEvent read FOnFormat write SetOnFormat;
    property OnChange: TChartChangeEvent read FOnChange write FOnChange;
  end;

implementation

uses
  Math;

constructor TChartAxis.Create;
begin
  inherited Create;
  FVisible := True;
  FShowGrid := True;
  FAutoRange := True;
  FIncludeZero := True;
  FMaximum := 1;
end;

procedure TChartAxis.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TChartAxis.SetRange(AMinimum, AMaximum: Double);
begin
  FMinimum := AMinimum;
  FMaximum := AMaximum;
  FAutoRange := False;
  Changed;
end;

function TChartAxis.ResolveRange(DataMinimum, DataMaximum: Double; MaximumTicks: LongInt): TAxisRange;
var
  TickStep: Double;
begin
  if FWindow > 0 then
  begin
    if FStep > 0 then
      TickStep := FStep
    else
      TickStep := StepFor(FWindow, MaximumTicks, FTickBase);
    Result := MakeRange(DataMaximum - FWindow, DataMaximum, TickStep);
    { Counted back from the newest value, the ticks stay where they are
      as the graph scrolls under them. }
    if FCountsBack then
      Result.Origin := DataMaximum;
    Exit;
  end;
  if not FAutoRange then
  begin
    if FStep > 0 then
      Exit(MakeRange(FMinimum, Max(FMaximum, FMinimum + FStep), FStep));
    Exit(FixedRange(FMinimum, FMaximum, MaximumTicks, FTickBase));
  end;
  Result := Controls.ChartScale.AutoRange(DataMinimum, DataMaximum, MaximumTicks, FIncludeZero, FTickBase);
  if FStep > 0 then
  begin
    Result.Step := FStep;
    Result.Minimum := Floor(Result.Minimum / FStep + 1E-9) * FStep;
    Result.Maximum := Ceil(Result.Maximum / FStep - 1E-9) * FStep;
    if Result.Maximum <= Result.Minimum then
      Result.Maximum := Result.Minimum + FStep;
  end;
end;

function TChartAxis.TickLabel(const Range: TAxisRange; Value: Double): string;
begin
  if FCountsBack then
    Value := Range.Maximum - Value;
  if Assigned(FOnFormat) then
    Exit(FOnFormat(Self, Value, Range.Step));
  Result := FormatChartValue(FFormat, Value, Range.Step);
end;

function TChartAxis.ValueText(const Range: TAxisRange; Value: Double): string;
begin
  if FCountsBack then
    Value := Range.Maximum - Value;
  if Assigned(FOnFormat) then
    Exit(FOnFormat(Self, Value, 0));
  Result := FormatChartValue(FFormat, Value, 0);
end;

procedure TChartAxis.SetTitle(const Value: string);
begin
  FTitle := Value;
  Changed;
end;

procedure TChartAxis.SetVisible(Value: Boolean);
begin
  FVisible := Value;
  Changed;
end;

procedure TChartAxis.SetShowGrid(Value: Boolean);
begin
  FShowGrid := Value;
  Changed;
end;

procedure TChartAxis.SetAutoRange(Value: Boolean);
begin
  FAutoRange := Value;
  Changed;
end;

procedure TChartAxis.SetStep(Value: Double);
begin
  if Value < 0 then
    Value := 0;
  FStep := Value;
  Changed;
end;

procedure TChartAxis.SetWindow(Value: Double);
begin
  if Value < 0 then
    Value := 0;
  FWindow := Value;
  Changed;
end;

procedure TChartAxis.SetIncludeZero(Value: Boolean);
begin
  FIncludeZero := Value;
  Changed;
end;

procedure TChartAxis.SetCountsBack(Value: Boolean);
begin
  FCountsBack := Value;
  Changed;
end;

procedure TChartAxis.SetTickBase(Value: TTickBase);
begin
  FTickBase := Value;
  Changed;
end;

procedure TChartAxis.SetFormat(Value: TChartValueFormat);
begin
  FFormat := Value;
  Changed;
end;

procedure TChartAxis.SetOnFormat(Value: TChartAxisFormatEvent);
begin
  FOnFormat := Value;
  Changed;
end;

end.
