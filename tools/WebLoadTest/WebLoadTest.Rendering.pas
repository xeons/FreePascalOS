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
  A fetched page rendered end to end: a navigable whose sink is the
  layout's (Web.Loading.LayoutSink) loads a page with an external style
  sheet, an @import from a <style>, an <img>, a url() background and a
  web font (TrueType and WOFF) from the in-process site; the layout
  tree then has the sizes those resources give, the background's
  pixels are painted, and the web font measures as DejaVu Sans Mono.
}
unit WebLoadTest.Rendering;

{$mode objfpc}
{$H+}

interface

procedure RunRenderingTests;

implementation

uses
  Classes,
  SysUtils,
  TestChecks,
  Image.Model,
  Image.Codecs,
  Image.Files,
  Drawing.Surfaces,
  Drawing.Rectangles,
  Web.Dom,
  Web.Loading.Contexts,
  Web.Loading.LayoutSink,
  Web.Navigation.Navigables,
  Web.Layout.Resources,
  Web.Layout.Document,
  Web.Layout.Dump,
  Web.Paint.Painter,
  Web.Text.Fonts,
  Web.Text.Woff,
  WebLoadTest.Server;

type
  TRenderConditions = class
  public
    Navigable: TNavigable;
    Sink: TLayoutResourceSink;
    Document: TDocument;
    Layout: TDocumentLayout;
    function Complete: Boolean;
    function BackgroundArrived: Boolean;
    function ImportApplied: Boolean;
  end;

var
  Environment: TTestEnvironment;
  Conditions: TRenderConditions;

function TRenderConditions.Complete: Boolean;
begin
  Result := (Navigable.State = LoadingComplete) and Navigable.Loader.LoadFired;
end;

function TRenderConditions.BackgroundArrived: Boolean;
begin
  Result := (Sink.PendingStyleImageCount = 0) and (DocumentResourcesOf(Document).UrlImage('bg.png', '') <> nil);
end;

{ The <style> sheet's import is asked for when the styler parses it
  (the first layout) and applies once loaded. }
function TRenderConditions.ImportApplied: Boolean;
var
  X, Y, Width, Height: Single;
begin
  Layout.Update;
  Result := Layout.NodeBounds(Document.GetElementById('imported'), X, Y, Width, Height) and (Abs(Width - 77) < 0.01);
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

function BytesToText(const Bytes: TBytes): string;
begin
  Result := '';
  if Length(Bytes) > 0 then
    SetString(Result, PChar(@Bytes[0]), Length(Bytes));
end;

function ReadBig32(const Data: TBytes; Offset: Integer): LongWord;
begin
  Result := (LongWord(Data[Offset]) shl 24) or (LongWord(Data[Offset + 1]) shl 16) or
    (LongWord(Data[Offset + 2]) shl 8) or LongWord(Data[Offset + 3]);
end;

procedure PutBig32(var Data: TBytes; Offset: Integer; Value: LongWord);
begin
  Data[Offset] := Byte(Value shr 24);
  Data[Offset + 1] := Byte(Value shr 16);
  Data[Offset + 2] := Byte(Value shr 8);
  Data[Offset + 3] := Byte(Value);
end;

{ A WOFF 1 file of the sfnt's tables, stored (not compressed). }
function StoredWoff(const Sfnt: TBytes): TBytes;
var
  TableCount, Index, Entry, Source: Integer;
  Offset, Length_: LongWord;
  Position: Integer;
begin
  TableCount := (Sfnt[4] shl 8) or Sfnt[5];
  Position := 44 + TableCount * 20;
  Result := nil;
  SetLength(Result, Position);
  for Index := 0 to TableCount - 1 do
  begin
    Source := 12 + Index * 16;
    Offset := ReadBig32(Sfnt, Source + 8);
    Length_ := ReadBig32(Sfnt, Source + 12);
    Entry := 44 + Index * 20;
    SetLength(Result, Position + Integer((Length_ + 3) and not 3));
    FillChar(Result[Position], Integer((Length_ + 3) and not 3), 0);
    Move(Sfnt[Offset], Result[Position], Length_);
    Move(Sfnt[Source], Result[Entry], 4);
    PutBig32(Result, Entry + 4, Position);
    PutBig32(Result, Entry + 8, Length_);
    PutBig32(Result, Entry + 12, Length_);
    PutBig32(Result, Entry + 16, ReadBig32(Sfnt, Source + 4));
    Position := Length(Result);
  end;
  PutBig32(Result, 0, $774F4646);
  PutBig32(Result, 4, ReadBig32(Sfnt, 0));
  PutBig32(Result, 8, Length(Result));
  Result[12] := Byte(TableCount shr 8);
  Result[13] := Byte(TableCount);
  PutBig32(Result, 16, Length(Sfnt) + 16);
end;

procedure CheckWoff(const Sfnt: TBytes);
var
  Woff, Back: TBytes;
begin
  Woff := StoredWoff(Sfnt);
  Check(DetectWebFontKind(Woff) = WebFontWoff, 'woff: recognized');
  Back := WebFontToSfnt(Woff);
  Check((Length(Back) > 0) and (ReadBig32(Back, 0) = ReadBig32(Sfnt, 0)), 'woff: unwrapped to sfnt');
  Check(WebFontToSfnt(Sfnt) = Sfnt, 'woff: TrueType data passes as it is');
end;

function WidthOf(Layout: TDocumentLayout; Document: TDocument; const Id: string; out Height: Single): Single;
var
  X, Y: Single;
begin
  Result := -1;
  Height := -1;
  if not Layout.NodeBounds(Document.GetElementById(Id), X, Y, Result, Height) then
    Result := -1;
end;

procedure CheckRenderedPage;
var
  Navigable: TNavigable;
  Sink: TLayoutResourceSink;
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
  Dump: string;
  Width, Height, MonoWidth, SansWidth, WoffWidth, BoxX, BoxY: Single;
  Pixel: LongWord;
  FontBytes: TBytes;
begin
  FontBytes := ReadFileBytes('userland/fonts/dejavu-sans-mono/DejaVuSansMono.ttf');
  CheckWoff(FontBytes);
  Environment.Site.AddRoute('r.test/page.html', 200, 'Content-Type: text/html; charset=utf-8',
    '<!DOCTYPE html><html><head><link rel=stylesheet href=r.css>' +
    '<style>@import "imp.css"; #bg { width: 10px; height: 10px; background-image: url(bg.png) }</style>' +
    '</head><body style="margin:0"><div id=box>x</div><img id=pic src=pic.png><div id=bg></div>' +
    '<p id=imported>i</p><span id=sans>iiii</span> <span id=mono>iiii</span> <span id=wmono>iiii</span>' +
    '</body></html>');
  Environment.Site.AddRoute('r.test/r.css', 200, 'Content-Type: text/css',
    '#box { width: 123px; height: 45px } span { display: inline-block } ' +
    '@font-face { font-family: Testface; src: url(nothing.woff2) format("woff2"), url(face.ttf) format("truetype") } ' +
    '@font-face { font-family: Woffface; src: url(face.woff) format("woff") } ' +
    '#mono { font-family: Testface, sans-serif } #wmono { font-family: Woffface, sans-serif }');
  Environment.Site.AddRoute('r.test/imp.css', 200, 'Content-Type: text/css', '#imported { width: 77px }');
  Environment.Site.AddRoute('r.test/pic.png', 200, 'Content-Type: image/png', PngText(40, 30, $FF00FF00));
  Environment.Site.AddRoute('r.test/bg.png', 200, 'Content-Type: image/png', PngText(4, 4, $FFFF0000));
  Environment.Site.AddRoute('r.test/face.ttf', 200, 'Content-Type: font/ttf', BytesToText(FontBytes));
  Environment.Site.AddRoute('r.test/face.woff', 200, 'Content-Type: font/woff', BytesToText(StoredWoff(FontBytes)));
  Sink := TLayoutResourceSink.Create;
  Navigable := TNavigable.Create(Environment.Fetcher, Sink, DefaultLoadingSettings);
  Sink.AttachNavigable(Navigable);
  Conditions.Navigable := Navigable;
  Conditions.Sink := Sink;
  Layout := nil;
  Painter := nil;
  try
    Navigable.NavigateTo('https://r.test/page.html');
    Check(Environment.RunUntil(@Conditions.Complete), 'render: the page loads');
    Document := Navigable.ActiveDocument;
    Conditions.Document := Document;
    Sink.PrepareDocument(Document);
    Layout := TDocumentLayout.Create(Document);
    Layout.SetViewport(800, 600, 1);
    Layout.Update;
    Width := WidthOf(Layout, Document, 'box', Height);
    Check((Abs(Width - 123) < 0.01) and (Abs(Height - 45) < 0.01), 'render: the linked sheet applies (' +
      FloatToStr(Width) + 'x' + FloatToStr(Height) + ')');
    Conditions.Layout := Layout;
    Check(Environment.RunUntil(@Conditions.ImportApplied), 'render: the <style> sheet''s import applies');
    Width := WidthOf(Layout, Document, 'pic', Height);
    Check((Abs(Width - 40) < 0.01) and (Abs(Height - 30) < 0.01), 'render: the image has its natural size (' +
      FloatToStr(Width) + 'x' + FloatToStr(Height) + ')');
    Dump := DumpLayoutTree(Layout.Root);
    Check(Pos('replaced <img> at (0,45) size 40x30', Dump) > 0, 'render: the layout dump has the image');
    Check(Pos('block <div> at (0,0) size 123x45', Dump) > 0, 'render: the layout dump has the styled box');
    { The background was asked for by the layout; it comes later. }
    Check(Environment.RunUntil(@Conditions.BackgroundArrived), 'render: the url() image is fetched');
    Layout.Update;
    Painter := TDocumentPainter.Create(Layout);
    CreateSurface(Surface, 200, 200, $FFFFFFFF);
    try
      Painter.Paint(Surface, MakeRectangle(0, 0, 200, 200));
      Layout.NodeBounds(Document.GetElementById('bg'), BoxX, BoxY, Width, Height);
      Pixel := GetSurfacePixel(Surface, Round(BoxX + 5), Round(BoxY + 5));
      Check(Pixel and $FFFFFF = $FF0000, 'render: the background painted (' + IntToHex(Pixel, 8) + ')');
      Layout.NodeBounds(Document.GetElementById('pic'), BoxX, BoxY, Width, Height);
      Pixel := GetSurfacePixel(Surface, Round(BoxX + 20), Round(BoxY + 15));
      Check(Pixel and $FFFFFF = $00FF00, 'render: the image painted (' + IntToHex(Pixel, 8) + ')');
    finally
      FreeSurface(Surface);
    end;
    Check(WebFontLibrary.ResolveFamily('testface', False) = 'testface', 'render: the web font joined the library');
    Check(WebFontLibrary.ResolveFamily('woffface', False) = 'woffface', 'render: the WOFF font joined the library');
    SansWidth := WidthOf(Layout, Document, 'sans', Height);
    MonoWidth := WidthOf(Layout, Document, 'mono', Height);
    WoffWidth := WidthOf(Layout, Document, 'wmono', Height);
    Check(MonoWidth > SansWidth + 4, 'render: text measured with the web font (' + FloatToStr(SansWidth) + ' ' +
      FloatToStr(MonoWidth) + ')');
    Check(Abs(WoffWidth - MonoWidth) < 0.01, 'render: the WOFF face measures the same (' + FloatToStr(WoffWidth) + ')');
  finally
    Painter.Free;
    Layout.Free;
    if Navigable.ActiveDocument <> nil then
    begin
      Sink.DocumentGoing(Navigable.ActiveDocument);
      FreeDocumentResources(Navigable.ActiveDocument);
    end;
    Navigable.Free;
    Sink.Free;
  end;
end;

procedure RunRenderingTests;
begin
  WebFontDirectory := 'userland/fonts';
  ResetWebFontLibrary;
  Environment := TTestEnvironment.Create;
  Conditions := TRenderConditions.Create;
  try
    CheckRenderedPage;
  finally
    Conditions.Free;
    Environment.Free;
  end;
end;

end.
