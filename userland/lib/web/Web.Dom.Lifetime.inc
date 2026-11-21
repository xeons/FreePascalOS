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
  Web.Dom: node lifetime. Subtree reference counts, the list of
  detached nodes waiting for collection, and freeing trees without
  recursion (a parsed tree can be arbitrarily deep).

  The reference parent of a node is its parent, or for an Attr its
  element: references to an Attr keep its element alive. A root (no
  reference parent) other than a document holds one reference to its
  document while anything in its subtree is referenced.
}

var
  CollectorEntries: TNodeArray;
  CollectorCount: Integer;
  NodeObjectCount: Int64;
  GlobalDomVersion: LongWord;

{ The subtree reference count and the collector slot live in the rare
  data: most nodes have neither. }
function SubtreeCount(Node: TNode): LongWord; inline;
begin
  if Node.FRareData = nil then
    Result := 0
  else
    Result := Node.FRareData.SubtreeReferences;
end;

function CollectorSlotOf(Node: TNode): LongWord; inline;
begin
  if Node.FRareData = nil then
    Result := 0
  else
    Result := Node.FRareData.CollectorSlot;
end;

function DomVersion: LongWord;
begin
  Result := GlobalDomVersion;
end;

procedure BumpDomVersion; inline;
begin
  GlobalDomVersion := LongWord((QWord(GlobalDomVersion) + 1) and $FFFFFFFF);
end;

function ListedNodeCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 1 to CollectorCount do
    if CollectorEntries[Index - 1] <> nil then
      Inc(Result);
end;

function LiveNodeCount: Int64;
begin
  Result := NodeObjectCount;
end;

procedure ListForCollection(Node: TNode);
begin
  if CollectorSlotOf(Node) <> 0 then
    Exit;
  if CollectorCount >= Length(CollectorEntries) then
    SetLength(CollectorEntries, CollectorCount * 2 + 64);
  CollectorEntries[CollectorCount] := Node;
  Inc(CollectorCount);
  Node.RareData.CollectorSlot := CollectorCount;
end;

procedure UnlistFromCollection(Node: TNode);
begin
  if CollectorSlotOf(Node) = 0 then
    Exit;
  CollectorEntries[Node.FRareData.CollectorSlot - 1] := nil;
  Node.FRareData.CollectorSlot := 0;
  while (CollectorCount > 0) and (CollectorEntries[CollectorCount - 1] = nil) do
    Dec(CollectorCount);
end;

function ReferenceParent(Node: TNode): TNode; inline;
begin
  if Node.FNodeType = NodeTypeAttribute then
    Result := TAttr(Node).FOwnerElement
  else
    Result := Node.FParent;
end;

{ A template's contents: a root its template owns. }
function IsHostedRoot(Node: TNode): Boolean; inline;
begin
  Result := (Node.FNodeType = NodeTypeDocumentFragment) and (TDocumentFragment(Node).FHost <> nil);
end;

{ Adds Count to the subtree references of Node and its reference
  ancestors; the root reached. }
function AddSubtreeReferences(Node: TNode; Count: LongWord): TNode;
var
  Current: TNode;
begin
  Current := Node;
  repeat
    Inc(Current.RareData.SubtreeReferences, Count);
    Result := Current;
    Current := ReferenceParent(Current);
  until Current = nil;
end;

function RemoveSubtreeReferences(Node: TNode; Count: LongWord): TNode;
var
  Current: TNode;
begin
  Current := Node;
  repeat
    Dec(Current.FRareData.SubtreeReferences, Count);
    Result := Current;
    Current := ReferenceParent(Current);
  until Current = nil;
end;

procedure TNode.Retain;
var
  Root: TNode;
begin
  Root := AddSubtreeReferences(Self, 1);
  if (Root.FNodeType <> NodeTypeDocument) and (SubtreeCount(Root) = 1) then
    Root.FOwnerDocument.Retain;
end;

procedure TNode.Release;
var
  Root: TNode;
  Document: TDocument;
begin
  Root := RemoveSubtreeReferences(Self, 1);
  if SubtreeCount(Root) <> 0 then
    Exit;
  if Root.FNodeType = NodeTypeDocument then
  begin
    Root.Free;
    Exit;
  end;
  { A detached subtree nothing refers to any more: collected later. }
  Document := Root.FOwnerDocument;
  if not IsHostedRoot(Root) then
    ListForCollection(Root);
  Document.Release;
end;

procedure TNode.RetainTarget;
begin
  Retain;
end;

procedure TNode.ReleaseTarget;
begin
  Release;
end;

function TNode.HeldByEvents: Boolean;
begin
  Result := True;
end;

{ Node has just become a root: it takes its references away from its old
  reference ancestors (OldParent up), and holds its document if it is
  referenced or is listed for collection otherwise. }
procedure BecameRoot(Node, OldParent: TNode);
var
  Count: LongWord;
  OldRoot: TNode;
begin
  Count := SubtreeCount(Node);
  if Count = 0 then
  begin
    if not IsHostedRoot(Node) then
      ListForCollection(Node);
    Exit;
  end;
  Node.FOwnerDocument.Retain;
  OldRoot := RemoveSubtreeReferences(OldParent, Count);
  if (OldRoot.FNodeType <> NodeTypeDocument) and (SubtreeCount(OldRoot) = 0) then
  begin
    if not IsHostedRoot(OldRoot) then
      ListForCollection(OldRoot);
    OldRoot.FOwnerDocument.Release;
  end;
end;

{ Node, a root, is about to get the reference parent NewParent: its
  references move to the new ancestors, and it stops holding its
  document. Node's document must already be NewParent's. }
procedure BecomingChild(Node, NewParent: TNode);
var
  Count: LongWord;
  NewRoot: TNode;
begin
  UnlistFromCollection(Node);
  Count := SubtreeCount(Node);
  if Count = 0 then
    Exit;
  NewRoot := AddSubtreeReferences(NewParent, Count);
  if (NewRoot.FNodeType <> NodeTypeDocument) and (SubtreeCount(NewRoot) = Count) then
    NewRoot.FOwnerDocument.Retain;
  Node.FOwnerDocument.Release;
end;

{ Node, a root, moves to another document. }
procedure RootChangedDocument(Node: TNode; OldDocument, NewDocument: TDocument);
begin
  if SubtreeCount(Node) > 0 then
  begin
    NewDocument.Retain;
    OldDocument.Release;
  end;
end;

{ Frees a tree from the leaves up, without recursion. }
procedure FreeTree(Root: TNode);
var
  Current: TNode;
  Parent: TContainerNode;
begin
  Current := Root;
  while True do
  begin
    if ((Current.FFlags and NodeFlagContainer) <> 0) and (TContainerNode(Current).FFirstChild <> nil) then
    begin
      Current := TContainerNode(Current).FFirstChild;
      Continue;
    end;
    if Current = Root then
    begin
      Current.Free;
      Exit;
    end;
    Parent := Current.FParent;
    Parent.FFirstChild := Current.FNextSibling;
    if Parent.FFirstChild = nil then
      Parent.FLastChild := nil
    else
      Parent.FFirstChild.FPreviousSibling := nil;
    Current.FParent := nil;
    Current.FNextSibling := nil;
    Current.Free;
    Current := Parent;
  end;
end;

procedure CollectGarbage;
var
  Doomed: TNodeArray;
  DoomedCount, Index: Integer;
  Node: TNode;
begin
  Doomed := nil;
  DoomedCount := 0;
  for Index := 1 to CollectorCount do
  begin
    Node := CollectorEntries[Index - 1];
    if Node = nil then
      Continue;
    if (ReferenceParent(Node) = nil) and (SubtreeCount(Node) = 0) and not IsHostedRoot(Node) then
    begin
      if DoomedCount >= Length(Doomed) then
        SetLength(Doomed, DoomedCount * 2 + 16);
      Doomed[DoomedCount] := Node;
      Inc(DoomedCount);
    end
    else
    begin
      CollectorEntries[Index - 1] := nil;
      Node.FRareData.CollectorSlot := 0;
    end;
  end;
  for Index := 1 to DoomedCount do
    FreeTree(Doomed[Index - 1]);
  CollectorCount := 0;
end;

procedure TDocument.FreeListedNodes;
var
  Index: Integer;
  Node: TNode;
begin
  Index := 0;
  while Index < CollectorCount do
  begin
    Node := CollectorEntries[Index];
    if (Node <> nil) and (Node.FOwnerDocument = Self) and (SubtreeCount(Node) = 0) and
      (ReferenceParent(Node) = nil) then
      FreeTree(Node);
    Inc(Index);
  end;
end;

procedure TDocument.CollectGarbage;
begin
  Web.Dom.CollectGarbage;
end;

{ Sets up a node object just made. }
procedure InitializeNode(Node: TNode; NodeKind: Byte; Document: TDocument);
begin
  Node.FNodeType := NodeKind;
  Node.FOwnerDocument := Document;
  if NodeKind in [NodeTypeElement, NodeTypeDocument, NodeTypeDocumentFragment] then
    Node.FFlags := NodeFlagContainer;
  Inc(NodeObjectCount);
end;
