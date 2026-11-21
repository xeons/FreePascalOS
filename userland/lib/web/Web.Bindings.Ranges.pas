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
  bindings/Ranges.webidl: AbstractRange, StaticRange, Range (DOM
  Standard 5) and Selection (Selection API), over Web.Dom's TLiveRange
  and TDocumentSelection and the algorithms of Web.Dom.RangeContents.

  A Range's wrapper holds a reference to its TLiveRange and is the one
  wrapper of it (TBindingContext.WrapRange), so the selection's range
  read twice is the same object. A Selection's wrapper is the window's
  (SingletonSelection); it keeps the wrapper of the selection's current
  range in a cache slot, so the range keeps its expandos while it is
  selected.
}
unit Web.Bindings.Ranges;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Web.Dom,
  Web.Bindings.Types,
  Web.Bindings.Context;

{$I Web.Bindings.Ranges.Members.inc}

type
  { A StaticRange: boundary points that do not follow the tree. }
  TStaticRangeData = class
  public
    StartContainer: TNode;
    StartOffset: Integer;
    EndContainer: TNode;
    EndOffset: Integer;
    destructor Destroy; override;
  end;

implementation

uses
  Js.Objects,
  Web.Atoms,
  Web.Namespaces,
  Web.Dom.Exceptions,
  Web.Dom.RangeContents,
  Web.Html.Parser;

const
  { The Selection wrapper's slot for its range's wrapper (slot 0 is the
    event handlers'). }
  SelectionRangeSlot = 1;

destructor TStaticRangeData.Destroy;
begin
  if StartContainer <> nil then
    StartContainer.Release;
  if EndContainer <> nil then
    EndContainer.Release;
  inherited Destroy;
end;

function Context(const Call: TBindingCall): TBindingContext; inline;
begin
  Result := TBindingContext(Call.Context);
end;

function ThisRange(const Call: TBindingCall): TLiveRange;
begin
  if not (Call.Target is TLiveRange) then
    raise EBindingTypeError.Create('Illegal invocation');
  Result := TLiveRange(Call.Target);
  if Result.StartContainer = nil then
    RaiseDomError(InvalidStateError, 'the range''s document is gone');
end;

function ThisSelection(const Call: TBindingCall): TDocumentSelection; inline;
begin
  Result := TDocumentSelection(Call.Target);
end;

function NodeArgument(const Call: TBindingCall; Index: Integer): TNode; inline;
begin
  Result := TNode(Call.Native(Index));
end;

function OffsetArgument(const Call: TBindingCall; Index: Integer): Integer;
var
  Value: Int64;
begin
  Value := Call.Int(Index);
  if Value > High(Integer) then
    Value := High(Integer);
  Result := Value;
end;

function WrapRange(const Call: TBindingCall; Range: TLiveRange): TJsValue; inline;
begin
  Result := Context(Call).WrapRange(Range, InterfaceRange);
end;

{ AbstractRange }

function PointsOf(const Call: TBindingCall): TBoundaryPoints;
var
  StaticRange: TStaticRangeData;
begin
  if Call.Target is TStaticRangeData then
  begin
    StaticRange := TStaticRangeData(Call.Target);
    Result.StartNode := StaticRange.StartContainer;
    Result.StartOffset := StaticRange.StartOffset;
    Result.EndNode := StaticRange.EndContainer;
    Result.EndOffset := StaticRange.EndOffset;
  end
  else
    Result := RangePoints(ThisRange(Call));
end;

function AbstractRange_get_startContainer(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(PointsOf(Call).StartNode);
end;

function AbstractRange_get_startOffset(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(PointsOf(Call).StartOffset);
end;

function AbstractRange_get_endContainer(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(PointsOf(Call).EndNode);
end;

function AbstractRange_get_endOffset(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(PointsOf(Call).EndOffset);
end;

function AbstractRange_get_collapsed(var Call: TBindingCall): TJsValue;
var
  Points: TBoundaryPoints;
begin
  Points := PointsOf(Call);
  Result := JsBoolean((Points.StartNode = Points.EndNode) and (Points.StartOffset = Points.EndOffset));
end;

{ StaticRange }

function StaticRange_constructor(var Call: TBindingCall): TJsValue;
var
  Init: PBindingValue;
  Data: TStaticRangeData;
begin
  Init := @Call.Arguments[0];
  Data := TStaticRangeData.Create;
  Data.StartContainer := TNode(Init^.Items[StaticRangeInit_startContainer].Native);
  Data.EndContainer := TNode(Init^.Items[StaticRangeInit_endContainer].Native);
  if (Data.StartContainer.NodeType in [NodeTypeDocumentType, NodeTypeAttribute]) or
    (Data.EndContainer.NodeType in [NodeTypeDocumentType, NodeTypeAttribute]) then
  begin
    Data.StartContainer := nil;
    Data.EndContainer := nil;
    Data.Free;
    RaiseDomError(InvalidNodeTypeError, 'a static range cannot be in a doctype or attribute');
  end;
  Data.StartContainer.Retain;
  Data.EndContainer.Retain;
  Data.StartOffset := Trunc(Init^.Items[StaticRangeInit_startOffset].Number);
  Data.EndOffset := Trunc(Init^.Items[StaticRangeInit_endOffset].Number);
  Result := Context(Call).ConstructedObject(Call, Data);
end;

{ Range }

function Range_constructor(var Call: TBindingCall): TJsValue;
var
  Range: TLiveRange;
begin
  Range := TLiveRange.Create(Context(Call).Document);
  try
    Result := Context(Call).WrapRange(Range, InterfaceRange, Context(Call).PrototypeForConstruct(Call));
  finally
    Range.Release;
  end;
end;

function Range_get_commonAncestorContainer(var Call: TBindingCall): TJsValue;
var
  Range: TLiveRange;
  Node: TNode;
begin
  Range := ThisRange(Call);
  Node := Range.StartContainer;
  while not Node.IsInclusiveAncestorOf(Range.EndContainer) do
    Node := Node.ParentNode;
  Result := Context(Call).WrapNode(Node);
end;

function Range_setStart(var Call: TBindingCall): TJsValue;
begin
  ThisRange(Call).SetStart(NodeArgument(Call, 0), OffsetArgument(Call, 1));
  Result := JsUndefined;
end;

function Range_setEnd(var Call: TBindingCall): TJsValue;
begin
  ThisRange(Call).SetEnd(NodeArgument(Call, 0), OffsetArgument(Call, 1));
  Result := JsUndefined;
end;

function ParentOrError(Node: TNode): TNode;
begin
  Result := Node.ParentNode;
  if Result = nil then
    RaiseDomError(InvalidNodeTypeError, 'the node has no parent');
end;

function Range_setStartBefore(var Call: TBindingCall): TJsValue;
var
  Node: TNode;
begin
  Node := NodeArgument(Call, 0);
  ThisRange(Call).SetStart(ParentOrError(Node), Node.IndexInParent);
  Result := JsUndefined;
end;

function Range_setStartAfter(var Call: TBindingCall): TJsValue;
var
  Node: TNode;
begin
  Node := NodeArgument(Call, 0);
  ThisRange(Call).SetStart(ParentOrError(Node), Node.IndexInParent + 1);
  Result := JsUndefined;
end;

function Range_setEndBefore(var Call: TBindingCall): TJsValue;
var
  Node: TNode;
begin
  Node := NodeArgument(Call, 0);
  ThisRange(Call).SetEnd(ParentOrError(Node), Node.IndexInParent);
  Result := JsUndefined;
end;

function Range_setEndAfter(var Call: TBindingCall): TJsValue;
var
  Node: TNode;
begin
  Node := NodeArgument(Call, 0);
  ThisRange(Call).SetEnd(ParentOrError(Node), Node.IndexInParent + 1);
  Result := JsUndefined;
end;

function Range_collapse(var Call: TBindingCall): TJsValue;
begin
  ThisRange(Call).Collapse(Call.Flag(0));
  Result := JsUndefined;
end;

function Range_selectNode(var Call: TBindingCall): TJsValue;
begin
  ThisRange(Call).SelectNode(NodeArgument(Call, 0));
  Result := JsUndefined;
end;

function Range_selectNodeContents(var Call: TBindingCall): TJsValue;
begin
  ThisRange(Call).SelectNodeContents(NodeArgument(Call, 0));
  Result := JsUndefined;
end;

function Range_compareBoundaryPoints(var Call: TBindingCall): TJsValue;
var
  Range, Source: TLiveRange;
  How: Int64;
  ThisNode, OtherNode: TNode;
  ThisOffset, OtherOffset: Integer;
begin
  Range := ThisRange(Call);
  How := Call.Int(0);
  if not (Call.Native(1) is TLiveRange) then
    raise EBindingTypeError.Create('the source is not a Range');
  Source := TLiveRange(Call.Native(1));
  if not (How in [0..3]) then
    RaiseDomError(NotSupportedError, 'how must be one of the four Range constants');
  if Range.Root <> Source.Root then
    RaiseDomError(WrongDocumentError, 'the ranges are in different trees');
  case How of
    0: { START_TO_START }
      begin
        ThisNode := Range.StartContainer; ThisOffset := Range.StartOffset;
        OtherNode := Source.StartContainer; OtherOffset := Source.StartOffset;
      end;
    1: { START_TO_END }
      begin
        ThisNode := Range.EndContainer; ThisOffset := Range.EndOffset;
        OtherNode := Source.StartContainer; OtherOffset := Source.StartOffset;
      end;
    2: { END_TO_END }
      begin
        ThisNode := Range.EndContainer; ThisOffset := Range.EndOffset;
        OtherNode := Source.EndContainer; OtherOffset := Source.EndOffset;
      end;
  else { END_TO_START }
    begin
      ThisNode := Range.StartContainer; ThisOffset := Range.StartOffset;
      OtherNode := Source.EndContainer; OtherOffset := Source.EndOffset;
    end;
  end;
  Result := JsInteger(CompareBoundaryPoints(ThisNode, ThisOffset, OtherNode, OtherOffset));
end;

function Range_deleteContents(var Call: TBindingCall): TJsValue;
begin
  RangeDeleteContents(ThisRange(Call));
  Result := JsUndefined;
end;

function Range_extractContents(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(RangeExtractContents(ThisRange(Call)));
end;

function Range_cloneContents(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(RangeCloneContents(ThisRange(Call)));
end;

function Range_insertNode(var Call: TBindingCall): TJsValue;
begin
  RangeInsertNode(ThisRange(Call), NodeArgument(Call, 0));
  Result := JsUndefined;
end;

function Range_surroundContents(var Call: TBindingCall): TJsValue;
begin
  RangeSurroundContents(ThisRange(Call), NodeArgument(Call, 0));
  Result := JsUndefined;
end;

function Range_cloneRange(var Call: TBindingCall): TJsValue;
var
  Source, Copy: TLiveRange;
begin
  Source := ThisRange(Call);
  Copy := TLiveRange.Create(Source.StartContainer.NodeDocument);
  try
    Copy.SetRange(Source.StartContainer, Source.StartOffset, Source.EndContainer, Source.EndOffset);
    Result := WrapRange(Call, Copy);
  finally
    Copy.Release;
  end;
end;

function Range_detach(var Call: TBindingCall): TJsValue;
begin
  Result := JsUndefined;
end;

function Range_isPointInRange(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(RangeIsPointInRange(ThisRange(Call), NodeArgument(Call, 0), OffsetArgument(Call, 1)));
end;

function Range_comparePoint(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(RangeComparePoint(ThisRange(Call), NodeArgument(Call, 0), OffsetArgument(Call, 1)));
end;

function Range_intersectsNode(var Call: TBindingCall): TJsValue;
begin
  Result := JsBoolean(RangeIntersectsNode(ThisRange(Call), NodeArgument(Call, 0)));
end;

{ HTML's createContextualFragment: the markup parsed as a fragment in the
  context of the start's element (body for none or html). }
function Range_createContextualFragment(var Call: TBindingCall): TJsValue;
var
  Range: TLiveRange;
  Node: TNode;
  ContextElement: TElement;
  OwnsContext: Boolean;
begin
  Range := ThisRange(Call);
  Node := Range.StartContainer;
  if Node.IsElement then
    ContextElement := TElement(Node)
  else
    ContextElement := Node.ParentElement;
  OwnsContext := False;
  if (ContextElement = nil) or (Node.NodeDocument.IsHtmlDocument and
    ContextElement.IsHtmlElement(AtomHtml)) then
  begin
    ContextElement := Node.NodeDocument.NewElement(AtomBody, NamespaceHtml);
    OwnsContext := True;
  end;
  try
    Result := Context(Call).WrapNode(ParseHtmlFragment(ContextElement, Call.Text(0)));
  finally
    if OwnsContext then
      ContextElement.Free;
  end;
end;

function Range_stringifier(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).TextValue(RangeText(RangePoints(ThisRange(Call))));
end;

{ Selection }

function DocumentSelectionValue(Context: TBindingContext): TJsValue;
var
  Document: TDocument;
begin
  Result := Context.Singleton(SingletonSelection);
  if JsIsObject(Result) then
    Exit;
  Document := Context.Document;
  Result := Context.WrapObject(Document.Selection, InterfaceSelection, False, Context.WrapNode(Document));
  Context.SetSingleton(SingletonSelection, Result);
end;

function Window_getSelection(var Call: TBindingCall): TJsValue;
begin
  Result := DocumentSelectionValue(Context(Call));
end;

function Document_getSelection(var Call: TBindingCall): TJsValue;
begin
  if TNode(Call.Target) <> Context(Call).Document then
    Exit(JsNull);
  Result := DocumentSelectionValue(Context(Call));
end;

function Document_createRange(var Call: TBindingCall): TJsValue;
var
  Range: TLiveRange;
begin
  Range := TLiveRange.Create(TDocument(Call.Target));
  try
    Result := WrapRange(Call, Range);
  finally
    Range.Release;
  end;
end;

{ The selection's range as script sees it (one wrapper while selected). }
function SelectionRangeValue(const Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
begin
  Selection := ThisSelection(Call);
  if Selection.Range = nil then
    Exit(JsNull);
  Result := WrapRange(Call, Selection.Range);
  TBindingWrapper(Call.Wrapper).SetCachedValue(SelectionRangeSlot, Result);
end;

function Selection_get_anchorNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisSelection(Call).AnchorNode);
end;

function Selection_get_anchorOffset(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisSelection(Call).AnchorOffset);
end;

function Selection_get_focusNode(var Call: TBindingCall): TJsValue;
begin
  Result := Context(Call).WrapNode(ThisSelection(Call).FocusNode);
end;

function Selection_get_focusOffset(var Call: TBindingCall): TJsValue;
begin
  Result := JsInteger(ThisSelection(Call).FocusOffset);
end;

function Selection_get_isCollapsed(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
begin
  Selection := ThisSelection(Call);
  Result := JsBoolean((Selection.Range = nil) or Selection.Range.Collapsed);
end;

function Selection_get_rangeCount(var Call: TBindingCall): TJsValue;
begin
  if ThisSelection(Call).Range = nil then
    Result := JsInteger(0)
  else
    Result := JsInteger(1);
end;

function Selection_get_type(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
begin
  Selection := ThisSelection(Call);
  if Selection.Range = nil then
    Result := Context(Call).TextValue('None')
  else if Selection.Range.Collapsed then
    Result := Context(Call).TextValue('Caret')
  else
    Result := Context(Call).TextValue('Range');
end;

function Selection_get_direction(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
begin
  Selection := ThisSelection(Call);
  if (Selection.Range = nil) or Selection.Range.Collapsed then
    Result := Context(Call).TextValue('none')
  else
    case Selection.Direction of
      SelectionDirectionForwards: Result := Context(Call).TextValue('forward');
      SelectionDirectionBackwards: Result := Context(Call).TextValue('backward');
    else
      Result := Context(Call).TextValue('none');
    end;
end;

function Selection_getRangeAt(var Call: TBindingCall): TJsValue;
begin
  if (Call.Int(0) <> 0) or (ThisSelection(Call).Range = nil) then
    RaiseDomError(IndexSizeError, 'there is no range at that index');
  Result := SelectionRangeValue(Call);
end;

{ The node is in the selection's document (its tree). }
function InSelectionDocument(Selection: TDocumentSelection; Node: TNode): Boolean;
begin
  Result := Node.GetRootNode = Selection.Document;
end;

function Selection_addRange(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
  Range: TLiveRange;
begin
  Result := JsUndefined;
  Selection := ThisSelection(Call);
  if not (Call.Native(0) is TLiveRange) then
    raise EBindingTypeError.Create('the argument is not a Range');
  Range := TLiveRange(Call.Native(0));
  if (Range.Root <> Selection.Document) or (Selection.Range <> nil) then
    Exit;
  Selection.SetRange(Range, SelectionDirectionForwards);
end;

function Selection_removeRange(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
begin
  Selection := ThisSelection(Call);
  if (Selection.Range = nil) or (Call.Native(0) <> Selection.Range) then
    RaiseDomError(NotFoundError, 'the range is not in the selection');
  Selection.RemoveAllRanges;
  Result := JsUndefined;
end;

function Selection_removeAllRanges(var Call: TBindingCall): TJsValue;
begin
  ThisSelection(Call).RemoveAllRanges;
  Result := JsUndefined;
end;

function Selection_empty(var Call: TBindingCall): TJsValue;
begin
  ThisSelection(Call).RemoveAllRanges;
  Result := JsUndefined;
end;

function CollapseSelection(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
  Node: TNode;
  Offset: Integer;
begin
  Result := JsUndefined;
  Selection := ThisSelection(Call);
  Node := NodeArgument(Call, 0);
  if Node = nil then
  begin
    Selection.RemoveAllRanges;
    Exit;
  end;
  Offset := OffsetArgument(Call, 1);
  if Node.NodeType = NodeTypeDocumentType then
    RaiseDomError(InvalidNodeTypeError, 'a selection cannot be in a doctype');
  if Offset > NodeLength(Node) then
    RaiseDomError(IndexSizeError, 'the offset is larger than the node''s length');
  if not InSelectionDocument(Selection, Node) then
    Exit;
  Selection.CollapseAt(Node, Offset);
end;

function Selection_collapse(var Call: TBindingCall): TJsValue;
begin
  Result := CollapseSelection(Call);
end;

function Selection_setPosition(var Call: TBindingCall): TJsValue;
begin
  Result := CollapseSelection(Call);
end;

function Selection_collapseToStart(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
begin
  Selection := ThisSelection(Call);
  if Selection.Range = nil then
    RaiseDomError(InvalidStateError, 'the selection is empty');
  Selection.CollapseAt(Selection.Range.StartContainer, Selection.Range.StartOffset);
  Result := JsUndefined;
end;

function Selection_collapseToEnd(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
begin
  Selection := ThisSelection(Call);
  if Selection.Range = nil then
    RaiseDomError(InvalidStateError, 'the selection is empty');
  Selection.CollapseAt(Selection.Range.EndContainer, Selection.Range.EndOffset);
  Result := JsUndefined;
end;

function Selection_extend(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
  Node: TNode;
begin
  Result := JsUndefined;
  Selection := ThisSelection(Call);
  Node := NodeArgument(Call, 0);
  if not InSelectionDocument(Selection, Node) then
    Exit;
  Selection.Extend(Node, OffsetArgument(Call, 1));
end;

function Selection_setBaseAndExtent(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
  AnchorNode, FocusNode: TNode;
begin
  Result := JsUndefined;
  Selection := ThisSelection(Call);
  AnchorNode := NodeArgument(Call, 0);
  FocusNode := NodeArgument(Call, 2);
  if (OffsetArgument(Call, 1) > NodeLength(AnchorNode)) or (OffsetArgument(Call, 3) > NodeLength(FocusNode)) then
    RaiseDomError(IndexSizeError, 'the offset is larger than the node''s length');
  if not InSelectionDocument(Selection, AnchorNode) or not InSelectionDocument(Selection, FocusNode) then
    Exit;
  Selection.SetBaseAndExtent(AnchorNode, OffsetArgument(Call, 1), FocusNode, OffsetArgument(Call, 3));
end;

function Selection_selectAllChildren(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
  Node: TNode;
begin
  Result := JsUndefined;
  Selection := ThisSelection(Call);
  Node := NodeArgument(Call, 0);
  if Node.NodeType = NodeTypeDocumentType then
    RaiseDomError(InvalidNodeTypeError, 'a selection cannot be in a doctype');
  if not InSelectionDocument(Selection, Node) then
    Exit;
  Selection.SetBaseAndExtent(Node, 0, Node, NodeLength(Node));
end;

function Selection_modify(var Call: TBindingCall): TJsValue;
begin
  { Moving by characters, words or lines needs the layout: not done. }
  Result := JsUndefined;
end;

function Selection_deleteFromDocument(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
begin
  Selection := ThisSelection(Call);
  if Selection.Range <> nil then
    RangeDeleteContents(Selection.Range);
  Result := JsUndefined;
end;

function Selection_containsNode(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
  Node: TNode;
  Range: TLiveRange;
  Points: TBoundaryPoints;
begin
  Selection := ThisSelection(Call);
  Node := NodeArgument(Call, 0);
  Range := Selection.Range;
  if (Range = nil) or (Node.GetRootNode <> Selection.Document) then
    Exit(JsFalse);
  Points := RangePoints(Range);
  if Call.Flag(1) then
    Result := JsBoolean(RangeIntersectsNode(Range, Node))
  else
    Result := JsBoolean(NodeContained(Node, Points) or
      ((Node.ParentNode = nil) and (Node = Range.StartContainer) and (Node = Range.EndContainer)));
end;

function Selection_stringifier(var Call: TBindingCall): TJsValue;
var
  Selection: TDocumentSelection;
begin
  Selection := ThisSelection(Call);
  if Selection.Range = nil then
    Exit(Context(Call).TextValue(''));
  Result := Context(Call).TextValue(RangeText(RangePoints(Selection.Range)));
end;

end.
