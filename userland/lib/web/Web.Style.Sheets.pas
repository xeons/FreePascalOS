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

  Each <style> element's sheet is parsed here and kept with the text it
  came from, so it is parsed again only when that text changes; a
  <link rel=stylesheet>'s sheet is the one the loader gave the
  document's resources. A media attribute becomes the sheet's media
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
  TStyleElementSheet = record
    Owner: TElement;
    Source: string;
    Media: string;
    Sheet: TCssStyleSheet;
    Used: Boolean;
  end;

  TCssStyleSheetArray = array of TCssStyleSheet;

  TDocumentSheetList = class
  private
    FDocument: TDocument;
    FResources: TDocumentResources;
    FStyleSheets: array of TStyleElementSheet;
    function SheetForStyleElement(Element: TElement): TCssStyleSheet;
    procedure DropUnused;
  public
    constructor Create(Document: TDocument; Resources: TDocumentResources);
    destructor Destroy; override;
    { Every sheet that applies now, user sheets first, then the author
      sheets in tree order. }
    function Collect: TCssStyleSheetArray;
  end;

{ Whether an element owns a style sheet (<style>, <link rel=stylesheet>),
  so changing it changes the sheets. }
function IsStyleSheetOwner(Element: TElement): Boolean;

implementation

uses
  Web.Profiling,
  SysUtils, Web.Atoms, Css.Parser, Css.MediaQueries;

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
end;

destructor TDocumentSheetList.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FStyleSheets) do
    FStyleSheets[Index].Sheet.Free;
  inherited Destroy;
end;

function TDocumentSheetList.SheetForStyleElement(Element: TElement): TCssStyleSheet;
var
  Index, Found: Integer;
  Source, Media: string;
  Rule: Integer;
  HasImports: Boolean;
begin
  Source := DescendantTextContent(Element);
  Media := Element.AttributeValueOf(AtomMedia);
  Found := -1;
  for Index := 0 to High(FStyleSheets) do
    if FStyleSheets[Index].Owner = Element then
    begin
      Found := Index;
      Break;
    end;
  if Found >= 0 then
  begin
    FStyleSheets[Found].Used := True;
    if (FStyleSheets[Found].Source = Source) and (FStyleSheets[Found].Media = Media) then
      Exit(FStyleSheets[Found].Sheet);
    FStyleSheets[Found].Sheet.Free;
    FStyleSheets[Found].Sheet := nil;
  end;
  EnterPhase(PhaseStyleSheetParse);
  try
    Result := ParseStyleSheet(Source, coAuthor, FDocument.Url);
  finally
    LeavePhase;
  end;
  if Trim(Media) <> '' then
    Result.Media := ParseMediaQueryText(Media);
  Index := Found;
  if Index < 0 then
  begin
    SetLength(FStyleSheets, Length(FStyleSheets) + 1);
    Index := High(FStyleSheets);
    FStyleSheets[Index].Owner := Element;
  end;
  FStyleSheets[Index].Source := Source;
  FStyleSheets[Index].Media := Media;
  FStyleSheets[Index].Sheet := Result;
  FStyleSheets[Index].Used := True;
  HasImports := False;
  for Rule := 0 to High(Result.Rules) do
    if Result.Rules[Rule].Kind = rkImport then
      HasImports := True;
  if HasImports and (FResources <> nil) then
    FResources.RequestImports(Result, Element);
end;

procedure TDocumentSheetList.DropUnused;
var
  Index: Integer;
begin
  Index := 0;
  while Index < Length(FStyleSheets) do
    if not FStyleSheets[Index].Used then
    begin
      FStyleSheets[Index].Sheet.Free;
      FStyleSheets[Index] := FStyleSheets[High(FStyleSheets)];
      SetLength(FStyleSheets, Length(FStyleSheets) - 1);
    end
    else
      Inc(Index);
end;

function TDocumentSheetList.Collect: TCssStyleSheetArray;
var
  Count, Index: Integer;
  Node: TNode;
  Element: TElement;
  Sheet: TCssStyleSheet;

  procedure Add(Item: TCssStyleSheet);
  begin
    if Item = nil then
      Exit;
    if Count >= Length(Result) then
      SetLength(Result, Count * 2 + 4);
    Result[Count] := Item;
    Inc(Count);
  end;

begin
  Result := nil;
  Count := 0;
  for Index := 0 to High(FStyleSheets) do
    FStyleSheets[Index].Used := False;
  if FResources <> nil then
    for Index := 0 to FResources.UserStyleSheetCount - 1 do
      Add(FResources.UserStyleSheet(Index));
  Node := FDocument.FirstChild;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      Element := TElement(Node);
      if Element.IsHtmlElement(AtomStyle) then
        Add(SheetForStyleElement(Element))
      else if Element.IsHtmlElement(AtomLink) and (FResources <> nil) then
      begin
        Sheet := FResources.ElementStyleSheet(Element);
        if (Sheet <> nil) and RelHas(Element.AttributeValueOf(AtomRel), 'stylesheet') and
           not RelHas(Element.AttributeValueOf(AtomRel), 'alternate') and
           not Element.HasAttributeAtom(AtomDisabled) then
          Add(Sheet);
      end
      else if Element.IsHtmlElement(AtomTemplate) then
      begin
        Node := Node.NextInTreeSkippingChildren(FDocument);
        Continue;
      end;
    end;
    Node := Node.NextInTree(FDocument);
  end;
  SetLength(Result, Count);
  DropUnused;
end;

end.
