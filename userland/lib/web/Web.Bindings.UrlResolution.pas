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
  URLs of a document (HTML Standard): its URL (about:blank when it has
  none), its base URL (the first base element with an href, resolved
  against the document's URL) and "encoding-parsing a URL" against it,
  with libhttp's URL parser.
}
unit Web.Bindings.UrlResolution;

{$mode objfpc}
{$H+}

interface

uses
  Url.Records,
  Url.Parser,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom;

{ The document's URL, about:blank when it has none. }
function DocumentUrlText(Document: TDocument): string;
function DocumentBaseUrl(Document: TDocument; out Base: TUrlRecord): Boolean;
{ Text parsed against the document's base URL. }
function ResolveUrl(Document: TDocument; const Text: string; out Url: TUrlRecord): Boolean;
{ The serialization of Text resolved, or '' when it is not a URL. }
function ResolveUrlText(Document: TDocument; const Text: string; out Resolved: string): Boolean;

implementation

function DocumentUrlText(Document: TDocument): string;
begin
  Result := Document.Url;
  if Result = '' then
    Result := 'about:blank';
end;

function FirstBaseHref(Document: TDocument): TElement;
var
  Node: TNode;
begin
  Node := Document.FirstChild;
  while Node <> nil do
  begin
    if (Node.NodeType = NodeTypeElement) and TElement(Node).IsHtmlElement(AtomBase) and
      TElement(Node).HasAttributeAtom(AtomHref) then
      Exit(TElement(Node));
    Node := Node.NextInTree(Document);
  end;
  Result := nil;
end;

function DocumentBaseUrl(Document: TDocument; out Base: TUrlRecord): Boolean;
var
  BaseElement: TElement;
  DocumentUrl: TUrlRecord;
begin
  if not ParseUrl(DocumentUrlText(Document), DocumentUrl) then
    DocumentUrl := EmptyUrl;
  BaseElement := FirstBaseHref(Document);
  if (BaseElement <> nil) and ParseUrl(BaseElement.AttributeValueOf(AtomHref), @DocumentUrl, Base) then
    Exit(True);
  Base := DocumentUrl;
  Result := DocumentUrl.Scheme <> '';
end;

function ResolveUrl(Document: TDocument; const Text: string; out Url: TUrlRecord): Boolean;
var
  Base: TUrlRecord;
begin
  if DocumentBaseUrl(Document, Base) then
    Result := ParseUrl(Text, @Base, Url)
  else
    Result := ParseUrl(Text, nil, Url);
end;

function ResolveUrlText(Document: TDocument; const Text: string; out Resolved: string): Boolean;
var
  Url: TUrlRecord;
begin
  Result := ResolveUrl(Document, Text, Url);
  if Result then
    Resolved := SerializeUrl(Url)
  else
    Resolved := '';
end;

end.
