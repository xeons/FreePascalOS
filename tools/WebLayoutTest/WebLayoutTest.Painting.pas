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
procedure CheckStickyPainting;
procedure CheckMaskPainting;
procedure CheckShadowPainting;
procedure CheckLayerPainting;
procedure CheckGaugePainting;
procedure ReportPerformance;

implementation

uses
  SysUtils, Math, DateUtils, TestChecks, Drawing.Colors, Drawing.Surfaces, Drawing.Rectangles, Web.Dom,
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

  { A sticky table of contents in a grid column (as Wikipedia's): it
    stays at the top while its column is in view, then leaves with it;
    a sticky header with a bottom inset inside a scroll container. }
  StickyPage =
    '<!doctype html><body style="margin:0;background:#ffffff">' +
    '<div style="display:grid;grid-template-columns:100px 1fr">' +
    '<div style="background:#eeeeee"><div id=toc style="position:sticky;top:10px;height:100px;background:#0000ff"></div></div>' +
    '<div style="height:2000px"></div></div>' +
    '<div style="height:1000px;background:#ff8000"></div>' +
    '<div id=scroller style="position:absolute;left:200px;top:0;width:80px;height:100px;overflow:hidden">' +
    '<div style="height:300px"></div><div style="position:sticky;bottom:0;height:20px;background:#00ff00"></div>' +
    '<div style="height:300px"></div></div></body>';

  { Masks: a gradient from opaque to transparent, an image that never
    loads (masks everything out), and a mask in a translucent group
    away from the surface's corner (groups are as small as their clip). }
  MaskPage =
    '<!doctype html><body style="margin:0;background:#ffffff">' +
    '<div style="width:100px;height:20px;background:#0000ff;mask-image:linear-gradient(to right, black, transparent)"></div>' +
    '<div style="width:100px;height:20px;background:#0000ff;-webkit-mask-image:url(nowhere.png)"></div>' +
    '<div style="margin:30px 0 0 150px;width:60px;height:20px;background:#ff0000;opacity:0.5;border-radius:4px"></div>' +
    '</body>';

  { A range's thumb at its value (129 x 16, a thumb of 16: its centre
    travels from 8 to 121), meters and a progress bar filled as far as
    their values. }
  GaugePage =
    '<!doctype html><body style="margin:0;background:#ffffff">' +
    '<div><input type=range min=0 max=10 value=10 style="margin:0"></div>' +
    '<div><input type=range min=0 max=10 value=0 style="margin:0"></div>' +
    '<div><meter value=0.25 style="width:100px;height:16px;display:block"></meter></div>' +
    '<div><progress value=3 max=4 style="width:100px;height:16px;display:block"></progress></div>' +
    '</body>';

  { A box shadow's blur and translucent text are blended in pixel values
    as other browsers do (a 0.2 black shadow 8px down with a 23px blur
    darkens the white just under the box to about 217; a fully covered
    pixel of 50% black text is 50% grey), not with the text gamma. }
  ShadowPage =
    '<!doctype html><body style="margin:0;background:#ffffff">' +
    '<div style="margin:50px;width:300px;height:100px;background:#ffffff;box-shadow:rgba(0,0,0,0.2) 0 8px 23px 0"></div>' +
    '<div style="font:100px/120px sans-serif;color:rgba(0,0,0,0.5);margin-left:50px">I</div>' +
    '</body>';

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
    { CSS 2 Appendix E: z-index 1 inside a position: relative box with
      z-index auto is in the root's stacking context, above the later
      opacity group (z-index auto). }
    CheckPixel(Surface, 60, 115, RgbColor(0, 255, 255), 'z-index 1 in a z-index auto box over a later stacking context');
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

procedure CheckGaugePainting;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
begin
  Layout := LayoutText(GaugePage, 300, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 300, 100, ColorBlack);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, 300, 100));
    CheckPixel(Surface, 121, 8, RgbColor($00, $75, $FF), 'a range at its maximum has its thumb at the end');
    CheckPixel(Surface, 8, 3, RgbColor(255, 255, 255), 'a range at its maximum has no thumb at the start');
    CheckPixel(Surface, 8, 27, RgbColor($00, $75, $FF), 'a range at its minimum has its thumb at the start');
    CheckPixel(Surface, 121, 19, RgbColor(255, 255, 255), 'a range at its minimum has no thumb at the end');
    CheckPixel(Surface, 15, 40, RgbColor($10, $7C, $10), 'a meter is filled up to its value');
    CheckPixel(Surface, 40, 40, RgbColor($E0, $E0, $E0), 'a meter is empty past its value');
    CheckPixel(Surface, 70, 62, RgbColor($10, $7C, $10), 'a progress bar is filled up to its value');
    CheckPixel(Surface, 85, 62, RgbColor($E0, $E0, $E0), 'a progress bar is empty past its value');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

procedure CheckStickyPainting;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
  Hit: THitTestResult;
begin
  Layout := LayoutText(StickyPage, 300, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 300, 600, ColorBlack);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, 300, 600));
    CheckPixel(Surface, 50, 5, RgbColor(238, 238, 238), 'sticky: above its inset at the top');
    CheckPixel(Surface, 50, 50, RgbColor(0, 0, 255), 'sticky: in place at the top');
    CheckPixel(Surface, 240, 90, RgbColor(0, 255, 0), 'sticky: bottom inset in a scroll container');
    Layout.SetScrollOffset(nil, 0, 1000);
    Painter.Paint(Surface, MakeRectangle(0, 0, 300, 600));
    CheckPixel(Surface, 50, 50, RgbColor(0, 0, 255), 'sticky: stays at its inset when scrolled');
    CheckPixel(Surface, 50, 200, RgbColor(238, 238, 238), 'sticky: its column below it');
    Hit := Painter.HitTest(50, 50);
    Check((Hit.Element <> nil) and (Hit.Element.GetAttribute('id') = 'toc'), 'sticky: hit where it is drawn');
    Layout.SetScrollOffset(nil, 0, 1950);
    Painter.Paint(Surface, MakeRectangle(0, 0, 300, 600));
    CheckPixel(Surface, 50, 5, RgbColor(0, 0, 255), 'sticky: pushed up by the end of its column');
    CheckPixel(Surface, 50, 49, RgbColor(0, 0, 255), 'sticky: bottom at the end of its column');
    CheckPixel(Surface, 50, 52, RgbColor(255, 128, 0), 'sticky: the page after its column');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

procedure CheckMaskPainting;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
begin
  Layout := LayoutText(MaskPage, 300, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 300, 600, ColorBlack);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, 300, 600));
    CheckPixel(Surface, 1, 10, RgbColor(2, 2, 255), 'mask: opaque end of a gradient mask');
    CheckPixel(Surface, 50, 10, RgbColor(126, 126, 255), 'mask: middle of a gradient mask');
    CheckPixel(Surface, 98, 10, RgbColor(250, 250, 255), 'mask: transparent end of a gradient mask');
    CheckPixel(Surface, 50, 30, RgbColor(255, 255, 255), 'mask: an image that is not there hides the box');
    CheckPixel(Surface, 180, 80, RgbColor(255, 128, 128), 'opacity group away from the corner');
    CheckPixel(Surface, 140, 80, RgbColor(255, 255, 255), 'opacity group: nothing outside it');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

procedure CheckShadowPainting;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
  X, Darkest: Integer;
begin
  Layout := LayoutText(ShadowPage, 400, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 400, 400, ColorBlack);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, 400, 400));
    CheckPixel(Surface, 200, 151, RgbColor(218, 218, 218), 'shadow: blur blended in pixel values');
    CheckPixel(Surface, 200, 190, RgbColor(253, 253, 253), 'shadow: fades out');
    Darkest := 255;
    for X := 50 to 150 do
      Darkest := Min(Darkest, RedOf(PixelAt(Surface, X, 260)));
    Check(Abs(Darkest - 128) <= 3, 'paint: translucent text: a covered pixel is half grey (' + IntToStr(Darkest) + ')');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

{ A menu with z-index 100 in a position: relative box (z-index auto) over
  a later flex item with z-index 1 (DuckDuckGo's suggestions under its
  page's wave); translations: an off-canvas drawer moved out with
  translateX(100%), a box centred with translate(-50%, -50%), the
  translate property; hit testing follows. }
procedure CheckLayerPainting;
const
  LayerPage =
    '<!doctype html><body style="margin:0;background:#ffffff">' +
    '<div style="position:relative;height:10px"><div id=menu style="position:absolute;z-index:100;top:0;left:0;' +
    'width:100px;height:100px;background:#ff0000"></div></div>' +
    '<div style="display:flex;position:relative"><div id=wave style="z-index:1;width:200px;height:50px;' +
    'background:#0000ff"></div></div>' +
    '<nav style="position:fixed;right:0;top:0;width:50px;height:300px;background:#00ff00;' +
    'transform:translateX(100%)"></nav>' +
    '<div style="position:absolute;left:150px;top:200px;width:40px;height:40px;background:#ff00ff;' +
    'transform:translate(-50%, -50%)"></div>' +
    '<div style="position:absolute;left:0;top:250px;width:20px;height:20px;background:#00ffff;translate:30px 5px"></div>' +
    '</body>';
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
begin
  Layout := LayoutText(LayerPage, 300, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 300, 300, ColorBlack);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, 300, 300));
    CheckPixel(Surface, 50, 30, RgbColor(255, 0, 0), 'layers: z-index 100 in a z-index auto box over a later z-index 1');
    CheckPixel(Surface, 150, 30, RgbColor(0, 0, 255), 'layers: the z-index 1 box beside it');
    Check(Painter.HitTest(50, 30).Element = Document.GetElementById('menu'), 'layers: the menu is hit over the box');
    CheckPixel(Surface, 290, 100, RgbColor(255, 255, 255), 'translate: a drawer moved out by translateX(100%)');
    CheckPixel(Surface, 135, 185, RgbColor(255, 0, 255), 'translate: centred with translate(-50%, -50%)');
    CheckPixel(Surface, 180, 230, RgbColor(255, 255, 255), 'translate: nothing where it was');
    CheckPixel(Surface, 40, 260, RgbColor(0, 255, 255), 'translate: the translate property');
    CheckPixel(Surface, 5, 252, RgbColor(255, 255, 255), 'translate: the translate property moved it');
  finally
    FreeSurface(Surface);
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
