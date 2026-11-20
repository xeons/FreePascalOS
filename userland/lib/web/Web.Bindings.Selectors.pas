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
  Selectors from script (DOM Standard "scope-match a selectors string"):
  querySelector, querySelectorAll, matches and closest with libcss's
  selector parser and matcher.

  TDomElementAdapter is a minimal element adapter for libcss over the
  DOM, enough for matching from script: names, ids and classes are
  libweb atoms translated to libcss atoms through a table indexed by the
  libweb atom; the dynamic states are the ones the DOM knows (link,
  checked, disabled, enabled, required, optional, placeholder-shown,
  read-only, read-write, defined). It is to be merged with the style
  system's adapter (Web.Style*) when that lands, which will know hover,
  focus and the rest from the input code.

  Parsed selector lists are cached by their text (a few recent ones).
}
unit Web.Bindings.Selectors;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Css.Atoms,
  Css.ElementAdapter,
  Css.Selectors,
  Css.SelectorParser,
  Css.SelectorMatching,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom,
  Web.Dom.Exceptions;

type
  TDomElementAdapter = class(TCssElementAdapter)
  private
    FDocument: TDocument;
  public
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
    function QuirksMode: TCssQuirksMode; override;
    property Document: TDocument read FDocument write FDocument;
  end;

{ The libcss atom of a libweb atom. }
function CssAtomOf(Atom: TAtom): TCssAtom;

function QuerySelector(Root: TNode; const Selectors: string): TElement;
function QuerySelectorAll(Root: TNode; const Selectors: string): TNodeArray;
function ElementMatches(Element: TElement; const Selectors: string): Boolean;
function ElementClosest(Element: TElement; const Selectors: string): TElement;

implementation

var
  AtomMap: array of TCssAtom;
  NamespaceAtoms: array of TCssAtom;
  CachedTexts: array[0..15] of string;
  CachedLists: array[0..15] of TCssSelectorList;
  NextCacheSlot: Integer;

function CssAtomOf(Atom: TAtom): TCssAtom;
var
  OldLength, Index: Integer;
begin
  if Atom = AtomNone then
    Exit(NoAtom);
  if Atom >= LongWord(Length(AtomMap)) then
  begin
    OldLength := Length(AtomMap);
    SetLength(AtomMap, Atom + 256);
    for Index := OldLength to High(AtomMap) do
      AtomMap[Index] := NoAtom;
  end;
  Result := AtomMap[Atom];
  if Result = NoAtom then
  begin
    Result := InternAtom(NameOfAtom(Atom));
    AtomMap[Atom] := Result;
  end;
end;

function NamespaceCssAtom(Namespace: TNamespaceId): TCssAtom;
var
  OldLength, Index: Integer;
begin
  if Web.Namespaces.NamespaceUri(Namespace) = AtomNone then
    Exit(NoAtom);
  if Namespace >= Length(NamespaceAtoms) then
  begin
    OldLength := Length(NamespaceAtoms);
    SetLength(NamespaceAtoms, Namespace + 16);
    for Index := OldLength to High(NamespaceAtoms) do
      NamespaceAtoms[Index] := NoAtom;
  end;
  Result := NamespaceAtoms[Namespace];
  if Result = NoAtom then
  begin
    Result := CssAtomOf(Web.Namespaces.NamespaceUri(Namespace));
    NamespaceAtoms[Namespace] := Result;
  end;
end;

function AsElement(Element: TCssElement): TElement; inline;
begin
  Result := TElement(Element);
end;

{ TDomElementAdapter }

function TDomElementAdapter.LocalName(Element: TCssElement): TCssAtom;
begin
  Result := CssAtomOf(AsElement(Element).LocalNameAtom);
end;

function TDomElementAdapter.NamespaceUri(Element: TCssElement): TCssAtom;
begin
  Result := NamespaceCssAtom(AsElement(Element).NamespaceId);
end;

function TDomElementAdapter.IsHtmlElementInHtmlDocument(Element: TCssElement): Boolean;
begin
  Result := AsElement(Element).IsHtml and AsElement(Element).NodeDocument.IsHtmlDocument;
end;

function TDomElementAdapter.Id(Element: TCssElement): TCssAtom;
var
  Index: Integer;
begin
  Index := AsElement(Element).AttributeIndexOf(AtomId);
  if Index < 0 then
    Exit(NoAtom);
  Result := InternAtom(AsElement(Element).AttributeAt(Index)^.Value);
end;

function TDomElementAdapter.ClassCount(Element: TCssElement): Integer;
begin
  Result := Length(AsElement(Element).ClassAtoms);
end;

function TDomElementAdapter.ClassAt(Element: TCssElement; Index: Integer): TCssAtom;
begin
  Result := CssAtomOf(AsElement(Element).ClassAtoms[Index]);
end;

function TDomElementAdapter.FindAttribute(Element: TCssElement; AttributeNamespace, AttributeName: TCssAtom;
  out Value: string): Boolean;
var
  Index: Integer;
  Attribute: PAttributeRecord;
begin
  for Index := 0 to AsElement(Element).AttributeCount - 1 do
  begin
    Attribute := AsElement(Element).AttributeAt(Index);
    if (CssAtomOf(Attribute^.LocalName) = AttributeName) and
      (NamespaceCssAtom(Attribute^.NamespaceId) = AttributeNamespace) then
    begin
      Value := Attribute^.Value;
      Exit(True);
    end;
  end;
  Value := '';
  Result := False;
end;

function TDomElementAdapter.AttributeCount(Element: TCssElement): Integer;
begin
  Result := AsElement(Element).AttributeCount;
end;

procedure TDomElementAdapter.AttributeAt(Element: TCssElement; Index: Integer; out AttributeNamespace,
  AttributeName: TCssAtom; out Value: string);
var
  Attribute: PAttributeRecord;
begin
  Attribute := AsElement(Element).AttributeAt(Index);
  AttributeNamespace := NamespaceCssAtom(Attribute^.NamespaceId);
  AttributeName := CssAtomOf(Attribute^.LocalName);
  Value := Attribute^.Value;
end;

function TDomElementAdapter.Parent(Element: TCssElement): TCssElement;
begin
  Result := AsElement(Element).ParentElement;
end;

function TDomElementAdapter.PreviousSibling(Element: TCssElement): TCssElement;
begin
  Result := AsElement(Element).PreviousElementSibling;
end;

function TDomElementAdapter.NextSibling(Element: TCssElement): TCssElement;
begin
  Result := AsElement(Element).NextElementSibling;
end;

function TDomElementAdapter.FirstChild(Element: TCssElement): TCssElement;
begin
  Result := AsElement(Element).FirstElementChild;
end;

function TDomElementAdapter.LastChild(Element: TCssElement): TCssElement;
begin
  Result := AsElement(Element).LastElementChild;
end;

function TDomElementAdapter.IsEmpty(Element: TCssElement): Boolean;
var
  Child: TNode;
begin
  Child := AsElement(Element).FirstChild;
  while Child <> nil do
  begin
    if Child.NodeType = NodeTypeElement then
      Exit(False);
    if (Child.NodeType in [NodeTypeText, NodeTypeCDataSection]) and (TCharacterData(Child).Data <> '') then
      Exit(False);
    Child := Child.NextSibling;
  end;
  Result := True;
end;

function TDomElementAdapter.IsRoot(Element: TCssElement): Boolean;
begin
  Result := (AsElement(Element).ParentNode <> nil) and (AsElement(Element).ParentNode.NodeType = NodeTypeDocument);
end;

function IsFormControl(Element: TElement): Boolean;
begin
  Result := Element.IsHtml and ((Element.LocalNameAtom = AtomInput) or (Element.LocalNameAtom = AtomButton) or
    (Element.LocalNameAtom = AtomSelect) or (Element.LocalNameAtom = AtomTextarea) or
    (Element.LocalNameAtom = AtomOptgroup) or (Element.LocalNameAtom = AtomOption) or
    (Element.LocalNameAtom = AtomFieldset));
end;

function IsTextControl(Element: TElement): Boolean;
var
  InputType: string;
begin
  if Element.IsHtmlElement(AtomTextarea) then
    Exit(True);
  if not Element.IsHtmlElement(AtomInput) then
    Exit(False);
  InputType := AsciiLowerCase(Element.AttributeValueOf(AtomType));
  Result := (InputType = '') or (InputType = 'text') or (InputType = 'search') or (InputType = 'url') or
    (InputType = 'tel') or (InputType = 'email') or (InputType = 'password') or (InputType = 'number');
end;

function TDomElementAdapter.States(Element: TCssElement): TCssElementStates;
var
  Target: TElement;
begin
  Target := AsElement(Element);
  Result := [esDefined];
  if not Target.IsHtml then
    Exit;
  if ((Target.LocalNameAtom = AtomA) or (Target.LocalNameAtom = AtomArea) or (Target.LocalNameAtom = AtomLink)) and
    Target.HasAttributeAtom(AtomHref) then
    Include(Result, esLink);
  if IsFormControl(Target) then
  begin
    if Target.HasAttributeAtom(AtomDisabled) then
      Include(Result, esDisabled)
    else
      Include(Result, esEnabled);
  end;
  if (Target.IsHtmlElement(AtomInput) and Target.HasAttributeAtom(AtomChecked)) or
    (Target.IsHtmlElement(AtomOption) and Target.HasAttributeAtom(AtomSelected)) then
    Include(Result, esChecked);
  if Target.IsHtmlElement(AtomInput) or Target.IsHtmlElement(AtomSelect) or Target.IsHtmlElement(AtomTextarea) then
  begin
    if Target.HasAttributeAtom(AtomRequired) then
      Include(Result, esRequired)
    else
      Include(Result, esOptional);
  end;
  if IsTextControl(Target) then
  begin
    if Target.HasAttributeAtom(AtomReadonly) or Target.HasAttributeAtom(AtomDisabled) then
      Include(Result, esReadOnly)
    else
      Include(Result, esReadWrite);
    if Target.HasAttributeAtom(AtomPlaceholder) and (Target.AttributeValueOf(AtomValue) = '') then
      Include(Result, esPlaceholderShown);
  end
  else
    Include(Result, esReadOnly);
  if (Target.IsHtmlElement(AtomDetails) or Target.IsHtmlElement(AtomDialog)) and
    Target.HasAttributeAtom(Atomize('open')) then
    Include(Result, esOpen);
end;

function TDomElementAdapter.Language(Element: TCssElement): string;
var
  Node: TElement;
begin
  Node := AsElement(Element);
  while Node <> nil do
  begin
    if Node.HasAttributeAtom(AtomLang) then
      Exit(Node.AttributeValueOf(AtomLang));
    Node := Node.ParentElement;
  end;
  Result := '';
end;

function TDomElementAdapter.QuirksMode: TCssQuirksMode;
begin
  Result := qmNoQuirks;
  if FDocument <> nil then
    case FDocument.Mode of
      DocumentModeQuirks:
        Result := qmQuirks;
      DocumentModeLimitedQuirks:
        Result := qmLimitedQuirks;
    end;
end;

{ Matching }

function ParsedSelectors(const Text: string): TCssSelectorList;
var
  Index: Integer;
begin
  for Index := 0 to High(CachedTexts) do
    if (CachedLists[Index] <> nil) and (CachedTexts[Index] = Text) then
      Exit(CachedLists[Index]);
  Result := ParseSelectorText(Text);
  if Result = nil then
    RaiseDomError(SyntaxError, '''' + Text + ''' is not a valid selector');
  CachedLists[NextCacheSlot].Free;
  CachedLists[NextCacheSlot] := Result;
  CachedTexts[NextCacheSlot] := Text;
  NextCacheSlot := (NextCacheSlot + 1) mod Length(CachedTexts);
end;

type
  TQuery = record
    Adapter: TDomElementAdapter;
    Matcher: TCssSelectorMatcher;
    List: TCssSelectorList;
  end;

procedure StartQuery(out Query: TQuery; Scope: TNode; const Selectors: string);
begin
  Query.List := ParsedSelectors(Selectors);
  Query.Adapter := TDomElementAdapter.Create;
  Query.Adapter.Document := Scope.NodeDocument;
  Query.Matcher := TCssSelectorMatcher.Create(Query.Adapter);
  if Scope.NodeType = NodeTypeElement then
    Query.Matcher.Scope := Scope
  else
    Query.Matcher.Scope := nil;
end;

procedure FinishQuery(var Query: TQuery);
begin
  Query.Matcher.Free;
  Query.Adapter.Free;
end;

function QuerySelector(Root: TNode; const Selectors: string): TElement;
var
  Query: TQuery;
  Node: TNode;
begin
  Result := nil;
  StartQuery(Query, Root, Selectors);
  try
    Node := Root.FirstChild;
    while Node <> nil do
    begin
      if (Node.NodeType = NodeTypeElement) and Query.Matcher.MatchesList(Query.List, Node) then
        Exit(TElement(Node));
      Node := Node.NextInTree(Root);
    end;
  finally
    FinishQuery(Query);
  end;
end;

function QuerySelectorAll(Root: TNode; const Selectors: string): TNodeArray;
var
  Query: TQuery;
  Node: TNode;
  Count: Integer;
begin
  Result := nil;
  Count := 0;
  StartQuery(Query, Root, Selectors);
  try
    Node := Root.FirstChild;
    while Node <> nil do
    begin
      if (Node.NodeType = NodeTypeElement) and Query.Matcher.MatchesList(Query.List, Node) then
      begin
        if Count >= Length(Result) then
          SetLength(Result, Count * 2 + 8);
        Result[Count] := Node;
        Inc(Count);
      end;
      Node := Node.NextInTree(Root);
    end;
  finally
    FinishQuery(Query);
  end;
  SetLength(Result, Count);
end;

function ElementMatches(Element: TElement; const Selectors: string): Boolean;
var
  Query: TQuery;
begin
  StartQuery(Query, Element, Selectors);
  try
    Result := Query.Matcher.MatchesList(Query.List, Element);
  finally
    FinishQuery(Query);
  end;
end;

function ElementClosest(Element: TElement; const Selectors: string): TElement;
var
  Query: TQuery;
begin
  StartQuery(Query, Element, Selectors);
  try
    Result := Element;
    while Result <> nil do
    begin
      if Query.Matcher.MatchesList(Query.List, Result) then
        Exit;
      Result := Result.ParentElement;
    end;
  finally
    FinishQuery(Query);
  end;
end;

procedure FreeCache;
var
  Index: Integer;
begin
  for Index := 0 to High(CachedLists) do
    FreeAndNil(CachedLists[Index]);
end;

finalization
  FreeCache;
end.
