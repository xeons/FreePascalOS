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
  Memory for the syntax tree's nodes: slots of one size handed out in
  order from blocks (a bump allocator). Making a node is an increment
  instead of a trip through the heap, and the most recent slots can be
  given back together (Truncate), to be handed out again: a lazily
  compiled function's body is parsed into slots that the next function
  reuses once it is checked.

  Blocks start small and double up to a thousand slots: a function
  compiled lazily makes a few dozen nodes, a bundle's top level a
  million. A slot is handed out zeroed: blocks come zeroed, and slots
  taken back are zeroed together (one fill per block instead of one per
  node). The pool only keeps the memory; what is in a slot (an object
  with strings) is made by the owner, and finalized by the procedure
  Truncate is given.
}
unit Js.NodePool;

{$mode objfpc}{$H+}

interface

type
  { Finalizes what a slot holds before it is taken back. }
  TJsSlotRelease = procedure(Slot: Pointer);

  TJsSlotBlock = record
    Memory: PByte;
    Capacity: Integer;
    { The index of the block's first slot. }
    First: Integer;
  end;

  TJsSlotPool = class
  private
    FSlotSize: Integer;
    FBlocks: array of TJsSlotBlock;
    { The block slots are handed out from, and how many of its slots
      are. }
    FCurrent: Integer;
    FUsed: Integer;
    FCount: Integer;
    procedure NextBlock;
  public
    constructor Create(SlotSize: Integer);
    destructor Destroy; override;
    { The next slot, zeroed. }
    function Allocate: Pointer;
    { Takes back the slots from Count on, latest first, each given to
      Release, then zeroed: they are handed out again. }
    procedure Truncate(Count: Integer; Release: TJsSlotRelease);
    { Gives every slot to Release, before the pool goes. }
    procedure ReleaseAll(Release: TJsSlotRelease);
    { Slots handed out. }
    property Count: Integer read FCount;
  end;

implementation

const
  FirstBlockSlots = 64;
  LargestBlockSlots = 1024;

constructor TJsSlotPool.Create(SlotSize: Integer);
begin
  inherited Create;
  { Doubles and pointers in the slots stay aligned. }
  FSlotSize := (SlotSize + 7) and not 7;
  FCurrent := -1;
end;

destructor TJsSlotPool.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FBlocks) do
    FreeMem(FBlocks[Index].Memory);
  inherited Destroy;
end;

{ On to the next block, made the first time. Blocks fill in order, so a
  block's first index never changes. }
procedure TJsSlotPool.NextBlock;
var
  Capacity: Integer;
begin
  Inc(FCurrent);
  FUsed := 0;
  if FCurrent < Length(FBlocks) then
    Exit;
  if FCurrent = 0 then
    Capacity := FirstBlockSlots
  else
  begin
    Capacity := FBlocks[FCurrent - 1].Capacity * 2;
    if Capacity > LargestBlockSlots then
      Capacity := LargestBlockSlots;
  end;
  SetLength(FBlocks, FCurrent + 1);
  FBlocks[FCurrent].Memory := AllocMem(Capacity * FSlotSize);
  FBlocks[FCurrent].Capacity := Capacity;
  FBlocks[FCurrent].First := FCount;
end;

function TJsSlotPool.Allocate: Pointer;
begin
  if (FCurrent < 0) or (FUsed = FBlocks[FCurrent].Capacity) then
    NextBlock;
  Result := FBlocks[FCurrent].Memory + FUsed * FSlotSize;
  Inc(FUsed);
  Inc(FCount);
end;

procedure TJsSlotPool.ReleaseAll(Release: TJsSlotRelease);
var
  Block, Used: Integer;
  Slot, Finish: PByte;
begin
  for Block := 0 to FCurrent do
  begin
    if Block = FCurrent then
      Used := FUsed
    else
      Used := FBlocks[Block].Capacity;
    Slot := FBlocks[Block].Memory;
    Finish := Slot + Used * FSlotSize;
    while Slot < Finish do
    begin
      Release(Slot);
      Inc(Slot, FSlotSize);
    end;
  end;
end;

procedure TJsSlotPool.Truncate(Count: Integer; Release: TJsSlotRelease);
var
  Slot, Kept, Finish: PByte;
  Keep: Integer;
begin
  if Count < 0 then
    Count := 0;
  { Block by block, from the current one back. }
  while FCount > Count do
  begin
    Keep := Count - FBlocks[FCurrent].First;
    if Keep < 0 then
      Keep := 0;
    Kept := FBlocks[FCurrent].Memory + Keep * FSlotSize;
    Finish := FBlocks[FCurrent].Memory + FUsed * FSlotSize;
    Slot := Kept;
    while Slot < Finish do
    begin
      Release(Slot);
      Inc(Slot, FSlotSize);
    end;
    FillChar(Kept^, Finish - Kept, 0);
    Dec(FCount, FUsed - Keep);
    FUsed := Keep;
    if (FUsed = 0) and (FCurrent > 0) then
    begin
      Dec(FCurrent);
      FUsed := FBlocks[FCurrent].Capacity;
    end;
  end;
end;

end.
