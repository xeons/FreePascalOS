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
  Web.Dom: the tree mutation algorithms of the DOM Standard (4.2.3):
  ensure pre-insertion validity, pre-insert, insert, append, replace,
  replace all, pre-remove, remove, adopt; and the Node, ParentNode and
  ChildNode methods built on them. Live ranges and node iterators come
  with the Range work of a later phase; the places they hook in are
  marked.
}

function IsCharacterDataType(NodeKind: Byte): Boolean; inline;
begin
  Result := NodeKind in [NodeTypeText, NodeTypeCDataSection, NodeTypeProcessingInstruction, NodeTypeComment];
end;

function IsTextType(NodeKind: Byte): Boolean; inline;
begin
  Result := NodeKind in [NodeTypeText, NodeTypeCDataSection];
end;

{ Whether Ancestor is a host-including inclusive ancestor of Node (the
  host of a template's contents counts as its parent). }
function IsHostIncludingInclusiveAncestor(Ancestor, Node: TNode): Boolean;
var
  Root: TNode;
begin
  while Node <> nil do
  begin
    if Ancestor.IsInclusiveAncestorOf(Node) then
      Exit(True);
    Root := Node.GetRootNode;
    if IsHostedRoot(Root) then
      Node := TDocumentFragment(Root).FHost
    else
      Node := nil;
  end;
  Result := False;
end;

function HasChildOfType(Parent: TNode; NodeKind: Byte; Excluded: TNode): Boolean;
var
  Child: TNode;
begin
  Child := Parent.GetFirstChild;
  while Child <> nil do
  begin
    if (Child.FNodeType = NodeKind) and (Child <> Excluded) then
      Exit(True);
    Child := Child.FNextSibling;
  end;
  Result := False;
end;

function HasTextChild(Parent: TNode): Boolean;
var
  Child: TNode;
begin
  Child := Parent.GetFirstChild;
  while Child <> nil do
  begin
    if IsTextType(Child.FNodeType) then
      Exit(True);
    Child := Child.FNextSibling;
  end;
  Result := False;
end;

function DoctypeFollows(Child: TNode): Boolean;
var
  Node: TNode;
begin
  Result := False;
  if Child = nil then
    Exit;
  Node := Child.FNextSibling;
  while Node <> nil do
  begin
    if Node.FNodeType = NodeTypeDocumentType then
      Exit(True);
    Node := Node.FNextSibling;
  end;
end;

function ElementPrecedes(Child: TNode): Boolean;
var
  Node: TNode;
begin
  Result := False;
  if Child = nil then
    Exit;
  Node := Child.FPreviousSibling;
  while Node <> nil do
  begin
    if Node.FNodeType = NodeTypeElement then
      Exit(True);
    Node := Node.FPreviousSibling;
  end;
end;

procedure HierarchyError(const Detail: string);
begin
  RaiseDomError(HierarchyRequestError, Detail);
end;

{ The checks shared by pre-insert and replace; Replacing is the child
  being replaced (nil for an insertion). }
procedure CheckInsertion(Node, Parent, Child: TNode; Replacing: Boolean);
var
  ElementChildren: Integer;
begin
  if not (Parent.FNodeType in [NodeTypeDocument, NodeTypeDocumentFragment, NodeTypeElement]) then
    HierarchyError('the parent cannot have children');
  if IsHostIncludingInclusiveAncestor(Node, Parent) then
    HierarchyError('the node is an ancestor of the parent');
  if (Child <> nil) and (Child.FParent <> Parent) then
    RaiseDomError(NotFoundError, 'the child is not a child of the parent');
  if not ((Node.FNodeType in [NodeTypeDocumentFragment, NodeTypeDocumentType, NodeTypeElement]) or
    IsCharacterDataType(Node.FNodeType)) then
    HierarchyError('the node cannot be a child');
  if (IsTextType(Node.FNodeType) and (Parent.FNodeType = NodeTypeDocument)) or
    ((Node.FNodeType = NodeTypeDocumentType) and (Parent.FNodeType <> NodeTypeDocument)) then
    HierarchyError('the node cannot be a child of the parent');
  if Parent.FNodeType <> NodeTypeDocument then
    Exit;
  case Node.FNodeType of
    NodeTypeDocumentFragment:
      begin
        ElementChildren := Node.ChildElementCount;
        if (ElementChildren > 1) or HasTextChild(Node) then
          HierarchyError('a document can have only one element and no text');
        if ElementChildren = 1 then
        begin
          if Replacing then
          begin
            if HasChildOfType(Parent, NodeTypeElement, Child) or DoctypeFollows(Child) then
              HierarchyError('a document can have only one element, after its doctype');
          end
          else if HasChildOfType(Parent, NodeTypeElement, nil) or
            ((Child <> nil) and (Child.FNodeType = NodeTypeDocumentType)) or DoctypeFollows(Child) then
            HierarchyError('a document can have only one element, after its doctype');
        end;
      end;
    NodeTypeElement:
      if Replacing then
      begin
        if HasChildOfType(Parent, NodeTypeElement, Child) or DoctypeFollows(Child) then
          HierarchyError('a document can have only one element, after its doctype');
      end
      else if HasChildOfType(Parent, NodeTypeElement, nil) or
        ((Child <> nil) and (Child.FNodeType = NodeTypeDocumentType)) or DoctypeFollows(Child) then
        HierarchyError('a document can have only one element, after its doctype');
    NodeTypeDocumentType:
      if Replacing then
      begin
        if HasChildOfType(Parent, NodeTypeDocumentType, Child) or ElementPrecedes(Child) then
          HierarchyError('a document can have only one doctype, before its element');
      end
      else if HasChildOfType(Parent, NodeTypeDocumentType, nil) or ElementPrecedes(Child) or
        ((Child = nil) and HasChildOfType(Parent, NodeTypeElement, nil)) then
        HierarchyError('a document can have only one doctype, before its element');
  end;
end;

procedure RemoveNode(Node: TNode; SuppressObservers: Boolean); forward;
procedure AdoptInto(Node: TNode; Document: TDocument); forward;

function DocumentHasObservers(Document: TDocument): Boolean; inline;
begin
  Result := System.Length(Document.FObservers) > 0;
end;

function NodeList1(Node: TNode): TNodeArray;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := Node;
end;

function ChildrenOf(Node: TNode): TNodeArray;
var
  Child: TNode;
  Count: Integer;
begin
  Result := nil;
  SetLength(Result, Node.ChildCount);
  Count := 0;
  Child := Node.GetFirstChild;
  while Child <> nil do
  begin
    Result[Count] := Child;
    Inc(Count);
    Child := Child.FNextSibling;
  end;
end;

{ Links Node (a root, already in Parent's document) into Parent's
  children before Child, and runs the insertion steps. }
procedure LinkChild(Node: TNode; Parent: TContainerNode; Child: TNode);
begin
  BecomingChild(Node, Parent);
  Node.FParent := Parent;
  if Child = nil then
  begin
    Node.FPreviousSibling := Parent.FLastChild;
    Node.FNextSibling := nil;
    if Parent.FLastChild <> nil then
      Parent.FLastChild.FNextSibling := Node
    else
      Parent.FFirstChild := Node;
    Parent.FLastChild := Node;
  end
  else
  begin
    Node.FPreviousSibling := Child.FPreviousSibling;
    Node.FNextSibling := Child;
    if Child.FPreviousSibling <> nil then
      Child.FPreviousSibling.FNextSibling := Node
    else
      Parent.FFirstChild := Node;
    Child.FPreviousSibling := Node;
  end;
  if (Parent.FFlags and NodeFlagConnected) <> 0 then
    Parent.FOwnerDocument.SubtreeConnected(Node);
end;

{ The insert algorithm. }
procedure InsertNode(Node: TNode; Parent: TContainerNode; Child: TNode; SuppressObservers: Boolean);
var
  Nodes: TNodeArray;
  Count, Index: Integer;
  PreviousSibling: TNode;
  Document: TDocument;
  Fragment: TNode;
begin
  Document := Parent.FOwnerDocument;
  BumpDomVersion;
  if Node.FNodeType = NodeTypeDocumentFragment then
  begin
    Fragment := Node;
    Nodes := ChildrenOf(Fragment);
    Count := System.Length(Nodes);
    if Count = 0 then
      Exit;
    for Index := 1 to Count do
      RemoveNode(Nodes[Index - 1], True);
    if DocumentHasObservers(Fragment.FOwnerDocument) then
      Fragment.FOwnerDocument.NotifyTreeMutated(Fragment, nil, Nodes, nil, nil);
  end
  else
  begin
    Nodes := nil;
    Count := 1;
  end;
  { Live ranges: the offsets after Child move by Count (later phase). }
  if Child <> nil then
    PreviousSibling := Child.FPreviousSibling
  else
    PreviousSibling := Parent.FLastChild;
  if Nodes = nil then
  begin
    AdoptInto(Node, Document);
    LinkChild(Node, Parent, Child);
  end
  else
    for Index := 1 to Count do
    begin
      AdoptInto(Nodes[Index - 1], Document);
      LinkChild(Nodes[Index - 1], Parent, Child);
    end;
  if DocumentHasObservers(Document) then
  begin
    if Nodes = nil then
      Nodes := NodeList1(Node);
    if not SuppressObservers then
      Document.NotifyTreeMutated(Parent, Nodes, nil, PreviousSibling, Child);
    Document.NotifyChildrenChanged(Parent);
  end;
end;

{ The remove algorithm. }
procedure RemoveNode(Node: TNode; SuppressObservers: Boolean);
var
  Parent: TContainerNode;
  OldPrevious, OldNext: TNode;
  WasConnected: Boolean;
  Document: TDocument;
begin
  Parent := Node.FParent;
  Document := Parent.FOwnerDocument;
  BumpDomVersion;
  { Live ranges and node iterators are adjusted here (later phase). }
  OldPrevious := Node.FPreviousSibling;
  OldNext := Node.FNextSibling;
  WasConnected := (Node.FFlags and NodeFlagConnected) <> 0;
  if OldPrevious <> nil then
    OldPrevious.FNextSibling := OldNext
  else
    Parent.FFirstChild := OldNext;
  if OldNext <> nil then
    OldNext.FPreviousSibling := OldPrevious
  else
    Parent.FLastChild := OldPrevious;
  Node.FParent := nil;
  Node.FPreviousSibling := nil;
  Node.FNextSibling := nil;
  if WasConnected then
    Document.SubtreeDisconnected(Node);
  BecameRoot(Node, Parent);
  if DocumentHasObservers(Document) then
  begin
    if not SuppressObservers then
      Document.NotifyTreeMutated(Parent, nil, NodeList1(Node), OldPrevious, OldNext);
    Document.NotifyChildrenChanged(Parent);
  end;
end;

{ The adopt algorithm. }
procedure AdoptInto(Node: TNode; Document: TDocument);
var
  OldDocument: TDocument;
  Current: TNode;
  Index: Integer;
  Element: TElement;
begin
  OldDocument := Node.FOwnerDocument;
  if Node.FParent <> nil then
    RemoveNode(Node, False);
  if Document = OldDocument then
    Exit;
  BumpDomVersion;
  Current := Node;
  while Current <> nil do
  begin
    Current.FOwnerDocument := Document;
    if Current.FNodeType = NodeTypeElement then
    begin
      Element := TElement(Current);
      if Element.FRareData <> nil then
      begin
        for Index := 1 to System.Length(Element.FRareData.AttrNodes) do
          if Element.FRareData.AttrNodes[Index - 1] <> nil then
            Element.FRareData.AttrNodes[Index - 1].FOwnerDocument := Document;
        { The adopting steps of a template: its contents go to the new
          document's template contents owner. }
        if Element.FRareData.TemplateContent <> nil then
          AdoptInto(Element.FRareData.TemplateContent, Document.TemplateContentsOwner);
      end;
    end;
    Current := Current.NextInTree(Node);
  end;
  RootChangedDocument(Node, OldDocument, Document);
end;

procedure TNode.InsertNodeBefore(Node, Child: TNode);
begin
  InsertNode(Node, TContainerNode(Self), Child, False);
end;

function PreInsert(Node, Parent, Child: TNode): TNode;
var
  ReferenceChild: TNode;
begin
  CheckInsertion(Node, Parent, Child, False);
  ReferenceChild := Child;
  if ReferenceChild = Node then
    ReferenceChild := Node.FNextSibling;
  InsertNode(Node, TContainerNode(Parent), ReferenceChild, False);
  Result := Node;
end;

function TNode.InsertBefore(Node, Child: TNode): TNode;
begin
  Result := PreInsert(Node, Self, Child);
end;

function TNode.AppendChild(Node: TNode): TNode;
begin
  Result := PreInsert(Node, Self, nil);
end;

function TNode.ReplaceChild(Node, Child: TNode): TNode;
var
  ReferenceChild, PreviousNode: TNode;
  Removed, Added: TNodeArray;
  Document: TDocument;
begin
  CheckInsertion(Node, Self, Child, True);
  if Child = nil then
    RaiseDomError(NotFoundError, 'no child to replace');
  ReferenceChild := Child.FNextSibling;
  if ReferenceChild = Node then
    ReferenceChild := Node.FNextSibling;
  PreviousNode := Child.FPreviousSibling;
  Document := FOwnerDocument;
  Removed := nil;
  if Child.FParent <> nil then
  begin
    Removed := NodeList1(Child);
    RemoveNode(Child, True);
  end;
  if Node.FNodeType = NodeTypeDocumentFragment then
    Added := ChildrenOf(Node)
  else
    Added := NodeList1(Node);
  InsertNode(Node, TContainerNode(Self), ReferenceChild, True);
  if DocumentHasObservers(Document) then
    Document.NotifyTreeMutated(Self, Added, Removed, PreviousNode, ReferenceChild);
  Result := Child;
end;

{ The replace all algorithm (Node may be nil). }
procedure ReplaceAll(Node: TNode; Parent: TNode);
var
  Removed, Added: TNodeArray;
  Document: TDocument;
begin
  Document := Parent.FOwnerDocument;
  Removed := nil;
  Added := nil;
  if DocumentHasObservers(Document) then
  begin
    Removed := ChildrenOf(Parent);
    if Node <> nil then
      if Node.FNodeType = NodeTypeDocumentFragment then
        Added := ChildrenOf(Node)
      else
        Added := NodeList1(Node);
  end;
  while Parent.GetFirstChild <> nil do
    RemoveNode(Parent.GetFirstChild, True);
  if Node <> nil then
    InsertNode(Node, TContainerNode(Parent), nil, True);
  if DocumentHasObservers(Document) and ((System.Length(Added) > 0) or (System.Length(Removed) > 0)) then
    Document.NotifyTreeMutated(Parent, Added, Removed, nil, nil);
end;

function TNode.RemoveChild(Child: TNode): TNode;
begin
  if (Child = nil) or (Child.FParent <> Self) then
    RaiseDomError(NotFoundError, 'the node is not a child of this node');
  RemoveNode(Child, False);
  Result := Child;
end;

{ "Convert nodes into a node": several nodes become a fragment. }
function ConvertNodesIntoNode(Document: TDocument; const Nodes: array of TNode): TNode;
var
  Index: Integer;
begin
  if System.Length(Nodes) = 1 then
    Exit(Nodes[0]);
  Result := Document.CreateDocumentFragment;
  for Index := 0 to High(Nodes) do
    Result.AppendChild(Nodes[Index]);
end;

procedure TNode.Prepend(const Nodes: array of TNode);
begin
  if System.Length(Nodes) = 0 then
    Exit;
  PreInsert(ConvertNodesIntoNode(FOwnerDocument, Nodes), Self, GetFirstChild);
end;

procedure TNode.Append(const Nodes: array of TNode);
begin
  if System.Length(Nodes) = 0 then
    Exit;
  PreInsert(ConvertNodesIntoNode(FOwnerDocument, Nodes), Self, nil);
end;

procedure TNode.ReplaceChildren(const Nodes: array of TNode);
var
  Node: TNode;
begin
  if System.Length(Nodes) = 0 then
  begin
    ReplaceAll(nil, Self);
    Exit;
  end;
  Node := ConvertNodesIntoNode(FOwnerDocument, Nodes);
  CheckInsertion(Node, Self, nil, False);
  ReplaceAll(Node, Self);
end;

function IsInNodeList(Node: TNode; const Nodes: array of TNode): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Nodes) do
    if Nodes[Index] = Node then
      Exit(True);
  Result := False;
end;

procedure TNode.Before(const Nodes: array of TNode);
var
  Parent, ViablePrevious, Node: TNode;
begin
  Parent := FParent;
  if (Parent = nil) or (System.Length(Nodes) = 0) then
    Exit;
  ViablePrevious := FPreviousSibling;
  while (ViablePrevious <> nil) and IsInNodeList(ViablePrevious, Nodes) do
    ViablePrevious := ViablePrevious.FPreviousSibling;
  Node := ConvertNodesIntoNode(FOwnerDocument, Nodes);
  if ViablePrevious = nil then
    ViablePrevious := Parent.GetFirstChild
  else
    ViablePrevious := ViablePrevious.FNextSibling;
  PreInsert(Node, Parent, ViablePrevious);
end;

procedure TNode.After(const Nodes: array of TNode);
var
  Parent, ViableNext, Node: TNode;
begin
  Parent := FParent;
  if (Parent = nil) or (System.Length(Nodes) = 0) then
    Exit;
  ViableNext := FNextSibling;
  while (ViableNext <> nil) and IsInNodeList(ViableNext, Nodes) do
    ViableNext := ViableNext.FNextSibling;
  Node := ConvertNodesIntoNode(FOwnerDocument, Nodes);
  PreInsert(Node, Parent, ViableNext);
end;

procedure TNode.ReplaceWith(const Nodes: array of TNode);
var
  Parent, ViableNext, Node: TNode;
begin
  Parent := FParent;
  if Parent = nil then
    Exit;
  ViableNext := FNextSibling;
  while (ViableNext <> nil) and IsInNodeList(ViableNext, Nodes) do
    ViableNext := ViableNext.FNextSibling;
  if System.Length(Nodes) = 0 then
  begin
    RemoveNode(Self, False);
    Exit;
  end;
  Node := ConvertNodesIntoNode(FOwnerDocument, Nodes);
  if FParent = Parent then
    Parent.ReplaceChild(Node, Self)
  else
    PreInsert(Node, Parent, ViableNext);
end;

procedure TNode.Remove;
begin
  if FParent <> nil then
    RemoveNode(Self, False);
end;

{ Replaces the children with one Text node (or none for ''). }
procedure StringReplaceAll(Parent: TNode; const Text: string);
var
  Node: TNode;
begin
  Node := nil;
  if Text <> '' then
    Node := Parent.FOwnerDocument.NewText(Text);
  ReplaceAll(Node, Parent);
end;
