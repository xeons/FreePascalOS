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
  What styling and layout keep for one node, in the node's LayoutData
  slot.

  A record made when the node is first styled (or laid out, for text)
  and freed when the node leaves the document: the computed style and
  those of its ::before, ::after and ::marker, the parsed style
  attribute and presentational hints, the id as a libcss atom, the
  dynamic states (hover, focus ...) the web view sets, the dirty bits of
  incremental restyling and box building, and the node's first box.

  Dirty bits go up the tree as "something below is dirty" bits, so that
  an update walks down only into the subtrees that changed.
}
unit Web.Style.NodeData;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Css.Atoms, Css.Declarations, Css.ElementAdapter, Css.ComputedStyle;

type
  TNodeDataFlag = (
    { The element's own style must be computed again. }
    ndStyleDirty,
    { Some descendant's style must be computed again. }
    ndDescendantStyleDirty,
    { The presentational hints or the style attribute must be parsed again. }
    ndHintsDirty,
    ndStyleAttributeDirty,
    { The boxes of this node's children must be built again. }
    ndBoxesDirty,
    { Some descendant has ndBoxesDirty. }
    ndDescendantBoxesDirty,
    { The id atom is known. }
    ndIdKnown,
    { Only time moved for the element's animations and transitions: its
      style is made again from BaseStyle without cascading. }
    ndAnimationDirty);
  TNodeDataFlags = set of TNodeDataFlag;

  PNodeData = ^TNodeData;
  TNodeData = record
    Style: TCssComputedStyle;
    BeforeStyle: TCssComputedStyle;
    AfterStyle: TCssComputedStyle;
    MarkerStyle: TCssComputedStyle;
    StyleAttribute: TCssDeclarationBlock;
    Hints: TCssDeclarationBlock;
    IdAtom: TCssAtom;
    Flags: TNodeDataFlags;
    States: TCssElementStates;
    { The node's principal box (a TLayoutBox), nil when it has none. }
    Box: TObject;
    { While animations or transitions run (Web.Style.Animations): the
      cascaded style under the animated Style, and their state (owned). }
    BaseStyle: TCssComputedStyle;
    Animations: TObject;
  end;

{ The node's data, made (all dirty) when missing. }
function NodeDataOf(Node: TNode): PNodeData;
{ The node's data or nil. }
function ExistingNodeData(Node: TNode): PNodeData; inline;
{ Frees the node's data (its styles and blocks). }
procedure FreeNodeData(Node: TNode);
{ Frees the data of Root and everything below it. }
procedure FreeSubtreeData(Root: TNode);
{ The element's computed style, nil when it has none. }
function StyleOf(Node: TNode): TCssComputedStyle;

{ The node's parent for styling and boxes: its flat tree parent (a
  shadow root's is its host); nil for nodes outside the flat tree. }
function StyleParentOf(Node: TNode): TNode;

{ Marks Node's style dirty and its ancestors' "descendant dirty". }
procedure MarkStyleDirty(Node: TNode);
{ Marks Node's animated style due (time moved) and its ancestors'
  "descendant dirty". }
procedure MarkAnimationDirty(Node: TNode);
{ Marks every element of Root's subtree for restyling. }
procedure MarkSubtreeStyleDirty(Root: TNode);
{ The presentational hints of Root's subtree must be built again. }
procedure MarkHintsOfSubtreeDirty(Root: TNode);
{ Marks the boxes of Node's children for rebuilding. }
procedure MarkBoxesDirty(Node: TNode);

implementation

function ExistingNodeData(Node: TNode): PNodeData;
begin
  Result := PNodeData(Node.LayoutData);
end;

function NodeDataOf(Node: TNode): PNodeData;
begin
  Result := PNodeData(Node.LayoutData);
  if Result <> nil then
    Exit;
  New(Result);
  FillChar(Result^, SizeOf(TNodeData), 0);
  Result^.Flags := [ndStyleDirty, ndHintsDirty, ndStyleAttributeDirty, ndBoxesDirty];
  Node.LayoutData := Result;
end;

procedure FreeNodeData(Node: TNode);
var
  Data: PNodeData;
begin
  Data := PNodeData(Node.LayoutData);
  if Data = nil then
    Exit;
  Node.LayoutData := nil;
  Data^.Style.Release;
  Data^.BeforeStyle.Release;
  Data^.AfterStyle.Release;
  Data^.MarkerStyle.Release;
  Data^.BaseStyle.Release;
  Data^.Animations.Free;
  Data^.StyleAttribute.Free;
  Data^.Hints.Free;
  Dispose(Data);
end;

procedure FreeSubtreeData(Root: TNode);
var
  Node: TNode;
begin
  Node := Root;
  while Node <> nil do
  begin
    FreeNodeData(Node);
    Node := Node.NextInShadowIncludingTree(Root);
  end;
end;

function StyleOf(Node: TNode): TCssComputedStyle;
var
  Data: PNodeData;
begin
  Data := PNodeData(Node.LayoutData);
  if Data = nil then
    Result := nil
  else
    Result := Data^.Style;
end;

function StyleParentOf(Node: TNode): TNode;
begin
  if Node is TShadowRoot then
    Result := TShadowRoot(Node).Host
  else
    Result := FlatTreeParent(Node);
end;

procedure MarkAncestors(Node: TNode; Flag: TNodeDataFlag);
var
  Ancestor: TNode;
  Data: PNodeData;
begin
  Ancestor := StyleParentOf(Node);
  while Ancestor <> nil do
  begin
    Data := NodeDataOf(Ancestor);
    if Flag in Data^.Flags then
      Break;
    Include(Data^.Flags, Flag);
    Ancestor := StyleParentOf(Ancestor);
  end;
end;

procedure MarkAnimationDirty(Node: TNode);
begin
  Include(NodeDataOf(Node)^.Flags, ndAnimationDirty);
  MarkAncestors(Node, ndDescendantStyleDirty);
end;

procedure MarkStyleDirty(Node: TNode);
begin
  Include(NodeDataOf(Node)^.Flags, ndStyleDirty);
  MarkAncestors(Node, ndDescendantStyleDirty);
end;

procedure MarkSubtreeStyleDirty(Root: TNode);
var
  Node: TNode;
  Data: PNodeData;
begin
  Node := Root;
  while Node <> nil do
  begin
    if Node.IsElement or Node.IsContainer then
    begin
      Data := NodeDataOf(Node);
      Data^.Flags := Data^.Flags + [ndStyleDirty, ndDescendantStyleDirty];
    end;
    Node := Node.NextInShadowIncludingTree(Root);
  end;
  MarkAncestors(Root, ndDescendantStyleDirty);
end;

procedure MarkHintsOfSubtreeDirty(Root: TNode);
var
  Node: TNode;
begin
  Node := Root;
  while Node <> nil do
  begin
    if Node.IsElement then
      Include(NodeDataOf(Node)^.Flags, ndHintsDirty);
    Node := Node.NextInShadowIncludingTree(Root);
  end;
end;

procedure MarkBoxesDirty(Node: TNode);
begin
  Include(NodeDataOf(Node)^.Flags, ndBoxesDirty);
  MarkAncestors(Node, ndDescendantBoxesDirty);
end;

end.
