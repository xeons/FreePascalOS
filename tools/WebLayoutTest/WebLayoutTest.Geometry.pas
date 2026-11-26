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

procedure CheckElementGeometry;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  ScriptLayout: TDocumentScriptLayout;
  X, Y, Width, Height, Unscrolled: Double;
  Rects: TScriptRectArray;
  Found: Boolean;
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
  finally
    ScriptLayout.Free;
    FreeLayout(Layout, Document);
  end;
end;

end.
