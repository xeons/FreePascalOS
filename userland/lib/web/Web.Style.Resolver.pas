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
  Styling a document: libcss's style engine over the DOM.

  TDocumentStyler owns the engine and the adapter, keeps the engine's
  sheets in step with the document's (Web.Style.Sheets), and computes
  styles top-down with the ancestor bloom filter, visiting only the
  subtrees whose dirty bits say something changed. It is a document
  observer: tree, attribute and text changes set the dirty bits (an
  inserted subtree and the siblings that structural selectors may now
  match differently; for an element whose class, id or other attribute
  changed what the selectors naming them reach (Css.NameInvalidation);
  a style attribute change only the element), and changes to <style>
  and <link> elements mark the sheets dirty.

  After restyling an element the styler compares the new style with
  the old one struct by struct (structs are interned, so pointers
  compare) and tells its client (the layout) what kind of change it was:
  boxes must be built again (display, position, float, generated
  content), layout must be done again, or only painting. A change in
  an inherited group restyles the children too.
}
unit Web.Style.Resolver;

{$mode objfpc}
{$H+}

interface

uses
  Web.Atoms, Web.Namespaces, Web.Dom, Css.ComputedStyle, Css.StyleEngine, Css.MediaQueries,
  Css.ElementAdapter, Css.Selectors, Css.TreeScopes, Web.Style.NodeData, Web.Style.Adapter, Web.Style.Sheets,
  Web.Layout.Resources, Css.Stylesheets, Web.Style.DocumentSheets, Web.Style.Animations, Web.Style.SheetChanges;

type
  { scMove: painting and the box's translation (transform, translate),
    which layout keeps as an offset of the box. }
  TStyleChangeKind = (scNone, scPaint, scMove, scLayout, scBoxes);

  TStyleChangedEvent = procedure(Element: TElement; Change: TStyleChangeKind) of object;
  TNodeChangedEvent = procedure(Node: TNode) of object;

  TDocumentStyler = class(TDocumentObserver)
  private
    FDocument: TDocument;
    FResources: TDocumentResources;
    FAdapter: TDomElementAdapter;
    FEngine: TCssStyleEngine;
    FAnimations: TStyleAnimations;
    FSheetList: TDocumentSheetList;
    FActiveSheets: TCssStyleSheetArray;
    FSheetsDirty: Boolean;
    { The resources said sheets changed: imports may have been hung on
      sheets already in use, so the engine indexes them again. }
    FSheetContentsChanged: Boolean;
    FTreeChanged: Boolean;
    FOnStyleChanged: TStyleChangedEvent;
    FOnTextChanged: TNodeChangedEvent;
    FOnNodeRemoved: TNodeChangedEvent;
    FOnChildrenChanged: TNodeChangedEvent;
    FOnElementAttributeChanged: TNodeChangedEvent;
    FStylesComputed: Int64;
    FAuthorStylesDisabled: Boolean;
    { Bumped whenever sheets may have changed: each shadow tree's scope
      collects its sheets again when it is behind. }
    FShadowSheetsVersion: LongWord;
    { What rules newly in effect may style, marked at the next update. }
    FNewRuleTargets: TStyleRuleTargets;
    procedure SetAuthorStylesEnabled(Value: Boolean);
    function GetAuthorStylesEnabled: Boolean;
    procedure ResourcesChanged(Change: TResourceChange);
    procedure DocumentSheetsChanged(Change: TSheetChange; Sheet: TCssStyleSheet; Rule: TCssRule);
    procedure UpdateSheets;
    procedure NoteSheetChange(const Old, New: TCssStyleSheetArray; ContentsChanged: Boolean);
    procedure PrepareElement(Element: TElement; Data: PNodeData);
    procedure StyleChildren(Parent: TNode; ParentStyle: TCssComputedStyle; Force: Boolean);
    function StyleElement(Element: TElement; Data: PNodeData; ParentStyle: TCssComputedStyle;
      Cascade: Boolean): Boolean;
    procedure ResolvePseudoStyles(Element: TElement; Data: PNodeData; AfterElement: Boolean;
      var Change: TStyleChangeKind);
    procedure MarkSiblingsDirty(Parent: TNode);
    procedure MarkLaterSiblingsDirty(Element: TElement);
    function CanNarrowAttributeChange(Element: TElement; NamespaceId: TNamespaceId): Boolean;
    procedure MarkAttributeChangeDirty(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue: string);
    procedure CheckSheetOwner(Node: TNode);
    procedure ShadowSheetsChanged(Node: TNode);
    function UpdateShadowScope(Host: TElement): Boolean;
    procedure MarkAssignedNodesDirty(Slot: TElement);
  public
    constructor Create(Document: TDocument; Resources: TDocumentResources);
    destructor Destroy; override;
    { Computes the styles that are dirty. }
    procedure UpdateStyles;
    { The media environment changed (viewport size, scale, color scheme). }
    procedure SetEnvironment(const Environment: TCssMediaEnvironment);
    { Sets an element's dynamic states (hover, focus ...): the web view. }
    procedure SetElementStates(Element: TElement; States: TCssElementStates);
    { Everything must be styled again. }
    procedure InvalidateAll;
    { Style of an anonymous box under ParentStyle (a new reference). }
    function AnonymousStyle(ParentStyle: TCssComputedStyle): TCssComputedStyle;
    { The style Element would have under ParentStyle (a new reference),
      whether or not it is styled in place: for content inline SVG's
      <use> instantiates, which may sit in a hidden sprite sheet. }
    function ResolveStyleUnder(Element: TElement; ParentStyle: TCssComputedStyle): TCssComputedStyle;
    { getComputedStyle's style of the element or one of its pseudo-elements
      (a new reference, nil for a node outside the flat tree): an element
      not styled in place (under display: none) is styled for the asking,
      down from its nearest styled ancestor, as other browsers do. }
    function StyleForScript(Element: TElement; PseudoElement: TCssPseudoElement): TCssComputedStyle;
    { Observer }
    procedure TreeMutated(Target: TNode; const Added, Removed: TNodeArray; PreviousSibling, NextSibling: TNode);
      override;
    procedure NodeDisconnected(Node: TNode); override;
    procedure AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue: string; HadValue: Boolean); override;
    procedure CharacterDataChanged(Node: TCharacterData; const OldValue: string); override;
    procedure ControlStateChanged(Element: TElement); override;
    procedure ShadowRootAttached(Host: TElement); override;
    procedure SlotAssignmentChanged(Slot: TElement); override;
    procedure CustomElementStateChanged(Element: TElement); override;
    property Document: TDocument read FDocument;
    property Engine: TCssStyleEngine read FEngine;
    { Running animations and transitions (Web.Style.Animations). }
    property Animations: TStyleAnimations read FAnimations;
    property Adapter: TDomElementAdapter read FAdapter;
    property Resources: TDocumentResources read FResources;
    property StylesComputed: Int64 read FStylesComputed;
    { The sheets changed (one loaded, was added or removed) and are
      collected again at the next update. }
    property SheetsDirty: Boolean read FSheetsDirty;
    { The document's own sheets and style attributes count (on unless
      turned off: then only the user agent's sheet and presentational
      hints style the page). }
    property AuthorStylesEnabled: Boolean read GetAuthorStylesEnabled write SetAuthorStylesEnabled;
    property OnStyleChanged: TStyleChangedEvent read FOnStyleChanged write FOnStyleChanged;
    property OnTextChanged: TNodeChangedEvent read FOnTextChanged write FOnTextChanged;
    property OnNodeRemoved: TNodeChangedEvent read FOnNodeRemoved write FOnNodeRemoved;
    property OnChildrenChanged: TNodeChangedEvent read FOnChildrenChanged write FOnChildrenChanged;
    property OnElementAttributeChanged: TNodeChangedEvent read FOnElementAttributeChanged
      write FOnElementAttributeChanged;
  end;

{ How a style changed from Old to New (Old nil: it is new). }
function CompareStyles(Old, New: TCssComputedStyle): TStyleChangeKind;

implementation

uses
  Css.PropertyIds, Css.StateInvalidation, Css.NameInvalidation, Css.StyleStructs, Css.ComputedValues, Css.Keywords,
  Css.Parser, Web.Style.Hints, Web.Style.UserAgent, Web.Style.AttributeChanges, Web.Fetch.Requests,
  Web.Fetch.CspChecks;

type
  { A shadow tree's style scope with the sheets version it collected. }
  TShadowStyleScope = class(TCssTreeScope)
  public
    SheetsVersion: LongWord;
    Collected: Boolean;
  end;

var
  AtomStyleAttribute: TAtom;

function SameValue(Old, New: TCssComputedStyle; Id: TCssPropertyId): Boolean;
begin
  Result := SameComputed(Old.Value(Id)^, New.Value(Id)^);
end;

function CompareStyles(Old, New: TCssComputedStyle): TStyleChangeKind;
const
  LayoutGroups = [pgFont, pgInheritedText, pgInheritedTable, pgList, pgBox, pgPosition, pgMargin, pgPadding,
    pgBorder, pgTable, pgColumn];
var
  Group: TCssStructGroup;
begin
  if Old = New then
    Exit(scNone);
  if (Old = nil) or (New = nil) then
    Exit(scBoxes);
  if Old.Structs[pgBox] <> New.Structs[pgBox] then
    if not SameValue(Old, New, cpDisplay) or not SameValue(Old, New, cpPosition) or
       not SameValue(Old, New, cpFloat) then
      Exit(scBoxes);
  if (Old.Structs[pgContent] <> New.Structs[pgContent]) or (Old.Structs[pgList] <> New.Structs[pgList]) then
    Exit(scBoxes);
  Result := scNone;
  for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
    if Old.Structs[Group] <> New.Structs[Group] then
    begin
      if Group in LayoutGroups then
        Exit(scLayout);
      Result := scPaint;
    end;
  if (Result = scPaint) and (not SameValue(Old, New, cpTransform) or not SameValue(Old, New, cpTranslate)) then
    Result := scMove;
end;

{ display: list-item in its two value forms (inline list-item). }
function IsListItemDisplay(Style: TCssComputedStyle): Boolean;
var
  Value: PCssComputedValue;
  Index: Integer;
begin
  Value := Style.Value(cpDisplay);
  Result := False;
  if (Value^.Kind = cvValue) and (Value^.Data <> nil) then
    for Index := 0 to Value^.Data.Count - 1 do
      if Value^.Data.Items[Index].IsKeyword(kwListItem) then
        Exit(True);
end;

function InheritedChanged(Old, New: TCssComputedStyle): Boolean;
var
  Group: TCssStructGroup;
begin
  if (Old = nil) or (New = nil) then
    Exit(True);
  for Group := Low(TCssStructGroup) to High(TCssStructGroup) do
    if (Group in InheritedGroups) and (Old.Structs[Group] <> New.Structs[Group]) then
      Exit(True);
  { Equal sets made separately (an element declaring variables gets a new
    one each time) change nothing below. }
  Result := not Old.Custom.Equals(New.Custom);
end;

{ An equal custom property set made again (an element declaring
  variables gets a new one each time) gives way to the old one, whose
  pointer the children's sets are layered over and the engine's
  substitution cache is keyed by: equal content, so the style stays
  what it was computed to be. }
procedure KeepEqualCustomProperties(Old, New: TCssComputedStyle);
begin
  if (Old = nil) or (New = nil) or (Old.Custom = New.Custom) or not Old.Custom.Equals(New.Custom) then
    Exit;
  New.Custom.Release;
  New.Custom := Old.Custom.AddRef;
end;

constructor TDocumentStyler.Create(Document: TDocument; Resources: TDocumentResources);
begin
  inherited Create;
  FDocument := Document;
  FResources := Resources;
  FAdapter := TDomElementAdapter.Create(Document);
  FEngine := TCssStyleEngine.Create(FAdapter, True);
  FAnimations := TStyleAnimations.Create(FEngine);
  FSheetList := TDocumentSheetList.Create(Document, Resources);
  FNewRuleTargets := TStyleRuleTargets.Create;
  { The engine's additions to the user agent sheet come first. }
  FEngine.AddStyleSheet(EngineUserAgentSheet);
  FSheetsDirty := True;
  if FResources <> nil then
    FResources.AddListener(@ResourcesChanged);
  DocumentSheetsOf(Document).AddListener(@DocumentSheetsChanged);
  Document.AddObserver(Self);
  MarkSubtreeStyleDirty(Document);
end;

destructor TDocumentStyler.Destroy;
begin
  FDocument.RemoveObserver(Self);
  if FResources <> nil then
    FResources.RemoveListener(@ResourcesChanged);
  if ExistingDocumentSheets(FDocument) <> nil then
    ExistingDocumentSheets(FDocument).RemoveListener(@DocumentSheetsChanged);
  FreeSubtreeData(FDocument);
  FAnimations.Free;
  FEngine.Free;
  FSheetList.Free;
  FNewRuleTargets.Free;
  FAdapter.Free;
  inherited Destroy;
end;

procedure TDocumentStyler.ResourcesChanged(Change: TResourceChange);
begin
  if Change = rcStyleSheets then
  begin
    FSheetsDirty := True;
    FSheetContentsChanged := True;
    Inc(FShadowSheetsVersion);
  end;
end;

{ Brings Host's shadow tree scope up to date (made on first use, its
  sheets collected again when behind); True when its rules changed. }
function TDocumentStyler.UpdateShadowScope(Host: TElement): Boolean;
var
  Shadow, Outer: TShadowRoot;
  Scope: TShadowStyleScope;
  Depth: Integer;
begin
  Result := False;
  Shadow := Host.ShadowRoot;
  if Shadow = nil then
    Exit;
  Scope := TShadowStyleScope(Shadow.StyleScope);
  if Scope = nil then
  begin
    Outer := Host.ContainingShadowRoot;
    Depth := 1;
    if (Outer <> nil) and (Outer.StyleScope <> nil) then
      Depth := TCssTreeScope(Outer.StyleScope).Depth + 1;
    Scope := TShadowStyleScope.Create(Host, Depth);
    Shadow.StyleScope := Scope;
  end;
  if Scope.Collected and (Scope.SheetsVersion = FShadowSheetsVersion) then
    Exit;
  Scope.SheetsVersion := FShadowSheetsVersion;
  Scope.Collected := True;
  if FAuthorStylesDisabled then
    Scope.SetSheets([])
  else
    Scope.SetSheets(FSheetList.CollectShadowRoot(Shadow));
  Scope.Invalidate;
  Result := True;
end;

{ A sheet owner in a shadow tree changed: the scopes collect again and
  the host's subtree is styled again. }
procedure TDocumentStyler.ShadowSheetsChanged(Node: TNode);
var
  Shadow: TShadowRoot;
begin
  Shadow := Node.ContainingShadowRoot;
  if (Shadow = nil) or (Shadow.Host = nil) then
    Exit;
  Inc(FShadowSheetsVersion);
  FTreeChanged := True;
  MarkSubtreeStyleDirty(Shadow.Host);
end;

{ Script changed the sheets (CSSOM): a rule appended at the end of the
  last sheet is indexed at once; anything else indexes them again. }
procedure TDocumentStyler.DocumentSheetsChanged(Change: TSheetChange; Sheet: TCssStyleSheet; Rule: TCssRule);
begin
  if (Change = scRuleAppended) and not FSheetsDirty and FEngine.AppendRule(Sheet, Rule) then
  begin
    FNewRuleTargets.AddRule(Rule);
    { Nothing is dirty yet: the update must still come here. }
    MarkStyleDirty(FDocument);
    Exit;
  end;
  FSheetsDirty := True;
  FSheetContentsChanged := True;
  Inc(FShadowSheetsVersion);
end;

{ The sheets of New that are not in Old, when New is Old with sheets
  inserted (Old's in the same order); False when sheets were removed or
  moved. }
function AddedSheets(const Old, New: TCssStyleSheetArray; out Added: TCssStyleSheetArray): Boolean;
var
  OldIndex, NewIndex, Count: Integer;
begin
  Added := nil;
  SetLength(Added, Length(New));
  Count := 0;
  OldIndex := 0;
  for NewIndex := 0 to High(New) do
    if (OldIndex <= High(Old)) and (New[NewIndex] = Old[OldIndex]) then
      Inc(OldIndex)
    else
    begin
      Added[Count] := New[NewIndex];
      Inc(Count);
    end;
  SetLength(Added, Count);
  Result := OldIndex > High(Old);
end;

{ Notes what the change of sheets from Old to New may restyle: only
  what the rules of added sheets may style when sheets were only added
  (Web.Style.SheetChanges), else everything. }
procedure TDocumentStyler.NoteSheetChange(const Old, New: TCssStyleSheetArray; ContentsChanged: Boolean);
var
  Added: TCssStyleSheetArray;
begin
  if not ContentsChanged and AddedSheets(Old, New, Added) then
    FNewRuleTargets.AddSheets(Added)
  else
    FNewRuleTargets.AddEverything;
end;

procedure TDocumentStyler.UpdateSheets;
var
  Sheets: TCssStyleSheetArray;
  Index: Integer;
  Same, ContentsChanged: Boolean;
begin
  FSheetsDirty := False;
  if FAuthorStylesDisabled then
    Sheets := nil
  else
    Sheets := FSheetList.Collect;
  ContentsChanged := FSheetContentsChanged;
  Same := (Length(Sheets) = Length(FActiveSheets)) and not ContentsChanged;
  FSheetContentsChanged := False;
  if Same then
    for Index := 0 to High(Sheets) do
      if Sheets[Index] <> FActiveSheets[Index] then
        Same := False;
  if Same then
    Exit;
  for Index := 0 to High(FActiveSheets) do
    FEngine.RemoveStyleSheet(FActiveSheets[Index]);
  for Index := 0 to High(Sheets) do
    FEngine.AddStyleSheet(Sheets[Index]);
  NoteSheetChange(FActiveSheets, Sheets, ContentsChanged);
  FActiveSheets := Sheets;
  FEngine.Invalidate;
  { Indexed now, so the sheets and rules the CSSOM took out can go. }
  FEngine.Prepare;
  DocumentSheetsOf(FDocument).FreeRetired;
end;

function TDocumentStyler.GetAuthorStylesEnabled: Boolean;
begin
  Result := not FAuthorStylesDisabled;
end;

procedure MarkStyleAttributesDirty(Node: TNode);
var
  Child: TNode;
  Data: PNodeData;
begin
  if Node.IsElement then
  begin
    Data := ExistingNodeData(Node);
    if Data <> nil then
      Include(Data^.Flags, ndStyleAttributeDirty);
  end;
  Child := Node.FirstChild;
  while Child <> nil do
  begin
    MarkStyleAttributesDirty(Child);
    Child := Child.NextSibling;
  end;
end;

procedure TDocumentStyler.SetAuthorStylesEnabled(Value: Boolean);
begin
  if Value = not FAuthorStylesDisabled then
    Exit;
  FAuthorStylesDisabled := not Value;
  { The style attributes are parsed again (or dropped) and every sheet
    taken again. }
  MarkStyleAttributesDirty(FDocument);
  FSheetContentsChanged := True;
  InvalidateAll;
end;

procedure TDocumentStyler.InvalidateAll;
begin
  FSheetsDirty := True;
  FEngine.Invalidate;
  MarkSubtreeStyleDirty(FDocument);
end;

procedure TDocumentStyler.SetEnvironment(const Environment: TCssMediaEnvironment);
begin
  FEngine.SetEnvironment(Environment);
  FEngine.Invalidate;
  MarkSubtreeStyleDirty(FDocument);
end;

procedure TDocumentStyler.SetElementStates(Element: TElement; States: TCssElementStates);
var
  Data: PNodeData;
  Invalidation: TCssStateInvalidation;
begin
  Data := NodeDataOf(Element);
  if Data^.States = States then
    Exit;
  { Only what a selector reading the changed states could now match
    or stop matching (moving the pointer changes :hover on a chain of
    ancestors: their subtrees are not all styled again). }
  Invalidation := FEngine.StateInvalidation(Element, Data^.States >< States);
  Data^.States := States;
  { The shadow trees' rules are not in the engine's dependencies: their
    elements are styled again with what may depend on them. }
  if FDocument.HasShadowRoots and ((Element.ShadowRoot <> nil) or (Element.AssignedSlot <> nil) or
    (Element.ContainingShadowRoot <> nil)) then
    Invalidation := [siSelf, siDescendants, siSiblings];
  if Invalidation = [] then
    Exit;
  FTreeChanged := True;
  if siDescendants in Invalidation then
    MarkSubtreeStyleDirty(Element)
  else if siSelf in Invalidation then
    MarkStyleDirty(Element);
  if siSiblings in Invalidation then
    MarkLaterSiblingsDirty(Element);
end;

{ The element's later siblings and everything in them. }
procedure TDocumentStyler.MarkLaterSiblingsDirty(Element: TElement);
var
  Sibling: TNode;
begin
  Sibling := Element.NextSibling;
  while Sibling <> nil do
  begin
    if Sibling.IsElement then
      MarkSubtreeStyleDirty(Sibling);
    Sibling := Sibling.NextSibling;
  end;
end;

function TDocumentStyler.AnonymousStyle(ParentStyle: TCssComputedStyle): TCssComputedStyle;
begin
  Result := FEngine.AnonymousStyle(ParentStyle);
end;

function TDocumentStyler.ResolveStyleUnder(Element: TElement; ParentStyle: TCssComputedStyle): TCssComputedStyle;
begin
  { Its presentational hints and style attribute must be parsed. }
  PrepareElement(Element, NodeDataOf(Element));
  Result := FEngine.ResolveStyle(Element, ParentStyle);
end;

function TDocumentStyler.StyleForScript(Element: TElement; PseudoElement: TCssPseudoElement): TCssComputedStyle;
var
  Chain, Ancestors: array of TElement;
  Node: TNode;
  Index: Integer;
  Base, Parent, Pseudo: TCssComputedStyle;
  Data: PNodeData;
begin
  Base := StyleOf(Element);
  if Base <> nil then
    Base := Base.AddRef
  else
  begin
    { The unstyled elements from Element up, and the styled ancestor. }
    Chain := nil;
    Node := Element;
    while (Node <> nil) and Node.IsElement and (StyleOf(Node) = nil) do
    begin
      SetLength(Chain, Length(Chain) + 1);
      Chain[High(Chain)] := TElement(Node);
      Node := StyleParentOf(Node);
      while (Node <> nil) and not Node.IsElement and not (Node is TDocument) do
        Node := StyleParentOf(Node);
    end;
    if (Node = nil) and (Chain[High(Chain)].ParentNode <> nil) then
      Exit(nil);
    Parent := nil;
    if (Node <> nil) and Node.IsElement then
      Parent := StyleOf(Node);
    { The ancestor filter must hold every ancestor of what is resolved. }
    Ancestors := nil;
    while (Node <> nil) and Node.IsElement do
    begin
      SetLength(Ancestors, Length(Ancestors) + 1);
      Ancestors[High(Ancestors)] := TElement(Node);
      Node := StyleParentOf(Node);
      while (Node <> nil) and not Node.IsElement and not (Node is TDocument) do
        Node := StyleParentOf(Node);
    end;
    FEngine.ResetAncestors;
    for Index := High(Ancestors) downto 0 do
      FEngine.PushAncestor(Ancestors[Index]);
    if Parent <> nil then
      Parent := Parent.AddRef;
    for Index := High(Chain) downto 0 do
    begin
      Base := ResolveStyleUnder(Chain[Index], Parent);
      Parent.Release;
      Parent := Base;
      if Index > 0 then
        FEngine.PushAncestor(Chain[Index]);
    end;
    FEngine.ResetAncestors;
  end;
  if PseudoElement = peNone then
    Exit(Base);
  Pseudo := nil;
  Data := ExistingNodeData(Element);
  if (PseudoElement = peBefore) and (Data <> nil) and (Data^.BeforeStyle <> nil) and (Data^.Style <> nil) then
    Pseudo := Data^.BeforeStyle.AddRef
  else if (PseudoElement = peAfter) and (Data <> nil) and (Data^.AfterStyle <> nil) and (Data^.Style <> nil) then
    Pseudo := Data^.AfterStyle.AddRef
  else
    Pseudo := FEngine.ResolvePseudoStyle(Element, Base, PseudoElement);
  { A pseudo-element no rule styles: what it would inherit. }
  if Pseudo = nil then
    Pseudo := FEngine.AnonymousStyle(Base);
  Base.Release;
  Result := Pseudo;
end;

procedure TDocumentStyler.PrepareElement(Element: TElement; Data: PNodeData);
var
  Source: string;
begin
  if ndHintsDirty in Data^.Flags then
  begin
    Data^.Hints.Free;
    Data^.Hints := BuildPresentationalHints(Element);
    Exclude(Data^.Flags, ndHintsDirty);
  end;
  if ndStyleAttributeDirty in Data^.Flags then
  begin
    Data^.StyleAttribute.Free;
    Data^.StyleAttribute := nil;
    if Element.HasAttributeAtom(AtomStyleAttribute) and not FAuthorStylesDisabled then
    begin
      Source := Element.AttributeValueOf(AtomStyleAttribute);
      { CSP: a style attribute from markup or setAttribute applies only
        if the policies allow it; one the CSSOM wrote always does. }
      if (Source <> '') and ((Element.ElementState and ElementStateStyleFromCssom) = 0) and
         CspBlocksInline(TFetchClient(Element.NodeDocument.SecurityPolicy), CspInlineStyleAttribute, Source, '',
         Element) then
        Source := '';
      if Source <> '' then
        Data^.StyleAttribute := ParseStyleAttribute(Source);
    end;
    Exclude(Data^.Flags, ndStyleAttributeDirty);
  end;
end;

{ AfterElement: the element's style was just cascaded (the engine then
  knows its pseudo-element rule candidates). }
procedure TDocumentStyler.ResolvePseudoStyles(Element: TElement; Data: PNodeData; AfterElement: Boolean;
  var Change: TStyleChangeKind);
var
  Before, After, Marker: TCssComputedStyle;
begin
  if Data^.Style.IsDisplayNone then
  begin
    Before := nil;
    After := nil;
    Marker := nil;
  end
  else
  begin
    Before := FEngine.ResolvePseudoStyle(Element, Data^.Style, peBefore, AfterElement);
    After := FEngine.ResolvePseudoStyle(Element, Data^.Style, peAfter, AfterElement);
    Marker := nil;
    if KeywordIn(Data^.Style.Keyword(cpDisplay), [kwListItem, kwInlineListItem]) or
       IsListItemDisplay(Data^.Style) then
      Marker := FEngine.ResolvePseudoStyle(Element, Data^.Style, peMarker, AfterElement);
  end;
  if (CompareStyles(Data^.BeforeStyle, Before) <> scNone) or (CompareStyles(Data^.AfterStyle, After) <> scNone) or
     (CompareStyles(Data^.MarkerStyle, Marker) <> scNone) then
    Change := scBoxes;
  Data^.BeforeStyle.Release;
  Data^.AfterStyle.Release;
  Data^.MarkerStyle.Release;
  Data^.BeforeStyle := Before;
  Data^.AfterStyle := After;
  Data^.MarkerStyle := Marker;
end;

{ Restyles Element (Cascade False: only its animations moved on, the
  kept cascaded style is animated again); True when its children must
  be restyled too. }
function TDocumentStyler.StyleElement(Element: TElement; Data: PNodeData; ParentStyle: TCssComputedStyle;
  Cascade: Boolean): Boolean;
var
  NewStyle, Base, OldBase, OldShown: TCssComputedStyle;
  Change: TStyleChangeKind;
begin
  PrepareElement(Element, Data);
  if Cascade or (Data^.BaseStyle = nil) then
  begin
    Base := FEngine.ResolveStyle(Element, ParentStyle);
    Inc(FStylesComputed);
  end
  else
    Base := Data^.BaseStyle.AddRef;
  OldShown := Data^.Style.AddRef;
  if Data^.BaseStyle <> nil then
    OldBase := Data^.BaseStyle.AddRef
  else
    OldBase := Data^.Style.AddRef;
  NewStyle := FAnimations.Animate(Element, OldBase, OldShown, Base, ParentStyle);
  Base.Release;
  OldBase.Release;
  OldShown.Release;
  KeepEqualCustomProperties(Data^.Style, NewStyle);
  Change := CompareStyles(Data^.Style, NewStyle);
  Result := InheritedChanged(Data^.Style, NewStyle) or (Data^.Style = nil) or
    (Data^.Style.IsDisplayNone <> NewStyle.IsDisplayNone);
  Data^.Style.Release;
  Data^.Style := NewStyle;
  if Cascade or (Change <> scNone) then
    ResolvePseudoStyles(Element, Data, Cascade, Change);
  Data^.Flags := Data^.Flags - [ndStyleDirty, ndAnimationDirty];
  if (Change <> scNone) and Assigned(FOnStyleChanged) then
    FOnStyleChanged(Element, Change);
end;

procedure TDocumentStyler.StyleChildren(Parent: TNode; ParentStyle: TCssComputedStyle; Force: Boolean);
var
  Child: TNode;
  Data: PNodeData;
  ForceChildren: Boolean;
  Cursor: TFlatTreeCursor;
begin
  { The flat tree: a host's children are its shadow tree's, a slot's the
    nodes assigned to it. }
  Child := FlatTreeFirstChild(Parent, Cursor);
  while Child <> nil do
  begin
    if Child.IsElement then
    begin
      Data := NodeDataOf(Child);
      ForceChildren := False;
      if (TElement(Child).ShadowRoot <> nil) and UpdateShadowScope(TElement(Child)) then
      begin
        { New rules for the host (:host) and its shadow tree. }
        Include(Data^.Flags, ndStyleDirty);
        ForceChildren := True;
      end;
      if ForceChildren then
        StyleElement(TElement(Child), Data, ParentStyle, True)
      else if Force or (ndStyleDirty in Data^.Flags) then
        ForceChildren := StyleElement(TElement(Child), Data, ParentStyle, True)
      else if ndAnimationDirty in Data^.Flags then
        ForceChildren := StyleElement(TElement(Child), Data, ParentStyle, False);
      if Data^.Style = nil then
        { Under a parent that is not displayed: styled when needed. }
      else if (ForceChildren or (ndDescendantStyleDirty in Data^.Flags)) and not Data^.Style.IsDisplayNone then
      begin
        FEngine.PushAncestor(Child);
        StyleChildren(Child, Data^.Style, ForceChildren);
        FEngine.PopAncestor;
        Exclude(Data^.Flags, ndDescendantStyleDirty);
      end
      else if Data^.Style.IsDisplayNone and ForceChildren then
        { Styled again when it is shown. }
        MarkSubtreeStyleDirty(Child);
    end;
    Child := FlatTreeNextChild(Cursor);
  end;
end;

procedure TDocumentStyler.UpdateStyles;
var
  Data: PNodeData;
begin
  if FSheetsDirty then
    UpdateSheets;
  FNewRuleTargets.MarkDirty(FDocument, FAdapter);
  Data := NodeDataOf(FDocument);
  if not (ndDescendantStyleDirty in Data^.Flags) and not (ndStyleDirty in Data^.Flags) then
    Exit;
  if FTreeChanged then
  begin
    FEngine.TreeChanged;
    FTreeChanged := False;
  end;
  FEngine.ResetAncestors;
  StyleChildren(FDocument, nil, False);
  Data^.Flags := Data^.Flags - [ndStyleDirty, ndDescendantStyleDirty];
end;

procedure TDocumentStyler.MarkSiblingsDirty(Parent: TNode);
var
  Child: TNode;
begin
  Child := Parent.FirstChild;
  while Child <> nil do
  begin
    if Child.IsElement then
      MarkStyleDirty(Child);
    Child := Child.NextSibling;
  end;
  if Parent.IsElement then
    MarkStyleDirty(Parent);
end;

procedure TDocumentStyler.CheckSheetOwner(Node: TNode);
var
  Ancestor: TNode;
begin
  Ancestor := Node;
  while Ancestor <> nil do
  begin
    if Ancestor.IsElement and IsStyleSheetOwner(TElement(Ancestor)) then
    begin
      FSheetsDirty := True;
      if FDocument.HasShadowRoots then
        ShadowSheetsChanged(Ancestor);
      Exit;
    end;
    Ancestor := Ancestor.ParentNode;
  end;
end;

function SubtreeHasSheetOwner(Root: TNode): Boolean;
var
  Node: TNode;
begin
  Node := Root;
  while Node <> nil do
  begin
    if Node.IsElement and IsStyleSheetOwner(TElement(Node)) then
      Exit(True);
    Node := Node.NextInTree(Root);
  end;
  Result := False;
end;

procedure TDocumentStyler.TreeMutated(Target: TNode; const Added, Removed: TNodeArray; PreviousSibling,
  NextSibling: TNode);
var
  Index: Integer;
begin
  if not Target.IsConnected then
    Exit;
  FTreeChanged := True;
  for Index := 0 to High(Added) do
  begin
    if Added[Index].IsElement then
      MarkSubtreeStyleDirty(Added[Index]);
    if SubtreeHasSheetOwner(Added[Index]) then
    begin
      FSheetsDirty := True;
      if FDocument.HasShadowRoots then
        ShadowSheetsChanged(Target);
    end;
  end;
  for Index := 0 to High(Removed) do
    if Removed[Index].IsElement and SubtreeHasSheetOwner(Removed[Index]) then
    begin
      FSheetsDirty := True;
      if FDocument.HasShadowRoots then
        ShadowSheetsChanged(Target);
    end;
  CheckSheetOwner(Target);
  MarkSiblingsDirty(Target);
  if Assigned(FOnChildrenChanged) then
    FOnChildrenChanged(Target);
end;

procedure TDocumentStyler.NodeDisconnected(Node: TNode);
begin
  if Node.IsElement then
    FAnimations.ElementRemoved(TElement(Node));
  if Assigned(FOnNodeRemoved) then
    FOnNodeRemoved(Node);
  FreeNodeData(Node);
end;

{ Whether a change of an attribute of Element can be followed through
  the selectors naming it (else everything around is styled again). }
function TDocumentStyler.CanNarrowAttributeChange(Element: TElement; NamespaceId: TNamespaceId): Boolean;
begin
  Result := False;
  if NamespaceId <> NamespaceNone then
    Exit;
  { Cells read their table's cellpadding and border. }
  if Element.IsHtmlElement(AtomTable) then
    Exit;
  { The shadow trees' rules are not in the engine's dependencies. }
  if FDocument.HasShadowRoots and ((Element.ShadowRoot <> nil) or (Element.AssignedSlot <> nil) or
    (Element.ContainingShadowRoot <> nil)) then
    Exit;
  Result := True;
end;

{ Marks what an attribute change asks to be styled again: the element
  (its presentational hints may change), and what the selectors naming
  the attribute, class or id reach. }
procedure TDocumentStyler.MarkAttributeChangeDirty(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
  const OldValue: string);
var
  Invalidation: TCssNameInvalidation;
begin
  if CanNarrowAttributeChange(Element, NamespaceId) then
    Invalidation := AttributeChangeInvalidation(FEngine, Element, LocalName, OldValue)
  else
    Invalidation := [niEverywhere];
  if niEverywhere in Invalidation then
  begin
    FTreeChanged := True;
    MarkSubtreeStyleDirty(Element);
    if Element.ParentNode <> nil then
      MarkSiblingsDirty(Element.ParentNode);
    if Element.IsHtmlElement(AtomTable) then
      MarkHintsOfSubtreeDirty(Element);
    Exit;
  end;
  if niDescendants in Invalidation then
    MarkSubtreeStyleDirty(Element)
  else
    MarkStyleDirty(Element);
  if niSiblings in Invalidation then
    MarkLaterSiblingsDirty(Element);
end;

procedure TDocumentStyler.AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
  const OldValue: string; HadValue: Boolean);
var
  Data: PNodeData;
begin
  if not Element.IsConnected then
    Exit;
  Data := NodeDataOf(Element);
  if (LocalName = AtomStyleAttribute) and (NamespaceId = NamespaceNone) then
  begin
    Include(Data^.Flags, ndStyleAttributeDirty);
    MarkStyleDirty(Element);
  end
  else
  begin
    if LocalName = AtomId then
      Exclude(Data^.Flags, ndIdKnown)
    else if LocalName = AtomClass then
      Exclude(Data^.Flags, ndClassesKnown);
    Include(Data^.Flags, ndHintsDirty);
    MarkAttributeChangeDirty(Element, LocalName, NamespaceId, OldValue);
    if IsStyleSheetOwner(Element) then
    begin
      FSheetsDirty := True;
      if FDocument.HasShadowRoots then
        ShadowSheetsChanged(Element);
    end;
  end;
  if Assigned(FOnElementAttributeChanged) then
    FOnElementAttributeChanged(Element);
end;

procedure TDocumentStyler.ControlStateChanged(Element: TElement);
begin
  if not Element.IsConnected then
    Exit;
  FTreeChanged := True;
  { :checked, :placeholder-shown and their sibling combinators. }
  MarkSubtreeStyleDirty(Element);
  if Element.ParentNode <> nil then
    MarkSiblingsDirty(Element.ParentNode);
  if Assigned(FOnElementAttributeChanged) then
    FOnElementAttributeChanged(Element);
end;

procedure TDocumentStyler.ShadowRootAttached(Host: TElement);
begin
  if not Host.IsConnected then
    Exit;
  FTreeChanged := True;
  MarkSubtreeStyleDirty(Host);
  if Assigned(FOnChildrenChanged) then
    FOnChildrenChanged(Host);
end;

procedure TDocumentStyler.MarkAssignedNodesDirty(Slot: TElement);
var
  Nodes: TNodeArray;
  Index: Integer;
begin
  Nodes := Slot.AssignedNodes;
  for Index := 0 to High(Nodes) do
    if Nodes[Index].IsElement then
      MarkSubtreeStyleDirty(Nodes[Index]);
end;

procedure TDocumentStyler.SlotAssignmentChanged(Slot: TElement);
begin
  if not Slot.IsConnected then
    Exit;
  FTreeChanged := True;
  MarkSubtreeStyleDirty(Slot);
  MarkAssignedNodesDirty(Slot);
  if Assigned(FOnChildrenChanged) then
    FOnChildrenChanged(Slot);
end;

procedure TDocumentStyler.CustomElementStateChanged(Element: TElement);
begin
  ControlStateChanged(Element);
end;

procedure TDocumentStyler.CharacterDataChanged(Node: TCharacterData; const OldValue: string);
begin
  if not Node.IsConnected then
    Exit;
  if Node.ParentNode <> nil then
    CheckSheetOwner(Node.ParentNode);
  if Assigned(FOnTextChanged) then
    FOnTextChanged(Node);
end;

initialization
  AtomStyleAttribute := Atomize('style');
end.
