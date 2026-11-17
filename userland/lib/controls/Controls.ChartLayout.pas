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
  Where the parts of a chart go in its rectangle, in pixels: the frame,
  the title, the legend, the axes' labels and titles, and the plot
  between them; the ranges the axes show; for a pie its centre and
  radius. Painting and finding what is under the pointer both work from
  this.

  From the outside in: the frame (a framed chart), a margin (none when
  nothing is drawn outside the plot, so a small graph fills its box),
  the title above, the legend (a column beside, or rows above or below),
  then the axes. The value axis (Y) is on the left and the X axis below,
  or the other way round for bars on their side (Horizontal). Ticks are
  as many as fit their labels: on an axis up the side every two lines
  of text, on one across as wide as the widest label and a
  gap. The left labels' width is measured from the range they get, so
  the plot is as wide as it can be.

  Pixel coordinates are of pixel centres, as for Drawing.SmoothLines:
  the lowest value is at the plot's bottom row, the highest at its top
  row; the X range runs from the first column to the last. For
  categories (bars, or every point with a name) each category gets an
  equal share of the plot, with its X in the middle of it.
}
unit Controls.ChartLayout;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Controls.ChartScale,
  Controls.ChartModel,
  Controls.ChartValues,
  Controls.ChartStyle,
  Controls.ChartLegend;

type
  TChartLayout = record
    Bounds: TRectangle;
    { Inside the frame. }
    Inner: TRectangle;
    Plot: TRectangle;
    TitleBox: TRectangle;
    { The axes' titles: the value axis' above the plot at the left
      (or below it for bars on their side), the X axis' below it. }
    LeftTitleBox: TRectangle;
    BottomTitleBox: TRectangle;
    Legend: TChartLegendItems;
    IsPie: Boolean;
    PieSeries: LongInt;
    Slices: TPieSlices;
    PieCentreX: Double;
    PieCentreY: Double;
    PieRadius: Double;
    PieInnerRadius: Double;
    ExplodeDistance: Double;
    Categorical: Boolean;
    Horizontal: Boolean;
    XRange: TAxisRange;
    YRange: TAxisRange;
    { Every how many categories a label is written (so they fit). }
    CategoryStride: LongInt;
  end;

procedure ComputeChartLayout(Model: TChartModel; const Style: TChartStyle; const Bounds: TRectangle;
  out Layout: TChartLayout);
{ The pixel (centre coordinates) along the value axis for Y, along the
  X axis for X (rows for bars on their side). }
function ValuePixel(const Layout: TChartLayout; Y: Double): Double;
function PositionPixel(const Layout: TChartLayout; X: Double): Double;
{ The value axis at Y in edge coordinates (the lowest value at the
  plot's bottom edge, the highest at its top edge): where bars end. }
function ValueEdge(const Layout: TChartLayout; Y: Double): Double;
{ Where bar PointIndex of series SeriesIndex is (empty if it is not
  shown): its place in its category, from its base to its top. }
function BarRectangle(Model: TChartModel; const Layout: TChartLayout; const Style: TChartStyle;
  SeriesIndex, PointIndex: LongInt): TRectangle;
{ The point (X, Y) on the screen. }
procedure PointPixel(const Layout: TChartLayout; X, Y: Double; out PixelX, PixelY: Double);
{ The X at screen pixel (PixelX, PixelY). }
function PositionAt(const Layout: TChartLayout; PixelX, PixelY: Double): Double;
{ How many pixels one unit of X spans (a category's width). }
function PositionUnitPixels(const Layout: TChartLayout): Double;
{ A tick's label on the X axis: the category's name, or the axis'
  label. }
function PositionLabel(Model: TChartModel; const Layout: TChartLayout; X: Double): string;
{ The text of a pie slice's label (by the model's PieLabels). }
function SliceLabel(Model: TChartModel; const Layout: TChartLayout; SliceIndex: LongInt; Outside: Boolean): string;

const
  { Logical units. }
  ChartMargin = 6;
  ChartFrameWidth = 2;
  ExplodeLogical = 8;
  { How much of a category its bars take (the rest is the gap between
    categories). }
  BarGroupShare = 0.75;

implementation

uses
  Math,
  Controls.ChartSeries,
  Controls.ChartFormat;

const
  { Logical units. }
  TitleGap = 4;
  LegendGap = 10;
  LabelGap = 5;
  TickWidthGap = 14;
  MinimumTickSpacing = 40;
  PieLabelGap = 8;

function PositionLabel(Model: TChartModel; const Layout: TChartLayout; X: Double): string;
begin
  if Layout.Categorical then
  begin
    Result := CategoryAt(Model, X);
    if Result = '' then
      Result := FormatChartNumber(X, 1);
  end
  else
    Result := Model.XAxis.TickLabel(Layout.XRange, X);
end;

function SliceLabel(Model: TChartModel; const Layout: TChartLayout; SliceIndex: LongInt; Outside: Boolean): string;
var
  Name: string;
  Share: string;
begin
  Name := Model[Layout.PieSeries].Points[Layout.Slices[SliceIndex].PointIndex].Text;
  Share := FormatShare(Layout.Slices[SliceIndex].Share);
  Result := '';
  case Model.PieLabels of
    PieLabelsPercent:
      if not Outside then
        Result := Share;
    PieLabelsNames:
      if Outside then
        Result := Name;
    PieLabelsNamesAndPercent:
      if Outside then
        Result := Name + ' ' + Share;
  end;
end;

function ValuePixel(const Layout: TChartLayout; Y: Double): Double;
begin
  with Layout do
    if Horizontal then
      Result := MapToPixels(Y, YRange.Minimum, YRange.Maximum, Plot.Left, Plot.Right - 1)
    else
      Result := MapToPixels(Y, YRange.Minimum, YRange.Maximum, Plot.Bottom - 1, Plot.Top);
end;

function PositionPixel(const Layout: TChartLayout; X: Double): Double;
begin
  with Layout do
    if Categorical then
    begin
      { Categories share the plot edge to edge, X in the middle of its
        share (pixel centres are half a pixel in). }
      if Horizontal then
        Result := MapToPixels(X, XRange.Minimum, XRange.Maximum, Plot.Top, Plot.Bottom) - 0.5
      else
        Result := MapToPixels(X, XRange.Minimum, XRange.Maximum, Plot.Left, Plot.Right) - 0.5;
    end
    else if Horizontal then
      Result := MapToPixels(X, XRange.Minimum, XRange.Maximum, Plot.Top, Plot.Bottom - 1)
    else
      Result := MapToPixels(X, XRange.Minimum, XRange.Maximum, Plot.Left, Plot.Right - 1);
end;

function ValueEdge(const Layout: TChartLayout; Y: Double): Double;
begin
  with Layout do
    if Horizontal then
      Result := MapToPixels(Y, YRange.Minimum, YRange.Maximum, Plot.Left, Plot.Right)
    else
      Result := MapToPixels(Y, YRange.Minimum, YRange.Maximum, Plot.Bottom, Plot.Top);
end;

{ The nearest whole pixel edge (halves up, not to even). }
function EdgeOf(Value: Double): LongInt;
begin
  Result := Floor(Value + 0.5);
end;

function BarRectangle(Model: TChartModel; const Layout: TChartLayout; const Style: TChartStyle;
  SeriesIndex, PointIndex: LongInt): TRectangle;
var
  Place: LongInt;
  Places: LongInt;
  GroupWidth: Double;
  Thickness: Double;
  Gap: Double;
  Centre: Double;
  Start: Double;
  Base: Double;
  Top: Double;
  Across0: LongInt;
  Across1: LongInt;
  Along0: LongInt;
  Along1: LongInt;
  Swap: LongInt;
begin
  Result := MakeRectangle(0, 0, 0, 0);
  Place := BarPlaceOf(Model, SeriesIndex);
  if Place < 0 then
    Exit;
  Places := BarPlaceCount(Model);
  GroupWidth := PositionUnitPixels(Layout) * BarGroupShare;
  Thickness := GroupWidth / Places;
  Gap := 0;
  if (Places > 1) and (Thickness > 4 * ChartPixels(Style, 1)) then
    Gap := ChartPixels(Style, 1);
  { Across the bar, in edge coordinates (a centre is half a pixel in). }
  Centre := PositionPixel(Layout, Model[SeriesIndex].X[PointIndex]) + 0.5;
  Start := Centre - GroupWidth / 2 + Place * Thickness;
  Across0 := EdgeOf(Start + Gap / 2);
  Across1 := EdgeOf(Start + Thickness - Gap / 2);
  if Across1 <= Across0 then
    Across1 := Across0 + 1;
  StackedPoint(Model, SeriesIndex, PointIndex, Base, Top);
  Along0 := EdgeOf(ValueEdge(Layout, Base));
  Along1 := EdgeOf(ValueEdge(Layout, Top));
  if Along1 < Along0 then
  begin
    Swap := Along0;
    Along0 := Along1;
    Along1 := Swap;
  end;
  { A value too small to see still shows a sliver. }
  if (Along1 = Along0) and (Top <> Base) then
    Along1 := Along0 + 1;
  if Layout.Horizontal then
    Result := MakeRectangle(Along0, Across0, Along1 - Along0, Across1 - Across0)
  else
    Result := MakeRectangle(Across0, Along0, Across1 - Across0, Along1 - Along0);
end;

procedure PointPixel(const Layout: TChartLayout; X, Y: Double; out PixelX, PixelY: Double);
begin
  if Layout.Horizontal then
  begin
    PixelX := ValuePixel(Layout, Y);
    PixelY := PositionPixel(Layout, X);
  end
  else
  begin
    PixelX := PositionPixel(Layout, X);
    PixelY := ValuePixel(Layout, Y);
  end;
end;

function PositionAt(const Layout: TChartLayout; PixelX, PixelY: Double): Double;
begin
  with Layout do
    if Categorical then
    begin
      if Horizontal then
        Result := MapFromPixels(PixelY + 0.5, XRange.Minimum, XRange.Maximum, Plot.Top, Plot.Bottom)
      else
        Result := MapFromPixels(PixelX + 0.5, XRange.Minimum, XRange.Maximum, Plot.Left, Plot.Right);
    end
    else if Horizontal then
      Result := MapFromPixels(PixelY, XRange.Minimum, XRange.Maximum, Plot.Top, Plot.Bottom - 1)
    else
      Result := MapFromPixels(PixelX, XRange.Minimum, XRange.Maximum, Plot.Left, Plot.Right - 1);
end;

function PositionUnitPixels(const Layout: TChartLayout): Double;
begin
  Result := Abs(PositionPixel(Layout, 1) - PositionPixel(Layout, 0));
end;

{ The widest label of the ticks of Range on an axis (names for
  categories). }
function WidestLabel(Model: TChartModel; const Layout: TChartLayout; const Style: TChartStyle;
  IsValueAxis: Boolean; const Range: TAxisRange): LongInt;
var
  Tick: LongInt;
  Text: string;
  Wide: LongInt;
begin
  Result := 0;
  for Tick := 0 to TickCount(Range) - 1 do
  begin
    if IsValueAxis then
      Text := Model.YAxis.TickLabel(Range, TickAt(Range, Tick))
    else
      Text := PositionLabel(Model, Layout, TickAt(Range, Tick));
    Wide := ChartTextWidth(Style.LabelFace, Text);
    if Wide > Result then
      Result := Wide;
  end;
end;

{ How many ticks fit Length pixels of an axis up the side, or across
  with labels Widest wide. }
function TicksAlongSide(const Style: TChartStyle; Length: LongInt): LongInt;
var
  Spacing: LongInt;
begin
  Spacing := Max(ChartTextHeight(Style.LabelFace) * 2, ChartPixels(Style, MinimumTickSpacing) div 2);
  Result := Max(1, Length div Max(1, Spacing));
end;

function TicksAcross(const Style: TChartStyle; Length, Widest: LongInt): LongInt;
var
  Spacing: LongInt;
begin
  Spacing := Max(Widest + ChartPixels(Style, TickWidthGap), ChartPixels(Style, MinimumTickSpacing));
  Result := Max(1, Length div Max(1, Spacing));
end;

function AnyThingOutsidePlot(Model: TChartModel; const Layout: TChartLayout): Boolean;
begin
  Result := ((Model.Title <> '') and (Model.TitlePlacement = TitleAbove)) or
    ((Model.LegendPosition <> LegendNone) and (Length(Layout.Legend) > 0)) or
    (not Layout.IsPie and (Model.XAxis.Visible or Model.YAxis.Visible));
end;

procedure PlaceLegend(Model: TChartModel; const Style: TChartStyle; var Layout: TChartLayout; var Content: TRectangle);
var
  Width: LongInt;
  Height: LongInt;
  Box: TRectangle;
  Gap: LongInt;
begin
  if (Model.LegendPosition = LegendNone) or (Length(Layout.Legend) = 0) then
    Exit;
  Gap := ChartPixels(Style, LegendGap);
  if Model.LegendPosition in [LegendLeft, LegendRight] then
    MeasureLegend(Layout.Legend, Style, Model.LegendPosition, RectangleWidth(Content) * 2 div 5, Width, Height)
  else
    MeasureLegend(Layout.Legend, Style, Model.LegendPosition, RectangleWidth(Content), Width, Height);
  case Model.LegendPosition of
    LegendRight:
      begin
        Box := MakeRectangle(Content.Right - Width, Content.Top + Max(0, (RectangleHeight(Content) - Height) div 2),
          Width, Height);
        Content.Right := Box.Left - Gap;
      end;
    LegendLeft:
      begin
        Box := MakeRectangle(Content.Left, Content.Top + Max(0, (RectangleHeight(Content) - Height) div 2), Width,
          Height);
        Content.Left := Box.Right + Gap;
      end;
    LegendTop:
      begin
        Box := MakeRectangle(Content.Left, Content.Top, RectangleWidth(Content), Height);
        Content.Top := Box.Bottom + Gap div 2;
      end;
  else
    begin
      Box := MakeRectangle(Content.Left, Content.Bottom - Height, RectangleWidth(Content), Height);
      Content.Bottom := Box.Top - Gap div 2;
    end;
  end;
  PlaceLegendItems(Layout.Legend, Style, Model.LegendPosition, Box);
end;

procedure LayOutPie(Model: TChartModel; const Style: TChartStyle; var Layout: TChartLayout);
var
  Series: TChartSeries;
  Widest: LongInt;
  Index: LongInt;
  Wide: LongInt;
  RoomX: Double;
  RoomY: Double;
  TextHeight: LongInt;
begin
  Series := Model[Layout.PieSeries];
  Layout.Slices := PieSlicesOf(Series);
  TextHeight := ChartTextHeight(Style.LabelFace);
  Widest := 0;
  for Index := 0 to High(Layout.Slices) do
  begin
    Wide := ChartTextWidth(Style.LabelFace, SliceLabel(Model, Layout, Index, True));
    if Wide > Widest then
      Widest := Wide;
  end;
  RoomX := RectangleWidth(Layout.Plot) / 2;
  RoomY := RectangleHeight(Layout.Plot) / 2;
  if Widest > 0 then
  begin
    RoomX := RoomX - Widest - ChartPixels(Style, PieLabelGap);
    { Labels above and below the pie stand beside its top and bottom:
      half a line each is enough. }
    RoomY := RoomY - TextHeight div 2 - ChartPixels(Style, PieLabelGap) div 2;
  end;
  Layout.PieRadius := Min(RoomX, RoomY) - ChartPixels(Style, 2);
  Layout.ExplodeDistance := 0;
  if (Series.ExplodedIndex >= 0) and (Series.ExplodedIndex < Series.Count) then
  begin
    Layout.ExplodeDistance := ChartPixels(Style, ExplodeLogical);
    Layout.PieRadius := Layout.PieRadius - Layout.ExplodeDistance;
  end;
  if Layout.PieRadius < 1 then
    Layout.PieRadius := 1;
  Layout.PieInnerRadius := Layout.PieRadius * Series.HoleRatio;
  Layout.PieCentreX := (Layout.Plot.Left + Layout.Plot.Right) / 2;
  Layout.PieCentreY := (Layout.Plot.Top + Layout.Plot.Bottom) / 2;
end;

function PositionRange(Model: TChartModel; const Layout: TChartLayout; const Extents: TValueExtents;
  MaximumTicks: LongInt): TAxisRange;
begin
  if Layout.Categorical then
    Result := MakeRange(Round(Extents.XMinimum) - 0.5, Round(Extents.XMaximum) + 0.5, 1)
  else
    Result := Model.XAxis.ResolvePositionRange(Extents.XMinimum, Extents.XMaximum, MaximumTicks);
end;

procedure LayOutAxes(Model: TChartModel; const Style: TChartStyle; var Layout: TChartLayout; Content: TRectangle);
var
  Extents: TValueExtents;
  TextHeight: LongInt;
  LeftIsValue: Boolean;
  LeftVisible: Boolean;
  BottomVisible: Boolean;
  LeftTitle: string;
  BottomTitle: string;
  LeftRange: TAxisRange;
  BottomRange: TAxisRange;
  LeftWidth: LongInt;
  Widest: LongInt;
  Ticks: LongInt;
  Gap: LongInt;
  Categories: LongInt;
  Room: Double;
begin
  Extents := ValueExtents(Model);
  TextHeight := ChartTextHeight(Style.LabelFace);
  Gap := ChartPixels(Style, LabelGap);
  LeftIsValue := not Layout.Horizontal;
  if LeftIsValue then
  begin
    LeftVisible := Model.YAxis.Visible;
    BottomVisible := Model.XAxis.Visible;
    LeftTitle := Model.YAxis.Title;
    BottomTitle := Model.XAxis.Title;
  end
  else
  begin
    LeftVisible := Model.XAxis.Visible;
    BottomVisible := Model.YAxis.Visible;
    LeftTitle := Model.XAxis.Title;
    BottomTitle := Model.YAxis.Title;
  end;
  { Rows: the left axis' title above, the bottom labels and title below;
    half a line at the top for the top label's upper half. }
  if LeftVisible and (LeftTitle <> '') then
  begin
    Layout.LeftTitleBox := MakeRectangle(Content.Left, Content.Top, RectangleWidth(Content), TextHeight);
    Content.Top := Content.Top + TextHeight + Gap;
  end
  else if LeftVisible then
    Content.Top := Content.Top + TextHeight div 2;
  if BottomVisible and (BottomTitle <> '') then
  begin
    Layout.BottomTitleBox := MakeRectangle(Content.Left, Content.Bottom - TextHeight, RectangleWidth(Content),
      TextHeight);
    Content.Bottom := Content.Bottom - TextHeight - Gap div 2;
  end;
  if BottomVisible then
    Content.Bottom := Content.Bottom - TextHeight - Gap;
  { The left axis' range and labels decide the plot's left edge. }
  Layout.Plot := Content;
  if LeftIsValue then
  begin
    LeftRange := Model.YAxis.ResolveRange(Extents.YMinimum, Extents.YMaximum,
      TicksAlongSide(Style, RectangleHeight(Content)));
    Layout.YRange := LeftRange;
  end
  else
  begin
    LeftRange := PositionRange(Model, Layout, Extents, TicksAlongSide(Style, RectangleHeight(Content)));
    Layout.XRange := LeftRange;
  end;
  LeftWidth := 0;
  if LeftVisible then
  begin
    LeftWidth := WidestLabel(Model, Layout, Style, LeftIsValue, LeftRange);
    { At most a third of the chart for names down the side. }
    LeftWidth := Min(LeftWidth, RectangleWidth(Content) div 3);
    Content.Left := Content.Left + LeftWidth + Gap;
  end;
  { The bottom axis: a first guess of the ticks, then as many as its
    widest label allows, and half that label's room at the right. }
  Ticks := TicksAcross(Style, RectangleWidth(Content), 0);
  if LeftIsValue then
    BottomRange := PositionRange(Model, Layout, Extents, Ticks)
  else
    BottomRange := Model.YAxis.ResolveRange(Extents.YMinimum, Extents.YMaximum, Ticks);
  Widest := WidestLabel(Model, Layout, Style, not LeftIsValue, BottomRange);
  if BottomVisible and not (LeftIsValue and Layout.Categorical) then
    Content.Right := Content.Right - Widest div 2;
  Ticks := TicksAcross(Style, RectangleWidth(Content), Widest);
  if LeftIsValue then
    BottomRange := PositionRange(Model, Layout, Extents, Ticks)
  else
    BottomRange := Model.YAxis.ResolveRange(Extents.YMinimum, Extents.YMaximum, Ticks);
  if LeftIsValue then
    Layout.XRange := BottomRange
  else
    Layout.YRange := BottomRange;
  Layout.Plot := Content;
  { Category labels: every one if there is room, else every so many. }
  Layout.CategoryStride := 1;
  if Layout.Categorical then
  begin
    Categories := Max(1, Round(Layout.XRange.Maximum - Layout.XRange.Minimum));
    if LeftIsValue then
    begin
      Room := RectangleWidth(Content) / Categories;
      Widest := WidestLabel(Model, Layout, Style, False, Layout.XRange) + Gap;
    end
    else
    begin
      Room := RectangleHeight(Content) / Categories;
      Widest := TextHeight + Gap div 2;
    end;
    if Room > 0 then
      Layout.CategoryStride := Max(1, Ceil(Widest / Room));
  end;
end;

procedure ComputeChartLayout(Model: TChartModel; const Style: TChartStyle; const Bounds: TRectangle;
  out Layout: TChartLayout);
var
  Content: TRectangle;
  TitleHeight: LongInt;
begin
  Layout := Default(TChartLayout);
  Layout.Bounds := Bounds;
  Layout.Horizontal := Model.Horizontal;
  Layout.PieSeries := ShownPieSeries(Model);
  Layout.IsPie := Layout.PieSeries >= 0;
  Layout.Categorical := not Layout.IsPie and IsCategorical(Model);
  Layout.Legend := BuildLegendItems(Model, Style);
  Layout.CategoryStride := 1;
  Layout.YRange := MakeRange(0, 1, 1);
  Layout.XRange := MakeRange(0, 1, 1);
  Layout.Inner := Bounds;
  if Model.Framed then
    Layout.Inner := InflateRectangle(Bounds, -ChartFrameWidth);
  Content := Layout.Inner;
  if AnyThingOutsidePlot(Model, Layout) then
    Content := InflateRectangle(Content, -ChartPixels(Style, ChartMargin));
  if (Model.Title <> '') and (Model.TitlePlacement = TitleAbove) then
  begin
    TitleHeight := ChartTextHeight(Style.TitleFace);
    Layout.TitleBox := MakeRectangle(Content.Left, Content.Top, RectangleWidth(Content), TitleHeight);
    Content.Top := Content.Top + TitleHeight + ChartPixels(Style, TitleGap);
  end;
  PlaceLegend(Model, Style, Layout, Content);
  if Content.Right < Content.Left then
    Content.Right := Content.Left;
  if Content.Bottom < Content.Top then
    Content.Bottom := Content.Top;
  Layout.Plot := Content;
  if Layout.IsPie then
    LayOutPie(Model, Style, Layout)
  else
    LayOutAxes(Model, Style, Layout, Content);
  if (Model.Title <> '') and (Model.TitlePlacement = TitleInside) then
    Layout.TitleBox := MakeRectangle(Layout.Plot.Left + ChartPixels(Style, 4), Layout.Plot.Top + ChartPixels(Style, 2),
      Max(0, RectangleWidth(Layout.Plot) - ChartPixels(Style, 8)), ChartTextHeight(Style.TitleFace));
end;

end.
