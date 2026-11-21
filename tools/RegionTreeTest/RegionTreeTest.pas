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
  RegionTreeTest

  The region tree of an address space (Processes.RegionTree) on the
  host, against a plain sorted list doing the same thing the slow way:
  random insertions and removals (regions packed tightly, so gaps of
  every size come and go), lookups of random addresses, overlap checks
  and first-fit searches above random bases, the tree checked after
  every change (order, AVL balance, the subtree figures), then a large
  tree of 200000 regions built in address order (thread stacks, heap
  chunks) whose height must stay logarithmic, emptied again.

  Prints every failed check and exits with 1 if there was one.
}
program RegionTreeTest;

{$mode objfpc}

uses
  SysUtils,
  Processes.UserRegions,
  Processes.RegionTree;

const
  PageBytes = 4096;
  SpacePages = 4096;
  RandomRounds = 60000;
  LargeTreeCount = 200000;

type
  TModelRegion = record
    Start: QWord;
    Length: QWord;
  end;

var
  Failures: Integer = 0;
  Model: array of TModelRegion;
  ModelCount: Integer = 0;
  DisposedCount: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    if Failures < 20 then
      WriteLn('REGION TREE TEST: failed: ', What);
    Inc(Failures);
  end;
end;

procedure DisposeNode(Node: PRegionNode);
begin
  Inc(DisposedCount);
  Dispose(Node);
end;

function NewNode(Start, Length: QWord): PRegionNode;
begin
  New(Result);
  FillChar(Result^, SizeOf(Result^), 0);
  Result^.Region.Start := Start;
  Result^.Region.Length := Length;
  Result^.Region.Kind := RegionKindAllocation;
end;

{ --- The model ------------------------------------------------------------ }

function ModelOverlaps(Start, Length: QWord): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to ModelCount - 1 do
    if (Start < Model[Index].Start + Model[Index].Length) and (Model[Index].Start < Start + Length) then
      Exit(True);
  Result := False;
end;

procedure ModelInsert(Start, Length: QWord);
var
  Index: Integer;
begin
  if ModelCount = System.Length(Model) then
    SetLength(Model, ModelCount * 2 + 16);
  Index := ModelCount;
  while (Index > 0) and (Model[Index - 1].Start > Start) do
  begin
    Model[Index] := Model[Index - 1];
    Dec(Index);
  end;
  Model[Index].Start := Start;
  Model[Index].Length := Length;
  Inc(ModelCount);
end;

procedure ModelRemoveAt(Position: Integer);
var
  Index: Integer;
begin
  for Index := Position to ModelCount - 2 do
    Model[Index] := Model[Index + 1];
  Dec(ModelCount);
end;

function ModelFind(Address: QWord): Integer;
var
  Index: Integer;
begin
  for Index := 0 to ModelCount - 1 do
    if (Address >= Model[Index].Start) and (Address < Model[Index].Start + Model[Index].Length) then
      Exit(Index);
  Result := -1;
end;

function ModelFreeGap(Length, Base, Limit: QWord; out Start: QWord): Boolean;
var
  Candidate: QWord;
  Index: Integer;
begin
  Candidate := Base;
  for Index := 0 to ModelCount - 1 do
  begin
    if Model[Index].Start + Model[Index].Length <= Candidate then
      Continue;
    if Model[Index].Start >= Candidate + Length then
      Break;
    Candidate := Model[Index].Start + Model[Index].Length;
  end;
  Result := Candidate + Length <= Limit;
  if Result then
    Start := Candidate
  else
    Start := 0;
end;

{ --- Checking the tree ------------------------------------------------------ }

type
  TWalkState = record
    Index: Integer;
    InOrder: Boolean;
  end;
  PWalkState = ^TWalkState;

procedure CompareWithModel(Region: PUserRegion; Context: Pointer);
var
  State: PWalkState;
begin
  State := PWalkState(Context);
  if (State^.Index >= ModelCount) or (Model[State^.Index].Start <> Region^.Start) or
     (Model[State^.Index].Length <> Region^.Length) then
    State^.InOrder := False;
  Inc(State^.Index);
end;

{ Checks Node's subtree; returns its height. }
function CheckSubtree(Node: PRegionNode; var Ok: Boolean): LongInt;
var
  LeftHeight: LongInt;
  RightHeight: LongInt;
  ExpectedStart: QWord;
  ExpectedEnd: QWord;
  ExpectedGap: QWord;
begin
  if Node = nil then
    Exit(0);
  LeftHeight := CheckSubtree(Node^.Left, Ok);
  RightHeight := CheckSubtree(Node^.Right, Ok);
  if Abs(LeftHeight - RightHeight) > 1 then
    Ok := False;
  if LeftHeight > RightHeight then
    Result := LeftHeight + 1
  else
    Result := RightHeight + 1;
  if Node^.Height <> Result then
    Ok := False;

  ExpectedStart := Node^.Region.Start;
  ExpectedEnd := Node^.Region.Start + Node^.Region.Length;
  ExpectedGap := 0;
  if Node^.Left <> nil then
  begin
    if Node^.Left^.SubtreeEnd > Node^.Region.Start then
      Ok := False;
    ExpectedStart := Node^.Left^.SubtreeStart;
    ExpectedGap := Node^.Left^.SubtreeLargestGap;
    if Node^.Region.Start - Node^.Left^.SubtreeEnd > ExpectedGap then
      ExpectedGap := Node^.Region.Start - Node^.Left^.SubtreeEnd;
  end;
  if Node^.Right <> nil then
  begin
    if Node^.Right^.SubtreeStart < Node^.Region.Start + Node^.Region.Length then
      Ok := False;
    ExpectedEnd := Node^.Right^.SubtreeEnd;
    if Node^.Right^.SubtreeLargestGap > ExpectedGap then
      ExpectedGap := Node^.Right^.SubtreeLargestGap;
    if Node^.Right^.SubtreeStart - (Node^.Region.Start + Node^.Region.Length) > ExpectedGap then
      ExpectedGap := Node^.Right^.SubtreeStart - (Node^.Region.Start + Node^.Region.Length);
  end;
  if (Node^.SubtreeStart <> ExpectedStart) or (Node^.SubtreeEnd <> ExpectedEnd) or
     (Node^.SubtreeLargestGap <> ExpectedGap) then
    Ok := False;
end;

procedure CheckTree(const Tree: TRegionTree; const When: string);
var
  Ok: Boolean;
  State: TWalkState;
begin
  Ok := True;
  CheckSubtree(Tree.Root, Ok);
  Check(Ok, 'the tree''s balance and figures after ' + When);
  Check(Tree.Count = LongWord(ModelCount), 'the count after ' + When);
  State.Index := 0;
  State.InOrder := True;
  VisitRegions(Tree, @CompareWithModel, @State);
  Check(State.InOrder and (State.Index = ModelCount), 'the regions in order after ' + When);
end;

{ --- Random changes ------------------------------------------------------- }

procedure TryInsert(var Tree: TRegionTree);
var
  Start: QWord;
  Length: QWord;
begin
  Start := QWord(1 + Random(SpacePages)) * PageBytes;
  Length := QWord(1 + Random(8)) * PageBytes;
  Check(RangeOverlapsRegion(Tree, Start, Length) = ModelOverlaps(Start, Length),
    'the overlap check at $' + IntToHex(Start, 1));
  if ModelOverlaps(Start, Length) then
    Exit;
  InsertRegionNode(Tree, NewNode(Start, Length));
  ModelInsert(Start, Length);
end;

procedure TryRemove(var Tree: TRegionTree);
var
  Position: Integer;
  Node: PRegionNode;
begin
  if ModelCount = 0 then
  begin
    Check(RemoveRegionNode(Tree, PageBytes) = nil, 'removing from an empty tree');
    Exit;
  end;
  Position := Random(ModelCount);
  { Not a region's start: nothing is removed. }
  Check(RemoveRegionNode(Tree, Model[Position].Start + 1) = nil, 'removing by an inner address');
  Node := RemoveRegionNode(Tree, Model[Position].Start);
  Check((Node <> nil) and (Node^.Region.Start = Model[Position].Start), 'removing a region');
  if Node <> nil then
    DisposeNode(Node);
  ModelRemoveAt(Position);
end;

procedure CheckLookups(const Tree: TRegionTree);
var
  Round: Integer;
  Address: QWord;
  Found: PUserRegion;
  Expected: Integer;
  Base: QWord;
  Length: QWord;
  Limit: QWord;
  TreeStart: QWord;
  ModelStart: QWord;
  TreeFound: Boolean;
begin
  for Round := 1 to 4 do
  begin
    Address := QWord(Random((SpacePages + 16) * PageBytes));
    Found := FindRegion(Tree, Address);
    Expected := ModelFind(Address);
    if Expected < 0 then
      Check(Found = nil, 'no region at $' + IntToHex(Address, 1))
    else
      Check((Found <> nil) and (Found^.Start = Model[Expected].Start), 'the region at $' + IntToHex(Address, 1));
  end;
  Base := QWord(Random(SpacePages)) * PageBytes + QWord(Random(2)) * 17;
  Length := QWord(1 + Random(12)) * PageBytes;
  Limit := QWord(SpacePages + 16) * PageBytes - QWord(Random(64)) * PageBytes;
  TreeFound := FindFreeGap(Tree, Length, Base, Limit, TreeStart);
  Check(TreeFound = ModelFreeGap(Length, Base, Limit, ModelStart),
    'whether a gap of ' + IntToStr(Length) + ' fits above $' + IntToHex(Base, 1));
  if TreeFound then
    Check(TreeStart = ModelStart, 'the first gap of ' + IntToStr(Length) + ' above $' + IntToHex(Base, 1) +
      ': $' + IntToHex(TreeStart, 1) + ', expected $' + IntToHex(ModelStart, 1));
end;

procedure TestRandomChanges;
var
  Tree: TRegionTree;
  Round: Integer;
  CreatedCount: Integer;
begin
  RandSeed := 1234;
  InitializeRegionTree(Tree);
  CreatedCount := 0;
  DisposedCount := 0;
  for Round := 1 to RandomRounds do
  begin
    { Mostly growing for the first half, mostly shrinking afterwards. }
    if (Round < RandomRounds div 2) = (Random(10) < 7) then
      TryInsert(Tree)
    else
      TryRemove(Tree);
    if Round mod 7 = 0 then
      CheckTree(Tree, 'round ' + IntToStr(Round));
    CheckLookups(Tree);
    if Failures > 0 then
      Break;
  end;
  CreatedCount := ModelCount + DisposedCount;
  ClearRegionTree(Tree, @DisposeNode);
  Check(DisposedCount = CreatedCount, 'clearing the tree disposes of every node');
  Check((Tree.Root = nil) and (Tree.Count = 0), 'the tree is empty after clearing');
  ModelCount := 0;
end;

{ --- A large tree --------------------------------------------------------- }

procedure TestLargeTree;
var
  Tree: TRegionTree;
  Index: Integer;
  Start: QWord;
  Found: QWord;
  Node: PRegionNode;
  RemovedAll: Boolean;
begin
  InitializeRegionTree(Tree);
  { Every region two pages with a page between: in address order, the
    worst case for an unbalanced tree. }
  for Index := 0 to LargeTreeCount - 1 do
    InsertRegionNode(Tree, NewNode(QWord(Index + 1) * 3 * PageBytes, 2 * PageBytes));
  Check(Tree.Count = LargeTreeCount, 'the large tree''s count');
  { An AVL tree is at most 1.44 log2 n high: 26 for 200000. }
  Check(RegionTreeHeight(Tree) <= 26, 'the large tree''s height is ' + IntToStr(RegionTreeHeight(Tree)));
  Check(FindRegion(Tree, QWord(100000) * 3 * PageBytes + 5)^.Start = QWord(100000) * 3 * PageBytes,
    'a lookup in the large tree');
  Check(FindRegion(Tree, QWord(100000) * 3 * PageBytes + 2 * PageBytes) = nil, 'a gap in the large tree');
  Check(FindFreeGap(Tree, PageBytes, 0, High(QWord) div 2, Found) and (Found = 0), 'the gap below every region');
  Check(FindFreeGap(Tree, PageBytes, 3 * PageBytes, High(QWord) div 2, Found) and (Found = 5 * PageBytes),
    'the first one page gap');
  Check(FindFreeGap(Tree, 2 * PageBytes, 3 * PageBytes, High(QWord) div 2, Found) and
    (Found = QWord(LargeTreeCount + 1) * 3 * PageBytes - PageBytes), 'the first two page gap is past the end');

  { Removed from the middle outwards. }
  RemovedAll := True;
  for Index := 0 to LargeTreeCount - 1 do
  begin
    if Index mod 2 = 0 then
      Start := QWord(LargeTreeCount div 2 - Index div 2) * 3 * PageBytes
    else
      Start := QWord(LargeTreeCount div 2 + 1 + Index div 2) * 3 * PageBytes;
    Node := RemoveRegionNode(Tree, Start);
    if Node = nil then
      RemovedAll := False
    else
      Dispose(Node);
    if (Index = LargeTreeCount div 2) and (RegionTreeHeight(Tree) > 26) then
      Check(False, 'the half emptied tree''s height');
  end;
  Check(RemovedAll and (Tree.Root = nil) and (Tree.Count = 0), 'emptying the large tree');
end;

begin
  TestRandomChanges;
  TestLargeTree;
  if Failures > 0 then
  begin
    WriteLn('REGION TREE TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('REGION TREE TEST PASSED');
end.
