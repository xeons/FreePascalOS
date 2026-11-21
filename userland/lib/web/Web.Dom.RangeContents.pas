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
  What a range does to its contents (DOM Standard 5.5): containment,
  cloning, extracting and deleting the contents, inserting a node at the
  start, surrounding the contents, the text, and the comparisons Range
  offers script. The boundary points and the live adjustments are in
  Web.Dom (Web.Dom.Ranges.inc); everything here goes through the DOM's
  own mutation algorithms, so live ranges, observers and mutation
  records follow as they would for script's own calls.
}
unit Web.Dom.RangeContents;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom;

{ A boundary point pair (a range or a static range). }
type
  TBoundaryPoints = record
    StartNode: TNode;
    StartOffset: Integer;
    EndNode: TNode;
    EndOffset: Integer;
  end;

function RangePoints(Range: TLiveRange): TBoundaryPoints;
{ Node is contained in the range: in its tree, entirely between its ends. }
function NodeContained(Node: TNode; constref Points: TBoundaryPoints): Boolean;
{ An inclusive ancestor of one end but not of the other. }
function NodePartiallyContained(Node: TNode; constref Points: TBoundaryPoints): Boolean;
function RangeCloneContents(Range: TLiveRange): TDocumentFragment;
function RangeExtractContents(Range: TLiveRange): TDocumentFragment;
procedure RangeDeleteContents(Range: TLiveRange);
procedure RangeInsertNode(Range: TLiveRange; Node: TNode);
procedure RangeSurroundContents(Range: TLiveRange; NewParent: TNode);
{ The concatenated data of the Text nodes in the range (stringifier). }
function RangeText(constref Points: TBoundaryPoints): string;
{ comparePoint: -1 before, 0 inside, 1 after (WrongDocumentError for
  another tree). }
function RangeComparePoint(Range: TLiveRange; Node: TNode; Offset: Integer): Integer;
function RangeIsPointInRange(Range: TLiveRange; Node: TNode; Offset: Integer): Boolean;
function RangeIntersectsNode(Range: TLiveRange; Node: TNode): Boolean;
{ The Text and element nodes the range covers, for its client rects:
  each Text partly or wholly in it with the code unit span, and each
  element wholly in it whose parent is not. }
type
  TRangePiece = record
    Node: TNode;
    { For Text: the span in UTF-16 code units. }
    StartOffset, EndOffset: Integer;
  end;
  TRangePieceArray = array of TRangePiece;

function RangePieces(constref Points: TBoundaryPoints): TRangePieceArray;

implementation

uses
  Web.Dom.Exceptions;

function RangePoints(Range: TLiveRange): TBoundaryPoints;
begin
  Result.StartNode := Range.StartContainer;
  Result.StartOffset := Range.StartOffset;
  Result.EndNode := Range.EndContainer;
  Result.EndOffset := Range.EndOffset;
end;

function IsCharacterData(Node: TNode): Boolean;
begin
  Result := Node.NodeType in [NodeTypeText, NodeTypeCDataSection, NodeTypeComment, NodeTypeProcessingInstruction];
end;

function NodeContained(Node: TNode; constref Points: TBoundaryPoints): Boolean;
begin
  Result := (Node.GetRootNode = Points.StartNode.GetRootNode) and
    (CompareBoundaryPoints(Node, 0, Points.StartNode, Points.StartOffset) > 0) and
    (CompareBoundaryPoints(Node, NodeLength(Node), Points.EndNode, Points.EndOffset) < 0);
end;

function NodePartiallyContained(Node: TNode; constref Points: TBoundaryPoints): Boolean;
begin
  Result := Node.IsInclusiveAncestorOf(Points.StartNode) <> Node.IsInclusiveAncestorOf(Points.EndNode);
end;

{ The first node in tree order after the start boundary point. }
function FirstNodeAfterStart(constref Points: TBoundaryPoints): TNode;
begin
  Result := nil;
  if Points.StartNode.IsContainer then
    Result := Points.StartNode.ChildAt(Points.StartOffset);
  if Result = nil then
    Result := Points.StartNode.NextInTreeSkippingChildren;
end;

{ Node starts at or after the end boundary point: the walk is over. }
function PastEnd(Node: TNode; constref Points: TBoundaryPoints): Boolean;
begin
  Result := (Node = nil) or (CompareBoundaryPoints(Node, 0, Points.EndNode, Points.EndOffset) >= 0);
end;

function IsCollapsed(constref Points: TBoundaryPoints): Boolean;
begin
  Result := (Points.StartNode = Points.EndNode) and (Points.StartOffset = Points.EndOffset);
end;

function Points(StartNode: TNode; StartOffset: Integer; EndNode: TNode; EndOffset: Integer): TBoundaryPoints;
begin
  Result.StartNode := StartNode;
  Result.StartOffset := StartOffset;
  Result.EndNode := EndNode;
  Result.EndOffset := EndOffset;
end;

{ A copy of a character data node with part of its data. }
function CloneWithData(Node: TNode; Offset, Count: Integer): TNode;
begin
  Result := Node.CloneNode(False);
  TCharacterData(Result).Data := TCharacterData(Node).SubstringData(Offset, Count);
end;

procedure FindCommonParts(constref Range: TBoundaryPoints; out Common, FirstPartial, LastPartial: TNode;
  out Contained: TNodeArray);
var
  Child: TNode;
begin
  Common := Range.StartNode;
  while not Common.IsInclusiveAncestorOf(Range.EndNode) do
    Common := Common.ParentNode;
  FirstPartial := nil;
  LastPartial := nil;
  Contained := nil;
  Child := Common.FirstChild;
  while Child <> nil do
  begin
    if NodeContained(Child, Range) then
    begin
      SetLength(Contained, Length(Contained) + 1);
      Contained[High(Contained)] := Child;
    end
    else if NodePartiallyContained(Child, Range) then
    begin
      if (FirstPartial = nil) and not Range.StartNode.IsInclusiveAncestorOf(Range.EndNode) and
        Child.IsInclusiveAncestorOf(Range.StartNode) then
        FirstPartial := Child;
      if not Range.EndNode.IsInclusiveAncestorOf(Range.StartNode) and Child.IsInclusiveAncestorOf(Range.EndNode) then
        LastPartial := Child;
    end;
    Child := Child.NextSibling;
  end;
end;

procedure CheckNoDoctype(const Contained: TNodeArray);
var
  Index: Integer;
begin
  for Index := 0 to High(Contained) do
    if Contained[Index].NodeType = NodeTypeDocumentType then
      RaiseDomError(HierarchyRequestError, 'the range contains a doctype');
end;

function CloneBetween(constref Range: TBoundaryPoints): TDocumentFragment;
var
  Common, FirstPartial, LastPartial, Clone: TNode;
  Contained: TNodeArray;
  Index: Integer;
begin
  Result := Range.StartNode.NodeDocument.CreateDocumentFragment;
  if IsCollapsed(Range) then
    Exit;
  if (Range.StartNode = Range.EndNode) and IsCharacterData(Range.StartNode) then
  begin
    Result.AppendChild(CloneWithData(Range.StartNode, Range.StartOffset, Range.EndOffset - Range.StartOffset));
    Exit;
  end;
  FindCommonParts(Range, Common, FirstPartial, LastPartial, Contained);
  CheckNoDoctype(Contained);
  if FirstPartial <> nil then
  begin
    if IsCharacterData(FirstPartial) then
      Result.AppendChild(CloneWithData(FirstPartial, Range.StartOffset,
        NodeLength(FirstPartial) - Range.StartOffset))
    else
    begin
      Clone := FirstPartial.CloneNode(False);
      Result.AppendChild(Clone);
      Clone.AppendChild(CloneBetween(Points(Range.StartNode, Range.StartOffset, FirstPartial,
        NodeLength(FirstPartial))));
    end;
  end;
  for Index := 0 to High(Contained) do
    Result.AppendChild(Contained[Index].CloneNode(True));
  if LastPartial <> nil then
  begin
    if IsCharacterData(LastPartial) then
      Result.AppendChild(CloneWithData(LastPartial, 0, Range.EndOffset))
    else
    begin
      Clone := LastPartial.CloneNode(False);
      Result.AppendChild(Clone);
      Clone.AppendChild(CloneBetween(Points(LastPartial, 0, Range.EndNode, Range.EndOffset)));
    end;
  end;
end;

function RangeCloneContents(Range: TLiveRange): TDocumentFragment;
begin
  Result := CloneBetween(RangePoints(Range));
end;

{ Where the range collapses after its contents went (extract, delete). }
procedure CollapsePointAfterRemoval(constref Range: TBoundaryPoints; out NewNode: TNode; out NewOffset: Integer);
var
  Reference: TNode;
begin
  if Range.StartNode.IsInclusiveAncestorOf(Range.EndNode) then
  begin
    NewNode := Range.StartNode;
    NewOffset := Range.StartOffset;
    Exit;
  end;
  Reference := Range.StartNode;
  while (Reference.ParentNode <> nil) and not Reference.ParentNode.IsInclusiveAncestorOf(Range.EndNode) do
    Reference := Reference.ParentNode;
  NewNode := Reference.ParentNode;
  NewOffset := Reference.IndexInParent + 1;
end;

function ExtractBetween(constref Range: TBoundaryPoints; out NewNode: TNode; out NewOffset: Integer): TDocumentFragment;
var
  Common, FirstPartial, LastPartial, Clone: TNode;
  Contained: TNodeArray;
  Index: Integer;
  IgnoredNode: TNode;
  IgnoredOffset: Integer;
begin
  NewNode := Range.StartNode;
  NewOffset := Range.StartOffset;
  Result := Range.StartNode.NodeDocument.CreateDocumentFragment;
  if IsCollapsed(Range) then
    Exit;
  if (Range.StartNode = Range.EndNode) and IsCharacterData(Range.StartNode) then
  begin
    Result.AppendChild(CloneWithData(Range.StartNode, Range.StartOffset, Range.EndOffset - Range.StartOffset));
    TCharacterData(Range.StartNode).ReplaceData(Range.StartOffset, Range.EndOffset - Range.StartOffset, '');
    Exit;
  end;
  FindCommonParts(Range, Common, FirstPartial, LastPartial, Contained);
  CheckNoDoctype(Contained);
  CollapsePointAfterRemoval(Range, NewNode, NewOffset);
  if FirstPartial <> nil then
  begin
    if IsCharacterData(FirstPartial) then
    begin
      Result.AppendChild(CloneWithData(FirstPartial, Range.StartOffset,
        NodeLength(FirstPartial) - Range.StartOffset));
      TCharacterData(Range.StartNode).ReplaceData(Range.StartOffset,
        NodeLength(Range.StartNode) - Range.StartOffset, '');
    end
    else
    begin
      Clone := FirstPartial.CloneNode(False);
      Result.AppendChild(Clone);
      Clone.AppendChild(ExtractBetween(Points(Range.StartNode, Range.StartOffset, FirstPartial,
        NodeLength(FirstPartial)), IgnoredNode, IgnoredOffset));
    end;
  end;
  for Index := 0 to High(Contained) do
    Result.AppendChild(Contained[Index]);
  if LastPartial <> nil then
  begin
    if IsCharacterData(LastPartial) then
    begin
      Result.AppendChild(CloneWithData(LastPartial, 0, Range.EndOffset));
      TCharacterData(Range.EndNode).ReplaceData(0, Range.EndOffset, '');
    end
    else
    begin
      Clone := LastPartial.CloneNode(False);
      Result.AppendChild(Clone);
      Clone.AppendChild(ExtractBetween(Points(LastPartial, 0, Range.EndNode, Range.EndOffset), IgnoredNode,
        IgnoredOffset));
    end;
  end;
end;

function RangeExtractContents(Range: TLiveRange): TDocumentFragment;
var
  NewNode: TNode;
  NewOffset: Integer;
begin
  Result := ExtractBetween(RangePoints(Range), NewNode, NewOffset);
  if Range.StartContainer <> nil then
    Range.SetRange(NewNode, NewOffset, NewNode, NewOffset);
end;

procedure RangeDeleteContents(Range: TLiveRange);
var
  Original: TBoundaryPoints;
  ToRemove: TNodeArray;
  Node, NewNode: TNode;
  NewOffset, Index: Integer;
begin
  Original := RangePoints(Range);
  if IsCollapsed(Original) then
    Exit;
  if (Original.StartNode = Original.EndNode) and IsCharacterData(Original.StartNode) then
  begin
    TCharacterData(Original.StartNode).ReplaceData(Original.StartOffset, Original.EndOffset - Original.StartOffset, '');
    Exit;
  end;
  { The contained nodes whose parents are not contained, in tree order. }
  ToRemove := nil;
  Node := FirstNodeAfterStart(Original);
  while not PastEnd(Node, Original) do
  begin
    if NodeContained(Node, Original) then
    begin
      SetLength(ToRemove, Length(ToRemove) + 1);
      ToRemove[High(ToRemove)] := Node;
      Node := Node.NextInTreeSkippingChildren;
    end
    else
      Node := Node.NextInTree;
  end;
  CollapsePointAfterRemoval(Original, NewNode, NewOffset);
  if IsCharacterData(Original.StartNode) then
    TCharacterData(Original.StartNode).ReplaceData(Original.StartOffset,
      NodeLength(Original.StartNode) - Original.StartOffset, '');
  for Index := 0 to High(ToRemove) do
    if ToRemove[Index].ParentNode <> nil then
      ToRemove[Index].ParentNode.RemoveChild(ToRemove[Index]);
  if IsCharacterData(Original.EndNode) then
    TCharacterData(Original.EndNode).ReplaceData(0, Original.EndOffset, '');
  Range.SetRange(NewNode, NewOffset, NewNode, NewOffset);
end;

procedure RangeInsertNode(Range: TLiveRange; Node: TNode);
var
  StartNode, Reference, Parent: TNode;
  NewOffset: Integer;
  WasCollapsed: Boolean;
begin
  StartNode := Range.StartContainer;
  if (StartNode.NodeType in [NodeTypeProcessingInstruction, NodeTypeComment]) or
    (StartNode.IsText and (StartNode.ParentNode = nil)) or (StartNode = Node) then
    RaiseDomError(HierarchyRequestError, 'the node cannot be inserted at the range''s start');
  WasCollapsed := Range.Collapsed;
  if StartNode.IsText then
    Reference := StartNode
  else
    Reference := StartNode.ChildAt(Range.StartOffset);
  if Reference = nil then
    Parent := StartNode
  else
    Parent := Reference.ParentNode;
  if Node.IsInclusiveAncestorOf(Parent) then
    RaiseDomError(HierarchyRequestError, 'the node would contain itself');
  if StartNode.IsText then
    Reference := TText(StartNode).SplitText(Range.StartOffset);
  if Node = Reference then
    Reference := Reference.NextSibling;
  if Node.ParentNode <> nil then
    Node.ParentNode.RemoveChild(Node);
  if Reference = nil then
    NewOffset := NodeLength(Parent)
  else
    NewOffset := Reference.IndexInParent;
  if Node.NodeType = NodeTypeDocumentFragment then
    Inc(NewOffset, NodeLength(Node))
  else
    Inc(NewOffset);
  Parent.InsertBefore(Node, Reference);
  if WasCollapsed then
    Range.SetEnd(Parent, NewOffset);
end;

procedure RangeSurroundContents(Range: TLiveRange; NewParent: TNode);
var
  Original: TBoundaryPoints;
  Node: TNode;
  Fragment: TDocumentFragment;
begin
  Original := RangePoints(Range);
  Node := Original.StartNode;
  while Node <> nil do
  begin
    if (not Node.IsText) and NodePartiallyContained(Node, Original) then
      RaiseDomError(InvalidStateError, 'the range partially contains a node that is not text');
    Node := Node.ParentNode;
  end;
  Node := Original.EndNode;
  while Node <> nil do
  begin
    if (not Node.IsText) and NodePartiallyContained(Node, Original) then
      RaiseDomError(InvalidStateError, 'the range partially contains a node that is not text');
    Node := Node.ParentNode;
  end;
  if NewParent.NodeType in [NodeTypeDocument, NodeTypeDocumentType, NodeTypeDocumentFragment] then
    RaiseDomError(InvalidNodeTypeError, 'that node cannot surround the range');
  Fragment := RangeExtractContents(Range);
  if NewParent.HasChildNodes then
    NewParent.ReplaceChildren([]);
  RangeInsertNode(Range, NewParent);
  NewParent.AppendChild(Fragment);
  Range.SelectNode(NewParent);
end;

function RangeText(constref Points: TBoundaryPoints): string;
var
  Node: TNode;
begin
  Result := '';
  if Points.StartNode = nil then
    Exit;
  if (Points.StartNode = Points.EndNode) and Points.StartNode.IsText then
    Exit(TCharacterData(Points.StartNode).SubstringData(Points.StartOffset, Points.EndOffset - Points.StartOffset));
  if Points.StartNode.IsText then
    Result := TCharacterData(Points.StartNode).SubstringData(Points.StartOffset,
      NodeLength(Points.StartNode) - Points.StartOffset);
  Node := FirstNodeAfterStart(Points);
  while not PastEnd(Node, Points) do
  begin
    if Node.IsText and NodeContained(Node, Points) then
      Result := Result + TCharacterData(Node).Data;
    Node := Node.NextInTree;
  end;
  if Points.EndNode.IsText then
    Result := Result + TCharacterData(Points.EndNode).SubstringData(0, Points.EndOffset);
end;

function RangeComparePoint(Range: TLiveRange; Node: TNode; Offset: Integer): Integer;
begin
  if Node.GetRootNode <> Range.Root then
    RaiseDomError(WrongDocumentError, 'the node is in another tree');
  if Node.NodeType = NodeTypeDocumentType then
    RaiseDomError(InvalidNodeTypeError, 'a range cannot be in a doctype');
  if (Offset < 0) or (Offset > NodeLength(Node)) then
    RaiseDomError(IndexSizeError, 'the offset is larger than the node''s length');
  if CompareBoundaryPoints(Node, Offset, Range.StartContainer, Range.StartOffset) < 0 then
    Exit(-1);
  if CompareBoundaryPoints(Node, Offset, Range.EndContainer, Range.EndOffset) > 0 then
    Exit(1);
  Result := 0;
end;

function RangeIsPointInRange(Range: TLiveRange; Node: TNode; Offset: Integer): Boolean;
begin
  if Node.GetRootNode <> Range.Root then
    Exit(False);
  Result := RangeComparePoint(Range, Node, Offset) = 0;
end;

function RangeIntersectsNode(Range: TLiveRange; Node: TNode): Boolean;
var
  Parent: TNode;
  Offset: Integer;
begin
  if Node.GetRootNode <> Range.Root then
    Exit(False);
  Parent := Node.ParentNode;
  if Parent = nil then
    Exit(True);
  Offset := Node.IndexInParent;
  Result := (CompareBoundaryPoints(Parent, Offset, Range.EndContainer, Range.EndOffset) < 0) and
    (CompareBoundaryPoints(Parent, Offset + 1, Range.StartContainer, Range.StartOffset) > 0);
end;

function RangePieces(constref Points: TBoundaryPoints): TRangePieceArray;

  procedure Add(Node: TNode; StartOffset, EndOffset: Integer);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Node := Node;
    Result[High(Result)].StartOffset := StartOffset;
    Result[High(Result)].EndOffset := EndOffset;
  end;

var
  Node: TNode;
begin
  Result := nil;
  if Points.StartNode = nil then
    Exit;
  if (Points.StartNode = Points.EndNode) and Points.StartNode.IsText then
  begin
    Add(Points.StartNode, Points.StartOffset, Points.EndOffset);
    Exit;
  end;
  if Points.StartNode.IsText then
    Add(Points.StartNode, Points.StartOffset, NodeLength(Points.StartNode));
  Node := FirstNodeAfterStart(Points);
  while not PastEnd(Node, Points) do
  begin
    if NodeContained(Node, Points) then
    begin
      if Node.IsText then
        Add(Node, 0, NodeLength(Node))
      else if Node.IsElement then
      begin
        { The element's box covers its contents. }
        Add(Node, 0, 0);
        Node := Node.NextInTreeSkippingChildren;
        Continue;
      end;
    end;
    Node := Node.NextInTree;
  end;
  if Points.EndNode.IsText and (Points.EndNode <> Points.StartNode) then
    Add(Points.EndNode, 0, Points.EndOffset);
end;

end.
