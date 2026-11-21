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
  Incremental restyle and relayout: after each DOM change the updated
  layout must equal a fresh layout of the changed document, and clean
  subtrees must have been skipped. Also hit testing.
}
unit WebLayoutTest.Dynamic;

{$mode objfpc}
{$H+}

interface

procedure CheckIncrementalLayout;
procedure CheckStateInvalidation;
procedure CheckHitTesting;

implementation

uses
  SysUtils, TestChecks, Web.Dom, Web.Atoms, Web.Html.Serializer, Web.Layout.Document, Web.Layout.Dump,
  Web.Layout.Dispatch, Web.Layout.Boxes, Web.Paint.Painter, Css.ElementAdapter, WebLayoutTest.Pages;

const
  DynamicPage =
    '<!doctype html><style>' +
    'body { margin: 8px; font: 14px sans-serif } .big { font-size: 24px } .wide { width: 300px }' +
    '#side { float: right; width: 100px; height: 60px } li:first-child { color: red } p:hover { padding: 10px }' +
    '</style><body><div id=side></div><h1 id=title>Title</h1>' +
    '<p id=first>First paragraph with some words that wrap.</p>' +
    '<ul id=list><li>one</li><li>two</li></ul>' +
    '<div id=box class=narrow>Box text</div>' +
    '<section id=many></section></body>';

  { Selectors reading :hover as the subject, from an ancestor, from a
    previous sibling, inside :is() and inside :has(); elements whose
    hover none of them reads. }
  HoverPage =
    '<!doctype html><style>' +
    'body { margin: 0; font: 14px sans-serif } .link { display: inline-block } .link:hover { padding-left: 5px }' +
    '.menu:hover .item { display: block } .item { display: none }' +
    '.tab:hover + .panel { height: 30px } .panel { height: 10px }' +
    ':is(.card:hover) .title { margin-top: 7px }' +
    '</style><body><div id=plain><p id=para>Text</p></div>' +
    '<a id=link class=link>link</a>' +
    '<div id=menu class=menu>menu<div id=item class=item>item</div></div>' +
    '<div id=tab class=tab>tab</div><div id=panel class=panel></div>' +
    '<div id=card class=card><div id=title class=title>t</div></div>' +
    '<div class=host><span id=hot class=hot>h</span><div id=flag class=flag>f</div></div></body>';
  HasPage = '<style>.host:has(.hot:hover) .flag { width: 50px }</style>' +
    '<div class=host><span id=hot class=hot>h</span><div id=flag class=flag>f</div></div>';

function FreshDump(Document: TDocument; Width: Single): string;
var
  Copy: TDocument;
  Layout: TDocumentLayout;
begin
  Layout := LayoutText('<!doctype html>' + SerializeNode(Document.DocumentElement), Width, Copy);
  try
    Result := DumpLayoutTree(Layout.Root);
  finally
    FreeLayout(Layout, Copy);
  end;
end;

procedure CheckSame(Layout: TDocumentLayout; Document: TDocument; const Name: string);
var
  Updated, Fresh: string;
begin
  Layout.Update;
  Updated := DumpLayoutTree(Layout.Root);
  Fresh := FreshDump(Document, Layout.ViewportWidth);
  if Updated <> Fresh then
  begin
    WriteLn('--- updated');
    Write(Updated);
    WriteLn('--- fresh');
    Write(Fresh);
  end;
  Check(Updated = Fresh, 'incremental: ' + Name);
end;

procedure CheckIncrementalLayout;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Element, Child: TElement;
  Index: Integer;
  SkippedBefore, LaidOutBefore: Int64;
begin
  Layout := LayoutText(DynamicPage, 600, Document);
  try
    CheckSame(Layout, Document, 'unchanged');
    Element := Document.GetElementById('title');
    Element.SetAttribute('class', 'big');
    CheckSame(Layout, Document, 'class change restyles and relays out');
    Element := Document.GetElementById('box');
    Element.SetAttribute('class', 'wide');
    CheckSame(Layout, Document, 'width from a class');
    Element := Document.GetElementById('list');
    Child := Document.CreateElement('li');
    Child.AppendChild(Document.CreateTextNode('zero'));
    Element.InsertBefore(Child, Element.FirstChild);
    CheckSame(Layout, Document, 'inserted first child (first-child moves)');
    TText(Document.GetElementById('first').FirstChild).Data := 'Changed text that is now much longer than it was and wraps to more lines beside the float.';
    CheckSame(Layout, Document, 'text changed');
    Element := Document.GetElementById('many');
    for Index := 1 to 20 do
    begin
      Child := Document.CreateElement('p');
      Child.AppendChild(Document.CreateTextNode('Paragraph ' + IntToStr(Index)));
      Element.AppendChild(Child);
    end;
    CheckSame(Layout, Document, 'many appended');
    Document.GetElementById('side').Remove;
    CheckSame(Layout, Document, 'float removed');
    Document.GetElementById('box').SetAttribute('style', 'display: none');
    CheckSame(Layout, Document, 'display none');
    Document.GetElementById('box').SetAttribute('style', 'display: inline-block; border: 3px solid');
    CheckSame(Layout, Document, 'display inline-block');
    { A change at the end leaves the earlier blocks alone. }
    SkippedBefore := BoxesSkipped;
    TText(Element.LastChild.FirstChild).Data := 'Last one changed';
    Layout.Update;
    Check(BoxesSkipped > SkippedBefore, 'incremental: clean boxes skipped');
    CheckSame(Layout, Document, 'last paragraph changed');
    { A change painting alone shows: no box is laid out again. }
    LaidOutBefore := BoxesLaidOut;
    Document.GetElementById('title').SetAttribute('style', 'background-color: yellow');
    Layout.Update;
    Check(BoxesLaidOut = LaidOutBefore, 'incremental: a paint-only change lays nothing out');
    CheckSame(Layout, Document, 'background color');
    { Dynamic states. }
    Layout.SetElementStates(Document.GetElementById('first'), [esHover]);
    Layout.Update;
    Check(Layout.BoxOf(Document.GetElementById('first')).Padding[sideTop] = 10, 'incremental: :hover restyles');
    Layout.SetElementStates(Document.GetElementById('first'), []);
    CheckSame(Layout, Document, 'hover gone');
    Layout.SetViewport(320, 600, 1);
    CheckSame(Layout, Document, 'narrower viewport');
  finally
    FreeLayout(Layout, Document);
    Document := nil;
  end;
  { Fixed and absolutely positioned boxes (one inside an inline box, as
    Next.js's route announcer is) are laid out after their ancestors: a
    layout must leave nothing due, else every frame lays out again. }
  Layout := LayoutText('<body><div style="position: fixed; top: 0">bar</div><p>text ' +
    '<span><b style="position: absolute; left: 4px">abs</b></span></p><div style="position: relative">' +
    '<i style="position: absolute; right: 0">in</i></div></body>', 600, Document);
  try
    Check(not Layout.NeedsUpdate, 'incremental: nothing due after laying out positioned boxes');
    Document.Body.AppendChild(Document.CreateElement('span'));
    Layout.Update;
    Check(not Layout.NeedsUpdate, 'incremental: nothing due after a box was added beside them');
  finally
    FreeLayout(Layout, Document);
    Document := nil;
  end;
end;

procedure CheckStateInvalidation;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  StylesBefore: Int64;

  procedure Hover(const Id: string; On: Boolean);
  begin
    if On then
      Layout.SetElementStates(Document.GetElementById(Id), [esHover])
    else
      Layout.SetElementStates(Document.GetElementById(Id), []);
    Layout.Update;
  end;

  function Box(const Id: string): TLayoutBox;
  begin
    Result := Layout.BoxOf(Document.GetElementById(Id));
  end;

begin
  Layout := LayoutText(HoverPage, 600, Document);
  try
    StylesBefore := Layout.Styler.StylesComputed;
    Hover('plain', True);
    Hover('para', True);
    Check(Layout.Styler.StylesComputed = StylesBefore, 'states: hover no selector reads styles nothing again');
    Hover('link', True);
    Check(Box('link').Padding[sideLeft] = 5, 'states: :hover on the subject');
    Hover('link', False);
    Check(Box('link').Padding[sideLeft] = 0, 'states: :hover gone from the subject');
    Hover('menu', True);
    Check((Box('item') <> nil) and (Box('item').Height > 0), 'states: :hover on an ancestor shows a descendant');
    Hover('menu', False);
    Check(Box('item') = nil, 'states: and hides it again');
    Hover('tab', True);
    Check(Box('panel').Height = 30, 'states: :hover on a previous sibling');
    Hover('tab', False);
    Check(Box('panel').Height = 10, 'states: and gone');
    Hover('card', True);
    Check(Box('title').Margin[sideTop] = 7, 'states: :hover inside :is()');
    Hover('card', False);
    CheckSame(Layout, Document, 'states: all hover gone');
  finally
    FreeLayout(Layout, Document);
  end;
  Layout := LayoutText('<!doctype html>' + HasPage, 600, Document);
  try
    Hover('hot', True);
    Check(Box('flag').Width = 50, 'states: :hover inside :has()');
    Hover('hot', False);
    CheckSame(Layout, Document, 'states: :has() hover gone');
  finally
    FreeLayout(Layout, Document);
  end;
end;

procedure CheckHitTesting;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Hit: THitTestResult;
begin
  Layout := LayoutText('<!doctype html><body style="margin:0">' +
    '<div id=a style="height:50px;background:red"></div>' +
    '<div id=b style="height:50px;position:relative"><span id=s>text here</span>' +
    '<div id=c style="position:absolute;left:100px;top:0;width:50px;height:50px;z-index:1"></div></div>' +
    '<div id=d style="height:40px;overflow:hidden"><div style="height:200px">tall</div></div>' +
    '<div style="margin-top:100px;height:1000px"></div>', 400, Document);
  Painter := TDocumentPainter.Create(Layout);
  try
    Hit := Painter.HitTest(10, 10);
    Check((Hit.Element <> nil) and (Hit.Element.Id = 'a'), 'hit test: block');
    Hit := Painter.HitTest(120, 60);
    Check((Hit.Element <> nil) and (Hit.Element.Id = 'c'), 'hit test: positioned box on top');
    Hit := Painter.HitTest(5, 60);
    Check((Hit.Element <> nil) and (Hit.Element.Id = 's') and (Hit.Node is TText), 'hit test: text');
    Hit := Painter.HitTest(300, 75);
    Check((Hit.Element <> nil) and (Hit.Element.Id = 'b'), 'hit test: container beside its content');
    Hit := Painter.HitTest(10, 170);
    Check((Hit.Element = nil) or (Hit.Element.LocalName = 'body') or (Hit.Element.LocalName = 'html'),
      'hit test: clipped overflow is not hit');
    Layout.SetScrollOffset(nil, 0, 50);
    Hit := Painter.HitTest(120, 10);
    Check((Hit.Element <> nil) and (Hit.Element.Id = 'c'), 'hit test: scrolled viewport');
  finally
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

end.
