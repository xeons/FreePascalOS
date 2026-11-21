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
  Web.Dom: a document's selection (Selection API, W3C): one range or
  none, and a direction. Script (Web.Bindings.Ranges) and the web view
  (the user's mouse selection) change it; every change tells the
  document's observers (SelectionChanged), which repaint and queue the
  selectionchange event.
}

procedure TDocumentObserver.SelectionChanged(Document: TDocument);
begin
end;

procedure TDocument.NotifySelectionChanged;
var
  Index: Integer;
begin
  for Index := 0 to High(FObservers) do
    if FObservers[Index] <> nil then
      FObservers[Index].SelectionChanged(Self);
end;

function TDocument.GetSelection: TDocumentSelection;
begin
  if FSelection = nil then
    FSelection := TDocumentSelection.Create(Self);
  Result := FSelection;
end;

{ TDocumentSelection }

constructor TDocumentSelection.Create(Document: TDocument);
begin
  inherited Create;
  FDocument := Document;
end;

destructor TDocumentSelection.Destroy;
begin
  if FRange <> nil then
  begin
    FRange.FSelection := nil;
    FRange.SetRetainsNodes(True);
    FRange.Release;
    FRange := nil;
  end;
  inherited Destroy;
end;

procedure TDocumentSelection.OrphanRange;
begin
  if FRange = nil then
    Exit;
  FRange.FSelection := nil;
  FRange.Detach;
  FRange.FStartContainer := nil;
  FRange.FEndContainer := nil;
  FRange.FStartOffset := 0;
  FRange.FEndOffset := 0;
  FRange.FRetainsNodes := True;
  FRange.Release;
  FRange := nil;
end;

procedure TDocumentSelection.Changed;
begin
  FDocument.NotifySelectionChanged;
end;

procedure TDocumentSelection.SetRange(Range: TLiveRange; Direction: TSelectionDirection);
var
  Old: TLiveRange;
begin
  if (Range = FRange) and (Direction = FDirection) then
    Exit;
  if (Range <> nil) and (Range <> FRange) then
  begin
    { A range is the selection of one document at most. }
    if Range.FSelection <> nil then
      Range.FSelection.SetRange(nil, SelectionDirectionNone);
    Range.Retain;
    Range.FSelection := Self;
    Range.SetRetainsNodes(False);
  end;
  Old := FRange;
  FRange := Range;
  FDirection := Direction;
  if (Old <> nil) and (Old <> Range) then
  begin
    Old.FSelection := nil;
    Old.SetRetainsNodes(True);
    Old.Release;
  end;
  Changed;
end;

procedure TDocumentSelection.RemoveAllRanges;
begin
  SetRange(nil, SelectionDirectionNone);
end;

procedure TDocumentSelection.CollapseAt(Node: TNode; Offset: Integer);
var
  NewRange: TLiveRange;
begin
  NewRange := TLiveRange.Create(FDocument);
  try
    NewRange.SetRange(Node, Offset, Node, Offset);
    SetRange(NewRange, SelectionDirectionNone);
  finally
    NewRange.Release;
  end;
end;

procedure TDocumentSelection.SetBaseAndExtent(AnchorNode: TNode; AnchorOffset: Integer; FocusNode: TNode;
  FocusOffset: Integer);
var
  NewRange: TLiveRange;
begin
  CheckBoundaryPoint(AnchorNode, AnchorOffset);
  CheckBoundaryPoint(FocusNode, FocusOffset);
  NewRange := TLiveRange.Create(FDocument);
  try
    if (AnchorNode.GetRootNode = FocusNode.GetRootNode) and
      (CompareBoundaryPoints(AnchorNode, AnchorOffset, FocusNode, FocusOffset) > 0) then
    begin
      NewRange.SetRange(FocusNode, FocusOffset, AnchorNode, AnchorOffset);
      SetRange(NewRange, SelectionDirectionBackwards);
    end
    else
    begin
      NewRange.SetRange(AnchorNode, AnchorOffset, AnchorNode, AnchorOffset);
      NewRange.SetEnd(FocusNode, FocusOffset);
      SetRange(NewRange, SelectionDirectionForwards);
    end;
  finally
    NewRange.Release;
  end;
end;

procedure TDocumentSelection.Extend(Node: TNode; Offset: Integer);
var
  OldAnchor: TNode;
  OldAnchorOffset: Integer;
begin
  if FRange = nil then
    RaiseDomError(InvalidStateError, 'the selection has no range');
  OldAnchor := GetAnchorNode;
  OldAnchorOffset := GetAnchorOffset;
  SetBaseAndExtent(OldAnchor, OldAnchorOffset, Node, Offset);
end;

function TDocumentSelection.GetAnchorNode: TNode;
begin
  if FRange = nil then
    Exit(nil);
  if FDirection = SelectionDirectionBackwards then
    Result := FRange.FEndContainer
  else
    Result := FRange.FStartContainer;
end;

function TDocumentSelection.GetAnchorOffset: Integer;
begin
  if FRange = nil then
    Exit(0);
  if FDirection = SelectionDirectionBackwards then
    Result := FRange.FEndOffset
  else
    Result := FRange.FStartOffset;
end;

function TDocumentSelection.GetFocusNode: TNode;
begin
  if FRange = nil then
    Exit(nil);
  if FDirection = SelectionDirectionBackwards then
    Result := FRange.FStartContainer
  else
    Result := FRange.FEndContainer;
end;

function TDocumentSelection.GetFocusOffset: Integer;
begin
  if FRange = nil then
    Exit(0);
  if FDirection = SelectionDirectionBackwards then
    Result := FRange.FStartOffset
  else
    Result := FRange.FEndOffset;
end;
