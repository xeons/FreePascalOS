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
  libcss's element adapter over libweb's DOM.

  The element handles are the TElement objects. Names come from the
  atom map (Web.Style.Atoms), the id atom and the parsed style attribute
  and presentational hints from the node's data (the styler keeps them
  up to date before it asks for a style), the dynamic states from the
  node's data too, plus the ones the document's attributes give (links,
  disabled and checked controls, open details).
}
unit Web.Style.Adapter;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms, Web.Namespaces, Web.Dom, Css.Atoms, Css.Declarations, Css.ElementAdapter;

type
  TDomElementAdapter = class(TCssElementAdapter)
  private
    FDocument: TDocument;
  public
    constructor Create(Document: TDocument);
    function LocalName(Element: TCssElement): TCssAtom; override;
    function NamespaceUri(Element: TCssElement): TCssAtom; override;
    function IsHtmlElementInHtmlDocument(Element: TCssElement): Boolean; override;
    function Id(Element: TCssElement): TCssAtom; override;
    function ClassCount(Element: TCssElement): Integer; override;
    function ClassAt(Element: TCssElement; Index: Integer): TCssAtom; override;
    function FindAttribute(Element: TCssElement; AttributeNamespace, AttributeName: TCssAtom;
      out Value: string): Boolean; override;
    function AttributeCount(Element: TCssElement): Integer; override;
    procedure AttributeAt(Element: TCssElement; Index: Integer; out AttributeNamespace, AttributeName: TCssAtom;
      out Value: string); override;
    function Parent(Element: TCssElement): TCssElement; override;
    function PreviousSibling(Element: TCssElement): TCssElement; override;
    function NextSibling(Element: TCssElement): TCssElement; override;
    function FirstChild(Element: TCssElement): TCssElement; override;
    function LastChild(Element: TCssElement): TCssElement; override;
    function IsEmpty(Element: TCssElement): Boolean; override;
    function IsRoot(Element: TCssElement): Boolean; override;
    function States(Element: TCssElement): TCssElementStates; override;
    function Language(Element: TCssElement): string; override;
    function Direction(Element: TCssElement): TCssDirection; override;
    function QuirksMode: TCssQuirksMode; override;
    function StyleAttribute(Element: TCssElement): TCssDeclarationBlock; override;
    function PresentationalHints(Element: TCssElement): TCssDeclarationBlock; override;
    property Document: TDocument read FDocument;
  end;

{ The element's id as a libcss atom (kept in its node data). }
function ElementIdAtom(Element: TElement): TCssAtom;

implementation

uses
  Web.Style.Atoms, Web.Style.NodeData;

var
  AtomLangAttribute, AtomDirAttribute, AtomOpenAttribute: TAtom;

function ElementIdAtom(Element: TElement): TCssAtom;
var
  Data: PNodeData;
  Value: string;
begin
  if (Element.Flags and NodeFlagHasId) = 0 then
    Exit(NoAtom);
  Data := NodeDataOf(Element);
  if not (ndIdKnown in Data^.Flags) then
  begin
    Value := Element.AttributeValueOf(AtomId);
    if Value = '' then
      Data^.IdAtom := NoAtom
    else
      Data^.IdAtom := InternAtom(Value);
    Include(Data^.Flags, ndIdKnown);
  end;
  Result := Data^.IdAtom;
end;

constructor TDomElementAdapter.Create(Document: TDocument);
begin
  inherited Create;
  FDocument := Document;
end;

function TDomElementAdapter.LocalName(Element: TCssElement): TCssAtom;
begin
  Result := CssAtomOf(TElement(Element).LocalNameAtom);
end;

function TDomElementAdapter.NamespaceUri(Element: TCssElement): TCssAtom;
begin
  Result := CssAtomOf(TElement(Element).NamespaceAtom);
end;

function TDomElementAdapter.IsHtmlElementInHtmlDocument(Element: TCssElement): Boolean;
begin
  Result := TElement(Element).IsHtml and FDocument.IsHtmlDocument;
end;

function TDomElementAdapter.Id(Element: TCssElement): TCssAtom;
begin
  Result := ElementIdAtom(TElement(Element));
end;

function TDomElementAdapter.ClassCount(Element: TCssElement): Integer;
begin
  if (TElement(Element).Flags and NodeFlagHasClass) = 0 then
    Exit(0);
  Result := Length(TElement(Element).ClassAtoms);
end;

function TDomElementAdapter.ClassAt(Element: TCssElement; Index: Integer): TCssAtom;
var
  Classes: TAtomArray;
begin
  Classes := TElement(Element).ClassAtoms;
  if (Index < 0) or (Index >= Length(Classes)) then
    Exit(NoAtom);
  Result := CssAtomOf(Classes[Index]);
end;

function TDomElementAdapter.FindAttribute(Element: TCssElement; AttributeNamespace, AttributeName: TCssAtom;
  out Value: string): Boolean;
var
  Index: Integer;
  RecordPointer: PAttributeRecord;
begin
  Value := '';
  for Index := 0 to TElement(Element).AttributeCount - 1 do
  begin
    RecordPointer := TElement(Element).AttributeAt(Index);
    if (CssAtomOf(RecordPointer^.LocalName) = AttributeName) and
       (CssAtomOf(Web.Namespaces.NamespaceUri(RecordPointer^.NamespaceId)) = AttributeNamespace) then
    begin
      Value := RecordPointer^.Value;
      Exit(True);
    end;
  end;
  Result := False;
end;

function TDomElementAdapter.AttributeCount(Element: TCssElement): Integer;
begin
  Result := TElement(Element).AttributeCount;
end;

procedure TDomElementAdapter.AttributeAt(Element: TCssElement; Index: Integer; out AttributeNamespace,
  AttributeName: TCssAtom; out Value: string);
var
  RecordPointer: PAttributeRecord;
begin
  RecordPointer := TElement(Element).AttributeAt(Index);
  AttributeNamespace := CssAtomOf(Web.Namespaces.NamespaceUri(RecordPointer^.NamespaceId));
  AttributeName := CssAtomOf(RecordPointer^.LocalName);
  Value := RecordPointer^.Value;
end;

function TDomElementAdapter.Parent(Element: TCssElement): TCssElement;
begin
  Result := TElement(Element).ParentElement;
end;

function TDomElementAdapter.PreviousSibling(Element: TCssElement): TCssElement;
begin
  Result := TElement(Element).PreviousElementSibling;
end;

function TDomElementAdapter.NextSibling(Element: TCssElement): TCssElement;
begin
  Result := TElement(Element).NextElementSibling;
end;

function TDomElementAdapter.FirstChild(Element: TCssElement): TCssElement;
begin
  Result := TElement(Element).FirstElementChild;
end;

function TDomElementAdapter.LastChild(Element: TCssElement): TCssElement;
begin
  Result := TElement(Element).LastElementChild;
end;

function TDomElementAdapter.IsEmpty(Element: TCssElement): Boolean;
var
  Child: TNode;
begin
  Child := TElement(Element).FirstChild;
  while Child <> nil do
  begin
    if Child.IsElement then
      Exit(False);
    if Child.IsText and (TCharacterData(Child).Data <> '') then
      Exit(False);
    Child := Child.NextSibling;
  end;
  Result := True;
end;

function TDomElementAdapter.IsRoot(Element: TCssElement): Boolean;
begin
  Result := TElement(Element) = FDocument.DocumentElement;
end;

function IsFormControl(Element: TElement): Boolean;
var
  Name: TAtom;
begin
  if not Element.IsHtml then
    Exit(False);
  Name := Element.LocalNameAtom;
  Result := (Name = AtomInput) or (Name = AtomButton) or (Name = AtomSelect) or (Name = AtomTextarea) or
    (Name = AtomFieldset) or (Name = AtomOptgroup) or (Name = AtomOption);
end;

function TDomElementAdapter.States(Element: TCssElement): TCssElementStates;
var
  Node: TElement;
  Data: PNodeData;
  Name: TAtom;
  InputType: string;
begin
  Node := TElement(Element);
  Data := ExistingNodeData(Node);
  if Data <> nil then
    Result := Data^.States
  else
    Result := [];
  if not Node.IsHtml then
    Exit;
  Include(Result, esDefined);
  Name := Node.LocalNameAtom;
  if ((Name = AtomA) or (Name = AtomArea) or (Name = AtomLink)) and Node.HasAttributeAtom(AtomHref) then
    Include(Result, esLink);
  if IsFormControl(Node) then
  begin
    if Node.HasAttributeAtom(AtomDisabled) then
      Include(Result, esDisabled)
    else
      Include(Result, esEnabled);
    if Node.HasAttributeAtom(AtomRequired) then
      Include(Result, esRequired)
    else
      Include(Result, esOptional);
    if Node.HasAttributeAtom(AtomReadonly) then
      Include(Result, esReadOnly)
    else if (Name = AtomInput) or (Name = AtomTextarea) then
      Include(Result, esReadWrite);
  end;
  if Name = AtomInput then
  begin
    InputType := AsciiLowerCase(Node.AttributeValueOf(AtomType));
    if ((InputType = 'checkbox') or (InputType = 'radio')) and Node.HasAttributeAtom(AtomChecked) then
      Include(Result, esChecked);
    if Node.HasAttributeAtom(AtomPlaceholder) and (Node.AttributeValueOf(AtomValue) = '') then
      Include(Result, esPlaceholderShown);
  end
  else if (Name = AtomOption) and Node.HasAttributeAtom(AtomSelected) then
    Include(Result, esChecked)
  else if ((Name = AtomDetails) or (Name = AtomDialog)) and Node.HasAttributeAtom(AtomOpenAttribute) then
    Include(Result, esOpen);
end;

function TDomElementAdapter.Language(Element: TCssElement): string;
var
  Node: TElement;
begin
  Node := TElement(Element);
  while Node <> nil do
  begin
    if Node.HasAttributeAtom(AtomLangAttribute, NamespaceXml) then
      Exit(Node.AttributeValueOf(AtomLangAttribute, NamespaceXml));
    if Node.HasAttributeAtom(AtomLangAttribute) then
      Exit(Node.AttributeValueOf(AtomLangAttribute));
    Node := Node.ParentElement;
  end;
  Result := '';
end;

function TDomElementAdapter.Direction(Element: TCssElement): TCssDirection;
var
  Node: TElement;
  Value: string;
begin
  Node := TElement(Element);
  while Node <> nil do
  begin
    Value := AsciiLowerCase(Node.AttributeValueOf(AtomDirAttribute));
    if Value = 'rtl' then
      Exit(dirRightToLeft);
    if Value = 'ltr' then
      Exit(dirLeftToRight);
    Node := Node.ParentElement;
  end;
  Result := dirLeftToRight;
end;

function TDomElementAdapter.QuirksMode: TCssQuirksMode;
begin
  case FDocument.Mode of
    DocumentModeQuirks: Result := qmQuirks;
    DocumentModeLimitedQuirks: Result := qmLimitedQuirks;
  else
    Result := qmNoQuirks;
  end;
end;

function TDomElementAdapter.StyleAttribute(Element: TCssElement): TCssDeclarationBlock;
var
  Data: PNodeData;
begin
  Data := ExistingNodeData(TElement(Element));
  if Data = nil then
    Result := nil
  else
    Result := Data^.StyleAttribute;
end;

function TDomElementAdapter.PresentationalHints(Element: TCssElement): TCssDeclarationBlock;
var
  Data: PNodeData;
begin
  Data := ExistingNodeData(TElement(Element));
  if Data = nil then
    Result := nil
  else
    Result := Data^.Hints;
end;

initialization
  AtomLangAttribute := Atomize('lang');
  AtomDirAttribute := Atomize('dir');
  AtomOpenAttribute := Atomize('open');
end.
