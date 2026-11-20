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
  match differently; an element whose class or id changed and its
  subtree; a style attribute change only the element), and changes to
  <style> and <link> elements mark the sheets dirty.

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
  Css.ElementAdapter, Css.Selectors, Web.Style.NodeData, Web.Style.Adapter, Web.Style.Sheets,
  Web.Layout.Resources;

type
  TStyleChangeKind = (scNone, scPaint, scLayout, scBoxes);

  TStyleChangedEvent = procedure(Element: TElement; Change: TStyleChangeKind) of object;
  TNodeChangedEvent = procedure(Node: TNode) of object;

  TDocumentStyler = class(TDocumentObserver)
  private
    FDocument: TDocument;
    FResources: TDocumentResources;
    FAdapter: TDomElementAdapter;
    FEngine: TCssStyleEngine;
    FSheetList: TDocumentSheetList;
    FActiveSheets: TCssStyleSheetArray;
    FSheetsDirty: Boolean;
    FTreeChanged: Boolean;
    FOnStyleChanged: TStyleChangedEvent;
    FOnTextChanged: TNodeChangedEvent;
    FOnNodeRemoved: TNodeChangedEvent;
    FOnChildrenChanged: TNodeChangedEvent;
    FOnElementAttributeChanged: TNodeChangedEvent;
    FStylesComputed: Int64;
    procedure ResourcesChanged(Change: TResourceChange);
    procedure UpdateSheets;
    procedure PrepareElement(Element: TElement; Data: PNodeData);
    procedure StyleChildren(Parent: TNode; ParentStyle: TCssComputedStyle; Force: Boolean);
    function StyleElement(Element: TElement; Data: PNodeData; ParentStyle: TCssComputedStyle): Boolean;
    procedure ResolvePseudoStyles(Element: TElement; Data: PNodeData; var Change: TStyleChangeKind);
    procedure MarkSiblingsDirty(Parent: TNode);
    procedure CheckSheetOwner(Node: TNode);
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
    { Observer }
    procedure TreeMutated(Target: TNode; const Added, Removed: TNodeArray; PreviousSibling, NextSibling: TNode);
      override;
    procedure NodeDisconnected(Node: TNode); override;
    procedure AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
      const OldValue: string; HadValue: Boolean); override;
    procedure CharacterDataChanged(Node: TCharacterData; const OldValue: string); override;
    property Document: TDocument read FDocument;
    property Engine: TCssStyleEngine read FEngine;
    property Adapter: TDomElementAdapter read FAdapter;
    property Resources: TDocumentResources read FResources;
    property StylesComputed: Int64 read FStylesComputed;
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
  Css.PropertyIds, Css.StyleStructs, Css.ComputedValues, Css.Keywords, Css.Parser, Web.Style.Hints, Web.Style.UserAgent;

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
  Result := Old.Custom <> New.Custom;
end;

constructor TDocumentStyler.Create(Document: TDocument; Resources: TDocumentResources);
begin
  inherited Create;
  FDocument := Document;
  FResources := Resources;
  FAdapter := TDomElementAdapter.Create(Document);
  FEngine := TCssStyleEngine.Create(FAdapter, True);
  FSheetList := TDocumentSheetList.Create(Document, Resources);
  { The engine's additions to the user agent sheet come first. }
  FEngine.AddStyleSheet(EngineUserAgentSheet);
  FSheetsDirty := True;
  if FResources <> nil then
    FResources.AddListener(@ResourcesChanged);
  Document.AddObserver(Self);
  MarkSubtreeStyleDirty(Document);
end;

destructor TDocumentStyler.Destroy;
begin
  FDocument.RemoveObserver(Self);
  if FResources <> nil then
    FResources.RemoveListener(@ResourcesChanged);
  FreeSubtreeData(FDocument);
  FEngine.Free;
  FSheetList.Free;
  FAdapter.Free;
  inherited Destroy;
end;

procedure TDocumentStyler.ResourcesChanged(Change: TResourceChange);
begin
  if Change = rcStyleSheets then
    FSheetsDirty := True;
end;

procedure TDocumentStyler.UpdateSheets;
var
  Sheets: TCssStyleSheetArray;
  Index: Integer;
  Same: Boolean;
begin
  FSheetsDirty := False;
  Sheets := FSheetList.Collect;
  Same := Length(Sheets) = Length(FActiveSheets);
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
  FActiveSheets := Sheets;
  FEngine.Invalidate;
  MarkSubtreeStyleDirty(FDocument);
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
begin
  Data := NodeDataOf(Element);
  if Data^.States = States then
    Exit;
  Data^.States := States;
  FTreeChanged := True;
  MarkSubtreeStyleDirty(Element);
  if Element.ParentNode <> nil then
    MarkSiblingsDirty(Element.ParentNode);
end;

function TDocumentStyler.AnonymousStyle(ParentStyle: TCssComputedStyle): TCssComputedStyle;
begin
  Result := FEngine.AnonymousStyle(ParentStyle);
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
    if Element.HasAttributeAtom(AtomStyleAttribute) then
    begin
      Source := Element.AttributeValueOf(AtomStyleAttribute);
      if Source <> '' then
        Data^.StyleAttribute := ParseStyleAttribute(Source);
    end;
    Exclude(Data^.Flags, ndStyleAttributeDirty);
  end;
end;

procedure TDocumentStyler.ResolvePseudoStyles(Element: TElement; Data: PNodeData; var Change: TStyleChangeKind);
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
    Before := FEngine.ResolvePseudoStyle(Element, Data^.Style, peBefore);
    After := FEngine.ResolvePseudoStyle(Element, Data^.Style, peAfter);
    Marker := nil;
    if KeywordIn(Data^.Style.Keyword(cpDisplay), [kwListItem, kwInlineListItem]) or
       IsListItemDisplay(Data^.Style) then
      Marker := FEngine.ResolvePseudoStyle(Element, Data^.Style, peMarker);
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

{ Restyles Element; True when its children must be restyled too. }
function TDocumentStyler.StyleElement(Element: TElement; Data: PNodeData; ParentStyle: TCssComputedStyle): Boolean;
var
  NewStyle: TCssComputedStyle;
  Change: TStyleChangeKind;
begin
  PrepareElement(Element, Data);
  NewStyle := FEngine.ResolveStyle(Element, ParentStyle);
  Inc(FStylesComputed);
  Change := CompareStyles(Data^.Style, NewStyle);
  Result := InheritedChanged(Data^.Style, NewStyle) or (Data^.Style = nil) or
    (Data^.Style.IsDisplayNone <> NewStyle.IsDisplayNone);
  Data^.Style.Release;
  Data^.Style := NewStyle;
  ResolvePseudoStyles(Element, Data, Change);
  Exclude(Data^.Flags, ndStyleDirty);
  if (Change <> scNone) and Assigned(FOnStyleChanged) then
    FOnStyleChanged(Element, Change);
end;

procedure TDocumentStyler.StyleChildren(Parent: TNode; ParentStyle: TCssComputedStyle; Force: Boolean);
var
  Child: TNode;
  Data: PNodeData;
  ForceChildren: Boolean;
begin
  Child := Parent.FirstChild;
  while Child <> nil do
  begin
    if Child.IsElement then
    begin
      Data := NodeDataOf(Child);
      ForceChildren := False;
      if Force or (ndStyleDirty in Data^.Flags) then
        ForceChildren := StyleElement(TElement(Child), Data, ParentStyle);
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
    Child := Child.NextSibling;
  end;
end;

procedure TDocumentStyler.UpdateStyles;
var
  Data: PNodeData;
begin
  if FSheetsDirty then
    UpdateSheets;
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
      FSheetsDirty := True;
  end;
  for Index := 0 to High(Removed) do
    if Removed[Index].IsElement and SubtreeHasSheetOwner(Removed[Index]) then
      FSheetsDirty := True;
  CheckSheetOwner(Target);
  MarkSiblingsDirty(Target);
  if Assigned(FOnChildrenChanged) then
    FOnChildrenChanged(Target);
end;

procedure TDocumentStyler.NodeDisconnected(Node: TNode);
begin
  if Assigned(FOnNodeRemoved) then
    FOnNodeRemoved(Node);
  FreeNodeData(Node);
end;

procedure TDocumentStyler.AttributeChanged(Element: TElement; LocalName: TAtom; NamespaceId: TNamespaceId;
  const OldValue: string; HadValue: Boolean);
var
  Data: PNodeData;
begin
  if not Element.IsConnected then
    Exit;
  Data := NodeDataOf(Element);
  FTreeChanged := True;
  if (LocalName = AtomStyleAttribute) and (NamespaceId = NamespaceNone) then
  begin
    Include(Data^.Flags, ndStyleAttributeDirty);
    MarkStyleDirty(Element);
  end
  else
  begin
    if LocalName = AtomId then
      Exclude(Data^.Flags, ndIdKnown);
    Include(Data^.Flags, ndHintsDirty);
    MarkSubtreeStyleDirty(Element);
    if Element.ParentNode <> nil then
      MarkSiblingsDirty(Element.ParentNode);
    { Cells read their table's cellpadding and border. }
    if Element.IsHtmlElement(AtomTable) then
      MarkHintsOfSubtreeDirty(Element);
    if IsStyleSheetOwner(Element) then
      FSheetsDirty := True;
  end;
  if Assigned(FOnElementAttributeChanged) then
    FOnElementAttributeChanged(Element);
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
