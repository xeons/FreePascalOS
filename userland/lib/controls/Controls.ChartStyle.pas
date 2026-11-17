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
  How a chart looks: its colours, its fonts and the scale it is drawn
  at. The chart control fills one in from the theme and the window's
  scale (Controls.Charts); a host test fills one in by hand. Every size
  in the chart's units is in logical units, made pixels here, so a chart
  at 200% has lines, gaps and text twice as big.

  Text goes through libfont directly (not Controls.Text), so the chart's
  drawing builds on the host too; without a face (nil) text is left out
  and measures nothing.
}
unit Controls.ChartStyle;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Canvas,
  Drawing.Bevels,
  Font.Faces,
  Controls.ChartSeries,
  Controls.ChartModel;

type
  TChartStyle = record
    { Percent: 100 at 96 dots per inch. }
    ScalePercent: LongWord;
    { The plot's background and the chart's text. }
    Background: TColor;
    Foreground: TColor;
    { Labels and other quieter text, grid lines, the axes' lines. }
    QuietText: TColor;
    Grid: TColor;
    AxisLine: TColor;
    Tooltip: TColor;
    TooltipText: TColor;
    { The sunken box of a framed chart. }
    Frame: TBevelColors;
    LabelFace: PFontFace;
    TitleFace: PFontFace;
  end;

{ A style with fixed colours (black on white, the default theme's
  edges) at ScalePercent and the given faces. }
function PlainChartStyle(ScalePercent: LongWord; LabelFace, TitleFace: PFontFace): TChartStyle;
{ Logical units to pixels, rounded; at least 1 for a size above 0. }
function ChartPixels(const Style: TChartStyle; Logical: LongInt): LongInt;
function ChartPixelsExact(const Style: TChartStyle; Logical: Double): Double;
function ChartTextWidth(Face: PFontFace; const Text: string): LongInt;
function ChartTextHeight(Face: PFontFace): LongInt;
procedure DrawChartText(const Canvas: TCanvas; Face: PFontFace; X, Y: LongInt; const Text: string; Color: TColor);
{ Series SeriesIndex's colour: its own or the palette's. }
function SeriesColor(Model: TChartModel; SeriesIndex: LongInt; const Style: TChartStyle): TColor;
{ A pie slice's colour: its own or the palette's for its place. }
function SliceColor(Series: TChartSeries; PointIndex: LongInt; const Style: TChartStyle): TColor;

implementation

uses
  Font.Text,
  Controls.ChartPalette;

function PlainChartStyle(ScalePercent: LongWord; LabelFace, TitleFace: PFontFace): TChartStyle;
begin
  Result.ScalePercent := ScalePercent;
  Result.Background := $FFFFFFFF;
  Result.Foreground := $FF000000;
  Result.QuietText := $FF505050;
  Result.Grid := $FFE4E4E4;
  Result.AxisLine := $FF8C8C8C;
  Result.Tooltip := $FFF4EFD8;
  Result.TooltipText := $FF000000;
  Result.Frame := SunkenBevel($FFFFFFFF, $FFE2DED6, $FF7E7A72, $FF35322D);
  Result.LabelFace := LabelFace;
  Result.TitleFace := TitleFace;
end;

function ChartPixels(const Style: TChartStyle; Logical: LongInt): LongInt;
begin
  if Logical >= 0 then
    Result := (Logical * LongInt(Style.ScalePercent) + 50) div 100
  else
    Result := -((-Logical * LongInt(Style.ScalePercent) + 50) div 100);
  if (Logical > 0) and (Result < 1) then
    Result := 1;
end;

function ChartPixelsExact(const Style: TChartStyle; Logical: Double): Double;
begin
  Result := Logical * Style.ScalePercent / 100;
end;

function ChartTextWidth(Face: PFontFace; const Text: string): LongInt;
begin
  if (Face = nil) or (Text = '') then
    Exit(0);
  Result := MeasureText(Face^, Text);
end;

function ChartTextHeight(Face: PFontFace): LongInt;
begin
  if Face = nil then
    Exit(0);
  Result := Face^.Height;
end;

procedure DrawChartText(const Canvas: TCanvas; Face: PFontFace; X, Y: LongInt; const Text: string; Color: TColor);
begin
  if (Face = nil) or (Text = '') then
    Exit;
  DrawText(Canvas, Face^, X, Y, Text, Color);
end;

function SeriesColor(Model: TChartModel; SeriesIndex: LongInt; const Style: TChartStyle): TColor;
begin
  Result := Model[SeriesIndex].Color;
  if Result = 0 then
    Result := ChartPaletteColor(SeriesIndex, Style.Background);
end;

function SliceColor(Series: TChartSeries; PointIndex: LongInt; const Style: TChartStyle): TColor;
begin
  Result := Series.Points[PointIndex].Color;
  if Result = 0 then
    Result := ChartPaletteColor(PointIndex, Style.Background);
end;

end.
