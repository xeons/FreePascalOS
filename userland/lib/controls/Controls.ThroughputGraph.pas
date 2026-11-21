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
  Throughput graphs: how fast a long operation has gone over the whole
  of it, the speed (up) against how much was done (across), a filled
  area from a TTransferRateMeter's history (Controls.TransferRates) in
  the theme's progress colour, with the current speed as a line across
  it and faint lines at the quarters, in a sunken field. Drawn with
  libdrawing's anti-aliased shapes. Invalidate it after new samples.
}
unit Controls.ThroughputGraph;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Canvas,
  Controls.Base,
  Controls.TransferRates;

type
  TThroughputGraph = class(TControl)
  private
    FMeter: TTransferRateMeter;
    procedure SetMeter(Value: TTransferRateMeter);
  protected
    procedure Paint(var Canvas: TCanvas); override;
  public
    { The rates drawn (shared: the graph does not own it; nil: none). }
    property Meter: TTransferRateMeter read FMeter write SetMeter;
  end;

implementation

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Rasterizer,
  Drawing.SmoothLines,
  Drawing.SmoothShapes,
  Windowing.Theme,
  Windowing.Connection,
  Controls.Painting;

const
  { The top of the graph is this much above the highest rate. }
  Headroom = 1.15;
  GraphInset = 3;

procedure TThroughputGraph.SetMeter(Value: TTransferRateMeter);
begin
  FMeter := Value;
  Invalidate;
end;

procedure TThroughputGraph.Paint(var Canvas: TCanvas);
var
  Box: TRectangle;
  Area: TRectangle;
  Inner: TCanvas;
  Top: Double;
  Index: LongInt;
  Count: LongInt;
  Points: array of TPrecisePoint;
  Line: array of TPrecisePoint;
  Point: TRatePoint;
  Y: Double;
  Quarter: LongInt;
  Stroke: Double;
begin
  Box := MakeRectangle(0, 0, RectangleWidth(PixelBounds), RectangleHeight(PixelBounds));
  FillRectangle(Canvas, Box, Theme.Field);
  DrawSunkenBevel(Canvas, Box);
  Area := InflateRectangle(Box, -(BevelWidth + Scaled(GraphInset)));
  if (RectangleWidth(Area) <= 0) or (RectangleHeight(Area) <= 0) then
    Exit;
  Inner := Canvas;
  NarrowCanvasClip(Inner, Area);
  for Quarter := 1 to 3 do
    DrawHorizontalLine(Inner, Area.Left, Area.Right - 1, Area.Top + RectangleHeight(Area) * Quarter div 4,
      MixColors(Theme.Field, Theme.Shadow, 60));
  if (FMeter = nil) or (FMeter.HistoryCount = 0) then
    Exit;
  Top := FMeter.PeakRate * Headroom;
  if Top <= 0 then
    Top := 1;
  Count := FMeter.HistoryCount;
  Points := nil;
  Line := nil;
  SetLength(Points, Count + 2);
  SetLength(Line, Count);
  for Index := 0 to Count - 1 do
  begin
    Point := FMeter.History[Index];
    Line[Index].X := Area.Left + Point.Fraction * RectangleWidth(Area);
    Line[Index].Y := Area.Bottom - Point.BytesPerSecond / Top * RectangleHeight(Area);
    Points[Index + 1] := Line[Index];
  end;
  { Down to the bottom at both ends, from the start of the operation. }
  Points[0].X := Area.Left;
  Points[0].Y := Area.Bottom;
  Points[1].X := Area.Left;
  Points[Count + 1].X := Line[Count - 1].X;
  Points[Count + 1].Y := Area.Bottom;
  FillSmoothPolygon(Inner, Points, MixColors(Theme.Field, Theme.ProgressBlock, 120));
  Stroke := Scaled(100) / 100;
  if Count > 1 then
    DrawSmoothPolyline(Inner, Line, Stroke, Theme.ProgressBlock);
  { The speed now, across the whole graph. }
  Y := Area.Bottom - FMeter.BytesPerSecond / Top * RectangleHeight(Area);
  DrawSmoothLine(Inner, Area.Left, Y, Area.Right, Y, Stroke * 1.5, Theme.FaceText);
end;

end.
