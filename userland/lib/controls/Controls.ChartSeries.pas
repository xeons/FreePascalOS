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
  A chart's series: a name, how it is drawn (a line, an area, bars or a
  pie) and its points.

  A point is an (X, Y) pair, or a category and a value: AddCategoryValue
  gives the point the next whole X (0, 1, 2...) and the category's name
  as its text, which a bar chart's axis and a pie's slices show. Points
  are kept in the order they come; a line joins them in that order.

  A series with MaxPoints keeps only that many, the oldest going as new
  ones come (AddPoint, AddValue): a scrolling graph of the last minute
  is a series of 60 points with an axis that shows the newest stretch
  (Controls.ChartAxes, Window). Dropping the oldest point moves nothing
  until half the room is spent, so adding a point costs the same however
  long the series runs.

  Stacked series of one kind (areas, bars) stand on each other, point by
  point: the second stacked series' point 3 starts where the first's
  point 3 ends (Controls.ChartValues). Every change is told through
  OnChange (the chart repaints).
}
unit Controls.ChartSeries;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors;

type
  TChartSeriesKind = (SeriesLine, SeriesArea, SeriesBar, SeriesPie);

  TChartPoint = record
    X: Double;
    Y: Double;
    { The category's name, or a pie slice's. }
    Text: string;
    { A slice's own colour (0: the palette's). }
    Color: TColor;
    { A slice left out of its pie (its legend entry was clicked). }
    Hidden: Boolean;
  end;

  TChartChangeEvent = procedure(Sender: TObject) of object;

  TChartSeries = class
  private
    FName: string;
    FKind: TChartSeriesKind;
    FColor: TColor;
    FVisible: Boolean;
    FShowMarkers: Boolean;
    FStepped: Boolean;
    FStacked: Boolean;
    FLineWidth: Double;
    FMaxPoints: LongInt;
    FExplodedIndex: LongInt;
    FHoleRatio: Double;
    FPoints: array of TChartPoint;
    FFirst: LongInt;
    FCount: LongInt;
    FOnChange: TChartChangeEvent;
    function GetPoint(Index: LongInt): TChartPoint;
    function GetX(Index: LongInt): Double;
    function GetY(Index: LongInt): Double;
    function GetHidden(Index: LongInt): Boolean;
    procedure SetHidden(Index: LongInt; Value: Boolean);
    procedure SetName(const Value: string);
    procedure SetKind(Value: TChartSeriesKind);
    procedure SetColor(Value: TColor);
    procedure SetVisible(Value: Boolean);
    procedure SetShowMarkers(Value: Boolean);
    procedure SetStepped(Value: Boolean);
    procedure SetStacked(Value: Boolean);
    procedure SetLineWidth(Value: Double);
    procedure SetMaxPoints(Value: LongInt);
    procedure SetExplodedIndex(Value: LongInt);
    procedure SetHoleRatio(Value: Double);
    procedure DropOldest(Count: LongInt);
    procedure Append(const Point: TChartPoint);
  protected
    procedure Changed;
  public
    constructor Create(const AName: string; AKind: TChartSeriesKind);
    procedure AddPoint(X, Y: Double);
    { At the X after the last point's (0 for the first). }
    procedure AddValue(Y: Double);
    procedure AddCategoryValue(const Category: string; Value: Double);
    { A pie slice of its own colour. }
    procedure AddSlice(const Name: string; Value: Double; SliceColor: TColor);
    procedure SetY(Index: LongInt; Value: Double);
    procedure Clear;
    { The index of the point with the X nearest to X (points in order of
      X); -1 if there are none. }
    function NearestIndex(X: Double): LongInt;
    function LastX: Double;
    property Name: string read FName write SetName;
    property Kind: TChartSeriesKind read FKind write SetKind;
    { 0: the palette's colour for the series' place. }
    property Color: TColor read FColor write SetColor;
    property Visible: Boolean read FVisible write SetVisible;
    { A dot at every point of a line or area. }
    property ShowMarkers: Boolean read FShowMarkers write SetShowMarkers;
    { A line in steps: level to the next point's X, then up or down. }
    property Stepped: Boolean read FStepped write SetStepped;
    property Stacked: Boolean read FStacked write SetStacked;
    { Logical units (scaled when drawn). }
    property LineWidth: Double read FLineWidth write SetLineWidth;
    { 0: no limit. }
    property MaxPoints: LongInt read FMaxPoints write SetMaxPoints;
    { A pie's slice drawn out from the rest (-1: none). }
    property ExplodedIndex: LongInt read FExplodedIndex write SetExplodedIndex;
    { A doughnut: the hole's radius as a share of the pie's (0 to 0.9). }
    property HoleRatio: Double read FHoleRatio write SetHoleRatio;
    property Count: LongInt read FCount;
    property Points[Index: LongInt]: TChartPoint read GetPoint;
    property X[Index: LongInt]: Double read GetX;
    property Y[Index: LongInt]: Double read GetY;
    property Hidden[Index: LongInt]: Boolean read GetHidden write SetHidden;
    property OnChange: TChartChangeEvent read FOnChange write FOnChange;
  end;

const
  DefaultLineWidth = 1.5;
  MostHoleRatio = 0.9;

implementation

constructor TChartSeries.Create(const AName: string; AKind: TChartSeriesKind);
begin
  inherited Create;
  FName := AName;
  FKind := AKind;
  FVisible := True;
  FLineWidth := DefaultLineWidth;
  FExplodedIndex := -1;
end;

procedure TChartSeries.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TChartSeries.GetPoint(Index: LongInt): TChartPoint;
begin
  Result := FPoints[FFirst + Index];
end;

function TChartSeries.GetX(Index: LongInt): Double;
begin
  Result := FPoints[FFirst + Index].X;
end;

function TChartSeries.GetY(Index: LongInt): Double;
begin
  Result := FPoints[FFirst + Index].Y;
end;

function TChartSeries.GetHidden(Index: LongInt): Boolean;
begin
  Result := FPoints[FFirst + Index].Hidden;
end;

procedure TChartSeries.SetHidden(Index: LongInt; Value: Boolean);
begin
  if FPoints[FFirst + Index].Hidden = Value then
    Exit;
  FPoints[FFirst + Index].Hidden := Value;
  Changed;
end;

procedure TChartSeries.SetY(Index: LongInt; Value: Double);
begin
  FPoints[FFirst + Index].Y := Value;
  Changed;
end;

procedure TChartSeries.DropOldest(Count: LongInt);
begin
  if Count > FCount then
    Count := FCount;
  if Count <= 0 then
    Exit;
  { Strings in the dropped points are let go now. }
  Finalize(FPoints[FFirst], Count);
  Initialize(FPoints[FFirst], Count);
  Inc(FFirst, Count);
  Dec(FCount, Count);
end;

procedure TChartSeries.Append(const Point: TChartPoint);
var
  Index: LongInt;
begin
  if (FMaxPoints > 0) and (FCount >= FMaxPoints) then
    DropOldest(FCount - FMaxPoints + 1);
  if FFirst + FCount >= Length(FPoints) then
  begin
    if FFirst > 0 then
    begin
      { Back to the start of the room, oldest first. }
      for Index := 0 to FCount - 1 do
        FPoints[Index] := FPoints[FFirst + Index];
      for Index := FCount to FFirst + FCount - 1 do
        FPoints[Index] := Default(TChartPoint);
      FFirst := 0;
    end;
    if FCount >= Length(FPoints) then
      SetLength(FPoints, 2 * Length(FPoints) + 16);
  end;
  FPoints[FFirst + FCount] := Point;
  Inc(FCount);
  Changed;
end;

procedure TChartSeries.AddPoint(X, Y: Double);
var
  Point: TChartPoint;
begin
  Point := Default(TChartPoint);
  Point.X := X;
  Point.Y := Y;
  Append(Point);
end;

procedure TChartSeries.AddValue(Y: Double);
begin
  if FCount = 0 then
    AddPoint(0, Y)
  else
    AddPoint(LastX + 1, Y);
end;

procedure TChartSeries.AddCategoryValue(const Category: string; Value: Double);
var
  Point: TChartPoint;
begin
  Point := Default(TChartPoint);
  if FCount = 0 then
    Point.X := 0
  else
    Point.X := LastX + 1;
  Point.Y := Value;
  Point.Text := Category;
  Append(Point);
end;

procedure TChartSeries.AddSlice(const Name: string; Value: Double; SliceColor: TColor);
begin
  AddCategoryValue(Name, Value);
  FPoints[FFirst + FCount - 1].Color := SliceColor;
end;

procedure TChartSeries.Clear;
begin
  FPoints := nil;
  FFirst := 0;
  FCount := 0;
  Changed;
end;

function TChartSeries.LastX: Double;
begin
  if FCount = 0 then
    Exit(0);
  Result := FPoints[FFirst + FCount - 1].X;
end;

function TChartSeries.NearestIndex(X: Double): LongInt;
var
  Low: LongInt;
  High: LongInt;
  Middle: LongInt;
begin
  if FCount = 0 then
    Exit(-1);
  { The first point at or after X, then whichever of it and the one
    before is nearer. }
  Low := 0;
  High := FCount - 1;
  while Low < High do
  begin
    Middle := (Low + High) div 2;
    if GetX(Middle) < X then
      Low := Middle + 1
    else
      High := Middle;
  end;
  Result := Low;
  if (Result > 0) and (Abs(GetX(Result - 1) - X) <= Abs(GetX(Result) - X)) then
    Dec(Result);
end;

procedure TChartSeries.SetName(const Value: string);
begin
  FName := Value;
  Changed;
end;

procedure TChartSeries.SetKind(Value: TChartSeriesKind);
begin
  FKind := Value;
  Changed;
end;

procedure TChartSeries.SetColor(Value: TColor);
begin
  FColor := Value;
  Changed;
end;

procedure TChartSeries.SetVisible(Value: Boolean);
begin
  if FVisible = Value then
    Exit;
  FVisible := Value;
  Changed;
end;

procedure TChartSeries.SetShowMarkers(Value: Boolean);
begin
  FShowMarkers := Value;
  Changed;
end;

procedure TChartSeries.SetStepped(Value: Boolean);
begin
  FStepped := Value;
  Changed;
end;

procedure TChartSeries.SetStacked(Value: Boolean);
begin
  FStacked := Value;
  Changed;
end;

procedure TChartSeries.SetLineWidth(Value: Double);
begin
  FLineWidth := Value;
  Changed;
end;

procedure TChartSeries.SetMaxPoints(Value: LongInt);
begin
  if Value < 0 then
    Value := 0;
  FMaxPoints := Value;
  if (FMaxPoints > 0) and (FCount > FMaxPoints) then
    DropOldest(FCount - FMaxPoints);
  Changed;
end;

procedure TChartSeries.SetExplodedIndex(Value: LongInt);
begin
  FExplodedIndex := Value;
  Changed;
end;

procedure TChartSeries.SetHoleRatio(Value: Double);
begin
  if Value < 0 then
    Value := 0;
  if Value > MostHoleRatio then
    Value := MostHoleRatio;
  FHoleRatio := Value;
  Changed;
end;

end.
