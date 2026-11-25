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
  Splitting and joining regions of a region tree.

  A region has one set of attributes for all its pages. Committing,
  decommitting or protecting part of an allocation (Processes.VirtualMemory)
  therefore splits it where the change begins and ends, and joins the
  pieces with their neighbours again once they are alike, so an
  allocation committed page by page does not end up as thousands of
  regions. The pieces of one allocation share its AllocationBase, which
  is what keeps two allocations that happen to be adjacent apart.

  Like the tree itself this allocates nothing (the caller provides the
  node a split needs and disposes of the one a join gives up) and depends
  on nothing else in the kernel, so the host tests build it too
  (tools/RegionTreeTest). A region with a Backing holds a reference to
  it: the caller takes another for the piece a split makes and gives one
  back with the node a join returns. The caller serializes access.
}
unit Processes.RegionEditing;

{$mode objfpc}

interface

uses
  Processes.UserRegions,
  Processes.RegionTree;

{ If Address lies inside a region (after its first byte), cuts it there:
  the region keeps [Start, Address) and NewNode, a free node, becomes
  [Address, End) with the same attributes (its BackingOffset moved
  along). Returns True if NewNode was used; False if no region holds
  Address or one starts there already. Address must be page aligned. }
function SplitRegionAt(var Tree: TRegionTree; Address: QWord; NewNode: PRegionNode): Boolean;

{ True if Right begins where Left ends and the two could be one region:
  pieces of the same allocation, alike in everything else. }
function RegionsCanMerge(const Left, Right: TUserRegion): Boolean;

{ Joins the region starting at Start with the region right after it if
  they can be one. Returns the node given up (no longer in the tree), or
  nil if nothing was joined. }
function MergeWithNext(var Tree: TRegionTree; Start: QWord): PRegionNode;

{ Joins every region overlapping [First, Finish) and the regions just
  before and after the range with their neighbours wherever they can be
  one, handing each node given up to Dispose. }
procedure MergeRange(var Tree: TRegionTree; First, Finish: QWord; Dispose: TRegionNodeDisposer);

implementation

function RegionEnd(const Region: TUserRegion): QWord;
begin
  Result := Region.Start + Region.Length;
end;

function SplitRegionAt(var Tree: TRegionTree; Address: QWord; NewNode: PRegionNode): Boolean;
var
  Region: PUserRegion;
  Node: PRegionNode;
  OldStart: QWord;
  OldEnd: QWord;
begin
  Result := False;
  Region := FindRegion(Tree, Address);
  if (Region = nil) or (Region^.Start = Address) then
    Exit;
  OldStart := Region^.Start;
  OldEnd := RegionEnd(Region^);

  { The tree keeps figures about every region's end: the shortened one
    goes out and comes back in. }
  Node := RemoveRegionNode(Tree, OldStart);
  NewNode^.Region := Node^.Region;
  Node^.Region.Length := Address - OldStart;
  InsertRegionNode(Tree, Node);

  NewNode^.Region.Start := Address;
  NewNode^.Region.Length := OldEnd - Address;
  if NewNode^.Region.Backing <> nil then
    NewNode^.Region.BackingOffset := NewNode^.Region.BackingOffset + (Address - OldStart);
  { A stack's reserve stays at its bottom. }
  NewNode^.Region.ReserveBytes := 0;
  NewNode^.Region.ReserveInUse := False;
  NewNode^.Left := nil;
  NewNode^.Right := nil;
  InsertRegionNode(Tree, NewNode);
  Result := True;
end;

function RegionsCanMerge(const Left, Right: TUserRegion): Boolean;
begin
  Result := (RegionEnd(Left) = Right.Start) and (Left.AllocationBase <> 0) and
    (Left.AllocationBase = Right.AllocationBase) and (Left.Kind = Right.Kind) and
    (Left.Attributes = Right.Attributes) and (Left.CommitsOnDemand = Right.CommitsOnDemand) and
    (Left.IsGuard = Right.IsGuard) and (Left.OwnerThreadId = Right.OwnerThreadId) and
    (Left.Backing = Right.Backing) and (Left.BackingIsPrivate = Right.BackingIsPrivate) and
    (Left.BackingIsWritable = Right.BackingIsWritable) and
    ((Left.Backing = nil) or (Right.BackingOffset = Left.BackingOffset + Left.Length)) and
    (Left.ReserveBytes = 0) and (Right.ReserveBytes = 0);
end;

function MergeWithNext(var Tree: TRegionTree; Start: QWord): PRegionNode;
var
  Left: PUserRegion;
  Right: PUserRegion;
  LeftNode: PRegionNode;
  RightLength: QWord;
begin
  Result := nil;
  Left := FindRegion(Tree, Start);
  if (Left = nil) or (Left^.Start <> Start) then
    Exit;
  Right := FindRegion(Tree, RegionEnd(Left^));
  if (Right = nil) or not RegionsCanMerge(Left^, Right^) then
    Exit;
  RightLength := Right^.Length;
  Result := RemoveRegionNode(Tree, Right^.Start);
  LeftNode := RemoveRegionNode(Tree, Start);
  LeftNode^.Region.Length := LeftNode^.Region.Length + RightLength;
  InsertRegionNode(Tree, LeftNode);
end;

procedure MergeRange(var Tree: TRegionTree; First, Finish: QWord; Dispose: TRegionNodeDisposer);
var
  Region: PUserRegion;
  Removed: PRegionNode;
  Position: QWord;
begin
  Region := nil;
  if First > 0 then
    Region := FindRegion(Tree, First - 1);
  if Region = nil then
    Region := FindRegionAtOrAbove(Tree, First);
  while Region <> nil do
  begin
    { Swallow alike neighbours one after another. }
    repeat
      Removed := MergeWithNext(Tree, Region^.Start);
      if Removed <> nil then
        Dispose(Removed);
    until Removed = nil;
    Position := Region^.Start + Region^.Length;
    if Position > Finish then
      Break;
    Region := FindRegionAtOrAbove(Tree, Position);
  end;
end;

end.
