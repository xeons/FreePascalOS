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
  The region tree: the regions of an address space, ordered by start
  address in a balanced (AVL) binary tree.

  Regions never overlap, so ordering them by start orders them by end
  too. Every node also knows its subtree's lowest start, highest end and
  largest gap between two neighbouring regions within it. That makes
  each of these take time logarithmic in the number of regions:

    * finding the region holding an address (every page fault),
    * checking that a new region overlaps none (the region starting
      last below its end is the only candidate),
    * finding the lowest free range of a given length above a base
      address (first fit): subtrees whose largest gap is too small are
      skipped as a whole.

  The tree does not allocate: the caller provides the nodes and gets
  them back when they are taken out. Nothing here depends on the rest
  of the kernel, so the host tests build it too (tools/RegionTreeTest).
  The caller serializes access (the address space's lock).
}
unit Processes.RegionTree;

{$mode objfpc}

interface

uses
  Processes.UserRegions;

type
  PRegionNode = ^TRegionNode;
  TRegionNode = record
    { First, so a PUserRegion handed out is also the node's address. }
    Region: TUserRegion;
    Left: PRegionNode;
    Right: PRegionNode;
    Height: LongInt;
    { Over the node and everything below it. }
    SubtreeStart: QWord;
    SubtreeEnd: QWord;
    SubtreeLargestGap: QWord;
  end;

  TRegionTree = record
    Root: PRegionNode;
    Count: LongWord;
  end;

  TRegionNodeDisposer = procedure(Node: PRegionNode);
  TRegionVisitor = procedure(Region: PUserRegion; Context: Pointer);

procedure InitializeRegionTree(out Tree: TRegionTree);
{ Takes every node out, handing each to Dispose. }
procedure ClearRegionTree(var Tree: TRegionTree; Dispose: TRegionNodeDisposer);

{ The region holding Address, or nil. }
function FindRegion(const Tree: TRegionTree; Address: QWord): PUserRegion;
{ The region holding Address or, if none does, the lowest one above it;
  nil if there is neither. }
function FindRegionAtOrAbove(const Tree: TRegionTree; Address: QWord): PUserRegion;
{ True if [Start, Start + Length) overlaps a region (Length > 0, and
  Start + Length does not wrap). }
function RangeOverlapsRegion(const Tree: TRegionTree; Start, Length: QWord): Boolean;
{ Links Node, whose Region is filled in and overlaps no region (the
  caller checked with RangeOverlapsRegion). }
procedure InsertRegionNode(var Tree: TRegionTree; Node: PRegionNode);
{ Unlinks the node of the region starting exactly at Start and returns
  it; nil if there is none. }
function RemoveRegionNode(var Tree: TRegionTree; Start: QWord): PRegionNode;
{ The lowest Start at or above Base with [Start, Start + Length) free
  and ending at or below Limit. }
function FindFreeGap(const Tree: TRegionTree; Length, Base, Limit: QWord; out Start: QWord): Boolean;
{ Calls Visit for every region, in address order. }
procedure VisitRegions(const Tree: TRegionTree; Visit: TRegionVisitor; Context: Pointer);
{ The tree's height (0 when empty), for the tests. }
function RegionTreeHeight(const Tree: TRegionTree): LongInt;

implementation

{ --- Node bookkeeping ------------------------------------------------- }

function NodeHeight(Node: PRegionNode): LongInt;
begin
  if Node = nil then
    Result := 0
  else
    Result := Node^.Height;
end;

function RegionEnd(Node: PRegionNode): QWord;
begin
  Result := Node^.Region.Start + Node^.Region.Length;
end;

{ Recomputes Node's height and subtree figures from its children. }
procedure UpdateNode(Node: PRegionNode);
var
  Largest: QWord;
  Gap: QWord;
begin
  if NodeHeight(Node^.Left) > NodeHeight(Node^.Right) then
    Node^.Height := NodeHeight(Node^.Left) + 1
  else
    Node^.Height := NodeHeight(Node^.Right) + 1;

  Largest := 0;
  if Node^.Left <> nil then
  begin
    Node^.SubtreeStart := Node^.Left^.SubtreeStart;
    Largest := Node^.Left^.SubtreeLargestGap;
    Gap := Node^.Region.Start - Node^.Left^.SubtreeEnd;
    if Gap > Largest then
      Largest := Gap;
  end
  else
    Node^.SubtreeStart := Node^.Region.Start;

  if Node^.Right <> nil then
  begin
    Node^.SubtreeEnd := Node^.Right^.SubtreeEnd;
    if Node^.Right^.SubtreeLargestGap > Largest then
      Largest := Node^.Right^.SubtreeLargestGap;
    Gap := Node^.Right^.SubtreeStart - RegionEnd(Node);
    if Gap > Largest then
      Largest := Gap;
  end
  else
    Node^.SubtreeEnd := RegionEnd(Node);
  Node^.SubtreeLargestGap := Largest;
end;

{ --- Balancing --------------------------------------------------------- }

function RotateRight(Node: PRegionNode): PRegionNode;
var
  Pivot: PRegionNode;
begin
  Pivot := Node^.Left;
  Node^.Left := Pivot^.Right;
  Pivot^.Right := Node;
  UpdateNode(Node);
  UpdateNode(Pivot);
  Result := Pivot;
end;

function RotateLeft(Node: PRegionNode): PRegionNode;
var
  Pivot: PRegionNode;
begin
  Pivot := Node^.Right;
  Node^.Right := Pivot^.Left;
  Pivot^.Left := Node;
  UpdateNode(Node);
  UpdateNode(Pivot);
  Result := Pivot;
end;

{ Updates Node and restores the balance below it (its subtrees are
  balanced and differ in height by at most two); returns the subtree's
  new root. }
function Rebalance(Node: PRegionNode): PRegionNode;
var
  Balance: LongInt;
begin
  UpdateNode(Node);
  Balance := NodeHeight(Node^.Left) - NodeHeight(Node^.Right);
  if Balance > 1 then
  begin
    if NodeHeight(Node^.Left^.Left) < NodeHeight(Node^.Left^.Right) then
      Node^.Left := RotateLeft(Node^.Left);
    Exit(RotateRight(Node));
  end;
  if Balance < -1 then
  begin
    if NodeHeight(Node^.Right^.Right) < NodeHeight(Node^.Right^.Left) then
      Node^.Right := RotateRight(Node^.Right);
    Exit(RotateLeft(Node));
  end;
  Result := Node;
end;

{ --- Creation and clearing -------------------------------------------- }

procedure InitializeRegionTree(out Tree: TRegionTree);
begin
  Tree.Root := nil;
  Tree.Count := 0;
end;

procedure DisposeSubtree(Node: PRegionNode; Dispose: TRegionNodeDisposer);
begin
  if Node = nil then
    Exit;
  DisposeSubtree(Node^.Left, Dispose);
  DisposeSubtree(Node^.Right, Dispose);
  Dispose(Node);
end;

procedure ClearRegionTree(var Tree: TRegionTree; Dispose: TRegionNodeDisposer);
begin
  DisposeSubtree(Tree.Root, Dispose);
  Tree.Root := nil;
  Tree.Count := 0;
end;

{ --- Lookups ------------------------------------------------------------ }

function FindRegion(const Tree: TRegionTree; Address: QWord): PUserRegion;
var
  Node: PRegionNode;
begin
  Node := Tree.Root;
  while Node <> nil do
  begin
    if Address < Node^.Region.Start then
      Node := Node^.Left
    else if Address - Node^.Region.Start < Node^.Region.Length then
      Exit(@Node^.Region)
    else
      Node := Node^.Right;
  end;
  Result := nil;
end;

function FindRegionAtOrAbove(const Tree: TRegionTree; Address: QWord): PUserRegion;
var
  Node: PRegionNode;
begin
  Result := nil;
  Node := Tree.Root;
  while Node <> nil do
  begin
    if Address < Node^.Region.Start then
    begin
      { A candidate; a lower one may be on the left. }
      Result := @Node^.Region;
      Node := Node^.Left;
    end
    else if Address - Node^.Region.Start < Node^.Region.Length then
      Exit(@Node^.Region)
    else
      Node := Node^.Right;
  end;
end;

{ The node of the region starting last below Limit, or nil. }
function FindLastStartingBelow(const Tree: TRegionTree; Limit: QWord): PRegionNode;
var
  Node: PRegionNode;
begin
  Result := nil;
  Node := Tree.Root;
  while Node <> nil do
  begin
    if Node^.Region.Start < Limit then
    begin
      Result := Node;
      Node := Node^.Right;
    end
    else
      Node := Node^.Left;
  end;
end;

function RangeOverlapsRegion(const Tree: TRegionTree; Start, Length: QWord): Boolean;
var
  Candidate: PRegionNode;
begin
  { Of the regions starting below the range's end, the last one ends
    last: the range is free if that one ends at or below its start. }
  Candidate := FindLastStartingBelow(Tree, Start + Length);
  Result := (Candidate <> nil) and (RegionEnd(Candidate) > Start);
end;

{ --- Insertion and removal --------------------------------------------- }

function InsertBelow(Node, NewNode: PRegionNode): PRegionNode;
begin
  if Node = nil then
  begin
    NewNode^.Left := nil;
    NewNode^.Right := nil;
    UpdateNode(NewNode);
    Exit(NewNode);
  end;
  if NewNode^.Region.Start < Node^.Region.Start then
    Node^.Left := InsertBelow(Node^.Left, NewNode)
  else
    Node^.Right := InsertBelow(Node^.Right, NewNode);
  Result := Rebalance(Node);
end;

procedure InsertRegionNode(var Tree: TRegionTree; Node: PRegionNode);
begin
  Tree.Root := InsertBelow(Tree.Root, Node);
  Inc(Tree.Count);
end;

{ Unlinks the lowest node below Node into Minimum; returns the
  subtree's new root. }
function DetachMinimum(Node: PRegionNode; out Minimum: PRegionNode): PRegionNode;
begin
  if Node^.Left = nil then
  begin
    Minimum := Node;
    Exit(Node^.Right);
  end;
  Node^.Left := DetachMinimum(Node^.Left, Minimum);
  Result := Rebalance(Node);
end;

function RemoveBelow(Node: PRegionNode; Start: QWord; var Removed: PRegionNode): PRegionNode;
var
  Successor: PRegionNode;
  RightRest: PRegionNode;
begin
  if Node = nil then
    Exit(nil);
  if Start < Node^.Region.Start then
    Node^.Left := RemoveBelow(Node^.Left, Start, Removed)
  else if Start > Node^.Region.Start then
    Node^.Right := RemoveBelow(Node^.Right, Start, Removed)
  else
  begin
    Removed := Node;
    if Node^.Left = nil then
      Exit(Node^.Right);
    if Node^.Right = nil then
      Exit(Node^.Left);
    { Two children: the next region takes the node's place. }
    RightRest := DetachMinimum(Node^.Right, Successor);
    Successor^.Left := Node^.Left;
    Successor^.Right := RightRest;
    Exit(Rebalance(Successor));
  end;
  Result := Rebalance(Node);
end;

function RemoveRegionNode(var Tree: TRegionTree; Start: QWord): PRegionNode;
begin
  Result := nil;
  Tree.Root := RemoveBelow(Tree.Root, Start, Result);
  if Result <> nil then
  begin
    Dec(Tree.Count);
    Result^.Left := nil;
    Result^.Right := nil;
  end;
end;

{ --- Free ranges --------------------------------------------------------- }

{ Walks Node's subtree in address order looking for the first gap of
  Length bytes at or above Candidate, the lowest address not ruled out
  yet. True if one ends at a region of the subtree (Candidate is then
  its start); otherwise Candidate has moved past the subtree's regions. }
function FindFirstFit(Node: PRegionNode; Length: QWord; var Candidate: QWord): Boolean;
begin
  if (Node = nil) or (Node^.SubtreeEnd <= Candidate) then
    Exit(False);
  if Node^.SubtreeStart >= Candidate + Length then
    Exit(True);
  { The gaps inside, cut at Candidate, are no larger than they are. }
  if Node^.SubtreeLargestGap < Length then
  begin
    Candidate := Node^.SubtreeEnd;
    Exit(False);
  end;
  if FindFirstFit(Node^.Left, Length, Candidate) then
    Exit(True);
  if Node^.Region.Start >= Candidate + Length then
    Exit(True);
  if RegionEnd(Node) > Candidate then
    Candidate := RegionEnd(Node);
  Result := FindFirstFit(Node^.Right, Length, Candidate);
end;

function FindFreeGap(const Tree: TRegionTree; Length, Base, Limit: QWord; out Start: QWord): Boolean;
var
  Candidate: QWord;
begin
  Start := 0;
  if (Length = 0) or (Base >= Limit) or (Length > Limit - Base) then
    Exit(False);
  Candidate := Base;
  FindFirstFit(Tree.Root, Length, Candidate);
  { Candidate is never above the highest region's end, below Limit or
    not, so this does not wrap. }
  Result := (Candidate <= Limit) and (Length <= Limit - Candidate);
  if Result then
    Start := Candidate;
end;

{ --- Walking ------------------------------------------------------------- }

procedure VisitSubtree(Node: PRegionNode; Visit: TRegionVisitor; Context: Pointer);
begin
  if Node = nil then
    Exit;
  VisitSubtree(Node^.Left, Visit, Context);
  Visit(@Node^.Region, Context);
  VisitSubtree(Node^.Right, Visit, Context);
end;

procedure VisitRegions(const Tree: TRegionTree; Visit: TRegionVisitor; Context: Pointer);
begin
  VisitSubtree(Tree.Root, Visit, Context);
end;

function RegionTreeHeight(const Tree: TRegionTree): LongInt;
begin
  Result := NodeHeight(Tree.Root);
end;

end.
