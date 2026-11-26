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
  CSS Overflow 3, 3.3: the overflow of the root element - or, when the
  root's is visible, the HTML body element's - applies to the viewport,
  and that element's own used overflow is visible. So body
  { overflow-y: scroll } is the page's scroll bar, not a body box of
  height 0 clipping the whole page.
}
unit Web.Layout.ViewportOverflow;

{$mode objfpc}
{$H+}

interface

uses
  Css.ComputedStyle, Css.PropertyIds, Web.Dom;

{ The element whose overflow the viewport takes (nil: none, the
  viewport's overflow is auto). }
function ViewportOverflowSource(Document: TDocument): TElement;
{ Whether Element's overflow goes to the viewport (it does not clip). }
function PropagatesOverflowToViewport(Element: TElement): Boolean;
{ Whether the viewport shows a scroll bar along the axis of Id
  (cpOverflowX, cpOverflowY): not when the overflow it takes is hidden
  or clip. }
function ViewportShowsBar(Document: TDocument; Id: TCssPropertyId): Boolean;

implementation

uses
  Css.Keywords, Web.Atoms, Web.Style.NodeData, Web.Layout.Values;

function ViewportOverflowSource(Document: TDocument): TElement;
var
  Root, Body: TElement;
  Style: TCssComputedStyle;
begin
  Result := nil;
  if Document = nil then
    Exit;
  Root := Document.DocumentElement;
  if Root = nil then
    Exit;
  Style := StyleOf(Root);
  if Style = nil then
    Exit;
  if OverflowClips(Style) then
    Exit(Root);
  if not Root.IsHtmlElement(AtomHtml) then
    Exit;
  Body := Document.Body;
  if (Body = nil) or (Body.ParentNode <> Root) then
    Exit;
  Style := StyleOf(Body);
  if (Style <> nil) and OverflowClips(Style) then
    Result := Body;
end;

function PropagatesOverflowToViewport(Element: TElement): Boolean;
begin
  Result := (Element <> nil) and (Element.NodeDocument <> nil) and
    (ViewportOverflowSource(Element.NodeDocument) = Element);
end;

function ViewportShowsBar(Document: TDocument; Id: TCssPropertyId): Boolean;
var
  Source: TElement;
begin
  Source := ViewportOverflowSource(Document);
  Result := (Source = nil) or not KeywordIn(StyleOf(Source).Keyword(Id), [kwHidden, kwClip]);
end;

end.
