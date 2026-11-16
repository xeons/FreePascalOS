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
  processor was, how much memory was in use.

  In a sunken box on the field colour, a light grid (a line every
  quarter up, every ten samples across) under the history: the newest
  sample at the right edge, older ones to the left, as a line with the
  area under it lightly filled, both anti-aliased (libdrawing). The
  caption (what it shows and the newest value: "CPU 37%") sits at the
  top left. Everything is measured at the window's scale, so the graph
  is as sharp and as thick at 150% as at 100%.
}
unit TaskManager.UsageGraph;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Controls.Base,
  TaskManager.History;

type
  TUsageGraph = class(TControl)
  private
    FHistory: PUsageHistory;
    FLineColor: TColor;
    procedure PaintGrid(const Canvas: TCanvas; Left, Top, Right, Bottom: LongInt);
    procedure PaintHistory(const Canvas: TCanvas; Left, Top, Right, Bottom: LongInt);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    constructor Create(AParent: TControl); override;
    { The history drawn (the caption is the control's Text). }
    property History: PUsageHistory read FHistory write FHistory;
    property LineColor: TColor read FLineColor write FLineColor;
  end;

const
  ProcessorLineColor = $FF2F6DB5;
  MemoryLineColor = $FF8A3FB0;

implementation

uses
  Drawing.Rectangles,
  Drawing.Bevels,
  Drawing.Rasterizer,
  Drawing.SmoothLines,
  Drawing.SmoothShapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Text;

const
  { Logical units: the line's width, the caption's margin. }
  LineWidth = 1.5;
  CaptionMargin = 4;
  { Samples between the grid's vertical lines. }
  SamplesPerGridLine = 10;
  { How strongly the grid and the filled area show over the field. }
  GridWeight = 40;
  AreaAlpha = 56;

constructor TUsageGraph.Create(AParent: TControl);
begin
  inherited Create(AParent);
  FLineColor := ProcessorLineColor;
end;

procedure TUsageGraph.PaintGrid(const Canvas: TCanvas; Left, Top, Right, Bottom: LongInt);
var
  GridColor: TColor;
  Quarter: LongInt;
  Line: LongInt;
  X: LongInt;
begin
  GridColor := MixColors(Theme.Field, FLineColor, GridWeight);
  for Quarter := 1 to 3 do
    DrawHorizontalLine(Canvas, Left, Right - 1, Top + (Bottom - Top) * Quarter div 4, GridColor);
  for Line := 1 to (HistoryLength - 1) div SamplesPerGridLine do
  begin
    X := Right - 1 - (Right - Left - 1) * Line * SamplesPerGridLine div (HistoryLength - 1);
    DrawVerticalLine(Canvas, X, Top, Bottom - 1, GridColor);
  end;
end;

procedure TUsageGraph.PaintHistory(const Canvas: TCanvas; Left, Top, Right, Bottom: LongInt);
var
  Points: array of TPrecisePoint;
  Area: array of TPrecisePoint;
  Count: LongInt;
  Age: LongInt;
  X: Double;
  Y: Double;
begin
  if (FHistory = nil) or (FHistory^.Count < 2) then
    Exit;
  Count := FHistory^.Count;
  SetLength(Points, Count);
  SetLength(Area, Count + 2);
  for Age := 0 to Count - 1 do
  begin
    { Oldest first, so the line runs left to right. }
    X := (Right - 1) - (Right - Left - 1) * Age / (HistoryLength - 1);
    Y := (Bottom - 1) - (Bottom - Top - 1) * SampleAt(FHistory^, Age) / 1000;
    Points[Count - 1 - Age] := PrecisePoint(X, Y);
  end;
  { The area: the line, then down to the bottom and back (rasterizer
    coordinates start at a pixel's corner, the line's at its centre). }
  for Age := 0 to Count - 1 do
    Area[Age] := PrecisePoint(Points[Age].X + 0.5, Points[Age].Y + 0.5);
  Area[Count] := PrecisePoint(Points[Count - 1].X + 0.5, Bottom);
  Area[Count + 1] := PrecisePoint(Points[0].X + 0.5, Bottom);
  FillSmoothPolygon(Canvas, Area, WithAlpha(FLineColor, AreaAlpha));
  DrawSmoothPolyline(Canvas, Points, LineWidth * DisplayScale / 100, FLineColor);
end;

procedure TUsageGraph.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Plot: TRectangle;
  PlotCanvas: TCanvas;
  Caption: TRectangle;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  DrawBevel(Canvas, Box, SunkenBevel(Theme.Highlight, Theme.Light, Theme.Shadow, Theme.DarkShadow));
  Plot := InflateRectangle(Box, -2);
  if RectangleIsEmpty(Plot) then
    Exit;
  FillRectangle(Canvas, Plot, Theme.Field);
  PlotCanvas := Canvas;
  NarrowCanvasClip(PlotCanvas, Plot);
  PaintGrid(PlotCanvas, Plot.Left, Plot.Top, Plot.Right, Plot.Bottom);
  PaintHistory(PlotCanvas, Plot.Left, Plot.Top, Plot.Right, Plot.Bottom);
  Caption := MakeRectangle(Plot.Left + Scaled(CaptionMargin), Plot.Top + Scaled(CaptionMargin div 2),
    RectangleWidth(Plot) - 2 * Scaled(CaptionMargin), TextHeight(ControlFace));
  DrawTextInBox(PlotCanvas, ControlFace, Text, Caption, AlignTextLeft, Theme.FieldText);
end;

end.
