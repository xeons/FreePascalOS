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
  Painting: pixels of boxes whose colors are known (backgrounds,
  borders, the canvas, z-order, opacity, clipping, scrolling, the
  device scale), a damaged rectangle painted alone equal to the same
  rectangle of a full paint, and the speed and memory of a large page.
}
unit WebLayoutTest.Painting;

{$mode objfpc}
{$H+}

interface

procedure CheckPainting;
procedure ReportPerformance;

implementation

uses
  SysUtils, DateUtils, TestChecks, Drawing.Colors, Drawing.Surfaces, Drawing.Rectangles, Web.Dom,
  Web.Layout.Document, Web.Layout.Boxes, Web.Paint.Painter, Web.Text.FontInstances, WebLayoutTest.Pages;

const
  ColorPage =
    '<!doctype html><body style="margin:0;background:#00ff00">' +
    '<div style="width:100px;height:40px;background:#ff0000;border:5px solid #0000ff"></div>' +
    '<div style="position:relative;height:60px">' +
    '  <div style="position:absolute;left:0;top:0;width:50px;height:50px;background:#ffff00;z-index:2"></div>' +
    '  <div style="position:absolute;left:20px;top:20px;width:50px;height:50px;background:#00ffff;z-index:1"></div>' +
    '</div>' +
    '<div style="height:30px;background:#000000;opacity:0.5"></div>' +
    '<div style="width:60px;height:30px;overflow:hidden"><div style="width:200px;height:30px;background:#ff00ff"></div></div>' +
    '<div style="height:600px"></div></body>';

function PixelAt(const Surface: TSurface; X, Y: Integer): TColor;
begin
  Result := GetSurfacePixel(Surface, X, Y) or $FF000000;
end;

function Near(Actual, Expected: TColor): Boolean;
begin
  Result := (Abs(Integer(RedOf(Actual)) - RedOf(Expected)) <= 3) and
    (Abs(Integer(GreenOf(Actual)) - GreenOf(Expected)) <= 3) and
    (Abs(Integer(BlueOf(Actual)) - BlueOf(Expected)) <= 3);
end;

procedure CheckPixel(const Surface: TSurface; X, Y: Integer; Expected: TColor; const Name: string);
var
  Actual: TColor;
begin
  Actual := PixelAt(Surface, X, Y);
  if not Near(Actual, Expected) then
    WriteLn('  pixel (', X, ',', Y, ') is ', IntToHex(Actual, 8), ', expected ', IntToHex(Expected, 8));
  Check(Near(Actual, Expected), 'paint: ' + Name);
end;

procedure CheckPainting;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface, Partial: TSurface;
  Damage: TRectangle;
  X, Y: Integer;
  Same: Boolean;
begin
  Layout := LayoutText(ColorPage, 300, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 300, 600, ColorBlack);
  CreateSurface(Partial, 300, 600, ColorBlack);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, 300, 600));
    CheckPixel(Surface, 50, 20, RgbColor(255, 0, 0), 'background');
    CheckPixel(Surface, 2, 2, RgbColor(0, 0, 255), 'border');
    CheckPixel(Surface, 200, 20, RgbColor(0, 255, 0), 'canvas from the body');
    CheckPixel(Surface, 30, 80, RgbColor(255, 255, 0), 'z-index 2 over z-index 1');
    CheckPixel(Surface, 60, 105, RgbColor(0, 255, 255), 'z-index 1 box');
    CheckPixel(Surface, 60, 115, RgbColor(0, 127, 127), 'a later stacking context (opacity) over z-index 1');
    CheckPixel(Surface, 100, 125, RgbColor(0, 128, 0), 'opacity 0.5 over the canvas');
    CheckPixel(Surface, 30, 155, RgbColor(255, 0, 255), 'inside the overflow clip');
    CheckPixel(Surface, 100, 155, RgbColor(0, 255, 0), 'outside the overflow clip');
    { A damaged rectangle alone. }
    Damage := MakeRectangle(10, 60, 80, 70);
    Painter.Paint(Partial, Damage);
    Same := True;
    for Y := Damage.Top to Damage.Bottom - 1 do
      for X := Damage.Left to Damage.Right - 1 do
        if GetSurfacePixel(Partial, X, Y) <> GetSurfacePixel(Surface, X, Y) then
          Same := False;
    Check(Same, 'paint: a damaged rectangle matches the full paint');
    Check(GetSurfacePixel(Partial, 5, 5) = ColorBlack, 'paint: nothing outside the damaged rectangle');
    { Scrolled. }
    Layout.SetScrollOffset(nil, 0, 50);
    Painter.Paint(Surface, MakeRectangle(0, 0, 300, 600));
    CheckPixel(Surface, 30, 30, RgbColor(255, 255, 0), 'scrolled viewport');
    { At twice the scale. }
    FreeSurface(Surface);
    Layout.SetScrollOffset(nil, 0, 0);
    Layout.SetViewport(300, 600, 2);
    Layout.Update;
    CreateSurface(Surface, 600, 1200, ColorBlack);
    Painter.Paint(Surface, MakeRectangle(0, 0, 600, 1200));
    CheckPixel(Surface, 100, 40, RgbColor(255, 0, 0), 'scale 2: background');
    CheckPixel(Surface, 5, 5, RgbColor(0, 0, 255), 'scale 2: border');
  finally
    FreeSurface(Surface);
    FreeSurface(Partial);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

procedure ReportPerformance;
var
  Html: string;
  Index: Integer;
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Started: TDateTime;
  LayoutMilliseconds, PaintMilliseconds: Int64;
  Surface: TSurface;
  BoxesBefore: Int64;
  Nodes: Integer;
  Node: TNode;
begin
  Html := '<!doctype html><style>p { margin: 4px 0 } .c { color: #333; padding: 2px; border-left: 3px solid #999 }' +
    ' span { font-weight: bold }</style><body>';
  for Index := 1 to 1000 do
    Html := Html + '<p class=c>Paragraph ' + IntToStr(Index) +
      ' with <span>some bold words</span> and a <a href="#">link</a> that wraps across a narrow column.</p>';
  BoxesBefore := LiveBoxCount;
  Started := Now;
  Layout := LayoutText(Html, 400, Document);
  LayoutMilliseconds := MilliSecondsBetween(Now, Started);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 400, 600, ColorWhite);
  try
    Started := Now;
    Painter.Paint(Surface, MakeRectangle(0, 0, 400, 600));
    PaintMilliseconds := MilliSecondsBetween(Now, Started);
    Nodes := 0;
    Node := Document;
    while Node <> nil do
    begin
      Inc(Nodes);
      Node := Node.NextInTree(Document);
    end;
    Check(Layout.DocumentHeight > 10000, 'large page laid out');
    WriteLn('perf layout of 1000 paragraphs (', Nodes, ' nodes): ', LayoutMilliseconds, ' ms, ',
      LiveBoxCount - BoxesBefore, ' boxes; display list ', Painter.DisplayList.Count, ' items, ',
      Painter.DisplayList.MemoryBytes div 1024, ' KB; first screen painted in ', PaintMilliseconds, ' ms');
    WriteLn('perf text measurements: ', MeasureCacheHits, ' from the cache, ', MeasureCacheMisses, ' measured');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

end.
