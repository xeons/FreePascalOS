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
  libsvg and libdrawing's paths on the host: small SVG documents drawn
  and their pixels probed where each feature decides the colour (shapes,
  path data with arcs, fill rules, strokes with caps, joins and dashes,
  transforms, viewBox and preserveAspectRatio, opacity, currentColor,
  <style> sheets and the cascade, use and symbol, gradients, patterns,
  clip paths, masks, text, images from data: URLs, nested viewports,
  entities and namespaces), the natural sizes of SVG images and their
  renderings at other sizes.

  SvgTest FONTS                 runs the checks (DejaVu from FONTS)
  SvgTest FONTS IN.svg OUT.png W H  draws a file at W x H (for looking)
}
program SvgTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  TestChecks,
  Drawing.Colors,
  Drawing.Surfaces,
  Image.Model,
  Image.Codecs,
  Image.Files,
  Image.Surfaces,
  Image.Scalable,
  Svg.Fonts,
  Svg.Document,
  Svg.Renderer,
  Svg.Images;

const
  Transparent = $00000000;
  Red = $FFFF0000;
  Green = $FF008000;
  Lime = $FF00FF00;
  Blue = $FF0000FF;
  Black = $FF000000;
  White = $FFFFFFFF;

var
  Surface: TSurface;
  HaveSurface: Boolean = False;

function ChannelClose(A, B: Byte; Tolerance: Integer): Boolean;
begin
  Result := Abs(Integer(A) - Integer(B)) <= Tolerance;
end;

function ColorsClose(Actual, Expected: TColor; Tolerance: Integer): Boolean;
begin
  if (AlphaOf(Expected) = 0) then
    Exit(AlphaOf(Actual) <= Tolerance);
  Result := ChannelClose(AlphaOf(Actual), AlphaOf(Expected), Tolerance) and
    ChannelClose(RedOf(Actual), RedOf(Expected), Tolerance) and
    ChannelClose(GreenOf(Actual), GreenOf(Expected), Tolerance) and
    ChannelClose(BlueOf(Actual), BlueOf(Expected), Tolerance);
end;

procedure Draw(const Source: string; Width, Height: Integer);
var
  Document: TSvgDocument;
begin
  if HaveSurface then
    FreeSurface(Surface);
  HaveSurface := False;
  Document := LoadSvgDocumentFromText(Source);
  try
    HaveSurface := RenderSvgToSurface(Document, Width, Height, Width, Height, True, Surface);
  finally
    Document.Free;
  end;
end;

procedure Probe(X, Y: Integer; Expected: TColor; const Name: string; Tolerance: Integer = 3);
var
  Actual: TColor;
begin
  Actual := GetSurfacePixel(Surface, X, Y);
  Check(ColorsClose(Actual, Expected, Tolerance), Format('%s at (%d,%d): %.8x, wanted %.8x',
    [Name, X, Y, Int64(Actual), Int64(Expected)]));
end;

function SvgDocumentText(const Body: string): string;
begin
  Result := '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" ' +
    'width="100" height="100">' + Body + '</svg>';
end;

{ How many pixels of the area are not transparent. }
function PaintedCount(Left, Top, Right, Bottom: Integer): Integer;
var
  X, Y: Integer;
begin
  Result := 0;
  for Y := Top to Bottom - 1 do
    for X := Left to Right - 1 do
      if AlphaOf(GetSurfacePixel(Surface, X, Y)) > 64 then
        Inc(Result);
end;

procedure TestShapes;
begin
  Draw(SvgDocumentText('<rect x="10" y="10" width="80" height="80" fill="red"/>'), 100, 100);
  Probe(50, 50, Red, 'rect inside');
  Probe(5, 5, Transparent, 'rect outside');
  Probe(10, 10, Red, 'rect corner pixel');
  Probe(9, 50, Transparent, 'rect left edge');
  Draw(SvgDocumentText('<rect width="100" height="100" rx="30" fill="blue"/>'), 100, 100);
  Probe(1, 1, Transparent, 'rounded corner cut');
  Probe(50, 1, Blue, 'rounded top edge');
  Probe(50, 50, Blue, 'rounded inside');
  Draw(SvgDocumentText('<circle cx="50" cy="50" r="40" fill="lime"/>'), 100, 100);
  Probe(50, 50, Lime, 'circle centre');
  Probe(50, 12, Lime, 'circle top inside');
  Probe(50, 8, Transparent, 'circle top outside');
  Probe(10, 10, Transparent, 'circle corner');
  Draw(SvgDocumentText('<ellipse cx="50" cy="50" rx="40" ry="20" fill="black"/>'), 100, 100);
  Probe(50, 35, Black, 'ellipse inside');
  Probe(50, 25, Transparent, 'ellipse outside');
  Probe(85, 50, Black, 'ellipse wide');
  Draw(SvgDocumentText('<polygon points="10,10 90,10 90,90" fill="red"/>'), 100, 100);
  Probe(80, 30, Red, 'polygon inside');
  Probe(30, 80, Transparent, 'polygon outside');
  Draw(SvgDocumentText('<rect width="0" height="50" fill="red"/><rect width="-5" height="50" fill="red"/>'), 100, 100);
  Probe(0, 10, Transparent, 'rect of no width');
end;

procedure TestPaths;
begin
  Draw(SvgDocumentText('<path d="M10,10l80,0 0,80-80,0z" fill="blue"/>'), 100, 100);
  Probe(50, 50, Blue, 'relative implicit lines');
  Draw(SvgDocumentText('<path d="M10 50 A40 40 0 0 1 90 50 Z" fill="black"/>'), 100, 100);
  Probe(50, 20, Black, 'arc over the top');
  Probe(50, 80, Transparent, 'arc not below');
  Draw(SvgDocumentText('<path d="M10 50a40 40 0 0 0 80 0z" fill="black"/>'), 100, 100);
  Probe(50, 80, Black, 'relative arc below');
  Probe(50, 20, Transparent, 'relative arc not above');
  Draw(SvgDocumentText('<path fill-rule="evenodd" d="M10 10H90V90H10Z M30 30H70V70H30Z" fill="red"/>'), 100, 100);
  Probe(20, 20, Red, 'even-odd outer');
  Probe(50, 50, Transparent, 'even-odd hole');
  Draw(SvgDocumentText('<path d="M10 10H90V90H10Z M30 30H70V70H30Z" fill="red"/>'), 100, 100);
  Probe(50, 50, Red, 'non-zero same direction');
  Draw(SvgDocumentText('<path d="M10 10H90V90H10Z M30 30V70H70V30Z" fill="red"/>'), 100, 100);
  Probe(50, 50, Transparent, 'non-zero reversed hole');
  Draw(SvgDocumentText('<path d="M0 100 C 0 0, 100 0, 100 100 S 200 200 200 100" fill="black"/>'), 100, 100);
  Probe(50, 60, Black, 'cubic curve');
  Draw(SvgDocumentText('<path d="M0 100 Q 50 0 100 100 T 200 100" fill="black"/>'), 100, 100);
  Probe(50, 70, Black, 'quadratic curve');
  Probe(50, 40, Transparent, 'quadratic curve above');
  Draw(SvgDocumentText('<path d="M10 10 L 90 10 L 90 90 L 10 90 Z garbage L 0 0" fill="lime"/>'), 100, 100);
  Probe(50, 50, Lime, 'path kept before an error');
end;

procedure TestStrokes;
begin
  Draw(SvgDocumentText('<line x1="10" y1="50" x2="90" y2="50" stroke="black" stroke-width="10"/>'), 100, 100);
  Probe(50, 50, Black, 'line stroke');
  Probe(50, 46, Black, 'line stroke width');
  Probe(50, 40, Transparent, 'line stroke edge');
  Probe(7, 50, Transparent, 'butt cap');
  Draw(SvgDocumentText('<line x1="10" y1="50" x2="90" y2="50" stroke="black" stroke-width="10" stroke-linecap="square"/>'),
    100, 100);
  Probe(7, 50, Black, 'square cap');
  Draw(SvgDocumentText('<line x1="20" y1="50" x2="80" y2="50" stroke="black" stroke-width="20" stroke-linecap="round"/>'),
    100, 100);
  Probe(12, 50, Black, 'round cap');
  Probe(12, 42, Transparent, 'round cap corner');
  Draw(SvgDocumentText('<polyline points="20,80 50,20 80,80" fill="none" stroke="black" stroke-width="10"/>'), 100, 100);
  Probe(50, 14, Black, 'miter join');
  Draw(SvgDocumentText('<polyline points="20,80 50,20 80,80" fill="none" stroke="black" stroke-width="10" ' +
    'stroke-linejoin="bevel"/>'), 100, 100);
  Probe(50, 14, Transparent, 'bevel join');
  Probe(50, 19, Black, 'bevel join body');
  Draw(SvgDocumentText('<polyline points="20,80 50,20 80,80" fill="none" stroke="black" stroke-width="10" ' +
    'stroke-miterlimit="1.5"/>'), 100, 100);
  Probe(50, 14, Transparent, 'miter beyond its limit bevels');
  Draw(SvgDocumentText('<line x1="0" y1="50" x2="100" y2="50" stroke="black" stroke-width="10" stroke-dasharray="10 10"/>'),
    100, 100);
  Probe(5, 50, Black, 'first dash');
  Probe(15, 50, Transparent, 'first gap');
  Probe(25, 50, Black, 'second dash');
  Draw(SvgDocumentText('<line x1="0" y1="50" x2="100" y2="50" stroke="black" stroke-width="10" stroke-dasharray="10,10" ' +
    'stroke-dashoffset="10"/>'), 100, 100);
  Probe(5, 50, Transparent, 'dash offset gap');
  Probe(15, 50, Black, 'dash offset dash');
  Draw(SvgDocumentText('<line x1="0" y1="50" x2="100" y2="50" stroke="black" stroke-width="10" stroke-dasharray="5"/>'),
    100, 100);
  Probe(2, 50, Black, 'odd dash list');
  Probe(7, 50, Transparent, 'odd dash list gap');
  Draw(SvgDocumentText('<rect x="20" y="20" width="60" height="60" fill="red" stroke="blue" stroke-width="10"/>'), 100, 100);
  Probe(50, 50, Red, 'fill under stroke');
  Probe(20, 50, Blue, 'stroke on the edge');
  Probe(16, 50, Blue, 'stroke outside half');
  Probe(24, 50, Blue, 'stroke inside half');
  Draw(SvgDocumentText('<rect x="20" y="20" width="60" height="60" fill="red" stroke="blue" stroke-width="10" ' +
    'paint-order="stroke"/>'), 100, 100);
  Probe(24, 50, Red, 'paint-order stroke first');
  Probe(16, 50, Blue, 'paint-order stroke outside');
  Draw(SvgDocumentText('<g transform="scale(2)"><line x1="0" y1="25" x2="50" y2="25" stroke="black" stroke-width="5"/></g>'),
    100, 100);
  Probe(50, 46, Black, 'stroke scaled with its transform');
  Draw(SvgDocumentText('<g transform="scale(4)"><line x1="0" y1="12.5" x2="25" y2="12.5" stroke="black" stroke-width="2" ' +
    'vector-effect="non-scaling-stroke"/></g>'), 100, 100);
  Probe(50, 50, Black, 'non-scaling stroke');
  Probe(50, 47, Transparent, 'non-scaling stroke stays thin');
end;

procedure TestTransformsAndViewports;
begin
  Draw(SvgDocumentText('<rect width="20" height="20" fill="red" transform="translate(40,40)"/>'), 100, 100);
  Probe(50, 50, Red, 'translate');
  Probe(10, 10, Transparent, 'translate moved away');
  Draw(SvgDocumentText('<rect x="40" y="0" width="20" height="100" fill="red" transform="rotate(90 50 50)"/>'), 100, 100);
  Probe(10, 50, Red, 'rotate about a centre');
  Probe(50, 10, Transparent, 'rotate moved away');
  Draw(SvgDocumentText('<rect width="10" height="10" fill="red" transform="translate(10) scale(2)"/>'), 100, 100);
  Probe(25, 15, Red, 'transform list');
  Probe(5, 5, Transparent, 'transform list moved');
  Draw('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 10 10">' +
    '<rect x="5" y="5" width="5" height="5"/></svg>', 100, 100);
  Probe(75, 75, Black, 'viewBox scales');
  Probe(25, 25, Transparent, 'viewBox origin');
  Draw('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 10 10">' +
    '<rect width="10" height="10" fill="red"/></svg>', 200, 100);
  Probe(25, 50, Transparent, 'meet centred left');
  Probe(100, 50, Red, 'meet centred');
  Draw('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 10 10" ' +
    'preserveAspectRatio="xMinYMid"><rect width="10" height="10" fill="red"/></svg>', 200, 100);
  Probe(25, 50, Red, 'xMinYMid left');
  Probe(175, 50, Transparent, 'xMinYMid right');
  Draw('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 10 10" ' +
    'preserveAspectRatio="none"><rect width="10" height="10" fill="red"/></svg>', 200, 100);
  Probe(5, 50, Red, 'aspect ratio none');
  Probe(195, 50, Red, 'aspect ratio none right');
  Draw(SvgDocumentText('<svg x="50" y="50" width="50" height="50" viewBox="0 0 1 1"><rect width="1" height="1" fill="blue"/>' +
    '<rect x="-1" y="-1" width="1" height="1" fill="red"/></svg>'), 100, 100);
  Probe(75, 75, Blue, 'nested viewport');
  Probe(25, 25, Transparent, 'nested viewport clips');
  { An image drawn at twice its size is drawn again, crisp. }
  Draw(SvgDocumentText('<rect x="49" y="49" width="2" height="2" fill="red"/>'), 200, 200);
  Probe(99, 99, Red, 'drawn at twice the size');
  Probe(96, 96, Transparent, 'drawn at twice the size, sharp');
end;

procedure TestOpacityAndColors;
begin
  Draw(SvgDocumentText('<rect width="100" height="100" fill="red" opacity="0.5"/>'), 100, 100);
  Probe(50, 50, $80FF0000, 'opacity on a shape', 2);
  Draw(SvgDocumentText('<rect width="100" height="100" fill="red" fill-opacity="0.5"/>'), 100, 100);
  Probe(50, 50, $80FF0000, 'fill-opacity', 2);
  Draw(SvgDocumentText('<g opacity="0.5"><rect width="100" height="100" fill="red"/><rect width="50" height="100" ' +
    'fill="blue"/></g>'), 100, 100);
  Probe(25, 50, $800000FF, 'group opacity blends once', 2);
  Probe(75, 50, $80FF0000, 'group opacity other half', 2);
  Draw(SvgDocumentText('<rect width="100" height="100" fill="red" stroke="blue" stroke-width="20" opacity="0.5"/>'), 100, 100);
  Probe(50, 5, $800000FF, 'opacity with fill and stroke', 2);
  Draw('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" color="lime">' +
    '<rect width="100" height="100" fill="currentColor"/></svg>', 100, 100);
  Probe(50, 50, Lime, 'currentColor');
  Draw(SvgDocumentText('<rect width="100" height="100" fill="#00f"/>'), 100, 100);
  Probe(50, 50, Blue, 'short hex colour');
  Draw(SvgDocumentText('<rect width="100" height="100" fill="rgb(255 0 0 / 50%)"/>'), 100, 100);
  Probe(50, 50, $80FF0000, 'colour with alpha', 2);
  Draw(SvgDocumentText('<rect width="100" height="100" fill="none" stroke="none"/>'), 100, 100);
  Probe(50, 50, Transparent, 'no paint');
  Draw(SvgDocumentText('<rect width="100" height="100"/>'), 100, 100);
  Probe(50, 50, Black, 'black by default');
end;

procedure TestStyling;
begin
  Draw(SvgDocumentText('<style>.a { fill: #00f }</style><rect class="a" width="100" height="100"/>'), 100, 100);
  Probe(50, 50, Blue, 'class selector');
  Draw(SvgDocumentText('<rect width="100" height="100" fill="red" style="fill:#0f0"/>'), 100, 100);
  Probe(50, 50, Lime, 'style attribute over presentation attribute');
  Draw(SvgDocumentText('<style>rect { fill: blue }</style><rect width="100" height="100" fill="red"/>'), 100, 100);
  Probe(50, 50, Blue, 'sheet over presentation attribute');
  Draw(SvgDocumentText('<style><![CDATA[ g > #x { fill: lime } ]]></style><g><rect id="x" width="100" height="100"/></g>'),
    100, 100);
  Probe(50, 50, Lime, 'child and id selectors in CDATA');
  Draw(SvgDocumentText('<g fill="red"><rect width="100" height="100"/></g>'), 100, 100);
  Probe(50, 50, Red, 'inherited fill');
  Draw(SvgDocumentText('<g style="stroke:blue;stroke-width:20"><line x1="0" y1="50" x2="100" y2="50"/></g>'), 100, 100);
  Probe(50, 50, Blue, 'inherited stroke');
  Draw(SvgDocumentText('<rect width="100" height="100" fill="red" display="none"/>'), 100, 100);
  Probe(50, 50, Transparent, 'display none');
  Draw(SvgDocumentText('<g visibility="hidden"><rect width="50" height="100" fill="red"/><rect x="50" width="50" ' +
    'height="100" fill="blue" visibility="visible"/></g>'), 100, 100);
  Probe(25, 50, Transparent, 'visibility hidden');
  Probe(75, 50, Blue, 'visible inside hidden');
  Draw(SvgDocumentText('<text x="10" y="50" font-size="20" fill="red" style="font-size:40px">.</text>' +
    '<rect width="10" height="10" style="fill: var(--c, lime)"/>'), 100, 100);
  Probe(5, 5, Lime, 'var() with fallback');
end;

procedure TestUse;
begin
  Draw(SvgDocumentText('<defs><rect id="r" width="20" height="20"/></defs><use href="#r" x="40" y="40" fill="green"/>'),
    100, 100);
  Probe(50, 50, Green, 'use inherits from use');
  Probe(10, 10, Transparent, 'defs not drawn');
  Draw(SvgDocumentText('<defs><rect id="r" width="20" height="20" fill="blue"/></defs><use xlink:href="#r" x="40" y="40" ' +
    'fill="green"/>'), 100, 100);
  Probe(50, 50, Blue, 'xlink:href, own fill');
  Draw(SvgDocumentText('<symbol id="s" viewBox="0 0 10 10"><rect width="10" height="10"/></symbol>' +
    '<use href="#s" width="50" height="50"/>'), 100, 100);
  Probe(25, 25, Black, 'symbol through use');
  Probe(75, 75, Transparent, 'symbol size');
  Draw(SvgDocumentText('<symbol id="s"><rect width="10" height="10"/></symbol>'), 100, 100);
  Probe(5, 5, Transparent, 'symbol not drawn alone');
  Draw(SvgDocumentText('<style>.icon { fill: lime }</style><symbol id="s" viewBox="0 0 10 10"><path d="M0 0H10V10H0Z"/>' +
    '</symbol><use class="icon" href="#s" width="100" height="100"/>'), 100, 100);
  Probe(50, 50, Lime, 'symbol path inherits a class fill through use');
  Draw(SvgDocumentText('<g id="loop"><use href="#loop"/></g><rect width="10" height="10" fill="red"/>'), 100, 100);
  Probe(5, 5, Red, 'use cycle ignored');
end;

procedure TestGradients;
begin
  Draw(SvgDocumentText('<linearGradient id="g"><stop offset="0" stop-color="black"/><stop offset="1" stop-color="white"/>' +
    '</linearGradient><rect width="100" height="100" fill="url(#g)"/>'), 100, 100);
  Probe(0, 50, $FF010101, 'linear start', 4);
  Probe(50, 50, $FF808080, 'linear middle', 4);
  Probe(99, 50, $FFFEFEFE, 'linear end', 4);
  Draw(SvgDocumentText('<linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="red"/>' +
    '<stop offset="1" stop-color="blue"/></linearGradient><rect width="100" height="100" fill="url(#g)"/>'), 100, 100);
  Probe(50, 0, Red, 'vertical start', 6);
  Probe(50, 99, Blue, 'vertical end', 6);
  Draw(SvgDocumentText('<linearGradient id="a"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/>' +
    '</linearGradient><linearGradient id="b" href="#a" x2="0" y2="1"/><rect width="100" height="100" ' +
    'fill="url(#b)"/>'), 100, 100);
  Probe(50, 0, Red, 'href inherits stops', 6);
  Probe(0, 99, Blue, 'href own direction', 6);
  Draw(SvgDocumentText('<linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" x2="50" spreadMethod="reflect">' +
    '<stop offset="0" stop-color="black"/><stop offset="1" stop-color="white"/></linearGradient>' +
    '<rect width="100" height="100" fill="url(#g)"/>'), 100, 100);
  Probe(49, 50, $FFFAFAFA, 'reflect up', 8);
  Probe(99, 50, $FF050505, 'reflect back', 8);
  Draw(SvgDocumentText('<linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" x2="50" spreadMethod="repeat">' +
    '<stop offset="0" stop-color="black"/><stop offset="1" stop-color="white"/></linearGradient>' +
    '<rect width="100" height="100" fill="url(#g)"/>'), 100, 100);
  Probe(51, 50, $FF050505, 'repeat starts again', 8);
  Draw(SvgDocumentText('<linearGradient id="g" gradientTransform="rotate(90 0.5 0.5)"><stop offset="0" stop-color="red"/>' +
    '<stop offset="1" stop-color="blue"/></linearGradient><rect width="100" height="100" fill="url(#g)"/>'), 100, 100);
  Probe(50, 0, Red, 'gradientTransform', 6);
  Probe(50, 99, Blue, 'gradientTransform end', 6);
  Draw(SvgDocumentText('<radialGradient id="g"><stop offset="0" stop-color="white"/><stop offset="1" stop-color="black"/>' +
    '</radialGradient><rect width="100" height="100" fill="url(#g)"/>'), 100, 100);
  Probe(50, 50, White, 'radial centre', 6);
  Probe(1, 1, Black, 'radial padded corner', 2);
  Probe(50, 25, $FF808080, 'radial half way', 8);
  Draw(SvgDocumentText('<radialGradient id="g" fx="0.25"><stop offset="0" stop-color="white"/><stop offset="1" ' +
    'stop-color="black"/></radialGradient><rect width="100" height="100" fill="url(#g)"/>'), 100, 100);
  Probe(25, 50, White, 'radial focus', 8);
  Draw(SvgDocumentText('<linearGradient id="g"><stop offset="0" stop-color="red" stop-opacity="0"/><stop offset="1" ' +
    'stop-color="red"/></linearGradient><rect width="100" height="100" fill="url(#g)"/>'), 100, 100);
  Probe(50, 50, $80FF0000, 'stop-opacity', 4);
  Draw(SvgDocumentText('<rect width="100" height="100" fill="url(#missing) lime"/>'), 100, 100);
  Probe(50, 50, Lime, 'paint fallback');
  Draw(SvgDocumentText('<linearGradient id="g"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/>' +
    '</linearGradient><line x1="0" y1="50" x2="100" y2="50" stroke="url(#g)" stroke-width="10"/>'), 100, 100);
  Probe(50, 50, Transparent, 'bounding box gradient on a flat line draws nothing');
end;

procedure TestPatterns;
begin
  Draw(SvgDocumentText('<pattern id="p" width="20" height="20" patternUnits="userSpaceOnUse"><rect width="10" height="10" ' +
    'fill="red"/></pattern><rect width="100" height="100" fill="url(#p)"/>'), 100, 100);
  Probe(5, 5, Red, 'pattern tile');
  Probe(15, 5, Transparent, 'pattern gap');
  Probe(25, 25, Red, 'pattern repeats');
  Probe(85, 65, Red, 'pattern far');
  Draw(SvgDocumentText('<pattern id="p" width="0.5" height="0.5"><rect width="25" height="25" fill="blue"/></pattern>' +
    '<rect width="100" height="100" fill="url(#p)"/>'), 100, 100);
  Probe(10, 10, Blue, 'bounding box pattern');
  Probe(40, 10, Transparent, 'bounding box pattern gap');
  Probe(60, 60, Blue, 'bounding box pattern repeats');
  Draw(SvgDocumentText('<pattern id="p" width="50" height="50" patternUnits="userSpaceOnUse" viewBox="0 0 1 1">' +
    '<rect width="0.5" height="1" fill="lime"/></pattern><rect width="100" height="100" fill="url(#p)"/>'), 100, 100);
  Probe(10, 10, Lime, 'pattern viewBox');
  Probe(35, 10, Transparent, 'pattern viewBox gap');
end;

procedure TestClipsAndMasks;
begin
  Draw(SvgDocumentText('<clipPath id="c"><circle cx="50" cy="50" r="20"/></clipPath><rect width="100" height="100" ' +
    'fill="red" clip-path="url(#c)"/>'), 100, 100);
  Probe(50, 50, Red, 'clip inside');
  Probe(10, 10, Transparent, 'clip outside');
  Probe(50, 25, Transparent, 'clip circle edge');
  Draw(SvgDocumentText('<clipPath id="c" clipPathUnits="objectBoundingBox"><rect width="0.5" height="1"/></clipPath>' +
    '<rect x="20" y="20" width="60" height="60" fill="blue" clip-path="url(#c)"/>'), 100, 100);
  Probe(30, 50, Blue, 'bounding box clip');
  Probe(70, 50, Transparent, 'bounding box clip cut');
  Draw(SvgDocumentText('<clipPath id="c"><rect width="50" height="100"/><rect y="50" width="100" height="50"/></clipPath>' +
    '<rect width="100" height="100" fill="lime" clip-path="url(#c)"/>'), 100, 100);
  Probe(25, 25, Lime, 'clip union first');
  Probe(75, 75, Lime, 'clip union second');
  Probe(75, 25, Transparent, 'clip union neither');
  Draw(SvgDocumentText('<mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100"><rect width="100" ' +
    'height="50" fill="white"/></mask><rect width="100" height="100" fill="red" mask="url(#m)"/>'), 100, 100);
  Probe(50, 25, Red, 'mask white');
  Probe(50, 75, Transparent, 'mask none');
  Draw(SvgDocumentText('<mask id="m"><rect width="100" height="100" fill="#808080"/></mask><rect width="100" height="100" ' +
    'fill="blue" mask="url(#m)"/>'), 100, 100);
  Probe(50, 50, $800000FF, 'mask luminance', 12);
end;

procedure TestText;
var
  Left, Right: Integer;
begin
  Draw(SvgDocumentText('<text x="10" y="60" font-size="40" fill="black">HI</text>'), 100, 100);
  Check(PaintedCount(10, 30, 70, 62) > 150, 'text drawn');
  Check(PaintedCount(0, 0, 100, 25) = 0, 'text not above its line');
  Check(PaintedCount(75, 0, 100, 100) = 0, 'text not past its advance');
  Draw(SvgDocumentText('<text x="50" y="60" font-size="30" text-anchor="middle">WWW</text>'), 100, 100);
  Left := PaintedCount(0, 30, 50, 65);
  Right := PaintedCount(50, 30, 100, 65);
  Check((Left > 50) and (Abs(Left - Right) < Left div 4), Format('text-anchor middle (%d, %d)', [Left, Right]));
  Draw(SvgDocumentText('<text x="90" y="60" font-size="30" text-anchor="end">II</text>'), 100, 100);
  Check((PaintedCount(91, 0, 100, 100) = 0) and (PaintedCount(60, 30, 90, 65) > 20), 'text-anchor end');
  Draw(SvgDocumentText('<text y="60" font-size="30"><tspan x="10">A</tspan><tspan x="60" fill="red">B</tspan></text>'),
    100, 100);
  Check(PaintedCount(10, 30, 35, 65) > 20, 'tspan x first');
  Check(GetSurfacePixel(Surface, 0, 0) = Transparent, 'tspan nothing at the corner');
  Check(PaintedCount(60, 30, 90, 65) > 20, 'tspan x second');
  Draw(SvgDocumentText('<text x="10" y="40" font-size="30" fill="none" stroke="blue" stroke-width="1">O</text>'), 100, 100);
  Check(PaintedCount(10, 10, 40, 45) > 10, 'stroked text');
end;

function Base64(const Data: TBytes): string;
const
  Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  Index: Integer;
  Value: LongWord;
  Remaining: Integer;
begin
  Result := '';
  Index := 0;
  while Index < Length(Data) do
  begin
    Remaining := Length(Data) - Index;
    Value := LongWord(Data[Index]) shl 16;
    if Remaining > 1 then
      Value := Value or (LongWord(Data[Index + 1]) shl 8);
    if Remaining > 2 then
      Value := Value or Data[Index + 2];
    Result := Result + Alphabet[(Value shr 18) and 63 + 1] + Alphabet[(Value shr 12) and 63 + 1];
    if Remaining > 1 then
      Result := Result + Alphabet[(Value shr 6) and 63 + 1]
    else
      Result := Result + '=';
    if Remaining > 2 then
      Result := Result + Alphabet[Value and 63 + 1]
    else
      Result := Result + '=';
    Inc(Index, 3);
  end;
end;

procedure TestImages;
var
  Picture: TImage;
  Encoded: TBytes;
  Url: string;
begin
  Picture := TImage.Create(2, 2);
  try
    Picture.Fill(Red);
    Picture.SetPixel(1, 1, Blue);
    Encoded := EncodeImage(Picture, ImageFormatPng);
  finally
    Picture.Free;
  end;
  Url := 'data:image/png;base64,' + Base64(Encoded);
  Draw(SvgDocumentText('<image href="' + Url + '" width="100" height="100" preserveAspectRatio="none" ' +
    'style="image-rendering:pixelated"/>'), 100, 100);
  Probe(25, 25, Red, 'image from a data URL');
  Probe(75, 75, Blue, 'image scaled');
  Draw(SvgDocumentText('<image href="' + Url + '" x="0" y="25" width="100" height="50"/>'), 100, 100);
  Probe(50, 10, Transparent, 'image meets its viewport');
  Probe(10, 50, Transparent, 'image centred');
  Probe(27, 27, Red, 'image drawn');
  Draw(SvgDocumentText('<image href="data:image/svg+xml;utf8,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%2210%22 ' +
    'height=%2210%22%3E%3Crect width=%2210%22 height=%2210%22 fill=%22lime%22/%3E%3C/svg%3E" width="100" ' +
    'height="100"/>'), 100, 100);
  Probe(50, 50, Lime, 'SVG image inside SVG');
end;

procedure TestParsing;
begin
  Draw('<?xml version="1.0"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "x.dtd" [<!ENTITY c "red">' +
    '<!ENTITY w "100">]><!-- a comment --><svg xmlns="http://www.w3.org/2000/svg" width="&w;" height="100">' +
    '<rect width="100" height="100" fill="&c;"/></svg>', 100, 100);
  Probe(50, 50, Red, 'entities from the doctype');
  Draw('<svg:svg xmlns:svg="http://www.w3.org/2000/svg" width="100" height="100"><svg:rect width="100" ' +
    'height="100" fill="blue"/><other xmlns="urn:x"><rect width="100" height="100" fill="red"/></other></svg:svg>',
    100, 100);
  Probe(50, 50, Blue, 'prefixed SVG, foreign elements skipped');
  Draw(SvgDocumentText('<rect width="100" height="100" fill="&#x72;ed"/>'), 100, 100);
  Probe(50, 50, Red, 'character references');
  Draw(SvgDocumentText('<rect width="50%" height="1in" fill="lime"/>'), 100, 100);
  Probe(40, 90, Lime, 'percent and inch lengths');
  Probe(60, 50, Transparent, 'percent width');
end;

procedure TestImageSizes;
var
  Image: TImage;

  function Bytes(const Text: string): TBytes;
  begin
    Result := nil;
    SetLength(Result, Length(Text));
    Move(Text[1], Result[0], Length(Text));
  end;

begin
  Check(LooksLikeSvg(Bytes('<?xml version="1.0"?>' + #10 + '<!-- x --><svg xmlns="x"/>')), 'sniffed svg');
  Check(LooksLikeSvg(Bytes('<!DOCTYPE svg [ <!ENTITY a ">"> ]><svg/>')), 'sniffed svg after a doctype');
  Check(not LooksLikeSvg(Bytes('<html><svg></svg></html>')), 'html is not svg');
  RegisterSvgImageCodec;
  Image := LoadImage(Bytes('<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" ' +
    'height="20" fill="red"/></svg>'));
  try
    Check(Image is TScalableImage, 'an SVG image is scalable');
    Check((Image.Width = 40) and (Image.Height = 20), 'natural size from width and height');
    Check(TScalableImage(Image).HasNaturalWidth and (TScalableImage(Image).NaturalWidth = 40), 'natural width');
    Check(TScalableImage(Image).RenderedAt(80, 40).GetPixel(70, 30) = Red, 'rendered at another size');
  finally
    Image.Free;
  end;
  Image := LoadImage(Bytes('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"/>'));
  try
    Check((Image.Width = 150) and (Image.Height = 150), 'a viewBox alone fits in 300 x 150');
    Check(not TScalableImage(Image).HasNaturalWidth and (Abs(TScalableImage(Image).NaturalRatio - 1) < 1E-9),
      'ratio without size');
  finally
    Image.Free;
  end;
  Image := LoadImage(Bytes('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" ' +
    'height="10" fill="blue"/></svg>'));
  try
    Check(TScalableImage(Image).RenderedAt(100, 100).GetPixel(95, 95) = Blue, 'a size alone scales as a viewBox');
  finally
    Image.Free;
  end;
end;

procedure RenderFile(const InputName, OutputName: string; Width, Height: Integer);
var
  Stream: TFileStream;
  Data: TBytes;
  Document: TSvgDocument;
  Image: TImage;
begin
  Stream := TFileStream.Create(InputName, fmOpenRead);
  try
    Data := nil;
    SetLength(Data, Stream.Size);
    if Length(Data) > 0 then
      Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  Document := LoadSvgDocument(Data);
  try
    if not RenderSvgToSurface(Document, Width, Height, Width, Height, True, Surface) then
      Halt(1);
  finally
    Document.Free;
  end;
  Image := ImageTakingSurface(Surface);
  try
    SaveImage(Image, OutputName, ImageFormatPng);
  finally
    Image.Free;
  end;
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: SvgTest FONTS [IN.svg OUT.png WIDTH HEIGHT]');
    Halt(2);
  end;
  SvgFontDirectory := ParamStr(1);
  if ParamCount >= 5 then
  begin
    RenderFile(ParamStr(2), ParamStr(3), StrToInt(ParamStr(4)), StrToInt(ParamStr(5)));
    Exit;
  end;
  TestShapes;
  TestPaths;
  TestStrokes;
  TestTransformsAndViewports;
  TestOpacityAndColors;
  TestStyling;
  TestUse;
  TestGradients;
  TestPatterns;
  TestClipsAndMasks;
  TestText;
  TestImages;
  TestParsing;
  TestImageSizes;
  if HaveSurface then
    FreeSurface(Surface);
  FinishChecks('SVG TEST');
end.
