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
  Transforms beyond translation (painted through the matrix, hit tested
  through its inverse, transformed bounds) and CSS animations and
  transitions sampled at fixed times of an injected clock.
}
unit WebLayoutTest.Transforms;

{$mode objfpc}
{$H+}

interface

procedure CheckTransforms;
procedure CheckAnimations;

implementation

uses
  SysUtils, TestChecks, Drawing.Colors, Drawing.Surfaces, Drawing.Rectangles, Web.Dom, Web.Html.Parser,
  Web.Layout.Document, Web.Layout.Resources, Web.Layout.Transforms, Web.Paint.Painter, Web.Style.Animations,
  WebLayoutTest.Pages;

const
  { A 100 x 20 bar turned a quarter about its centre (150, 60): it covers
    x 140..160, y 10..110. A box scaled twice about its top left. A
    skewed box. }
  TransformPage =
    '<!doctype html><body style="margin:0;background:#ffffff">' +
    '<div id=turned style="position:absolute;left:100px;top:50px;width:100px;height:20px;background:#ff0000;' +
    'transform:rotate(90deg)"></div>' +
    '<div id=scaled style="position:absolute;left:0;top:150px;width:20px;height:20px;background:#0000ff;' +
    'transform:scale(2);transform-origin:0 0"></div>' +
    '<div id=skewed style="position:absolute;left:100px;top:200px;width:40px;height:40px;background:#00ff00;' +
    'transform:skewX(45deg)"></div>' +
    '<div id=flat style="position:absolute;left:220px;top:150px;width:40px;height:40px;background:#000000;' +
    'transform:rotateY(60deg)"></div>' +
    '</body>';

  { Opacity from 0 to 1 over a second, linear, kept at the end; a
    transition of the background color over a second. }
  AnimationPage =
    '<!doctype html><head><style>' +
    '@keyframes appear { from { opacity: 0 } to { opacity: 1 } }' +
    '#fade { animation: appear 1s linear forwards; position:absolute; left:0; top:0; width:50px; height:50px;' +
    ' background:#000000 }' +
    '#move { position:absolute; left:100px; top:0; width:50px; height:50px; background:#000000;' +
    ' transition: background-color 1s linear }' +
    '#move.on { background:#ffffff }' +
    '#spin { animation: turn 4s linear infinite; position:absolute; left:0; top:100px; width:100px; height:10px;' +
    ' background:#0000ff }' +
    '@keyframes turn { to { transform: rotate(360deg) } }' +
    '</style></head><body style="margin:0;background:#ffffff">' +
    '<div id=fade></div><div id=move></div><div id=spin></div></body>';

type
  TTestClock = class
  public
    Time: Double;
    function Now: Double;
  end;

function TTestClock.Now: Double;
begin
  Result := Time;
end;

function Near(Actual, Expected: TColor; Tolerance: Integer): Boolean;
begin
  Result := (Abs(Integer(RedOf(Actual)) - RedOf(Expected)) <= Tolerance) and
    (Abs(Integer(GreenOf(Actual)) - GreenOf(Expected)) <= Tolerance) and
    (Abs(Integer(BlueOf(Actual)) - BlueOf(Expected)) <= Tolerance);
end;

procedure CheckPixelNear(const Surface: TSurface; X, Y: Integer; Expected: TColor; Tolerance: Integer;
  const Name: string);
var
  Actual: TColor;
begin
  Actual := GetSurfacePixel(Surface, X, Y) or $FF000000;
  if not Near(Actual, Expected, Tolerance) then
    WriteLn('  pixel (', X, ',', Y, ') is ', IntToHex(Actual, 8), ', expected ', IntToHex(Expected, 8));
  Check(Near(Actual, Expected, Tolerance), Name);
end;

procedure CheckTransforms;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
  Hit: THitTestResult;
  X, Y, Width, Height: Single;
begin
  Layout := LayoutText(TransformPage, 300, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 300, 300, ColorBlack);
  try
    Painter.Paint(Surface, MakeRectangle(0, 0, 300, 300));
    CheckPixelNear(Surface, 150, 20, RgbColor(255, 0, 0), 3, 'transform: rotate(90deg) paints the bar upright');
    CheckPixelNear(Surface, 110, 60, RgbColor(255, 255, 255), 3, 'transform: nothing where the bar was');
    CheckPixelNear(Surface, 35, 185, RgbColor(0, 0, 255), 3, 'transform: scale(2) from its top left');
    CheckPixelNear(Surface, 45, 195, RgbColor(255, 255, 255), 3, 'transform: past the scaled box');
    { skewX(45deg) about the centre (120, 220): the top row moves left by
      20, the bottom row right by 20. }
    CheckPixelNear(Surface, 85, 202, RgbColor(0, 255, 0), 3, 'transform: skewX moves the top left');
    CheckPixelNear(Surface, 155, 238, RgbColor(0, 255, 0), 3, 'transform: skewX moves the bottom right');
    CheckPixelNear(Surface, 105, 238, RgbColor(255, 255, 255), 3, 'transform: skewX leaves the bottom left');
    { rotateY(60deg) seen flat: half as wide about its centre (240). }
    CheckPixelNear(Surface, 240, 170, RgbColor(0, 0, 0), 3, 'transform: 3D flattened, centre');
    CheckPixelNear(Surface, 225, 170, RgbColor(255, 255, 255), 3, 'transform: 3D flattened, narrower');
    Hit := Painter.HitTest(150, 100);
    Check((Hit.Element <> nil) and (Hit.Element.GetAttribute('id') = 'turned'), 'transform: hit through the rotation');
    Hit := Painter.HitTest(110, 60);
    Check((Hit.Element = nil) or (Hit.Element.GetAttribute('id') <> 'turned'),
      'transform: no hit where the bar was before turning');
    Hit := Painter.HitTest(35, 185);
    Check((Hit.Element <> nil) and (Hit.Element.GetAttribute('id') = 'scaled'), 'transform: hit through the scale');
    Check(Layout.NodeBounds(Document.GetElementById('turned'), X, Y, Width, Height), 'transform: the bar has bounds');
    TransformRectangle(Layout.BoxOf(Document.GetElementById('turned')), X, Y, Width, Height);
    Check((Abs(X - 140) < 0.5) and (Abs(Y - 10) < 0.5) and (Abs(Width - 20) < 0.5) and (Abs(Height - 100) < 0.5),
      'transform: bounds of the turned bar (' + FloatToStr(X) + ' ' + FloatToStr(Y) + ' ' + FloatToStr(Width) + ' ' +
      FloatToStr(Height) + ')');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

procedure CheckAnimations;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
  Clock: TTestClock;
  Events: TPendingAnimationEventArray;
  Index: Integer;
  SawEnd, SawTransitionEnd: Boolean;

  procedure Frame(Time: Double);
  begin
    Clock.Time := Time;
    Layout.AdvanceAnimations;
    if Layout.NeedsUpdate then
      Layout.Update;
    Painter.Paint(Surface, MakeRectangle(0, 0, 200, 200));
  end;

begin
  Clock := TTestClock.Create;
  Document := ParseHtmlText(AnimationPage);
  Layout := TDocumentLayout.Create(Document, DocumentResourcesOf(Document));
  Layout.SetAnimationClock(@Clock.Now);
  Layout.SetViewport(200, 200, 1);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 200, 200, ColorBlack);
  try
    Frame(1000);
    CheckPixelNear(Surface, 25, 25, RgbColor(255, 255, 255), 3, 'animation: opacity 0 at the start');
    Check(Layout.AnimationsRunning, 'animation: running');
    Frame(1500);
    CheckPixelNear(Surface, 25, 25, RgbColor(128, 128, 128), 4, 'animation: half way at 0.5 s');
    Frame(1750);
    CheckPixelNear(Surface, 25, 25, RgbColor(64, 64, 64), 4, 'animation: three quarters at 0.75 s');
    Frame(2500);
    CheckPixelNear(Surface, 25, 25, RgbColor(0, 0, 0), 3, 'animation: kept at the end (forwards)');
    { The spinner: a quarter turn after one second. }
    Frame(2000);
    CheckPixelNear(Surface, 50, 140, RgbColor(0, 0, 255), 3, 'animation: a quarter turn after a second');
    CheckPixelNear(Surface, 10, 105, RgbColor(255, 255, 255), 3, 'animation: the turned bar left its place');
    Events := Layout.TakeAnimationEvents;
    SawEnd := False;
    for Index := 0 to High(Events) do
      if (Events[Index].Kind = aeAnimationEnd) and (Events[Index].Name = 'appear') then
        SawEnd := True;
    Check(SawEnd, 'animation: animationend collected');
    { A transition from black to white over a second. }
    Document.GetElementById('move').SetAttribute('class', 'on');
    Frame(3000);
    CheckPixelNear(Surface, 125, 25, RgbColor(0, 0, 0), 3, 'transition: starts from the old value');
    Frame(3500);
    CheckPixelNear(Surface, 125, 25, RgbColor(128, 128, 128), 4, 'transition: half way');
    Frame(4100);
    CheckPixelNear(Surface, 125, 25, RgbColor(255, 255, 255), 3, 'transition: at the new value after it');
    Events := Layout.TakeAnimationEvents;
    SawTransitionEnd := False;
    for Index := 0 to High(Events) do
      if (Events[Index].Kind = aeTransitionEnd) and (Events[Index].Name = 'background-color') then
        SawTransitionEnd := True;
    Check(SawTransitionEnd, 'transition: transitionend collected');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
    Clock.Free;
  end;
end;

end.
