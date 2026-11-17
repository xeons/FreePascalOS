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
  A pie (or doughnut) chart: its slices anti-aliased (Drawing.
  SmoothArcs), each parted from the next by a thin line of the
  background, the exploded slice drawn out from the centre along its
  middle; the percentages inside the slices wide enough to hold them (in
  black or white, whichever reads on the slice), the names outside,
  beside the slices' middles.
}
unit Controls.ChartPiePainting;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.ChartModel,
  Controls.ChartStyle,
  Controls.ChartLayout;

{ HoverPoint is a slice to draw lit (-1: none). }
procedure PaintChartPie(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; HoverPoint: LongInt);
{ Where slice SliceIndex's centre is moved to (the pie's centre unless
  it is the exploded one). }
procedure SliceCentre(Model: TChartModel; const Layout: TChartLayout; SliceIndex: LongInt; out X, Y: Double);

implementation

uses
  Drawing.Colors,
  Drawing.Rasterizer,
  Drawing.SmoothLines,
  Drawing.SmoothArcs,
  Controls.ChartSeries,
  Controls.ChartPalette;

const
  { Logical units. }
  SeparatorWidth = 1.5;
  OutsideLabelGap = 6;
  { The narrowest slice that holds its percentage, in degrees. }
  NarrowestLabelledSlice = 20;
  { Where an inside label sits, as a share of the radius (a pie). }
  InsideLabelRadius = 0.62;
  HoverLightening = 60;

function MiddleAngle(const Layout: TChartLayout; SliceIndex: LongInt): Double;
begin
  Result := Layout.Slices[SliceIndex].StartAngle + Layout.Slices[SliceIndex].SweepAngle / 2;
end;

procedure SliceCentre(Model: TChartModel; const Layout: TChartLayout; SliceIndex: LongInt; out X, Y: Double);
var
  Moved: TPrecisePoint;
begin
  X := Layout.PieCentreX;
  Y := Layout.PieCentreY;
  if (Layout.ExplodeDistance > 0) and (Length(Layout.Slices) > 1) and
    (Layout.Slices[SliceIndex].PointIndex = Model[Layout.PieSeries].ExplodedIndex) then
  begin
    Moved := PointOnCircle(X, Y, Layout.ExplodeDistance, MiddleAngle(Layout, SliceIndex));
    X := Moved.X;
    Y := Moved.Y;
  end;
end;

{ The thin background lines at both edges of a slice (centre
  coordinates are half a pixel before the rasterizer's). }
procedure PaintSeparators(const Canvas: TCanvas; const Layout: TChartLayout; const Style: TChartStyle;
  CentreX, CentreY: Double; SliceIndex: LongInt);
var
  Edge: LongInt;
  Angle: Double;
  Inner: TPrecisePoint;
  Outer: TPrecisePoint;
  Width: Double;
begin
  Width := ChartPixelsExact(Style, SeparatorWidth);
  for Edge := 0 to 1 do
  begin
    Angle := Layout.Slices[SliceIndex].StartAngle + Edge * Layout.Slices[SliceIndex].SweepAngle;
    Inner := PointOnCircle(CentreX - 0.5, CentreY - 0.5, Layout.PieInnerRadius, Angle);
    Outer := PointOnCircle(CentreX - 0.5, CentreY - 0.5, Layout.PieRadius + 1, Angle);
    DrawSmoothLine(Canvas, Inner.X, Inner.Y, Outer.X, Outer.Y, Width, Style.Background);
  end;
end;

procedure PaintInsideLabel(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; SliceIndex: LongInt; CentreX, CentreY: Double; Fill: TColor);
var
  Text: string;
  Radius: Double;
  Anchor: TPrecisePoint;
begin
  Text := SliceLabel(Model, Layout, SliceIndex, False);
  if (Text = '') or (Layout.Slices[SliceIndex].SweepAngle < NarrowestLabelledSlice) then
    Exit;
  if Layout.PieInnerRadius > 0 then
    Radius := (Layout.PieRadius + Layout.PieInnerRadius) / 2
  else
    Radius := Layout.PieRadius * InsideLabelRadius;
  { Too small a pie for words in it. }
  if Layout.PieRadius - Layout.PieInnerRadius < ChartTextHeight(Style.LabelFace) * 3 div 2 then
    Exit;
  Anchor := PointOnCircle(CentreX, CentreY, Radius, MiddleAngle(Layout, SliceIndex));
  DrawChartText(Canvas, Style.LabelFace, Round(Anchor.X) - ChartTextWidth(Style.LabelFace, Text) div 2,
    Round(Anchor.Y) - ChartTextHeight(Style.LabelFace) div 2, Text, ContrastingTextColor(Fill));
end;

procedure PaintOutsideLabel(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; SliceIndex: LongInt; CentreX, CentreY: Double);
var
  Text: string;
  Angle: Double;
  Anchor: TPrecisePoint;
  X: LongInt;
  Y: LongInt;
  Width: LongInt;
  Height: LongInt;
begin
  Text := SliceLabel(Model, Layout, SliceIndex, True);
  if Text = '' then
    Exit;
  Angle := MiddleAngle(Layout, SliceIndex);
  Anchor := PointOnCircle(CentreX, CentreY, Layout.PieRadius + ChartPixels(Style, OutsideLabelGap), Angle);
  Width := ChartTextWidth(Style.LabelFace, Text);
  Height := ChartTextHeight(Style.LabelFace);
  { Beside the slice: to the right of a slice on the right half, to the
    left of one on the left, centred on the slice's middle line. }
  if Angle < 180 then
    X := Round(Anchor.X)
  else
    X := Round(Anchor.X) - Width;
  Y := Round(Anchor.Y - Height / 2);
  DrawChartText(Canvas, Style.LabelFace, X, Y, Text, Style.Foreground);
end;

procedure PaintChartPie(const Canvas: TCanvas; Model: TChartModel; const Layout: TChartLayout;
  const Style: TChartStyle; HoverPoint: LongInt);
var
  Series: TChartSeries;
  Index: LongInt;
  CentreX: Double;
  CentreY: Double;
  Fill: TColor;
  PieCanvas: TCanvas;
begin
  if not Layout.IsPie or (Length(Layout.Slices) = 0) then
    Exit;
  Series := Model[Layout.PieSeries];
  PieCanvas := Canvas;
  NarrowCanvasClip(PieCanvas, Layout.Inner);
  for Index := 0 to High(Layout.Slices) do
  begin
    SliceCentre(Model, Layout, Index, CentreX, CentreY);
    Fill := SliceColor(Series, Layout.Slices[Index].PointIndex, Style);
    if Layout.Slices[Index].PointIndex = HoverPoint then
      Fill := MixColors(Fill, $FFFFFFFF, HoverLightening);
    FillSmoothSector(PieCanvas, CentreX, CentreY, Layout.PieRadius, Layout.PieInnerRadius,
      Layout.Slices[Index].StartAngle, Layout.Slices[Index].SweepAngle, Fill);
  end;
  if Length(Layout.Slices) > 1 then
    for Index := 0 to High(Layout.Slices) do
    begin
      SliceCentre(Model, Layout, Index, CentreX, CentreY);
      PaintSeparators(PieCanvas, Layout, Style, CentreX, CentreY, Index);
    end;
  for Index := 0 to High(Layout.Slices) do
  begin
    SliceCentre(Model, Layout, Index, CentreX, CentreY);
    Fill := SliceColor(Series, Layout.Slices[Index].PointIndex, Style);
    PaintInsideLabel(PieCanvas, Model, Layout, Style, Index, CentreX, CentreY, Fill);
    PaintOutsideLabel(PieCanvas, Model, Layout, Style, Index, CentreX, CentreY);
  end;
end;

end.
