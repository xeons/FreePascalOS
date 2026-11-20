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
  Markup as a DOM property: innerHTML, outerHTML and insertAdjacentHTML
  (DOM Parsing and Serialization, as merged into the HTML Standard),
  joining the fragment parser and the serializer.
}
unit Web.Html.Markup;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

function GetInnerHtml(Node: TNode): string;
{ Replaces the children of Element (or of a fragment: a body element is
  the context) with what Markup parses into. }
procedure SetInnerHtml(Node: TNode; const Markup: string);
function GetOuterHtml(Element: TElement): string;
procedure SetOuterHtml(Element: TElement; const Markup: string);
{ Position: beforebegin, afterbegin, beforeend or afterend. }
procedure InsertAdjacentHtml(Element: TElement; const Position, Markup: string);

implementation

uses
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Exceptions,
  Web.Html.Parser,
  Web.Html.Serializer;

function GetInnerHtml(Node: TNode): string;
begin
  Result := SerializeChildren(Node);
end;

procedure SetInnerHtml(Node: TNode; const Markup: string);
var
  Context: TElement;
  Fragment: TDocumentFragment;
  Target: TNode;
begin
  if Node.NodeType = NodeTypeElement then
    Context := TElement(Node)
  else
    Context := Node.NodeDocument.NewElement(AtomBody, NamespaceHtml);
  Fragment := ParseHtmlFragment(Context, Markup);
  if Context <> Node then
    Context.Free;
  Target := Node;
  if (Node.NodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(AtomTemplate) then
    Target := TElement(Node).TemplateContent;
  Target.ReplaceChildren([Fragment]);
end;

function GetOuterHtml(Element: TElement): string;
begin
  Result := SerializeNode(Element);
end;

procedure SetOuterHtml(Element: TElement; const Markup: string);
var
  Parent: TNode;
  Context: TElement;
  Fragment: TDocumentFragment;
  OwnsContext: Boolean;
begin
  Parent := Element.ParentNode;
  if Parent = nil then
    Exit;
  if Parent.NodeType = NodeTypeDocument then
    RaiseDomError(NoModificationAllowedError, 'the element is the document element');
  OwnsContext := Parent.NodeType = NodeTypeDocumentFragment;
  if OwnsContext then
    Context := Element.NodeDocument.NewElement(AtomBody, NamespaceHtml)
  else
    Context := TElement(Parent);
  try
    Fragment := ParseHtmlFragment(Context, Markup);
  finally
    if OwnsContext then
      Context.Free;
  end;
  Parent.ReplaceChild(Fragment, Element);
end;

procedure InsertAdjacentHtml(Element: TElement; const Position, Markup: string);
var
  Where: string;
  Context: TElement;
  Fragment: TDocumentFragment;
  OwnsContext: Boolean;
begin
  Where := AsciiLowerCase(Position);
  OwnsContext := False;
  if (Where = 'beforebegin') or (Where = 'afterend') then
  begin
    if (Element.ParentNode = nil) or (Element.ParentNode.NodeType = NodeTypeDocument) then
      RaiseDomError(NoModificationAllowedError, 'there is no parent element to insert into');
    if Element.ParentNode.NodeType = NodeTypeElement then
      Context := TElement(Element.ParentNode)
    else
    begin
      Context := Element.NodeDocument.NewElement(AtomBody, NamespaceHtml);
      OwnsContext := True;
    end;
  end
  else if (Where = 'afterbegin') or (Where = 'beforeend') then
    Context := Element
  else
    RaiseDomError(SyntaxError, 'unknown position ' + Position);
  { An html element of an HTML document is no context: use body. }
  if not OwnsContext and Context.IsHtmlElement(AtomHtml) and Context.NodeDocument.IsHtmlDocument then
  begin
    Context := Element.NodeDocument.NewElement(AtomBody, NamespaceHtml);
    OwnsContext := True;
  end;
  try
    Fragment := ParseHtmlFragment(Context, Markup);
  finally
    if OwnsContext then
      Context.Free;
  end;
  if Where = 'beforebegin' then
    Element.ParentNode.InsertBefore(Fragment, Element)
  else if Where = 'afterbegin' then
    Element.InsertBefore(Fragment, Element.FirstChild)
  else if Where = 'beforeend' then
    Element.AppendChild(Fragment)
  else
    Element.ParentNode.InsertBefore(Fragment, Element.NextSibling);
end;

end.
