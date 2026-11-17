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
  A chart's legend: a swatch of colour and a name for each series (for
  a pie, each slice). Above or below the plot the entries run in rows,
  centred, as many to a row as fit; beside it they stand in a column.
  An entry whose series (or slice) is hidden is drawn faint, its swatch
  hollow: clicking an entry hides or shows what it stands for
  (Controls.Charts).
}
unit Controls.ChartLegend;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Canvas,
  Controls.ChartModel,
  Controls.ChartStyle;

type
  TChartLegendItem = record
    Text: string;
    Color: TColor;
    Shown: Boolean;
    SeriesIndex: LongInt;
    { The slice for a pie's entry, -1 for a series'. }
    PointIndex: LongInt;
    { Where it was placed (pixels, the chart's own). }
    Box: TRectangle;
  end;
  TChartLegendItems = array of TChartLegendItem;

function BuildLegendItems(Model: TChartModel; const Style: TChartStyle): TChartLegendItems;
{ The room the legend needs: a column beside the plot (at most
  MostWidth wide), or rows across Width above or below it. }
procedure MeasureLegend(const Items: TChartLegendItems; const Style: TChartStyle; Position: TChartLegendPosition;
  AvailableWidth: LongInt; out Width, Height: LongInt);
{ Gives every item its Box within Area. }
procedure PlaceLegendItems(var Items: TChartLegendItems; const Style: TChartStyle; Position: TChartLegendPosition;
  const Area: TRectangle);
procedure PaintLegend(const Canvas: TCanvas; const Items: TChartLegendItems; const Style: TChartStyle;
  HoverIndex: LongInt);
{ The item at (X, Y), -1 if none. }
function LegendItemAt(const Items: TChartLegendItems; X, Y: LongInt): LongInt;

implementation

uses
  Controls.ChartSeries,
  Controls.ChartValues;

const
  { Logical units. }
  SwatchSize = 10;
  SwatchGap = 5;
  ItemGap = 14;
  RowPadding = 4;

function BuildLegendItems(Model: TChartModel; const Style: TChartStyle): TChartLegendItems;
var
  PieIndex: LongInt;
  Series: TChartSeries;
  Index: LongInt;
begin
  Result := nil;
  PieIndex := ShownPieSeries(Model);
  if PieIndex >= 0 then
  begin
    Series := Model[PieIndex];
    SetLength(Result, Series.Count);
    for Index := 0 to Series.Count - 1 do
    begin
      Result[Index].Text := Series.Points[Index].Text;
      Result[Index].Color := SliceColor(Series, Index, Style);
      Result[Index].Shown := not Series.Hidden[Index];
      Result[Index].SeriesIndex := PieIndex;
      Result[Index].PointIndex := Index;
    end;
    Exit;
  end;
  SetLength(Result, Model.SeriesCount);
  for Index := 0 to Model.SeriesCount - 1 do
  begin
    Result[Index].Text := Model[Index].Name;
    Result[Index].Color := SeriesColor(Model, Index, Style);
    Result[Index].Shown := Model[Index].Visible;
    Result[Index].SeriesIndex := Index;
    Result[Index].PointIndex := -1;
  end;
end;

function RowHeight(const Style: TChartStyle): LongInt;
begin
  Result := ChartTextHeight(Style.LabelFace);
  if Result < ChartPixels(Style, SwatchSize) then
    Result := ChartPixels(Style, SwatchSize);
  Result := Result + ChartPixels(Style, RowPadding);
end;

function ItemWidth(const Item: TChartLegendItem; const Style: TChartStyle): LongInt;
begin
  Result := ChartPixels(Style, SwatchSize) + ChartPixels(Style, SwatchGap) + ChartTextWidth(Style.LabelFace, Item.Text);
end;

function IsColumn(Position: TChartLegendPosition): Boolean;
begin
  Result := Position in [LegendLeft, LegendRight];
end;

procedure MeasureLegend(const Items: TChartLegendItems; const Style: TChartStyle; Position: TChartLegendPosition;
  AvailableWidth: LongInt; out Width, Height: LongInt);
var
  Index: LongInt;
  RowWidth: LongInt;
  Rows: LongInt;
  Gap: LongInt;
  Wide: LongInt;
begin
  Width := 0;
  Height := 0;
  if (Length(Items) = 0) or (Position = LegendNone) then
    Exit;
  if IsColumn(Position) then
  begin
    for Index := 0 to High(Items) do
      if ItemWidth(Items[Index], Style) > Width then
        Width := ItemWidth(Items[Index], Style);
    if Width > AvailableWidth then
      Width := AvailableWidth;
    Height := Length(Items) * RowHeight(Style);
    Exit;
  end;
  Gap := ChartPixels(Style, ItemGap);
  Rows := 1;
  RowWidth := 0;
  for Index := 0 to High(Items) do
  begin
    Wide := ItemWidth(Items[Index], Style);
    if (RowWidth > 0) and (RowWidth + Gap + Wide > AvailableWidth) then
    begin
      Inc(Rows);
      RowWidth := 0;
    end;
    if RowWidth > 0 then
      RowWidth := RowWidth + Gap;
    RowWidth := RowWidth + Wide;
    if RowWidth > Width then
      Width := RowWidth;
  end;
  if Width > AvailableWidth then
    Width := AvailableWidth;
  Height := Rows * RowHeight(Style);
end;

{ Items First to Last in one row, centred in Area at Top. }
procedure PlaceRow(var Items: TChartLegendItems; const Style: TChartStyle; First, Last, RowWidth, Top: LongInt;
  const Area: TRectangle);
var
  Index: LongInt;
  X: LongInt;
  Wide: LongInt;
begin
  X := Area.Left + (RectangleWidth(Area) - RowWidth) div 2;
  if X < Area.Left then
    X := Area.Left;
  for Index := First to Last do
  begin
    Wide := ItemWidth(Items[Index], Style);
    Items[Index].Box := MakeRectangle(X, Top, Wide, RowHeight(Style));
    X := X + Wide + ChartPixels(Style, ItemGap);
  end;
end;

procedure PlaceLegendItems(var Items: TChartLegendItems; const Style: TChartStyle; Position: TChartLegendPosition;
  const Area: TRectangle);
var
  Index: LongInt;
  First: LongInt;
  RowWidth: LongInt;
  Top: LongInt;
  Wide: LongInt;
  Gap: LongInt;
begin
  if Length(Items) = 0 then
    Exit;
  if IsColumn(Position) then
  begin
    for Index := 0 to High(Items) do
      Items[Index].Box := MakeRectangle(Area.Left, Area.Top + Index * RowHeight(Style), RectangleWidth(Area),
        RowHeight(Style));
    Exit;
  end;
  Gap := ChartPixels(Style, ItemGap);
  First := 0;
  RowWidth := 0;
  Top := Area.Top;
  for Index := 0 to High(Items) do
  begin
    Wide := ItemWidth(Items[Index], Style);
    if (RowWidth > 0) and (RowWidth + Gap + Wide > RectangleWidth(Area)) then
    begin
      PlaceRow(Items, Style, First, Index - 1, RowWidth, Top, Area);
      Top := Top + RowHeight(Style);
      First := Index;
      RowWidth := 0;
    end;
    if RowWidth > 0 then
      RowWidth := RowWidth + Gap;
    RowWidth := RowWidth + Wide;
  end;
  PlaceRow(Items, Style, First, High(Items), RowWidth, Top, Area);
end;

procedure PaintLegend(const Canvas: TCanvas; const Items: TChartLegendItems; const Style: TChartStyle;
  HoverIndex: LongInt);
var
  Index: LongInt;
  Swatch: TRectangle;
  Size: LongInt;
  TextColor: TColor;
  ItemCanvas: TCanvas;
begin
  Size := ChartPixels(Style, SwatchSize);
  for Index := 0 to High(Items) do
  begin
    ItemCanvas := Canvas;
    NarrowCanvasClip(ItemCanvas, Items[Index].Box);
    Swatch := MakeRectangle(Items[Index].Box.Left, Items[Index].Box.Top + (RectangleHeight(Items[Index].Box) - Size)
      div 2, Size, Size);
    if Items[Index].Shown then
    begin
      FillRectangle(ItemCanvas, Swatch, Items[Index].Color);
      TextColor := Style.Foreground;
    end
    else
    begin
      DrawRectangleOutline(ItemCanvas, Swatch, Items[Index].Color);
      TextColor := MixColors(Style.Background, Style.QuietText, 140);
    end;
    if Index = HoverIndex then
      TextColor := MixColors(TextColor, Items[Index].Color, 160);
    DrawChartText(ItemCanvas, Style.LabelFace, Swatch.Right + ChartPixels(Style, SwatchGap), Items[Index].Box.Top +
      (RectangleHeight(Items[Index].Box) - ChartTextHeight(Style.LabelFace)) div 2, Items[Index].Text, TextColor);
  end;
end;

function LegendItemAt(const Items: TChartLegendItems; X, Y: LongInt): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to High(Items) do
    if RectangleContainsPoint(Items[Index].Box, X, Y) then
      Exit(Index);
  Result := -1;
end;

end.
