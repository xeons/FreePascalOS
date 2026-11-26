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
  Shadow trees in styling and layout, by their pixels: the shadow
  tree's sheet styles its own elements and not the document's, the
  document's rules do not reach into it, :host styles the host (losing
  to the document's rules), ::slotted() styles the assigned elements, a
  host's unassigned children are not rendered, a slot's fallback shows
  when nothing is assigned, ::part() from the document styles a part,
  and assigning a node later moves it into the slot.
}
unit WebLayoutTest.ShadowTrees;

{$mode objfpc}
{$H+}

interface

procedure CheckShadowTrees;

implementation

uses
  SysUtils, TestChecks, Drawing.Colors, Drawing.Surfaces, Drawing.Rectangles, Web.Dom, Web.Layout.Document,
  Web.Paint.Painter, Web.Html.Markup, WebLayoutTest.Pages;

const
  ShadowPage =
    '<!doctype html><head><style>' +
    'div { background: #ff0000 } span { display: block; height: 20px } #host { width: 60px }' +
    '#host::part(label) { background: #ff00ff } p { margin: 0; height: 20px; background: #ff0000 }' +
    '</style></head>' +
    '<body style="margin:0;background:#ffffff"><section id=host><span id=a>a</span><p slot=nowhere>x</p>' +
    '</section></body>';

  ShadowMarkup =
    '<style>:host { display: block; padding-bottom: 20px; background: #0000ff }' +
    ' div { height: 20px; background: #00ff00 } ::slotted(span) { background: #ffff00 }' +
    ' b { display: block; height: 20px }</style>' +
    '<div></div><slot></slot><slot name=later><b style="background:#00ffff">f</b></slot>' +
    '<b part=label>p</b>';

function PixelIs(const Surface: TSurface; Y: Integer; Expected: TColor; const What: string): Boolean;
var
  Actual: TColor;
begin
  Actual := GetSurfacePixel(Surface, 20, Y) or $FF000000;
  Result := (Abs(Integer(RedOf(Actual)) - RedOf(Expected)) <= 3) and
    (Abs(Integer(GreenOf(Actual)) - GreenOf(Expected)) <= 3) and
    (Abs(Integer(BlueOf(Actual)) - BlueOf(Expected)) <= 3);
  if not Result then
    WriteLn('  ', What, ': pixel at y ', Y, ' is ', IntToHex(Actual, 8), ', expected ', IntToHex(Expected, 8));
end;

procedure CheckShadowTrees;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Painter: TDocumentPainter;
  Surface: TSurface;
  Host, Late: TElement;
  Shadow: TShadowRoot;

  procedure Repaint;
  begin
    if Layout.NeedsUpdate then
      Layout.Update;
    Painter.Paint(Surface, MakeRectangle(0, 0, 100, 200));
  end;

begin
  Layout := LayoutText(ShadowPage, 100, Document);
  Painter := TDocumentPainter.Create(Layout);
  CreateSurface(Surface, 100, 200, ColorBlack);
  try
    Host := Document.GetElementById('host');
    Shadow := Host.AttachShadow(ShadowRootOpen, False, False, False, SlotAssignmentNamed);
    SetInnerHtml(Shadow, ShadowMarkup);
    Repaint;
    { 0-20 the shadow div, 20-40 the slotted span, 40-60 the fallback,
      60-80 the part, 80-100 the host's padding. }
    Check(PixelIs(Surface, 10, RgbColor(0, 255, 0), 'shadow div'),
      'shadow: the shadow tree''s sheet styles its elements, the document''s does not');
    Check(PixelIs(Surface, 30, RgbColor(255, 255, 0), 'slotted span'), 'shadow: ::slotted() styles an assigned element');
    Check(PixelIs(Surface, 50, RgbColor(0, 255, 255), 'fallback'), 'shadow: a slot with nothing assigned shows its fallback');
    Check(PixelIs(Surface, 70, RgbColor(255, 0, 255), 'part'), 'shadow: ::part() from the document styles a part');
    Check(PixelIs(Surface, 90, RgbColor(0, 0, 255), 'host padding'), 'shadow: :host styles the host');
    Check(PixelIs(Surface, 110, RgbColor(255, 255, 255), 'below'), 'shadow: an unassigned child is not rendered');
    { A node assigned to the named slot replaces its fallback. }
    Late := Document.CreateElement('span');
    Late.SetAttribute('slot', 'later');
    Late.SetAttribute('style', 'background:#808080');
    Host.AppendChild(Late);
    Repaint;
    Check(PixelIs(Surface, 50, RgbColor(128, 128, 128), 'assigned later'),
      'shadow: a node assigned later takes the slot''s place');
  finally
    FreeSurface(Surface);
    Painter.Free;
    FreeLayout(Layout, Document);
  end;
end;

end.
