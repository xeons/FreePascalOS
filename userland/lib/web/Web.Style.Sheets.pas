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
  The document's style sheets in effect, in tree order.

  Each <style> element's sheet comes from Web.Style.DocumentSheets
  (parsed again only when its text changes, shared with the CSSOM); a
  <link rel=stylesheet>'s sheet is the one the loader gave the
  document's resources; adopted sheets (adoptedStyleSheets) come last. A media attribute becomes the sheet's media
  list; alternate style sheets and disabled links do not apply. The
  user sheets of the resources come first (user origin).
}
unit Web.Style.Sheets;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Css.Stylesheets, Web.Layout.Resources;

type
  TCssStyleSheetArray = array of TCssStyleSheet;

  TDocumentSheetList = class
  private
    FDocument: TDocument;
    FResources: TDocumentResources;
  public
    constructor Create(Document: TDocument; Resources: TDocumentResources);
    { Every sheet that applies now, user sheets first, then the author
      sheets in tree order, then the adopted ones. }
    function Collect: TCssStyleSheetArray;
    { The author sheets of a shadow tree: its <style> and <link> sheets
      in tree order, then its adopted ones. }
    function CollectShadowRoot(Shadow: TShadowRoot): TCssStyleSheetArray;
  end;

{ Whether an element owns a style sheet (<style>, <link rel=stylesheet>),
  so changing it changes the sheets. }
function IsStyleSheetOwner(Element: TElement): Boolean;

implementation

uses
  SysUtils, Web.Atoms, Web.Style.DocumentSheets;

function IsStyleSheetOwner(Element: TElement): Boolean;
begin
  Result := Element.IsHtmlElement(AtomStyle) or Element.IsHtmlElement(AtomLink);
end;

function RelHas(const Rel, Token: string): Boolean;
var
  Lowered: string;
  Position, StartPosition: Integer;
begin
  Lowered := AsciiLowerCase(Rel);
  Position := 1;
  while Position <= Length(Lowered) do
  begin
    while (Position <= Length(Lowered)) and (Lowered[Position] in [#9, #10, #12, #13, ' ']) do
      Inc(Position);
    StartPosition := Position;
    while (Position <= Length(Lowered)) and not (Lowered[Position] in [#9, #10, #12, #13, ' ']) do
      Inc(Position);
    if Copy(Lowered, StartPosition, Position - StartPosition) = Token then
      Exit(True);
  end;
  Result := False;
end;

constructor TDocumentSheetList.Create(Document: TDocument; Resources: TDocumentResources);
begin
  inherited Create;
  FDocument := Document;
  FResources := Resources;
  if Resources <> nil then
    DocumentSheetsOf(Document).OnSheetParsed := @Resources.RequestImports;
end;

procedure AddSheet(Item: TCssStyleSheet; var Result: TCssStyleSheetArray; var Count: Integer);
begin
  if Item = nil then
    Exit;
  if Count >= Length(Result) then
    SetLength(Result, Count * 2 + 4);
  Result[Count] := Item;
  Inc(Count);
end;

{ The <style> and <link rel=stylesheet> sheets of Root's tree in tree
  order (not inside templates or shadow trees), appended to Result. }
procedure CollectTreeSheets(Root: TNode; Resources: TDocumentResources; var Result: TCssStyleSheetArray;
  var Count: Integer);
var
  Node: TNode;
  Element: TElement;
  Sheet: TCssStyleSheet;
  Sheets: TDocumentSheets;
begin
  Sheets := DocumentSheetsOf(Root.NodeDocument);
  Node := Root.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      Element := TElement(Node);
      if Element.IsHtmlElement(AtomStyle) then
        AddSheet(Sheets.StyleElementSheet(Element), Result, Count)
      else if Element.IsHtmlElement(AtomLink) and (Resources <> nil) then
      begin
        Sheet := Resources.ElementStyleSheet(Element);
        if (Sheet <> nil) and RelHas(Element.AttributeValueOf(AtomRel), 'stylesheet') and
           not RelHas(Element.AttributeValueOf(AtomRel), 'alternate') and
           not Element.HasAttributeAtom(AtomDisabled) then
          AddSheet(Sheet, Result, Count);
      end
      else if Element.IsHtmlElement(AtomTemplate) then
      begin
        Node := Node.NextInTreeSkippingChildren(Root);
        Continue;
      end;
    end;
    Node := Node.NextInTree(Root);
  end;
end;

function TDocumentSheetList.Collect: TCssStyleSheetArray;
var
  Count, Index: Integer;
  Sheets: TDocumentSheets;
begin
  Result := nil;
  Count := 0;
  Sheets := DocumentSheetsOf(FDocument);
  if FResources <> nil then
    for Index := 0 to FResources.UserStyleSheetCount - 1 do
      AddSheet(FResources.UserStyleSheet(Index), Result, Count);
  CollectTreeSheets(FDocument, FResources, Result, Count);
  for Index := 0 to High(Sheets.AdoptedSheets) do
    AddSheet(Sheets.AdoptedSheets[Index], Result, Count);
  SetLength(Result, Count);
end;

function TDocumentSheetList.CollectShadowRoot(Shadow: TShadowRoot): TCssStyleSheetArray;
var
  Count, Index: Integer;
  Adopted: TCssStyleSheetList;
begin
  Result := nil;
  Count := 0;
  CollectTreeSheets(Shadow, FResources, Result, Count);
  Adopted := ShadowRootAdoptedSheets(Shadow);
  for Index := 0 to High(Adopted) do
    AddSheet(Adopted[Index], Result, Count);
  SetLength(Result, Count);
end;

end.
