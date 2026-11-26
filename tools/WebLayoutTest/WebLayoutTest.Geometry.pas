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
  Element geometry as script sees it (getBoundingClientRect,
  getClientRects through the script layout): an inline element's
  fragments (a link has a size, one rectangle per line), position:
  relative and translate moving the box, a scrolled container moving
  what is in it; the resolved width and height getComputedStyle gives
  (the used size of a box by its box-sizing, auto for an inline box).
}
unit WebLayoutTest.Geometry;

{$mode objfpc}
{$H+}

interface

procedure CheckElementGeometry;

implementation

uses
  SysUtils, TestChecks, Web.Dom, Web.Layout.Document, Web.Layout.BoxGeometry, Web.ScriptEnvironment,
  Web.Script.Layout, WebLayoutTest.Pages;

const
  GeometryPage =
    '<!doctype html><body style="margin:0;font:16px/20px sans-serif">' +
    '<p style="margin:0;width:200px"><a id=short href="#">link</a> and ' +
    '<a id=long href="#">a link long enough to go on to the next line</a></p>' +
    '<div id=moved style="position:relative;left:10px;top:5px;width:50px;height:10px"></div>' +
    '<div id=translated style="width:50px;height:10px;transform:translateX(30px)"></div>' +
    '<div id=scroller style="height:50px;overflow:auto"><div style="height:30px"></div>' +
    '<div id=inside style="height:200px"></div></div>' +
    '<span id=empty></span>' +
    '<div id=sized style="width:50%;padding:5px;border:2px solid;height:auto"><p style="margin:0;height:30px"></p></div>' +
    '<div id=bordered style="box-sizing:border-box;width:100px;padding:10px;height:40px"></div>' +
    { An image grid's tile (reCAPTCHA): a relative inline-block three
      times its 100px box, moved by percentages of the box. }
    '<div id=tilebox style="width:100px;height:100px;overflow:hidden;line-height:0">' +
    '<span id=tile style="display:inline-block;position:relative;top:-100%;left:-200%;width:300%;height:300%">' +
    '</span></div>' +
    { getComputedStyle of an element under display: none (styled for the
      asking) and of pseudo-elements. }
    '<div style="display:none;color:rgb(1,2,3)"><span id=hidden style="width:7px">x</span></div>' +
    '<style>#pseudo::before{content:"a";color:rgb(4,5,6)}</style><p id=pseudo>z</p>' +
    '</body>';

{ An absolutely positioned box without a positioned ancestor is placed
  in the initial containing block (the viewport at the canvas origin),
  whatever the root's margin and border (WPT's CSS2 blocks-025). }
procedure CheckInitialContainingBlock;
const
  Page = '<!doctype html><html style="margin:0 0 0 30px;border-left:5px solid"><body style="margin:0">' +
    '<div id=abs style="position:absolute;left:10px;top:20px;width:10px;height:10px"></div></body></html>';
var
  Document: TDocument;
  Layout: TDocumentLayout;
  ScriptLayout: TDocumentScriptLayout;
  X, Y, Width, Height: Double;
  Found: Boolean;
begin
  Layout := LayoutText(Page, 800, Document);
  ScriptLayout := TDocumentScriptLayout.Create;
  try
    ScriptLayout.Layout := Layout;
    Found := ScriptLayout.BorderBox(Document.GetElementById('abs'), X, Y, Width, Height);
    Check(Found and (Abs(X - 10) < 0.5) and (Abs(Y - 20) < 0.5),
      'geometry: absolute positioning without a positioned ancestor uses the initial containing block (' +
      FloatToStr(X) + ', ' + FloatToStr(Y) + ')');
  finally
    ScriptLayout.Free;
    FreeLayout(Layout, Document);
  end;
end;

{ Table parts without a table get an anonymous one (CSS 2.2 17.2.1): two
  table-cell boxes in a block sit side by side, and an absolutely
  positioned row group of a table is laid out in its containing block
  (WPT's CSS2 bottom-applies-to tests). }
procedure CheckAnonymousTables;
const
  Page = '<!doctype html><body style="margin:0">' +
    '<div><div id=c1 style="display:table-cell;width:50px;height:10px"></div>' +
    '<div id=c2 style="display:table-cell;width:30px;height:10px"></div></div>' +
    '<div style="display:table"><div id=group style="display:table-row-group;position:absolute;bottom:0">' +
    '<div style="display:table-row"><div id=c3 style="display:table-cell;width:20px;height:20px"></div></div>' +
    '</div></div></body>';
var
  Document: TDocument;
  Layout: TDocumentLayout;
  ScriptLayout: TDocumentScriptLayout;
  X, Y, Width, Height, FirstY: Double;
  Found: Boolean;
begin
  Layout := LayoutText(Page, 400, Document);
  ScriptLayout := TDocumentScriptLayout.Create;
  try
    ScriptLayout.Layout := Layout;
    Found := ScriptLayout.BorderBox(Document.GetElementById('c1'), X, FirstY, Width, Height) and
      ScriptLayout.BorderBox(Document.GetElementById('c2'), X, Y, Width, Height);
    Check(Found and (Abs(X - 50) < 0.5) and (Abs(Y - FirstY) < 0.5),
      'geometry: table cells without a table share an anonymous one (' + FloatToStr(X) + ', ' + FloatToStr(Y) + ')');
    Found := ScriptLayout.BorderBox(Document.GetElementById('c3'), X, Y, Width, Height);
    Check(Found and (Abs(Width - 20) < 0.5) and (Abs(Height - 20) < 0.5) and (Y > 100),
      'geometry: an absolutely positioned row group is laid out at its offsets (' + FloatToStr(Y) + ', ' +
      FloatToStr(Width) + ' x ' + FloatToStr(Height) + ')');
  finally
    ScriptLayout.Free;
    FreeLayout(Layout, Document);
  end;
end;

{ table-layout: fixed (CSS 2.2 17.5.2.1): the first row's cell widths and
  the column elements decide, not the content; the rest is shared. }
procedure CheckFixedTableLayout;
const
  Page = '<!doctype html><body style="margin:0">' +
    '<table style="table-layout:fixed;width:300px;border-spacing:0"><tr><td id=f1 style="width:50px;padding:0">a</td>' +
    '<td id=f2 style="padding:0">bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb</td><td id=f3 style="padding:0">c</td></tr></table>' +
    '<table style="table-layout:fixed;width:200px;border-spacing:0"><col style="width:20%"><col style="width:100px">' +
    '<tr><td id=g1 style="padding:0">x</td><td id=g2 style="padding:0">y</td><td id=g3 style="padding:0">z</td></tr>' +
    '</table></body>';
var
  Document: TDocument;
  Layout: TDocumentLayout;
  ScriptLayout: TDocumentScriptLayout;
  X, Y, Width, Height: Double;
  Widths: string;
  Name: string;
begin
  Layout := LayoutText(Page, 800, Document);
  ScriptLayout := TDocumentScriptLayout.Create;
  try
    ScriptLayout.Layout := Layout;
    Widths := '';
    for Name in ['f1', 'f2', 'f3', 'g1', 'g2', 'g3'] do
      if ScriptLayout.BorderBox(Document.GetElementById(Name), X, Y, Width, Height) then
        Widths := Widths + FloatToStr(Round(Width)) + ' ';
    Check(Widths = '50 125 125 40 100 60 ', 'geometry: fixed table layout column widths (' + Widths + ')');
  finally
    ScriptLayout.Free;
    FreeLayout(Layout, Document);
  end;
end;

{ Collapsing borders (CSS 2.2 17.6.2): each edge's widest border wins,
  centred on its line; a cell's used border is its half of the edge, the
  table's the outer half. }
procedure CheckCollapsedBorders;
const
  Page = '<!doctype html><body style="margin:10px"><table id=bt style="border-collapse:collapse;border:6px solid #0000ff">' +
    '<tr><td id=b1 style="border:2px solid #ff0000;width:50px;height:30px;padding:0"></td>' +
    '<td id=b2 style="border:4px solid #008000;width:50px;height:30px;padding:0"></td></tr>' +
    '<tr><td id=b3 colspan=2 style="border:1px solid #000000;height:20px;padding:0"></td></tr></table></body>';
var
  Document: TDocument;
  Layout: TDocumentLayout;
  ScriptLayout: TDocumentScriptLayout;
  X, Y, Width, Height: Double;
  Sizes: string;
  Name: string;
begin
  Layout := LayoutText(Page, 800, Document);
  ScriptLayout := TDocumentScriptLayout.Create;
  try
    ScriptLayout.Layout := Layout;
    Sizes := '';
    for Name in ['bt', 'b1', 'b2', 'b3'] do
      if ScriptLayout.BorderBox(Document.GetElementById(Name), X, Y, Width, Height) then
        Sizes := Sizes + FloatToStr(Round(X)) + ',' + FloatToStr(Round(Y)) + ' ' + FloatToStr(Round(Width)) + 'x' +
          FloatToStr(Round(Height)) + ' ';
    Check(Sizes = '10,10 116x66 13,13 55x35 68,13 55x35 13,48 110x25 ',
      'geometry: collapsed table borders (' + Sizes + ')');
  finally
    ScriptLayout.Free;
    FreeLayout(Layout, Document);
  end;
end;

{ A box with a formatting context of its own does not overlap floats
  along its height: where it does not fit beside them it goes down to
  the next float bottom (WPT's CSS2 floats-wrap-bfc tests). }
procedure CheckFormattingContextBesideFloats;
const
  Page = '<!doctype html><body style="margin:0"><div style="width:100px">' +
    '<div style="float:left;width:100px;height:50px"></div><div style="float:left;width:50px;height:50px"></div>' +
    '<div id=bfc style="overflow:hidden;width:50px;height:50px"></div></div></body>';
var
  Document: TDocument;
  Layout: TDocumentLayout;
  ScriptLayout: TDocumentScriptLayout;
  X, Y, Width, Height: Double;
  Found: Boolean;
begin
  Layout := LayoutText(Page, 800, Document);
  ScriptLayout := TDocumentScriptLayout.Create;
  try
    ScriptLayout.Layout := Layout;
    Found := ScriptLayout.BorderBox(Document.GetElementById('bfc'), X, Y, Width, Height);
    Check(Found and (Abs(X - 50) < 0.5) and (Abs(Y - 50) < 0.5),
      'geometry: a formatting context root moves down to fit beside floats (' + FloatToStr(X) + ', ' +
      FloatToStr(Y) + ')');
  finally
    ScriptLayout.Free;
    FreeLayout(Layout, Document);
  end;
end;

procedure CheckElementGeometry;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  ScriptLayout: TDocumentScriptLayout;
  X, Y, Width, Height, Unscrolled: Double;
  Rects: TScriptRectArray;
  Found: Boolean;
  Prefixed: TElement;
begin
  Layout := LayoutText(GeometryPage, 800, Document);
  ScriptLayout := TDocumentScriptLayout.Create;
  try
    ScriptLayout.Layout := Layout;
    Found := ScriptLayout.BorderBox(Document.GetElementById('short'), X, Y, Width, Height);
    Check(Found and (Width > 20) and
      (Height > 10) and (Y < 5), 'geometry: an inline link has a size (' + FloatToStr(Width) + ' x ' +
      FloatToStr(Height) + ')');
    Rects := ScriptLayout.ClientRects(Document.GetElementById('long'));
    Check(Length(Rects) >= 2, 'geometry: a link over two lines has a rectangle per line (' +
      IntToStr(Length(Rects)) + ')');
    if Length(Rects) >= 2 then
      Check(Rects[1].Y > Rects[0].Y, 'geometry: the second line''s rectangle is below the first');
    Found := ScriptLayout.BorderBox(Document.GetElementById('long'), X, Y, Width, Height);
    Check(Found and (Width > 150) and
      (Height >= 35), 'geometry: the bounding box is the union of the lines');
    Found := ScriptLayout.BorderBox(Document.GetElementById('moved'), X, Y, Width, Height);
    Check(Found and (Abs(X - 10) < 0.5),
      'geometry: position:relative moves the box (' + FloatToStr(X) + ')');
    Found := ScriptLayout.BorderBox(Document.GetElementById('translated'), X, Y, Width, Height);
    Check(Found and (Abs(X - 30) < 0.5),
      'geometry: translateX moves the box (' + FloatToStr(X) + ')');
    Found := ScriptLayout.BorderBox(Document.GetElementById('inside'), X, Unscrolled, Width, Height);
    Check(Found,
      'geometry: inside a scroller');
    Layout.SetScrollOffset(Document.GetElementById('scroller'), 0, 20);
    Found := ScriptLayout.BorderBox(Document.GetElementById('inside'), X, Y, Width, Height);
    Check(Found and
      (Abs(Y - (Unscrolled - 20)) < 0.5), 'geometry: the scroller''s offset moves what is in it (' +
      FloatToStr(Unscrolled) + ' -> ' + FloatToStr(Y) + ')');
    Check(Length(ScriptLayout.ClientRects(Document.GetElementById('empty'))) <= 1,
      'geometry: an empty span has at most one rectangle');
    Check((ScriptLayout.ComputedValue(Document.GetElementById('sized'), 'width') = '400px') and
      (ScriptLayout.ComputedValue(Document.GetElementById('sized'), 'height') = '30px'),
      'geometry: the resolved width and height are the used content size (' +
      ScriptLayout.ComputedValue(Document.GetElementById('sized'), 'width') + ' x ' +
      ScriptLayout.ComputedValue(Document.GetElementById('sized'), 'height') + ')');
    Check((ScriptLayout.ComputedValue(Document.GetElementById('bordered'), 'width') = '100px') and
      (ScriptLayout.ComputedValue(Document.GetElementById('bordered'), 'height') = '40px'),
      'geometry: with box-sizing: border-box the border box size');
    Check(ScriptLayout.ComputedValue(Document.GetElementById('short'), 'width') = 'auto',
      'geometry: an inline box''s width stays auto');
    Check((ScriptLayout.ComputedValue(Document.GetElementById('hidden'), 'color') = 'rgb(1, 2, 3)') and
      (ScriptLayout.ComputedValue(Document.GetElementById('hidden'), 'width') = '7px'),
      'computed style: an element under display: none has one (' +
      ScriptLayout.ComputedValue(Document.GetElementById('hidden'), 'color') + ')');
    Check((ScriptLayout.ComputedValue(Document.GetElementById('pseudo'), 'color', '::before') = 'rgb(4, 5, 6)') and
      (ScriptLayout.ComputedValue(Document.GetElementById('pseudo'), 'content', ':before') = '"a"'),
      'computed style: of a ::before (' +
      ScriptLayout.ComputedValue(Document.GetElementById('pseudo'), 'color', '::before') + ')');
    Check(ScriptLayout.ComputedValue(Document.GetElementById('pseudo'), 'color', '::nothing') = '',
      'computed style: of an unknown pseudo-element is empty');
    Found := ScriptLayout.BorderBox(Document.GetElementById('tilebox'), X, Unscrolled, Width, Height) and
      ScriptLayout.BorderBox(Document.GetElementById('tile'), X, Y, Width, Height);
    Check(Found and (Abs(X + 200) < 0.5) and (Abs(Y - (Unscrolled - 100)) < 0.5) and (Abs(Height - 300) < 0.5),
      'geometry: an inline-block''s percentage top, left and height resolve against a definite box (' +
      FloatToStr(X) + ', ' + FloatToStr(Y - Unscrolled) + ', ' + FloatToStr(Height) + ')');
    CheckInitialContainingBlock;
    CheckAnonymousTables;
    CheckFixedTableLayout;
    CheckCollapsedBorders;
    CheckFormattingContextBesideFloats;
    { A prefixed svg:svg (as XHTML writes it) is an SVG element: its
      height attribute sizes it. }
    Prefixed := Document.CreateElementNS('http://www.w3.org/2000/svg', 'svg:svg');
    Prefixed.SetAttribute('height', '50');
    Prefixed.SetAttribute('id', 'prefixed');
    Document.Body.AppendChild(Prefixed);
    Layout.Update;
    Found := ScriptLayout.BorderBox(Document.GetElementById('prefixed'), X, Y, Width, Height);
    Check(Found and (Abs(Height - 50) < 0.5), 'geometry: a prefixed svg:svg takes its height attribute (' +
      FloatToStr(Height) + ')');
  finally
    ScriptLayout.Free;
    FreeLayout(Layout, Document);
  end;
end;

end.
