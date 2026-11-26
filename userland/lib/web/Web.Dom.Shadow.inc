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
  Web.Dom: shadow trees (DOM Standard 4.2.2 and 4.8). A shadow root is a
  document fragment whose host is its shadow host; the host keeps it in
  its rare data and frees it. For references the shadow root's parent
  is its host (Web.Dom.Lifetime.inc), so script holding a node of a
  shadow tree keeps the host and its tree alive.

  Shadow-including tree order visits an element, then its shadow root
  and the shadow tree, then its children; connecting and disconnecting
  follow it, so the nodes of a connected host's shadow tree are
  connected too (their ids are not the document's: a shadow root
  answers getElementById for its own tree).
}

function TNode.IsNodeTarget: Boolean;
begin
  Result := True;
end;

function TNode.TargetRoot: TEventTarget;
begin
  Result := GetRootNode;
end;

function TNode.GetShadowIncludingRoot: TNode;
begin
  Result := GetRootNode;
  while (Result is TShadowRoot) and (TShadowRoot(Result).FHost <> nil) do
    Result := TShadowRoot(Result).FHost.GetRootNode;
end;

function TNode.ContainingShadowRoot: TShadowRoot;
var
  Root: TNode;
begin
  Root := GetRootNode;
  if Root is TShadowRoot then
    Result := TShadowRoot(Root)
  else
    Result := nil;
end;

function TNode.IsShadowIncludingInclusiveAncestorOfNode(Other: TNode): Boolean;
var
  Root: TNode;
begin
  while Other <> nil do
  begin
    if IsInclusiveAncestorOf(Other) then
      Exit(True);
    Root := Other.GetRootNode;
    if Root is TShadowRoot then
      Other := TShadowRoot(Root).FHost
    else
      Other := nil;
  end;
  Result := False;
end;

function TNode.IsShadowIncludingInclusiveAncestorOf(Other: TEventTarget): Boolean;
begin
  Result := (Other is TNode) and IsShadowIncludingInclusiveAncestorOfNode(TNode(Other));
end;

function TNode.AssignedSlotTarget: TEventTarget;
begin
  Result := AssignedSlot;
end;

function TNode.AssignedSlot: TElement;
begin
  if FRareData = nil then
    Result := nil
  else
    Result := FRareData.AssignedSlot;
end;

function TNode.NextInShadowIncludingTree(Root: TNode): TNode;
var
  Node: TNode;
begin
  if (FNodeType = NodeTypeElement) and (FRareData <> nil) and (FRareData.ShadowRoot <> nil) then
    Exit(FRareData.ShadowRoot);
  Result := GetFirstChild;
  if Result <> nil then
    Exit;
  Node := Self;
  while Node <> Root do
  begin
    if Node.FNextSibling <> nil then
      Exit(Node.FNextSibling);
    if Node.FParent <> nil then
      Node := Node.FParent
    else if Node is TShadowRoot then
    begin
      { After the shadow tree come the host's children. }
      Node := TShadowRoot(Node).FHost;
      if Node = nil then
        Exit(nil);
      Result := Node.GetFirstChild;
      if Result <> nil then
        Exit;
    end
    else
      Exit(nil);
  end;
  Result := nil;
end;

function TElement.ShadowRoot: TShadowRoot;
begin
  if FRareData = nil then
    Result := nil
  else
    Result := FRareData.ShadowRoot;
end;

{ The elements attachShadow accepts (DOM Standard: "valid shadow host
  name"): autonomous custom elements and some HTML elements. }
function IsValidShadowHostName(Element: TElement): Boolean;
begin
  if not Element.IsHtml then
    Exit(False);
  case Element.FLocalName of
    AtomArticle, AtomAside, AtomBlockquote, AtomBody, AtomDiv, AtomFooter, AtomH1, AtomH2, AtomH3, AtomH4,
    AtomH5, AtomH6, AtomHeader, AtomMain, AtomNav, AtomP, AtomSection, AtomSpan:
      Result := True;
  else
    Result := IsCustomElementNameAtom(Element.FLocalName);
  end;
end;

{ Attaches a new shadow root to Host without the checks. }
function AttachShadowRoot(Host: TElement; Mode: TShadowRootMode; Clonable, Serializable, DelegatesFocus: Boolean;
  SlotAssignment: TSlotAssignmentMode): TShadowRoot;
var
  Index: Integer;
  Document: TDocument;
begin
  Document := Host.FOwnerDocument;
  Result := TShadowRoot.Create;
  InitializeNode(Result, NodeTypeDocumentFragment, Document);
  Result.FHost := Host;
  Result.FMode := Mode;
  Result.FDelegatesFocus := DelegatesFocus;
  Result.FSlotAssignment := SlotAssignment;
  Result.FClonable := Clonable;
  Result.FSerializable := Serializable;
  if (Host.FFlags and NodeFlagConnected) <> 0 then
    Result.FFlags := Result.FFlags or NodeFlagConnected;
  Host.RareData.ShadowRoot := Result;
  Document.FHasShadowRoots := True;
  BumpDomVersion;
  for Index := 1 to System.Length(Document.FObservers) do
    Document.FObservers[Index - 1].ShadowRootAttached(Host);
end;

function TElement.AttachShadow(Mode: TShadowRootMode; Clonable, Serializable, DelegatesFocus: Boolean;
  SlotAssignment: TSlotAssignmentMode): TShadowRoot;
var
  Existing: TShadowRoot;
begin
  if Web.Namespaces.NamespaceUri(FNamespaceId) <> AtomHtmlNamespace then
    RaiseDomError(NotSupportedError, 'only HTML elements can be shadow hosts');
  if not IsValidShadowHostName(Self) then
    RaiseDomError(NotSupportedError, 'this element cannot be a shadow host');
  Existing := ShadowRoot;
  if Existing <> nil then
  begin
    { A declarative shadow root of the same mode is emptied and kept. }
    if Existing.FDeclarative and (Existing.FMode = Mode) then
    begin
      ReplaceAll(nil, Existing);
      Existing.FDeclarative := False;
      Exit(Existing);
    end;
    RaiseDomError(NotSupportedError, 'the element already has a shadow root');
  end;
  Result := AttachShadowRoot(Self, Mode, Clonable, Serializable, DelegatesFocus, SlotAssignment);
end;

destructor TShadowRoot.Destroy;
begin
  FreeAndNil(FStyleSheets);
  FreeAndNil(FStyleScope);
  inherited Destroy;
end;

function TShadowRoot.GetModeText: string;
begin
  if FMode = ShadowRootModeOpen then
    Result := 'open'
  else
    Result := 'closed';
end;

function TShadowRoot.ShadowHostTarget: TEventTarget;
begin
  Result := FHost;
end;

function TShadowRoot.IsClosedShadowRoot: Boolean;
begin
  Result := FMode = ShadowRootModeClosed;
end;

{ A shadow root's "get the parent": its host, unless the event is not
  composed and started in this shadow tree. }
function TShadowRoot.GetTheParent(Event: TEvent): TEventTarget;
var
  First: TEventTarget;
begin
  First := Event.FirstPathTarget;
  if not Event.Composed and (First <> nil) and (First.TargetRoot = Self) then
    Result := nil
  else
    Result := FHost;
end;

function TShadowRoot.CloneSelf(Document: TDocument): TNode;
begin
  RaiseDomError(NotSupportedError, 'a shadow root cannot be cloned');
  Result := nil;
end;

function TShadowRoot.GetElementById(const IdValue: string): TElement;
var
  Node: TNode;
begin
  Result := nil;
  if IdValue = '' then
    Exit;
  Node := GetFirstChild;
  while Node <> nil do
  begin
    if ((Node.FFlags and NodeFlagHasId) <> 0) and (TElement(Node).AttributeValueOf(AtomId) = IdValue) then
      Exit(TElement(Node));
    Node := Node.NextInTree(Self);
  end;
end;

{ Clones Source's shadow root into Copy when it is clonable (the clone
  steps of the DOM Standard's "clone a node"). }
procedure CloneShadowRoot(Source, Copy: TElement; Document: TDocument);
var
  Shadow, CopyShadow: TShadowRoot;
  Child: TNode;
begin
  Shadow := Source.ShadowRoot;
  if (Shadow = nil) or not Shadow.FClonable then
    Exit;
  if Copy.ShadowRoot <> nil then
    Exit;
  CopyShadow := AttachShadowRoot(Copy, Shadow.FMode, True, Shadow.FSerializable, Shadow.FDelegatesFocus,
    Shadow.FSlotAssignment);
  CopyShadow.FDeclarative := Shadow.FDeclarative;
  Child := Shadow.FFirstChild;
  while Child <> nil do
  begin
    AppendChildRaw(CopyShadow, CloneTree(Child, Document, True));
    Child := Child.FNextSibling;
  end;
end;

{ Whether Node is in a shadow tree (only asked when the document has
  shadow roots). }
function IsInShadowTreeNode(Node: TNode): Boolean;
begin
  Result := Node.FOwnerDocument.FHasShadowRoots and (Node.GetRootNode is TShadowRoot);
end;
