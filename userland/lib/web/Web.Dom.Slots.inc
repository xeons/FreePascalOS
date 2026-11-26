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
  Web.Dom: slots and slottables (DOM Standard 4.2.2.1 to 4.2.2.4) and
  the flat tree. A slot in a shadow tree gets the host's children whose
  slot attribute names it (named assignment) or the ones script gave it
  with assign() (manual assignment). The mutation algorithms and the
  attribute change steps call the hooks below, only for documents that
  have shadow roots; assignments that change tell the observers, and a
  changed slot's slotchange is signaled for the next mutation observer
  microtask.

  Pointers between slots and slottables are weak both ways: a node that
  is freed takes itself out of its slot's lists and clears the slot
  pointers of the nodes it lists.
}

function TElement.IsSlot: Boolean;
begin
  Result := (FLocalName = AtomSlot) and IsHtml;
end;

function TElement.SlotName: string;
begin
  Result := AttributeValueOf(AtomName);
end;

function TElement.SlottableName: string;
begin
  Result := AttributeValueOf(AtomSlot);
end;

function TElement.AssignedNodes: TNodeArray;
begin
  if FRareData = nil then
    Result := nil
  else
    Result := FRareData.SlotAssignedNodes;
end;

function IsSlottable(Node: TNode): Boolean; inline;
begin
  Result := Node.FNodeType in [NodeTypeElement, NodeTypeText];
end;

function IsSlotNode(Node: TNode): Boolean; inline;
begin
  Result := (Node.FNodeType = NodeTypeElement) and TElement(Node).IsSlot;
end;

function NodeArrayContains(const Nodes: TNodeArray; Node: TNode): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Nodes) do
    if Nodes[Index] = Node then
      Exit(True);
  Result := False;
end;

procedure RemoveFromNodeArray(var Nodes: TNodeArray; Node: TNode);
var
  Index, Position: Integer;
begin
  for Index := 0 to High(Nodes) do
    if Nodes[Index] = Node then
    begin
      for Position := Index + 1 to High(Nodes) do
        Nodes[Position - 1] := Nodes[Position];
      SetLength(Nodes, System.Length(Nodes) - 1);
      Exit;
    end;
end;

function SameNodeArrays(const A, B: TNodeArray): Boolean;
var
  Index: Integer;
begin
  if System.Length(A) <> System.Length(B) then
    Exit(False);
  for Index := 0 to High(A) do
    if A[Index] <> B[Index] then
      Exit(False);
  Result := True;
end;

function SubtreeHasSlot(Root: TNode): Boolean;
var
  Node: TNode;
begin
  Node := Root;
  while Node <> nil do
  begin
    if IsSlotNode(Node) then
      Exit(True);
    Node := Node.NextInTree(Root);
  end;
  Result := False;
end;

{ "Find a slot" for Slottable; OpenOnly: nil in closed shadow trees. }
function FindSlot(Slottable: TNode; OpenOnly: Boolean): TElement;
var
  Parent: TNode;
  Shadow: TShadowRoot;
  Name: string;
  Node: TNode;
begin
  Result := nil;
  Parent := Slottable.FParent;
  if (Parent = nil) or (Parent.FNodeType <> NodeTypeElement) then
    Exit;
  Shadow := TElement(Parent).ShadowRoot;
  if Shadow = nil then
    Exit;
  if OpenOnly and (Shadow.FMode <> ShadowRootOpen) then
    Exit;
  if Shadow.FSlotAssignment = SlotAssignmentManual then
  begin
    if (Slottable.FRareData <> nil) and (Slottable.FRareData.ManualSlotAssignment <> nil) and
      (Slottable.FRareData.ManualSlotAssignment.GetRootNode = Shadow) then
      Result := Slottable.FRareData.ManualSlotAssignment;
    Exit;
  end;
  if not Shadow.FMayHaveSlots then
    Exit;
  if Slottable.FNodeType = NodeTypeElement then
    Name := TElement(Slottable).SlottableName
  else
    Name := '';
  Node := Shadow.FFirstChild;
  while Node <> nil do
  begin
    if IsSlotNode(Node) and (TElement(Node).SlotName = Name) then
      Exit(TElement(Node));
    Node := Node.NextInTree(Shadow);
  end;
end;

{ "Find slottables" for Slot. }
function FindSlottables(Slot: TElement): TNodeArray;
var
  Root: TNode;
  Host: TElement;
  Child: TNode;
  Count, Index: Integer;
  Manual: TNodeArray;
begin
  Result := nil;
  Root := Slot.GetRootNode;
  if not (Root is TShadowRoot) or (TShadowRoot(Root).FHost = nil) then
    Exit;
  Host := TShadowRoot(Root).FHost;
  Count := 0;
  if TShadowRoot(Root).FSlotAssignment = SlotAssignmentManual then
  begin
    if Slot.FRareData = nil then
      Exit;
    Manual := Slot.FRareData.SlotManualNodes;
    SetLength(Result, System.Length(Manual));
    for Index := 0 to High(Manual) do
      if Manual[Index].FParent = Host then
      begin
        Result[Count] := Manual[Index];
        Inc(Count);
      end;
  end
  else
  begin
    SetLength(Result, Host.ChildCount);
    Child := Host.FFirstChild;
    while Child <> nil do
    begin
      if IsSlottable(Child) and (FindSlot(Child, False) = Slot) then
      begin
        Result[Count] := Child;
        Inc(Count);
      end;
      Child := Child.FNextSibling;
    end;
  end;
  SetLength(Result, Count);
end;

procedure AppendFlattened(Slot: TElement; var Result: TNodeArray; var Count: Integer);
var
  Nodes: TNodeArray;
  Index: Integer;
  Child: TNode;

  procedure Add(Node: TNode);
  begin
    if Count >= System.Length(Result) then
      SetLength(Result, Count * 2 + 4);
    Result[Count] := Node;
    Inc(Count);
  end;

begin
  Nodes := Slot.AssignedNodes;
  if System.Length(Nodes) = 0 then
  begin
    { The slot's own slottable children stand in. }
    Child := Slot.FFirstChild;
    while Child <> nil do
    begin
      if IsSlottable(Child) then
        if IsSlotNode(Child) and (Child.GetRootNode is TShadowRoot) then
          AppendFlattened(TElement(Child), Result, Count)
        else
          Add(Child);
      Child := Child.FNextSibling;
    end;
    Exit;
  end;
  for Index := 0 to High(Nodes) do
    if IsSlotNode(Nodes[Index]) and (Nodes[Index].GetRootNode is TShadowRoot) then
      AppendFlattened(TElement(Nodes[Index]), Result, Count)
    else
      Add(Nodes[Index]);
end;

function TElement.FlattenedAssignedNodes: TNodeArray;
var
  Count: Integer;
begin
  Result := nil;
  if not (GetRootNode is TShadowRoot) then
    Exit;
  Count := 0;
  AppendFlattened(Self, Result, Count);
  SetLength(Result, Count);
end;

procedure SignalSlotChange(Slot: TElement);
begin
  Slot.FOwnerDocument.NotifySlotChangeSignaled(Slot);
end;

{ "Assign slottables" for Slot. }
procedure AssignSlottables(Slot: TElement);
var
  Slottables, Old: TNodeArray;
  Index: Integer;
  Node: TNode;
begin
  Slottables := FindSlottables(Slot);
  Old := Slot.AssignedNodes;
  if SameNodeArrays(Slottables, Old) then
    Exit;
  SignalSlotChange(Slot);
  { Nodes that are no longer assigned here lose their slot. }
  for Index := 0 to High(Old) do
  begin
    Node := Old[Index];
    if (Node.FRareData <> nil) and (Node.FRareData.AssignedSlot = Slot) and
      not NodeArrayContains(Slottables, Node) then
      Node.FRareData.AssignedSlot := nil;
  end;
  if (Slottables <> nil) or (Slot.FRareData <> nil) then
    Slot.RareData.SlotAssignedNodes := Slottables;
  for Index := 0 to High(Slottables) do
  begin
    Node := Slottables[Index];
    if (Node.FRareData <> nil) and (Node.FRareData.AssignedSlot <> nil) and
      (Node.FRareData.AssignedSlot <> Slot) then
      RemoveFromNodeArray(Node.FRareData.AssignedSlot.FRareData.SlotAssignedNodes, Node);
    Node.RareData.AssignedSlot := Slot;
  end;
  BumpDomVersion;
  Slot.FOwnerDocument.NotifySlotAssignmentChanged(Slot);
end;

{ "Assign slottables for a tree" (only shadow trees can have slots with
  assigned nodes; elsewhere slots are emptied). }
procedure AssignSlottablesForTree(Root: TNode);
var
  Node: TNode;
begin
  if (Root is TShadowRoot) and not TShadowRoot(Root).FMayHaveSlots then
    Exit;
  Node := Root;
  while Node <> nil do
  begin
    if IsSlotNode(Node) then
      if Root is TShadowRoot then
        AssignSlottables(TElement(Node))
      else if (Node.FRareData <> nil) and (System.Length(Node.FRareData.SlotAssignedNodes) > 0) then
        AssignSlottables(TElement(Node));
    Node := Node.NextInTree(Root);
  end;
end;

{ "Assign a slot" for Slottable. }
procedure AssignASlot(Slottable: TNode);
var
  Slot: TElement;
begin
  Slot := FindSlot(Slottable, False);
  if Slot <> nil then
    AssignSlottables(Slot);
end;

procedure TElement.AssignNodesManually(const Nodes: TNodeArray);
var
  Index: Integer;
  Node: TNode;
  Kept: TNodeArray;
  Count: Integer;
  Old: TElement;
begin
  if FRareData <> nil then
    for Index := 0 to High(FRareData.SlotManualNodes) do
      if FRareData.SlotManualNodes[Index].FRareData <> nil then
        FRareData.SlotManualNodes[Index].FRareData.ManualSlotAssignment := nil;
  Kept := nil;
  SetLength(Kept, System.Length(Nodes));
  Count := 0;
  for Index := 0 to High(Nodes) do
  begin
    Node := Nodes[Index];
    if (Node = nil) or NodeArrayContains(Copy(Kept, 0, Count), Node) then
      Continue;
    if Node.FRareData <> nil then
    begin
      Old := Node.FRareData.ManualSlotAssignment;
      if (Old <> nil) and (Old <> Self) and (Old.FRareData <> nil) then
        RemoveFromNodeArray(Old.FRareData.SlotManualNodes, Node);
    end;
    Node.RareData.ManualSlotAssignment := Self;
    Kept[Count] := Node;
    Inc(Count);
  end;
  SetLength(Kept, Count);
  RareData.SlotManualNodes := Kept;
  AssignSlottablesForTree(GetRootNode);
end;

{ The insertion hooks (DOM Standard: insert, step 7.4 to 7.6), for Node
  just inserted into Parent. }
procedure SlotsNodeInserted(Node: TNode; Parent: TContainerNode);
var
  Root: TNode;
  Shadow: TShadowRoot;
begin
  if (Parent.FNodeType = NodeTypeElement) and IsSlottable(Node) then
  begin
    Shadow := TElement(Parent).ShadowRoot;
    if (Shadow <> nil) and (Shadow.FSlotAssignment = SlotAssignmentNamed) then
      AssignASlot(Node);
  end;
  Root := Parent.GetRootNode;
  if not (Root is TShadowRoot) then
    Exit;
  if IsSlotNode(Parent) and (System.Length(TElement(Parent).AssignedNodes) = 0) then
    SignalSlotChange(TElement(Parent));
  if SubtreeHasSlot(Node) then
  begin
    TShadowRoot(Root).FMayHaveSlots := True;
    AssignSlottablesForTree(Root);
  end;
end;

{ The removal hooks (DOM Standard: remove, steps 7 to 10), for Node just
  taken out of OldParent; OldSlot is the slot it was assigned to. }
procedure SlotsNodeRemoved(Node: TNode; OldParent: TContainerNode; OldSlot: TElement);
var
  ParentRoot: TNode;
begin
  if OldSlot <> nil then
    AssignSlottables(OldSlot);
  ParentRoot := OldParent.GetRootNode;
  if (ParentRoot is TShadowRoot) and IsSlotNode(OldParent) and
    (System.Length(TElement(OldParent).AssignedNodes) = 0) then
    SignalSlotChange(TElement(OldParent));
  if SubtreeHasSlot(Node) then
  begin
    AssignSlottablesForTree(ParentRoot);
    AssignSlottablesForTree(Node);
  end;
end;

{ The attribute change steps for slot names and slottable names. }
procedure SlotsAttributeChanged(Element: TElement; LocalAtom: TAtom; const OldValue: string; HadValue: Boolean);
var
  NewValue: string;
  HasValue: Boolean;
  OldSlot: TElement;
begin
  HasValue := Element.HasAttributeAtom(LocalAtom);
  NewValue := Element.AttributeValueOf(LocalAtom);
  if (HasValue = HadValue) and (NewValue = OldValue) then
    Exit;
  if (not HasValue and (OldValue = '')) or (not HadValue and (NewValue = '')) then
    Exit;
  if (LocalAtom = AtomName) and Element.IsSlot then
    AssignSlottablesForTree(Element.GetRootNode)
  else if LocalAtom = AtomSlot then
  begin
    OldSlot := Element.AssignedSlot;
    if OldSlot <> nil then
      AssignSlottables(OldSlot);
    AssignASlot(Element);
  end;
end;

{ A node being freed takes itself out of the slot lists. }
procedure SlotsNodeDestroyed(Node: TNode);
var
  Data: TNodeRareData;
  Index: Integer;
  Other: TNode;
begin
  Data := Node.FRareData;
  if Data.AssignedSlot <> nil then
    if Data.AssignedSlot.FRareData <> nil then
      RemoveFromNodeArray(Data.AssignedSlot.FRareData.SlotAssignedNodes, Node);
  if Data.ManualSlotAssignment <> nil then
    if Data.ManualSlotAssignment.FRareData <> nil then
      RemoveFromNodeArray(Data.ManualSlotAssignment.FRareData.SlotManualNodes, Node);
  for Index := 0 to High(Data.SlotAssignedNodes) do
  begin
    Other := Data.SlotAssignedNodes[Index];
    if (Other.FRareData <> nil) and (Other.FRareData.AssignedSlot = Node) then
      Other.FRareData.AssignedSlot := nil;
  end;
  for Index := 0 to High(Data.SlotManualNodes) do
  begin
    Other := Data.SlotManualNodes[Index];
    if (Other.FRareData <> nil) and (Other.FRareData.ManualSlotAssignment = Node) then
      Other.FRareData.ManualSlotAssignment := nil;
  end;
  Data.AssignedSlot := nil;
  Data.ManualSlotAssignment := nil;
  Data.SlotAssignedNodes := nil;
  Data.SlotManualNodes := nil;
end;

procedure TDocument.NotifySlotChangeSignaled(Slot: TElement);
var
  Index: Integer;
begin
  for Index := 1 to System.Length(FObservers) do
    FObservers[Index - 1].SlotChangeSignaled(Slot);
end;

procedure TDocument.NotifySlotAssignmentChanged(Slot: TElement);
var
  Index: Integer;
begin
  for Index := 1 to System.Length(FObservers) do
    FObservers[Index - 1].SlotAssignmentChanged(Slot);
end;

{ The flat tree (CSS Scoping 2.1). }

function FlatTreeParent(Node: TNode): TNode;
var
  Parent: TNode;
begin
  if (Node.FRareData <> nil) and (Node.FRareData.AssignedSlot <> nil) then
    Exit(Node.FRareData.AssignedSlot);
  Parent := Node.FParent;
  if Parent = nil then
    Exit(nil);
  if Parent is TShadowRoot then
    Exit(TShadowRoot(Parent).FHost);
  if Parent.FNodeType = NodeTypeElement then
  begin
    { A host's unassigned children and a filled slot's own children are
      not in the flat tree. }
    if TElement(Parent).ShadowRoot <> nil then
      Exit(nil);
    if IsSlotNode(Parent) and (System.Length(TElement(Parent).AssignedNodes) > 0) then
      Exit(nil);
  end;
  Result := Parent;
end;

function FlatTreeFirstChild(Node: TNode; out Cursor: TFlatTreeCursor): TNode;
var
  Shadow: TShadowRoot;
begin
  Cursor.Nodes := nil;
  Cursor.Index := 0;
  Cursor.Current := nil;
  if Node.FNodeType = NodeTypeElement then
  begin
    Shadow := TElement(Node).ShadowRoot;
    if Shadow <> nil then
    begin
      Cursor.Current := Shadow.FFirstChild;
      Exit(Cursor.Current);
    end;
    if (Node.FRareData <> nil) and (System.Length(Node.FRareData.SlotAssignedNodes) > 0) then
    begin
      Cursor.Nodes := Node.FRareData.SlotAssignedNodes;
      Cursor.Current := Cursor.Nodes[0];
      Exit(Cursor.Current);
    end;
  end;
  Cursor.Current := Node.GetFirstChild;
  Result := Cursor.Current;
end;

function FlatTreeNextChild(var Cursor: TFlatTreeCursor): TNode;
begin
  if Cursor.Nodes <> nil then
  begin
    Inc(Cursor.Index);
    if Cursor.Index < System.Length(Cursor.Nodes) then
      Cursor.Current := Cursor.Nodes[Cursor.Index]
    else
      Cursor.Current := nil;
  end
  else if Cursor.Current <> nil then
    Cursor.Current := Cursor.Current.FNextSibling;
  Result := Cursor.Current;
end;

function HasFlatTreeChildren(Node: TNode): Boolean;
var
  Cursor: TFlatTreeCursor;
begin
  Result := FlatTreeFirstChild(Node, Cursor) <> nil;
end;
