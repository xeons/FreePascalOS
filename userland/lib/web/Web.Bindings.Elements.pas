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
  bindings/Elements.webidl: Element over Web.Dom, the markup members
  over Web.Html.Markup and the selector members over
  Web.Bindings.Selectors.
}
unit Web.Bindings.Elements;

{$mode objfpc}
{$H+}

interface

uses
  Js.Values,
  Web.Bindings.Types;

{$I Web.Bindings.Elements.Members.inc}

implementation

uses
  SysUtils,
  Web.Atoms,
  Web.Dom,
  Web.Dom.Exceptions,
  Web.Html.Markup,
  Web.Html.Serializer,
  Web.Bindings.Context,
  Web.Bindings.Selectors;

function ThisElement(const Call: TBindingCall): TElement; inline;
begin
  Result := TElement(Call.Target);
end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function OptionalText(const Call: TBindingCall; const Text: string): TJsValue;
begin
  Result := Context(Call).NullableText(Text, Text = '');
end;

function Element_get_namespaceURI(var Call: TBindingCall): TJsValue;
begin
  Result := OptionalText(Call, ThisElement(Call).NamespaceUri);
end;

function Element_get_prefix(var Call: TBindingCall): TJsValue;
begin
  Result := OptionalText(Call, ThisElement(Call).Prefix);
end;

function Element_get_localName(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisElement(Call).LocalName);
end;

function Element_get_tagName(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(ThisElement(Call).TagName);
end;

function Element_get_classList(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisElement(Call).ClassList, InterfaceDOMTokenList, False, Call.This);
end;

function Element_hasAttributes(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisElement(Call).HasAttributes);
end;

function Element_get_attributes(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisElement(Call).Attributes, InterfaceNamedNodeMap, False, Call.This);
end;

function Element_getAttributeNames(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).StringArray(ThisElement(Call).GetAttributeNames);
end;

function Element_getAttribute(var Call: TBindingCall): TJsValue;
begin
  if not ThisElement(Call).HasAttribute(Call.Text(0)) then
    Exit(JsNull);
  Result := Context(Call).TextValue(ThisElement(Call).GetAttribute(Call.Text(0)));
end;

function Element_getAttributeNS(var Call: TBindingCall): TJsValue;
begin
  if not ThisElement(Call).HasAttributeNS(Call.Text(0), Call.Text(1)) then
    Exit(JsNull);
  Result := Context(Call).TextValue(ThisElement(Call).GetAttributeNS(Call.Text(0), Call.Text(1)));
end;

function Element_setAttribute(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).SetAttribute(Call.Text(0), Call.Text(1));
  Result := JsUndefined;
end;

function Element_setAttributeNS(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).SetAttributeNS(Call.Text(0), Call.Text(1), Call.Text(2));
  Result := JsUndefined;
end;

function Element_removeAttribute(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).RemoveAttribute(Call.Text(0));
  Result := JsUndefined;
end;

function Element_removeAttributeNS(var Call: TBindingCall): TJsValue;
begin
  ThisElement(Call).RemoveAttributeNS(Call.Text(0), Call.Text(1));
  Result := JsUndefined;
end;

function Element_toggleAttribute(var Call: TBindingCall): TJsValue;
var
  Force: Integer;
begin
  if Call.Present(1) then
    Force := Ord(Call.Flag(1))
  else
    Force := -1;
  Result := JsBoolean(ThisElement(Call).ToggleAttribute(Call.Text(0), Force));
end;

function Element_hasAttribute(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisElement(Call).HasAttribute(Call.Text(0)));
end;

function Element_hasAttributeNS(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ThisElement(Call).HasAttributeNS(Call.Text(0), Call.Text(1)));
end;

function Element_getAttributeNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisElement(Call).GetAttributeNode(Call.Text(0)));
end;

function Element_getAttributeNodeNS(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisElement(Call).GetAttributeNodeNS(Call.Text(0), Call.Text(1)));
end;

function Element_setAttributeNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisElement(Call).SetAttributeNode(TAttr(Call.Native(0))));
end;

function Element_setAttributeNodeNS(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisElement(Call).SetAttributeNode(TAttr(Call.Native(0))));
end;

function Element_removeAttributeNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisElement(Call).RemoveAttributeNode(TAttr(Call.Native(0))));
end;

function Element_closest(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ElementClosest(ThisElement(Call), Call.Text(0)));
end;

function Element_matches(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ElementMatches(ThisElement(Call), Call.Text(0)));
end;

function Element_webkitMatchesSelector(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(ElementMatches(ThisElement(Call), Call.Text(0)));
end;

function Element_getElementsByTagName(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisElement(Call).GetElementsByTagName(Call.Text(0)), InterfaceHTMLCollection,
    True, JsUndefined);
end;

function Element_getElementsByTagNameNS(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisElement(Call).GetElementsByTagNameNS(Call.Text(0), Call.Text(1)),
    InterfaceHTMLCollection, True, JsUndefined);
end;

function Element_getElementsByClassName(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapObject(ThisElement(Call).GetElementsByClassName(Call.Text(0)),
    InterfaceHTMLCollection, True, JsUndefined);
end;

{ The insert adjacent steps; nil when there is no parent to insert at. }
function InsertAdjacent(Element: TElement; const Where: string; Node: TNode): TNode;
var
  Position: string;
begin
  Position := AsciiLowerCase(Where);
  Result := Node;
  if Position = 'beforebegin' then
  begin
    if Element.ParentNode = nil then
      Exit(nil);
    Element.ParentNode.InsertBefore(Node, Element);
  end
  else if Position = 'afterbegin' then
    Element.InsertBefore(Node, Element.FirstChild)
  else if Position = 'beforeend' then
    Element.AppendChild(Node)
  else if Position = 'afterend' then
  begin
    if Element.ParentNode = nil then
      Exit(nil);
    Element.ParentNode.InsertBefore(Node, Element.NextSibling);
  end
  else
    RaiseDomError(SyntaxError, '''' + Where + ''' is not a position');
end;

function Element_insertAdjacentElement(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(InsertAdjacent(ThisElement(Call), Call.Text(0), TNode(Call.Native(1))));
end;

function Element_insertAdjacentText(var Call: TBindingCall): TJsValue;
begin
  InsertAdjacent(ThisElement(Call), Call.Text(0), ThisElement(Call).NodeDocument.CreateTextNode(Call.Text(1)));
  Result := JsUndefined;
end;

function Element_get_innerHTML(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetInnerHtml(ThisElement(Call)));
end;

function Element_set_innerHTML(var Call: TBindingCall): TJsValue;
begin
  SetInnerHtml(ThisElement(Call), Call.Text(0));
  Result := JsUndefined;
end;

function Element_get_outerHTML(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(GetOuterHtml(ThisElement(Call)));
end;

function Element_set_outerHTML(var Call: TBindingCall): TJsValue;
begin
  SetOuterHtml(ThisElement(Call), Call.Text(0));
  Result := JsUndefined;
end;

function Element_insertAdjacentHTML(var Call: TBindingCall): TJsValue;
begin
  InsertAdjacentHtml(ThisElement(Call), AsciiLowerCase(Call.Text(0)), Call.Text(1));
  Result := JsUndefined;
end;

function Element_getHTML(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(SerializeChildren(ThisElement(Call)));
end;

end.
