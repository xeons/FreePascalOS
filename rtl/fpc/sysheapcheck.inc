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
  Heap checking for user programs: a memory manager in front of Free
  Pascal's heap (heap.inc) that makes misuse of heap memory show where
  it happens instead of much later, or never.

  Freed memory that keeps its old contents hides bugs: an object used
  after it was freed goes on working until its memory is reused. With
  HEAP_CHECKS (sysheapchecklevel.inc) every block gets a 16-byte header
  of its own (its state and the size asked for), and:

    * new blocks (GetMem, New, ReAllocMem's new part) hold
      HeapCheckAllocationFill, so reading memory that was never set
      gives junk rather than a lucky zero; AllocMem still zeroes;
    * freed blocks are filled with HeapCheckFreeFill: a pointer or
      method table read from a freed object is $DFDFDFDFDFDFDFDF, not a
      canonical address, so following it faults at once (runtime error
      216 at the place of the bug);
    * at least HeapCheckMinimumGuard bytes of HeapCheckGuardFill follow
      the requested bytes; the guard is checked when the block is freed
      (writes past the end);
    * freeing, resizing or measuring a block that was freed, or a
      pointer that is not a heap block, is reported (double free);
    * with the quarantine (sysheapquarantine.inc) freed blocks wait
      before they go back to the heap; when one leaves, its fill is
      checked (writes after free).

  A failed check ends the program with a report (sysheapcheckreport.inc).
  ReAllocMem moves a block when it no longer fits, so a pointer kept
  into the old block finds the free fill too. MemSize returns the size
  asked for. The kernel heap has the same checks with the same patterns
  (kernel/memory/Memory.HeapChecks.pas).
}

const
  HeapCheckAllocationFill = Byte($A5);
  HeapCheckFreeFill = Byte($DF);
  HeapCheckGuardFill = Byte($FD);

  HeapCheckMagicAllocated = LongWord($B10CA110);
  HeapCheckMagicQuarantined = LongWord($B10CDEAD);
  { Given back to the heap, which reuses the header's memory. }
  HeapCheckMagicReleased = LongWord($B10CF4EE);

  HeapCheckMinimumGuard = 8;
  HeapCheckLargestRequest = High(PtrUInt) div 2;

type
  { 16 bytes, so blocks keep the heap's alignment. }
  THeapCheckHeader = record
    Magic: LongWord;
    { The thread whose heap it is from (HeapCheckOwnerTag). }
    Owner: LongWord;
    RequestedSize: PtrUInt;
  end;
  PHeapCheckHeader = ^THeapCheckHeader;

const
  NoFreedBy: THeapCheckFreedBy = (nil, nil, nil, nil, nil, nil, nil, nil);

function HeapCheckHeaderOf(Block: Pointer): PHeapCheckHeader;
begin
  HeapCheckHeaderOf := PHeapCheckHeader(Block) - 1;
end;

function HeapCheckBlockOf(Header: PHeapCheckHeader): PByte;
begin
  HeapCheckBlockOf := PByte(Header + 1);
end;

{ What the block can hold: the requested bytes and the guard. }
function HeapCheckCapacity(Header: PHeapCheckHeader): PtrUInt;
begin
  HeapCheckCapacity := SysMemSize(Header) - SizeOf(THeapCheckHeader);
end;

{ The index of the first of Count bytes that is not Value; Count if
  they all are. }
function HeapCheckFindChangedByte(Start: PByte; Count: PtrUInt; Value: Byte): PtrUInt;
var
  Pattern: QWord;
  Index: PtrUInt;
begin
  Pattern := QWord(Value) * QWord($0101010101010101);
  Index := 0;
  { Whole QWords first (blocks are aligned); the byte loop then finds
    the byte that differs. }
  if (PtrUInt(Start) and 7) = 0 then
    while (Index + 8 <= Count) and (PQWord(Start + Index)^ = Pattern) do
      Inc(Index, 8);
  while (Index < Count) and (Start[Index] = Value) do
    Inc(Index);
  HeapCheckFindChangedByte := Index;
end;

{ Tells the blocks of one running thread from another's: the address of
  its threadvar block (0 for the main thread before it has one). The
  number of a thread that has ended may come again for a new one, which
  only makes that one's ending release the old blocks early too. }
function HeapCheckOwnerTag: LongWord;
begin
  HeapCheckOwnerTag := LongWord(PtrUInt(ReadRuntimeWord) shr 4);
end;

{ A block from the heap with a header for Size bytes; the bytes are not
  filled. Nil if the heap returns nil. }
function AllocateCheckedBlock(Size: PtrUInt): Pointer;
var
  Header: PHeapCheckHeader;
begin
  if Size > HeapCheckLargestRequest then
    HandleError(203);
  Header := PHeapCheckHeader(SysGetMem(SizeOf(THeapCheckHeader) + Size + HeapCheckMinimumGuard));
  if Header = nil then
    Exit(nil);
  Header^.Magic := HeapCheckMagicAllocated;
  { Which thread's heap the block is from. }
  Header^.Owner := HeapCheckOwnerTag;
  Header^.RequestedSize := Size;
  AllocateCheckedBlock := HeapCheckBlockOf(Header);
end;

procedure FillHeapCheckGuard(Header: PHeapCheckHeader);
begin
  FillChar(HeapCheckBlockOf(Header)[Header^.RequestedSize],
    HeapCheckCapacity(Header) - Header^.RequestedSize, HeapCheckGuardFill);
end;

{ Stops the program unless Block is an allocated block: ProblemIfFreed
  is reported for a freed one, ProblemIfStray for anything else. }
procedure CheckAllocatedBlock(Block: Pointer; ProblemIfFreed, ProblemIfStray: PChar);
var
  Header: PHeapCheckHeader;
  Entry: TQuarantineEntry;
begin
  Header := HeapCheckHeaderOf(Block);
  if Header^.Magic = HeapCheckMagicAllocated then
    Exit;
  if Header^.Magic = HeapCheckMagicQuarantined then
  begin
    FindInQuarantine(Block, Entry);
    ReportBadHeapPointer(ProblemIfFreed, Block, Header^.Magic, Entry.FreedBy);
  end;
  ReportBadHeapPointer(ProblemIfStray, Block, Header^.Magic, NoFreedBy);
end;

{ The guard after the requested bytes, from Start (an offset into the
  block) on, must be intact. }
procedure CheckHeapGuard(Block: Pointer; Start: PtrUInt);
var
  Header: PHeapCheckHeader;
  Capacity: PtrUInt;
  Offset: PtrUInt;
begin
  Header := HeapCheckHeaderOf(Block);
  Capacity := HeapCheckCapacity(Header);
  Offset := Start + HeapCheckFindChangedByte(PByte(Block) + Start, Capacity - Start, HeapCheckGuardFill);
  if Offset < Capacity then
    ReportDamagedHeapBlock('memory was written past the end of a block', Block, Header^.RequestedSize,
      Offset, PByte(Block)[Offset], HeapCheckGuardFill, NoFreedBy);
end;

procedure GiveBackToHeap(Header: PHeapCheckHeader);
begin
  Header^.Magic := HeapCheckMagicReleased;
  SysFreeMem(Header);
end;

{ A block leaving the quarantine: its header and fill must be as they
  were left. }
procedure ReleaseQuarantinedBlock(const Entry: TQuarantineEntry);
var
  Header: PHeapCheckHeader;
  Offset: PtrUInt;
begin
  Header := HeapCheckHeaderOf(Entry.Block);
  if Header^.Magic <> HeapCheckMagicQuarantined then
    ReportBadHeapPointer('the header of a freed block was overwritten while it was in the quarantine',
      Entry.Block, Header^.Magic, Entry.FreedBy);
  Offset := HeapCheckFindChangedByte(Entry.Block, Entry.ByteCount, HeapCheckFreeFill);
  if Offset < Entry.ByteCount then
    ReportDamagedHeapBlock('memory was written after it was freed', Entry.Block, Entry.ByteCount,
      Offset, PByte(Entry.Block)[Offset], HeapCheckFreeFill, Entry.FreedBy);
  GiveBackToHeap(Header);
end;

procedure QuarantineHeapBlock(Block: Pointer; Capacity: PtrUInt);
var
  Entry: TQuarantineEntry;
  Leaving: TQuarantineEntry;
begin
  HeapCheckHeaderOf(Block)^.Magic := HeapCheckMagicQuarantined;
  Entry.Block := Block;
  Entry.ByteCount := Capacity;
  Entry.Owner := HeapCheckHeaderOf(Block)^.Owner;
  Entry.FreedBy := NoFreedBy;
  { Skips this procedure and HeapCheckFreeMem: the code that freed. }
  CaptureBacktrace(2, HeapCheckFreedByDepth, @Entry.FreedBy[0]);
  while TakeOldestToMakeRoom(Capacity, Leaving) do
    ReleaseQuarantinedBlock(Leaving);
  if AddToQuarantine(Entry, Leaving) then
    ReleaseQuarantinedBlock(Leaving);
end;

{ Called by a thread about to end, before the heap gives up its chunks:
  releases the blocks of this thread waiting in the quarantine, so that
  the chunks holding them are free and go back to the kernel. }
procedure ReleaseQuarantineOfEndingThread;
var
  Taken: array[0..31] of TQuarantineEntry;
  Count: SizeInt;
  Index: SizeInt;
  Owner: LongWord;
begin
  if HeapCheckLevel <> HeapChecksQuarantine then
    Exit;
  Owner := HeapCheckOwnerTag;
  repeat
    Count := TakeQuarantinedBlocksOf(Owner, @Taken[0], Length(Taken));
    for Index := 0 to Count - 1 do
      ReleaseQuarantinedBlock(Taken[Index]);
  until Count < Length(Taken);
end;

{ --- The memory manager ------------------------------------------------ }

function HeapCheckGetMem(Size: PtrUInt): Pointer;
begin
  HeapCheckGetMem := AllocateCheckedBlock(Size);
  if HeapCheckGetMem = nil then
    Exit;
  FillChar(HeapCheckGetMem^, Size, HeapCheckAllocationFill);
  FillHeapCheckGuard(HeapCheckHeaderOf(HeapCheckGetMem));
end;

function HeapCheckAllocMem(Size: PtrUInt): Pointer;
begin
  HeapCheckAllocMem := AllocateCheckedBlock(Size);
  if HeapCheckAllocMem = nil then
    Exit;
  FillChar(HeapCheckAllocMem^, Size, 0);
  FillHeapCheckGuard(HeapCheckHeaderOf(HeapCheckAllocMem));
end;

function HeapCheckFreeMem(Block: Pointer): PtrUInt;
var
  Header: PHeapCheckHeader;
  Capacity: PtrUInt;
begin
  if Block = nil then
    Exit(0);
  CheckAllocatedBlock(Block, 'a block was freed twice',
    'freeing a pointer that is not an allocated heap block (freed before, or a stray pointer)');
  Header := HeapCheckHeaderOf(Block);
  CheckHeapGuard(Block, Header^.RequestedSize);
  HeapCheckFreeMem := Header^.RequestedSize;

  Capacity := HeapCheckCapacity(Header);
  FillChar(Block^, Capacity, HeapCheckFreeFill);
  if (HeapCheckLevel = HeapChecksQuarantine) and (Capacity <= QuarantineLargestBlock) then
    QuarantineHeapBlock(Block, Capacity)
  else
    GiveBackToHeap(Header);
end;

function HeapCheckFreeMemSize(Block: Pointer; Size: PtrUInt): PtrUInt;
begin
  HeapCheckFreeMemSize := HeapCheckFreeMem(Block);
end;

function HeapCheckMemSize(Block: Pointer): PtrUInt;
begin
  CheckAllocatedBlock(Block, 'asking the size of a block that was freed',
    'asking the size of a pointer that is not an allocated heap block');
  HeapCheckMemSize := HeapCheckHeaderOf(Block)^.RequestedSize;
end;

{ Resizes within the block's capacity: new bytes get the allocation
  fill, bytes given up become guard. Only the guard bytes taken over
  (and the minimum guard after them) are checked, so that growing a
  block step by step stays cheap; the whole guard is checked when the
  block is freed. }
procedure ResizeInPlace(Block: Pointer; Size: PtrUInt);
var
  Header: PHeapCheckHeader;
  OldSize: PtrUInt;
  Offset: PtrUInt;
begin
  Header := HeapCheckHeaderOf(Block);
  OldSize := Header^.RequestedSize;
  if Size > OldSize then
  begin
    Offset := OldSize + HeapCheckFindChangedByte(PByte(Block) + OldSize,
      Size + HeapCheckMinimumGuard - OldSize, HeapCheckGuardFill);
    if Offset < Size + HeapCheckMinimumGuard then
      ReportDamagedHeapBlock('memory was written past the end of a block', Block, OldSize,
        Offset, PByte(Block)[Offset], HeapCheckGuardFill, NoFreedBy);
    FillChar(PByte(Block)[OldSize], Size - OldSize, HeapCheckAllocationFill);
  end
  else
    FillChar(PByte(Block)[Size], OldSize - Size, HeapCheckGuardFill);
  Header^.RequestedSize := Size;
end;

{ Moves the block to a new one of Size bytes. Room to grow is kept (as
  Free Pascal's heap does), so that growing step by step does not move
  every time. }
function MoveToLargerBlock(Block: Pointer; Size: PtrUInt): Pointer;
var
  OldSize: PtrUInt;
  Room: PtrUInt;
  Header: PHeapCheckHeader;
begin
  OldSize := HeapCheckHeaderOf(Block)^.RequestedSize;
  Room := Size;
  if Room < OldSize + OldSize div 2 then
    Room := OldSize + OldSize div 2;
  MoveToLargerBlock := AllocateCheckedBlock(Room);
  if MoveToLargerBlock = nil then
    Exit;
  Header := HeapCheckHeaderOf(MoveToLargerBlock);
  Header^.RequestedSize := Size;
  Move(Block^, MoveToLargerBlock^, OldSize);
  FillChar(PByte(MoveToLargerBlock)[OldSize], Size - OldSize, HeapCheckAllocationFill);
  FillHeapCheckGuard(Header);
  HeapCheckFreeMem(Block);
end;

function HeapCheckReAllocMem(var Block: Pointer; Size: PtrUInt): Pointer;
var
  Moved: Pointer;
begin
  if Size = 0 then
  begin
    if Block <> nil then
      HeapCheckFreeMem(Block);
    Block := nil;
    Exit(nil);
  end;
  if Block = nil then
  begin
    Block := HeapCheckGetMem(Size);
    Exit(Block);
  end;

  CheckAllocatedBlock(Block, 'resizing a block that was freed',
    'resizing a pointer that is not an allocated heap block');
  if Size + HeapCheckMinimumGuard <= HeapCheckCapacity(HeapCheckHeaderOf(Block)) then
    ResizeInPlace(Block, Size)
  else
  begin
    Moved := MoveToLargerBlock(Block, Size);
    if Moved = nil then
      Exit(nil);
    Block := Moved;
  end;
  HeapCheckReAllocMem := Block;
end;

const
  CheckingMemoryManager: TMemoryManager = (
    NeedLock: False;
    GetMem: @HeapCheckGetMem;
    FreeMem: @HeapCheckFreeMem;
    FreeMemSize: @HeapCheckFreeMemSize;
    AllocMem: @HeapCheckAllocMem;
    ReAllocMem: @HeapCheckReAllocMem;
    MemSize: @HeapCheckMemSize;
    InitThread: nil;
    DoneThread: nil;
    RelocateHeap: nil;
    GetHeapStatus: @SysGetHeapStatus;
    GetFPCHeapStatus: @SysGetFPCHeapStatus;
  );

{ Called by the System unit's initialization right after InitHeap,
  before anything is allocated. }
procedure InitHeapChecks;
begin
  ChooseHeapCheckLevel;
  if HeapCheckLevel <> HeapChecksOff then
    SetMemoryManager(CheckingMemoryManager);
end;
