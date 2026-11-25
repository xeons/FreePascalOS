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
  Web.Dom: live ranges (DOM Standard 5.2 and 5.5): boundary points, their
  comparison, setting a range's ends, and the adjustments the mutation
  algorithms make to every live range of a document (insert, remove,
  replace data, split text, normalize). The operations on a range's
  contents are in Web.Dom.RangeContents.
}

function NodeLength(Node: TNode): Integer;
var
  Child: TNode;
begin
  case Node.FNodeType of
    NodeTypeDocumentType, NodeTypeAttribute:
      Result := 0;
    NodeTypeText, NodeTypeCDataSection, NodeTypeComment, NodeTypeProcessingInstruction:
      Result := TCharacterData(Node).GetLength;
  else
    begin
      Result := 0;
      Child := Node.GetFirstChild;
      while Child <> nil do
      begin
        Inc(Result);
        Child := Child.FNextSibling;
      end;
    end;
  end;
end;

function CompareBoundaryPoints(NodeA: TNode; OffsetA: Integer; NodeB: TNode; OffsetB: Integer): Integer;
var
  Position: Word;
  Child: TNode;
begin
  if NodeA = NodeB then
  begin
    if OffsetA = OffsetB then
      Exit(0);
    if OffsetA < OffsetB then
      Exit(-1);
    Exit(1);
  end;
  Position := NodeA.CompareDocumentPosition(NodeB);
  { NodeB precedes NodeA: compare the other way round. }
  if (Position and DocumentPositionPreceding) <> 0 then
    Exit(-CompareBoundaryPoints(NodeB, OffsetB, NodeA, OffsetA));
  if (Position and DocumentPositionContainedBy) <> 0 then
  begin
    Child := NodeB;
    while Child.FParent <> NodeA do
      Child := Child.FParent;
    if Child.IndexInParent < OffsetA then
      Exit(1);
  end;
  Result := -1;
end;

{ TLiveRange }

constructor TLiveRange.Create(Document: TDocument);
begin
  inherited Create;
  FReferences := 1;
  FRetainsNodes := True;
  FStartContainer := Document;
  FEndContainer := Document;
  Document.Retain;
  Document.Retain;
  AttachTo(Document);
end;

destructor TLiveRange.Destroy;
begin
  Detach;
  if FRetainsNodes then
  begin
    if FStartContainer <> nil then
      FStartContainer.Release;
    if FEndContainer <> nil then
      FEndContainer.Release;
  end;
  inherited Destroy;
end;

procedure TLiveRange.Retain;
begin
  Inc(FReferences);
end;

procedure TLiveRange.Release;
begin
  Dec(FReferences);
  if FReferences = 0 then
    Free;
end;

procedure TLiveRange.AttachTo(Document: TDocument);
begin
  if FDocument = Document then
    Exit;
  Detach;
  FDocument := Document;
  if Document <> nil then
    Document.AddLiveRange(Self);
end;

procedure TLiveRange.Detach;
begin
  if FDocument <> nil then
    FDocument.RemoveLiveRange(Self);
  FDocument := nil;
end;

procedure TLiveRange.SetRetainsNodes(Value: Boolean);
begin
  if Value = FRetainsNodes then
    Exit;
  FRetainsNodes := Value;
  if FStartContainer = nil then
    Exit;
  if Value then
  begin
    FStartContainer.Retain;
    FEndContainer.Retain;
  end
  else
  begin
    FStartContainer.Release;
    FEndContainer.Release;
  end;
end;

{ Moves one end (no checks), keeping the references right. }
procedure TLiveRange.SetBoundary(IsStart: Boolean; Node: TNode; Offset: Integer);
var
  Old: TNode;
begin
  if IsStart then
  begin
    Old := FStartContainer;
    FStartContainer := Node;
    FStartOffset := Offset;
  end
  else
  begin
    Old := FEndContainer;
    FEndContainer := Node;
    FEndOffset := Offset;
  end;
  if FRetainsNodes and (Old <> Node) then
  begin
    Node.Retain;
    if Old <> nil then
      Old.Release;
  end;
end;

procedure TLiveRange.Changed;
begin
  if FSelection <> nil then
    FSelection.Changed;
end;

procedure TLiveRange.Moved;
begin
  if (FSelection <> nil) and (Root <> FSelection.Document) then
  begin
    { Letting go holds the nodes again and tells the selection's
      observers that it is empty now. }
    FSelection.SetRange(nil, SelectionDirectionNone);
    Exit;
  end;
  Changed;
end;

function TLiveRange.GetCollapsed: Boolean;
begin
  Result := (FStartContainer = FEndContainer) and (FStartOffset = FEndOffset);
end;

function TLiveRange.Root: TNode;
begin
  if FStartContainer = nil then
    Exit(nil);
  Result := FStartContainer.GetRootNode;
end;

procedure CheckBoundaryPoint(Node: TNode; Offset: Integer);
begin
  if Node.FNodeType = NodeTypeDocumentType then
    RaiseDomError(InvalidNodeTypeError, 'a range cannot be in a doctype');
  if (Offset < 0) or (Offset > NodeLength(Node)) then
    RaiseDomError(IndexSizeError, 'the offset is larger than the node''s length');
end;

procedure TLiveRange.SetRange(StartNode: TNode; StartOffset: Integer; EndNode: TNode; EndOffset: Integer);
begin
  CheckBoundaryPoint(StartNode, StartOffset);
  CheckBoundaryPoint(EndNode, EndOffset);
  SetBoundary(True, StartNode, StartOffset);
  SetBoundary(False, EndNode, EndOffset);
  AttachTo(StartNode.FOwnerDocument);
  Moved;
end;

procedure TLiveRange.SetStart(Node: TNode; Offset: Integer);
begin
  CheckBoundaryPoint(Node, Offset);
  if (FEndContainer = nil) or (Node.GetRootNode <> Root) or
    (CompareBoundaryPoints(Node, Offset, FEndContainer, FEndOffset) > 0) then
    SetBoundary(False, Node, Offset);
  SetBoundary(True, Node, Offset);
  AttachTo(Node.FOwnerDocument);
  Moved;
end;

procedure TLiveRange.SetEnd(Node: TNode; Offset: Integer);
begin
  CheckBoundaryPoint(Node, Offset);
  if (FStartContainer = nil) or (Node.GetRootNode <> Root) or
    (CompareBoundaryPoints(Node, Offset, FStartContainer, FStartOffset) < 0) then
    SetBoundary(True, Node, Offset);
  SetBoundary(False, Node, Offset);
  AttachTo(Node.FOwnerDocument);
  Moved;
end;

procedure TLiveRange.Collapse(ToStart: Boolean);
begin
  if FStartContainer = nil then
    Exit;
  if ToStart then
    SetBoundary(False, FStartContainer, FStartOffset)
  else
    SetBoundary(True, FEndContainer, FEndOffset);
  Moved;
end;

procedure TLiveRange.SelectNode(Node: TNode);
var
  Parent: TNode;
  Index: Integer;
begin
  Parent := Node.FParent;
  if Parent = nil then
    RaiseDomError(InvalidNodeTypeError, 'the node has no parent');
  Index := Node.IndexInParent;
  SetBoundary(True, Parent, Index);
  SetBoundary(False, Parent, Index + 1);
  AttachTo(Parent.FOwnerDocument);
  Moved;
end;

procedure TLiveRange.SelectNodeContents(Node: TNode);
begin
  if Node.FNodeType = NodeTypeDocumentType then
    RaiseDomError(InvalidNodeTypeError, 'a range cannot be in a doctype');
  SetBoundary(True, Node, 0);
  SetBoundary(False, Node, NodeLength(Node));
  AttachTo(Node.FOwnerDocument);
  Moved;
end;

{ The document's list of live ranges and the mutation algorithms' steps. }

procedure TDocument.AddLiveRange(Range: TLiveRange);
begin
  if FLiveRangeCount = System.Length(FLiveRanges) then
    SetLength(FLiveRanges, FLiveRangeCount * 2 + 4);
  FLiveRanges[FLiveRangeCount] := Range;
  Inc(FLiveRangeCount);
end;

procedure TDocument.RemoveLiveRange(Range: TLiveRange);
var
  Index: Integer;
begin
  for Index := 0 to FLiveRangeCount - 1 do
    if FLiveRanges[Index] = Range then
    begin
      Dec(FLiveRangeCount);
      FLiveRanges[Index] := FLiveRanges[FLiveRangeCount];
      FLiveRanges[FLiveRangeCount] := nil;
      Exit;
    end;
end;

{ The insert algorithm, before Count nodes go in at Index of Parent:
  boundary points after the place move along. }
procedure TDocument.RangesChildrenInserted(Parent: TNode; Index, Count: Integer);
var
  Walk: Integer;
  Range: TLiveRange;
  Moved: Boolean;
begin
  for Walk := 0 to FLiveRangeCount - 1 do
  begin
    Range := FLiveRanges[Walk];
    Moved := False;
    if (Range.FStartContainer = Parent) and (Range.FStartOffset > Index) then
    begin
      Inc(Range.FStartOffset, Count);
      Moved := True;
    end;
    if (Range.FEndContainer = Parent) and (Range.FEndOffset > Index) then
    begin
      Inc(Range.FEndOffset, Count);
      Moved := True;
    end;
    if Moved then
      Range.Changed;
  end;
end;

{ The remove algorithm, before Node leaves its parent: points inside it
  go to where it was, points after it in the parent move back. }
procedure TDocument.RangesNodeRemoving(Node: TNode);
var
  Walk, Index: Integer;
  Parent: TNode;
  Range: TLiveRange;
  Moved: Boolean;
begin
  Parent := Node.FParent;
  Index := Node.IndexInParent;
  Walk := 0;
  while Walk < FLiveRangeCount do
  begin
    Range := FLiveRanges[Walk];
    Moved := False;
    if Node.IsInclusiveAncestorOf(Range.FStartContainer) then
    begin
      Range.SetBoundary(True, Parent, Index);
      Moved := True;
    end;
    if Node.IsInclusiveAncestorOf(Range.FEndContainer) then
    begin
      Range.SetBoundary(False, Parent, Index);
      Moved := True;
    end;
    if (Range.FStartContainer = Parent) and (Range.FStartOffset > Index) then
    begin
      Dec(Range.FStartOffset);
      Moved := True;
    end;
    if (Range.FEndContainer = Parent) and (Range.FEndOffset > Index) then
    begin
      Dec(Range.FEndOffset);
      Moved := True;
    end;
    if Moved then
      Range.Changed;
    Inc(Walk);
  end;
end;

{ The replace data algorithm (offsets in UTF-16 code units). }
procedure TDocument.RangesDataReplaced(Node: TNode; Offset, Count, InsertedLength: Integer);
var
  Walk: Integer;
  Range: TLiveRange;
  Moved: Boolean;

  procedure Adjust(var Point: Integer);
  begin
    if (Point > Offset) and (Point <= Offset + Count) then
    begin
      Point := Offset;
      Moved := True;
    end
    else if Point > Offset + Count then
    begin
      Point := Point + InsertedLength - Count;
      Moved := True;
    end;
  end;

begin
  for Walk := 0 to FLiveRangeCount - 1 do
  begin
    Range := FLiveRanges[Walk];
    Moved := False;
    if Range.FStartContainer = Node then
      Adjust(Range.FStartOffset);
    if Range.FEndContainer = Node then
      Adjust(Range.FEndOffset);
    if Moved then
      Range.Changed;
  end;
end;

{ splitText, after the new node was inserted and before the data is cut:
  points past Offset go to the new node; points just after the node in
  the parent move past the new one. }
procedure TDocument.RangesTextSplit(Node, NewNode: TNode; Offset: Integer);
var
  Walk, NodeIndex: Integer;
  Parent: TNode;
  Range: TLiveRange;
  Moved: Boolean;
begin
  Parent := Node.FParent;
  NodeIndex := -1;
  if Parent <> nil then
    NodeIndex := Node.IndexInParent;
  for Walk := 0 to FLiveRangeCount - 1 do
  begin
    Range := FLiveRanges[Walk];
    Moved := False;
    if (Range.FStartContainer = Node) and (Range.FStartOffset > Offset) then
    begin
      Range.SetBoundary(True, NewNode, Range.FStartOffset - Offset);
      Moved := True;
    end;
    if (Range.FEndContainer = Node) and (Range.FEndOffset > Offset) then
    begin
      Range.SetBoundary(False, NewNode, Range.FEndOffset - Offset);
      Moved := True;
    end;
    if Parent <> nil then
    begin
      if (Range.FStartContainer = Parent) and (Range.FStartOffset = NodeIndex + 1) then
      begin
        Inc(Range.FStartOffset);
        Moved := True;
      end;
      if (Range.FEndContainer = Parent) and (Range.FEndOffset = NodeIndex + 1) then
      begin
        Inc(Range.FEndOffset);
        Moved := True;
      end;
    end;
    if Moved then
      Range.Changed;
  end;
end;

{ normalize(), before Sibling (a Text after Node) is merged into Node,
  whose data had LengthBefore code units. }
procedure TDocument.RangesTextMerged(Sibling, Node: TNode; LengthBefore: Integer);
var
  Walk, SiblingIndex: Integer;
  Parent: TNode;
  Range: TLiveRange;
  Moved: Boolean;
begin
  Parent := Sibling.FParent;
  SiblingIndex := Sibling.IndexInParent;
  for Walk := 0 to FLiveRangeCount - 1 do
  begin
    Range := FLiveRanges[Walk];
    Moved := False;
    if Range.FStartContainer = Sibling then
    begin
      Range.SetBoundary(True, Node, Range.FStartOffset + LengthBefore);
      Moved := True;
    end
    else if (Range.FStartContainer = Parent) and (Range.FStartOffset = SiblingIndex) then
    begin
      Range.SetBoundary(True, Node, LengthBefore);
      Moved := True;
    end;
    if Range.FEndContainer = Sibling then
    begin
      Range.SetBoundary(False, Node, Range.FEndOffset + LengthBefore);
      Moved := True;
    end
    else if (Range.FEndContainer = Parent) and (Range.FEndOffset = SiblingIndex) then
    begin
      Range.SetBoundary(False, Node, LengthBefore);
      Moved := True;
    end;
    if Moved then
      Range.Changed;
  end;
end;
