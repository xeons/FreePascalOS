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
  A sample picture of the chart, with text (DejaVu Sans), for looking
  at: a line chart with markers, stacked areas of sizes in bytes,
  grouped bars and a pie with a slice drawn out, two by two, written as
  a PPM. It checks that the text fits too: drawing with the faces gives
  the same places as without for what does not depend on them.
}
unit ChartTest.Sample;

{$mode objfpc}
{$H+}

interface

{ Draws the sample at ScalePercent into Path; False if the fonts are not
  in Directory. }
function WriteChartSample(const FontDirectory, Path: string; ScalePercent: LongWord): Boolean;

implementation

uses
  SysUtils,
  Classes,
  Drawing.Colors,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Drawing.Canvas,
  Font.Faces,
  Font.TrueType,
  Font.OutlineFaces,
  Controls.ChartScale,
  Controls.ChartFormat,
  Controls.ChartSeries,
  Controls.ChartModel,
  Controls.ChartStyle,
  Controls.ChartLayout,
  Controls.ChartHitTesting,
  Controls.ChartPainting;

function ReadFileBytes(const Path: string; out Data: TBytes): Boolean;
var
  Stream: TFileStream;
begin
  Data := nil;
  Result := FileExists(Path);
  if not Result then
    Exit;
  Stream := TFileStream.Create(Path, fmOpenRead);
  try
    SetLength(Data, Stream.Size);
    if Length(Data) > 0 then
      Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
end;

function LoadFace(const Path: string; Size: LongInt; out Face: TFontFace): Boolean;
var
  Data: TBytes;
  Font: TTrueTypeFont;
  Scalable: TFontFace;
begin
  ClearFace(Face);
  ClearFace(Scalable);
  Font := nil;
  if ReadFileBytes(Path, Data) then
    Font := LoadTrueTypeFont(Data);
  Result := Font <> nil;
  if not Result then
    Exit;
  DescribeOutlineFont(Font, Scalable);
  MakeOutlineFace(Scalable, Size, Face);
end;

procedure WritePpm(const Surface: TSurface; const Path: string);
var
  Output: TFileStream;
  Header: string;
  Line: array of Byte;
  X: LongInt;
  Y: LongInt;
  Pixel: TColor;
begin
  Output := TFileStream.Create(Path, fmCreate);
  try
    Header := 'P6' + #10 + IntToStr(Surface.Width) + ' ' + IntToStr(Surface.Height) + #10 + '255' + #10;
    Output.WriteBuffer(Header[1], Length(Header));
    Line := nil;
    SetLength(Line, Surface.Width * 3);
    for Y := 0 to Surface.Height - 1 do
    begin
      for X := 0 to Surface.Width - 1 do
      begin
        Pixel := GetSurfacePixel(Surface, X, Y);
        Line[X * 3] := RedOf(Pixel);
        Line[X * 3 + 1] := GreenOf(Pixel);
        Line[X * 3 + 2] := BlueOf(Pixel);
      end;
      Output.WriteBuffer(Line[0], Length(Line));
    end;
  finally
    Output.Free;
  end;
end;

procedure FillLineChart(Model: TChartModel);
var
  Point: LongInt;
begin
  Model.Title := 'Temperature';
  Model.LegendPosition := LegendBottom;
  Model.XAxis.Title := 'Hour';
  Model.YAxis.Title := 'Degrees';
  Model.YAxis.IncludeZero := False;
  Model.AddSeries('Inside', SeriesLine).ShowMarkers := True;
  Model.AddSeries('Outside', SeriesLine).Stepped := True;
  for Point := 0 to 12 do
  begin
    Model[0].AddPoint(Point * 2, 20 + 2 * Sin(Point / 2));
    Model[1].AddPoint(Point * 2, 12 + 6 * Sin(Point / 3 - 1));
  end;
end;

procedure FillAreaChart(Model: TChartModel);
const
  Sizes: array[0..2, 0..5] of LongInt = ((40, 55, 70, 62, 90, 84), (20, 35, 30, 48, 52, 60), (12, 12, 14, 13, 15, 15));
  Names: array[0..2] of string = ('Programs', 'Cache', 'Kernel');
var
  Index: LongInt;
  Point: LongInt;
begin
  Model.Title := 'Memory';
  Model.LegendPosition := LegendTop;
  Model.XAxis.Format := ChartFormatDuration;
  Model.XAxis.TickBase := TickBaseTime;
  Model.YAxis.Format := ChartFormatBytes;
  Model.YAxis.TickBase := TickBaseBinary;
  for Index := 0 to 2 do
  begin
    Model.AddSeries(Names[Index], SeriesArea).Stacked := True;
    for Point := 0 to 5 do
      Model[Index].AddPoint(Point * 60, Sizes[Index, Point] * 1024.0 * 1024);
  end;
end;

procedure FillBarChart(Model: TChartModel);
const
  Sales: array[0..2, 0..3] of LongInt = ((12, 19, 15, 24), (8, 11, 17, 14), (5, 9, 7, 12));
  Names: array[0..2] of string = ('North', 'South', 'West');
  Quarters: array[0..3] of string = ('Q1', 'Q2', 'Q3', 'Q4');
var
  Index: LongInt;
  Quarter: LongInt;
begin
  Model.Title := 'Sales';
  Model.LegendPosition := LegendRight;
  for Index := 0 to 2 do
  begin
    Model.AddSeries(Names[Index], SeriesBar);
    for Quarter := 0 to 3 do
      Model[Index].AddCategoryValue(Quarters[Quarter], Sales[Index, Quarter]);
  end;
end;

procedure FillPieChart(Model: TChartModel);
var
  Series: TChartSeries;
begin
  Model.Title := 'Disk';
  Model.LegendPosition := LegendRight;
  Model.PieLabels := PieLabelsNamesAndPercent;
  Series := Model.AddSeries('Disk', SeriesPie);
  Series.AddCategoryValue('Programs', 42);
  Series.AddCategoryValue('Pictures', 25);
  Series.AddCategoryValue('Music', 18);
  Series.AddCategoryValue('Free', 15);
  Series.ExplodedIndex := 1;
  Series.HoleRatio := 0.45;
end;

function WriteChartSample(const FontDirectory, Path: string; ScalePercent: LongWord): Boolean;
var
  LabelFace: TFontFace;
  TitleFace: TFontFace;
  Surface: TSurface;
  Canvas: TCanvas;
  Style: TChartStyle;
  Models: array[0..3] of TChartModel;
  Index: LongInt;
  Width: LongInt;
  Height: LongInt;
  Layout: TChartLayout;
  Hover: TChartHit;
begin
  Result := LoadFace(IncludeTrailingPathDelimiter(FontDirectory) + 'DejaVuSans.ttf', 11 * ScalePercent div 100,
    LabelFace) and LoadFace(IncludeTrailingPathDelimiter(FontDirectory) + 'DejaVuSans-Bold.ttf',
    12 * ScalePercent div 100, TitleFace);
  if not Result then
    Exit;
  Style := PlainChartStyle(ScalePercent, @LabelFace, @TitleFace);
  Width := 320 * ScalePercent div 100;
  Height := 220 * ScalePercent div 100;
  CreateSurface(Surface, 2 * Width, 2 * Height, $FFCBC6BD);
  for Index := 0 to 3 do
    Models[Index] := TChartModel.Create;
  FillLineChart(Models[0]);
  FillAreaChart(Models[1]);
  FillBarChart(Models[2]);
  FillPieChart(Models[3]);
  for Index := 0 to 3 do
  begin
    BeginCanvas(Canvas, Surface);
    SetCanvasOrigin(Canvas, (Index mod 2) * Width, (Index div 2) * Height);
    NarrowCanvasClip(Canvas, MakeRectangle(4, 4, Width - 8, Height - 8));
    { The bars show a tooltip, as under the pointer. }
    Hover := NoChartHit;
    if Index = 2 then
    begin
      Hover.Kind := HitBar;
      Hover.SeriesIndex := 1;
      Hover.PointIndex := 2;
    end;
    PaintChart(Canvas, Models[Index], Style, MakeRectangle(4, 4, Width - 8, Height - 8), Hover, Layout);
    Models[Index].Free;
  end;
  WritePpm(Surface, Path);
  FreeSurface(Surface);
end;

end.
