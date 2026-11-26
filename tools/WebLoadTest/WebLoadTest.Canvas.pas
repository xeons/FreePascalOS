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
  A canvas on a fetched page, end to end: the page draws on a <canvas>,
  draws a loaded <img> on another (a same-origin one is readable, a
  cross-origin one taints the canvas: getImageData and toDataURL then
  throw SecurityError), and draws text with the system fonts. The
  layout shows the canvas's pixels through its image provider: after a
  layout update the element's image has them, the painter draws them,
  more drawing marks the layout out of date, and a new width gives a
  new image.
}
unit WebLoadTest.Canvas;

{$mode objfpc}
{$H+}

interface

procedure RunCanvasTests;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Drawing.Rectangles,
  Drawing.Surfaces,
  Image.Model,
  Image.Codecs,
  Image.Files,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.LayoutSink,
  Web.Layout.Resources,
  Web.Layout.Document,
  Web.Paint.Painter,
  Web.Navigation.Navigables,
  Web.Script.PageScripting,
  Web.Text.Fonts,
  WebLoadTest.Server;

type
  TCanvasConditions = class
  public
    Navigable: TNavigable;
    Console: string;
    procedure ConsoleMessage(const Level, Text: string);
    function Done: Boolean;
  end;

procedure TCanvasConditions.ConsoleMessage(const Level, Text: string);
begin
  Console := Console + Level + ': ' + Text + LineEnding;
end;

function TCanvasConditions.Done: Boolean;
var
  Output: TElement;
begin
  Result := False;
  if (Navigable.ActiveDocument = nil) then
    Exit;
  Output := Navigable.ActiveDocument.GetElementById('out');
  Result := (Output <> nil) and (Pos('done', Output.TextContent) > 0);
end;

function PngText(Width, Height: Integer; Color: LongWord): string;
var
  Image: TImage;
  Bytes: TBytes;
begin
  Image := TImage.Create(Width, Height);
  try
    Image.Fill(Color);
    Bytes := EncodeImage(Image, ImageFormatPng);
  finally
    Image.Free;
  end;
  SetString(Result, PChar(@Bytes[0]), Length(Bytes));
end;

const
  CanvasPage =
    '<!DOCTYPE html><body style="margin:0"><canvas id=c width=40 height=20></canvas>' +
    '<img id=pic src=pic.png><img id=far src="https://other.test/far.png"><p id=out>x</p><script>' +
    'var ctx = document.getElementById("c").getContext("2d");' +
    'ctx.fillStyle = "#f00"; ctx.fillRect(0, 0, 40, 20);' +
    'window.onload = function () {' +
    '  var results = [];' +
    '  var t = document.createElement("canvas").getContext("2d");' +
    '  t.canvas.width = 50; t.canvas.height = 40;' +
    '  t.drawImage(document.getElementById("pic"), 0, 0);' +
    '  var p = t.getImageData(5, 5, 1, 1).data;' +
    '  results.push("img " + p[0] + "," + p[1] + "," + p[2] + "," + p[3]);' +
    '  t.clearRect(0, 0, 50, 40);' +
    '  t.font = "20px sans-serif"; t.fillStyle = "#000"; t.fillText("Hi", 2, 30);' +
    '  var d = t.getImageData(0, 0, 50, 40).data, ink = 0;' +
    '  for (var i = 3; i < d.length; i += 4) if (d[i] > 0) ink++;' +
    '  var m = t.measureText("Hi");' +
    '  results.push("text " + (ink > 30) + " " + (m.actualBoundingBoxAscent > 10) + " " + (m.width > 15));' +
    '  t.drawImage(document.getElementById("far"), 0, 0);' +
    '  try { t.getImageData(0, 0, 1, 1); results.push("readable"); } catch (e) { results.push(e.name); }' +
    '  try { t.canvas.toDataURL(); results.push("exported"); } catch (e) { results.push(e.name); }' +
    '  document.getElementById("out").textContent = results.join(";") + " done";' +
    '};</script></body></html>';

function PixelAt(Painter: TDocumentPainter; X, Y: Integer): LongWord;
var
  Surface: TSurface;
begin
  CreateSurface(Surface, 100, 100, $FFFFFFFF);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, 100, 100));
    Result := GetSurfacePixel(Surface, X, Y) and $FFFFFF;
  finally
    FreeSurface(Surface);
  end;
end;

procedure CheckCanvasPage;
var
  Environment: TTestEnvironment;
  Conditions: TCanvasConditions;
  Sink: TLayoutResourceSink;
  Navigable: TNavigable;
  Executor: TPageScriptExecutor;
  Document: TDocument;
  Canvas: TElement;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Image: TImage;
  Text: string;
begin
  Environment := TTestEnvironment.Create;
  Conditions := TCanvasConditions.Create;
  Sink := TLayoutResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Sink.AttachNavigable(Navigable);
  Executor := TPageScriptExecutor.Create(Navigable);
  Executor.OnConsoleMessage := @Conditions.ConsoleMessage;
  Navigable.Executor := Executor;
  Conditions.Navigable := Navigable;
  Layout := nil;
  Painter := nil;
  try
    Environment.Site.AddRoute('c.test/page.html', 200, 'Content-Type: text/html', CanvasPage);
    Environment.Site.AddRoute('c.test/pic.png', 200, 'Content-Type: image/png', PngText(8, 8, $FF00FF00));
    Environment.Site.AddRoute('other.test/far.png', 200, 'Content-Type: image/png', PngText(4, 4, $FF0000FF));
    Navigable.NavigateTo('https://c.test/page.html');
    Check(Environment.RunUntil(@Conditions.Done), 'canvas: the page''s script finished (' +
      Trim(Conditions.Console) + ')');
    Document := Navigable.ActiveDocument;
    Text := Document.GetElementById('out').TextContent;
    Check(Pos('img 0,255,0,255;', Text) = 1, 'canvas: a same-origin image is drawn and readable (' + Text + ')');
    Check(Pos('text true true true;', Text) > 0, 'canvas: text is drawn and measured with the system fonts (' +
      Text + ')');
    Check(Pos('SecurityError;SecurityError done', Text) > 0,
      'canvas: a cross-origin image taints the canvas (' + Text + ')');
    Canvas := Document.GetElementById('c');
    Sink.PrepareDocument(Document);
    Layout := TDocumentLayout.Create(Document);
    Layout.SetViewport(400, 300, 1);
    Layout.Update;
    Image := DocumentResourcesOf(Document).ElementImage(Canvas);
    Check((Image <> nil) and (Image.Width = 40) and (Image.Height = 20) and (Image.GetPixel(10, 10) = $FFFF0000),
      'canvas: the layout took the canvas''s pixels');
    Painter := TDocumentPainter.Create(Layout);
    Check(PixelAt(Painter, 30, 10) = $FF0000, 'canvas: the canvas is painted (' +
      IntToHex(PixelAt(Painter, 30, 10), 6) + ')');
    Check(not Layout.NeedsUpdate, 'canvas: nothing to do once the pixels are taken');
    Executor.ContextOf(Document).Engine.Evaluate('ctx.fillStyle = "#00f"; ctx.fillRect(0, 0, 10, 10);', 'test');
    Check(Layout.NeedsUpdate, 'canvas: drawing again puts the layout out of date');
    Layout.Update;
    Check((PixelAt(Painter, 5, 5) = $0000FF) and (PixelAt(Painter, 30, 10) = $FF0000),
      'canvas: the new pixels are painted');
    Executor.ContextOf(Document).Engine.Evaluate('ctx.canvas.width = 60; ctx.fillRect(0, 0, 60, 20);', 'test');
    Layout.Update;
    Image := DocumentResourcesOf(Document).ElementImage(Canvas);
    Check((Image <> nil) and (Image.Width = 60), 'canvas: a new width gives a new image');
    Check(Pos('error', Conditions.Console) = 0, 'canvas: no errors on the console (' + Trim(Conditions.Console) + ')');
  finally
    Painter.Free;
    Layout.Free;
    if Navigable.ActiveDocument <> nil then
    begin
      Sink.DocumentGoing(Navigable.ActiveDocument);
      FreeDocumentResources(Navigable.ActiveDocument);
    end;
    Navigable.Free;
    Executor.Free;
    Sink.Free;
    Conditions.Free;
    Environment.Free;
  end;
end;

procedure RunCanvasTests;
begin
  WebFontDirectory := TestFontDirectory;
  ResetWebFontLibrary;
  CheckCanvasPage;
end;

end.
