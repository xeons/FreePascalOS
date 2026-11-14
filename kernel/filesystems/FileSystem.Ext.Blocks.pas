{
  Mapping of file blocks for ext2/3/4: from a block number within a file
  (logical) to a block number on the volume (physical), for reading and
  for writing.

  Two schemes exist:

    Block pointers (ext2, ext3)  Blocks 0-11 are listed in the inode; slot
      12 points at a table of block numbers, slot 13 at a table of tables
      and slot 14 at a table of tables of tables.

    Extents (ext4)  The inode holds the root of a tree of extents, each
      describing a run of consecutive blocks. Leaves hold extents; index
      nodes point at lower levels.

  For writing extent files the whole extent list is loaded, changed and
  written back as a tree. That keeps a single code path for appending,
  filling holes and truncating; it supports trees of depth 0 (up to four
  extents in the inode) and depth 1 (up to four leaf blocks), which covers
  thousands of extents.

  A physical block number of zero means "not allocated" (a hole), which
  reads back as zeros. Every block a file owns, including indirect tables
  and extent tree blocks, is counted in the inode's block count (in
  512-byte units).
}
unit FileSystem.Ext.Blocks;

{$mode objfpc}
{$pointermath on}

interface

uses
  FileSystem.Types,
  FileSystem.Ext.Structures,
  FileSystem.Ext.Volume;

function NodeUsesExtents(Node: PExtNode): Boolean;

function MapLogicalBlock(Node: PExtNode; LogicalBlock: LongWord; out PhysicalBlock: QWord): TFileSystemStatus;

{ Makes sure blocks FirstLogical .. FirstLogical + Count - 1 are allocated
  (newly allocated blocks are zero filled). }
function AllocateBlockRange(Node: PExtNode; FirstLogical: LongWord; Count: LongWord): TFileSystemStatus;

{ Releases every block at or after KeepBlocks (a block count). }
function ReleaseBlocksFrom(Node: PExtNode; KeepBlocks: LongWord): TFileSystemStatus;

{ Initializes the inode's block area as an empty extent tree. }
procedure InitializeEmptyExtentTree(Node: PExtNode);

{ Reads data of the node, treating holes as zeros. }
function ReadNodeData(Node: PExtNode; Offset: QWord; ByteCount: QWord; Buffer: PByte): TFileSystemStatus;
{ Writes data into already allocated blocks (Source = nil writes zeros). }
function WriteNodeData(Node: PExtNode; Offset: QWord; ByteCount: QWord; Source: PByte): TFileSystemStatus;

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap;

type
  TExtentRecord = record
    LogicalBlock: LongWord;
    { The raw on-disk length: above ExtentMaximumLength marks an extent
      that is allocated but not yet written (it reads as zeros). }
    RawLength: Word;
    PhysicalBlock: QWord;
  end;
  PExtentRecord = ^TExtentRecord;

  { All extents of a file plus the tree blocks that held them. }
  TExtentList = record
    Extents: PExtentRecord;
    Count: LongWord;
    Capacity: LongWord;
    TreeBlocks: array[0..ExtentRootCapacity - 1] of QWord;
    TreeBlockCount: Integer;
  end;

function NodeUsesExtents(Node: PExtNode): Boolean;
begin
  Result := (InodeRecord(Node)^.Flags and InodeFlagExtents) <> 0;
end;

function SectorsPerBlock(Ext: PExtVolume): LongWord;
begin
  Result := LongWord(Ext^.BlockSize div 512);
end;

procedure AdjustBlockCount(Node: PExtNode; BlockDelta: LongInt);
var
  Inode: PInode;
  Sectors: QWord;
begin
  Inode := InodeRecord(Node);
  Sectors := Inode^.BlocksLow or (QWord(Inode^.BlocksHigh) shl 32);
  Sectors := QWord(Int64(Sectors) + Int64(BlockDelta) * SectorsPerBlock(ExtVolumeOf(@Node^.Common)));
  Inode^.BlocksLow := LongWord(Sectors);
  Inode^.BlocksHigh := Word(Sectors shr 32);
end;

function ExtentLength(RawLength: Word): LongWord;
begin
  if RawLength > ExtentMaximumLength then
    Result := RawLength - ExtentMaximumLength
  else
    Result := RawLength;
end;

{ --- Reading: extent trees ------------------------------------------- }

function ReadExtentHeader(Volume: PVolume; Address: QWord; out Header: TExtentHeader): Boolean;
begin
  Result := VolumeRead(Volume, Address, SizeOf(Header), @Header) and (Header.Magic = ExtentMagic);
end;

function MapThroughExtents(Node: PExtNode; LogicalBlock: LongWord; out PhysicalBlock: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Volume: PVolume;
  Header: TExtentHeader;
  Entry: TExtentEntry;
  NextEntry: TExtentEntry;
  RootEntries: PExtentEntry;
  FromInode: Boolean;
  NodeAddress: QWord;
  EntryIndex: Integer;
  ChosenIndex: Integer;
  Level: Integer;
  Length: LongWord;
  StartBlock: QWord;

  function GetEntry(Index: Integer; out Value: TExtentEntry): Boolean;
  begin
    if FromInode then
    begin
      Value := RootEntries[Index];
      Result := True;
    end
    else
      Result := VolumeRead(Volume, NodeAddress + ExtentHeaderSize + QWord(Index) * ExtentEntrySize,
        ExtentEntrySize, @Value);
  end;

begin
  PhysicalBlock := 0;
  Ext := ExtVolumeOf(@Node^.Common);
  Volume := Node^.Common.Volume;
  Header := PExtentHeader(@InodeRecord(Node)^.Block[0])^;
  if Header.Magic <> ExtentMagic then
    Exit(StatusCorrupted);
  RootEntries := PExtentEntry(PByte(@InodeRecord(Node)^.Block[0]) + ExtentHeaderSize);
  FromInode := True;
  NodeAddress := 0;

  for Level := 0 to MaximumExtentDepth do
  begin
    if Header.Depth = 0 then
    begin
      for EntryIndex := 0 to Integer(Header.Entries) - 1 do
      begin
        if not GetEntry(EntryIndex, Entry) then
          Exit(StatusIoError);
        Length := ExtentLength(Entry.Length);
        if (LogicalBlock >= Entry.LogicalBlock) and (LogicalBlock < Entry.LogicalBlock + Length) then
        begin
          { An unwritten extent reads as zeros, like a hole. }
          if Entry.Length > ExtentMaximumLength then
            Exit(StatusSuccess);
          StartBlock := Entry.StartLow or (QWord(Entry.StartHigh) shl 32);
          PhysicalBlock := StartBlock + (LogicalBlock - Entry.LogicalBlock);
          if PhysicalBlock >= Ext^.BlockCount then
            Exit(StatusCorrupted);
          Exit(StatusSuccess);
        end;
      end;
      Exit(StatusSuccess); { a hole }
    end;

    { Index node: descend into the last child starting at or before the
      wanted block. }
    if Header.Entries = 0 then
      Exit(StatusSuccess);
    ChosenIndex := 0;
    for EntryIndex := 1 to Integer(Header.Entries) - 1 do
    begin
      if not GetEntry(EntryIndex, NextEntry) then
        Exit(StatusIoError);
      if NextEntry.LogicalBlock > LogicalBlock then
        Break;
      ChosenIndex := EntryIndex;
    end;
    if not GetEntry(ChosenIndex, Entry) then
      Exit(StatusIoError);

    StartBlock := Entry.ChildLow or (QWord(Entry.ChildHigh) shl 32);
    if StartBlock >= Ext^.BlockCount then
      Exit(StatusCorrupted);
    NodeAddress := StartBlock * Ext^.BlockSize;
    FromInode := False;
    if not ReadExtentHeader(Volume, NodeAddress, Header) then
      Exit(StatusCorrupted);
  end;
  Result := StatusCorrupted; { deeper than any valid tree }
end;

{ --- Reading: block pointers ----------------------------------------- }

function ReadBlockPointer(Volume: PVolume; TableBlock: QWord; Index: QWord; out Value: LongWord): Boolean;
var
  Ext: PExtVolume;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Result := VolumeRead(Volume, TableBlock * Ext^.BlockSize + Index * 4, 4, @Value);
end;

function WriteBlockPointer(Volume: PVolume; TableBlock: QWord; Index: QWord; Value: LongWord): Boolean;
var
  Ext: PExtVolume;
begin
  Ext := PExtVolume(Volume^.DriverData);
  Result := VolumeWrite(Volume, TableBlock * Ext^.BlockSize + Index * 4, 4, @Value);
end;

{ Works out which inode slot and how many levels of tables lead to a
  logical block, and the block's position below that slot. }
function LocateBlockPointer(Ext: PExtVolume; LogicalBlock: LongWord; out Slot: Integer;
  out LevelCount: Integer; out Remaining: QWord): Boolean;
var
  PointersPerBlock: QWord;
begin
  PointersPerBlock := Ext^.BlockSize div 4;
  Remaining := LogicalBlock;
  Result := True;

  if Remaining < DirectBlockCount then
  begin
    Slot := Integer(Remaining);
    LevelCount := 0;
    Exit;
  end;
  Remaining := Remaining - DirectBlockCount;

  if Remaining < PointersPerBlock then
  begin
    Slot := SingleIndirectSlot;
    LevelCount := 1;
    Exit;
  end;
  Remaining := Remaining - PointersPerBlock;

  if Remaining < PointersPerBlock * PointersPerBlock then
  begin
    Slot := DoubleIndirectSlot;
    LevelCount := 2;
    Exit;
  end;
  Remaining := Remaining - PointersPerBlock * PointersPerBlock;

  Slot := TripleIndirectSlot;
  LevelCount := 3;
  Result := Remaining < PointersPerBlock * PointersPerBlock * PointersPerBlock;
end;

function BlocksCoveredPerEntry(Ext: PExtVolume; Level: Integer): QWord;
var
  Multiplication: Integer;
begin
  { An entry in a table at Level covers PointersPerBlock^(Level - 1). }
  Result := 1;
  for Multiplication := 2 to Level do
    Result := Result * (Ext^.BlockSize div 4);
end;

function MapThroughBlockPointers(Node: PExtNode; LogicalBlock: LongWord;
  out PhysicalBlock: QWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Slot: Integer;
  LevelCount: Integer;
  Level: Integer;
  Remaining: QWord;
  PerEntry: QWord;
  TableBlock: LongWord;
  NextBlock: LongWord;
begin
  PhysicalBlock := 0;
  Ext := ExtVolumeOf(@Node^.Common);
  if not LocateBlockPointer(Ext, LogicalBlock, Slot, LevelCount, Remaining) then
    Exit(StatusCorrupted);

  TableBlock := InodeRecord(Node)^.Block[Slot];
  for Level := LevelCount downto 1 do
  begin
    if TableBlock = 0 then
      Exit(StatusSuccess); { a hole }
    if TableBlock >= Ext^.BlockCount then
      Exit(StatusCorrupted);
    PerEntry := BlocksCoveredPerEntry(Ext, Level);
    if not ReadBlockPointer(Node^.Common.Volume, TableBlock, Remaining div PerEntry, NextBlock) then
      Exit(StatusIoError);
    Remaining := Remaining mod PerEntry;
    TableBlock := NextBlock;
  end;

  PhysicalBlock := TableBlock;
  Result := StatusSuccess;
end;

function MapLogicalBlock(Node: PExtNode; LogicalBlock: LongWord; out PhysicalBlock: QWord): TFileSystemStatus;
begin
  if NodeUsesExtents(Node) then
    Result := MapThroughExtents(Node, LogicalBlock, PhysicalBlock)
  else
    Result := MapThroughBlockPointers(Node, LogicalBlock, PhysicalBlock);
end;

{ --- Writing: block pointers ----------------------------------------- }

function GoalNear(Node: PExtNode; LogicalBlock: LongWord): QWord;
var
  Ext: PExtVolume;
  Previous: QWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  if (LogicalBlock > 0) and (MapLogicalBlock(Node, LogicalBlock - 1, Previous) = StatusSuccess) and
     (Previous <> 0) then
    Exit(Previous + 1);
  Result := QWord(Ext^.FirstDataBlock) +
    QWord(GroupOfInode(Ext, Node^.InodeNumber)) * Ext^.BlocksPerGroup;
end;

function AllocateBlockPointer(Node: PExtNode; LogicalBlock: LongWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Volume: PVolume;
  Slot: Integer;
  LevelCount: Integer;
  Level: Integer;
  Remaining: QWord;
  PerEntry: QWord;
  Index: QWord;
  TableBlock: QWord;
  NextBlock: LongWord;
  NewBlock: QWord;
  Goal: QWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Volume := Node^.Common.Volume;
  if not LocateBlockPointer(Ext, LogicalBlock, Slot, LevelCount, Remaining) then
    Exit(StatusNoSpace);
  Goal := GoalNear(Node, LogicalBlock);

  { The inode slot itself. }
  if InodeRecord(Node)^.Block[Slot] = 0 then
  begin
    Result := AllocateBlock(Volume, Goal, NewBlock);
    if Result <> StatusSuccess then
      Exit;
    InodeRecord(Node)^.Block[Slot] := LongWord(NewBlock);
    AdjustBlockCount(Node, 1);
    Goal := NewBlock + 1;
  end;
  TableBlock := InodeRecord(Node)^.Block[Slot];

  for Level := LevelCount downto 1 do
  begin
    PerEntry := BlocksCoveredPerEntry(Ext, Level);
    Index := Remaining div PerEntry;
    Remaining := Remaining mod PerEntry;
    if not ReadBlockPointer(Volume, TableBlock, Index, NextBlock) then
      Exit(StatusIoError);
    if NextBlock = 0 then
    begin
      Result := AllocateBlock(Volume, Goal, NewBlock);
      if Result <> StatusSuccess then
        Exit;
      if not WriteBlockPointer(Volume, TableBlock, Index, LongWord(NewBlock)) then
        Exit(StatusIoError);
      AdjustBlockCount(Node, 1);
      NextBlock := LongWord(NewBlock);
      Goal := NewBlock + 1;
    end;
    TableBlock := NextBlock;
  end;
  Result := StatusSuccess;
end;

{ Releases blocks at or after KeepBlocks below one table. Returns in
  IsEmpty whether every pointer in the table is now zero. }
function ReleaseInTable(Node: PExtNode; TableBlock: QWord; Level: Integer; FirstLogical: QWord;
  KeepBlocks: QWord; out IsEmpty: Boolean): TFileSystemStatus;
var
  Ext: PExtVolume;
  Volume: PVolume;
  PointersPerBlock: QWord;
  PerEntry: QWord;
  Index: QWord;
  EntryBlock: LongWord;
  EntryFirstLogical: QWord;
  ChildIsEmpty: Boolean;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Volume := Node^.Common.Volume;
  PointersPerBlock := Ext^.BlockSize div 4;
  PerEntry := BlocksCoveredPerEntry(Ext, Level);
  IsEmpty := True;

  Index := 0;
  while Index < PointersPerBlock do
  begin
    if not ReadBlockPointer(Volume, TableBlock, Index, EntryBlock) then
      Exit(StatusIoError);
    EntryFirstLogical := FirstLogical + Index * PerEntry;

    if (EntryBlock <> 0) and (EntryFirstLogical + PerEntry > KeepBlocks) then
    begin
      if Level = 1 then
        ChildIsEmpty := True
      else
      begin
        Result := ReleaseInTable(Node, EntryBlock, Level - 1, EntryFirstLogical, KeepBlocks, ChildIsEmpty);
        if Result <> StatusSuccess then
          Exit;
      end;
      { A data block (level 1) at or past the cut, or a table emptied by
        the cut, is released. }
      if ((Level = 1) and (EntryFirstLogical >= KeepBlocks)) or ((Level > 1) and ChildIsEmpty) then
      begin
        Result := FreeBlock(Volume, EntryBlock);
        if Result <> StatusSuccess then
          Exit;
        AdjustBlockCount(Node, -1);
        if not WriteBlockPointer(Volume, TableBlock, Index, 0) then
          Exit(StatusIoError);
        EntryBlock := 0;
      end;
    end;

    if EntryBlock <> 0 then
      IsEmpty := False;
    Inc(Index);
  end;
  Result := StatusSuccess;
end;

function ReleaseBlockPointers(Node: PExtNode; KeepBlocks: LongWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Volume: PVolume;
  Inode: PInode;
  Slot: Integer;
  PointersPerBlock: QWord;
  FirstLogical: QWord;
  Level: Integer;
  TableIsEmpty: Boolean;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Volume := Node^.Common.Volume;
  Inode := InodeRecord(Node);
  PointersPerBlock := Ext^.BlockSize div 4;

  for Slot := 0 to DirectBlockCount - 1 do
  begin
    if (LongWord(Slot) >= KeepBlocks) and (Inode^.Block[Slot] <> 0) then
    begin
      Result := FreeBlock(Volume, Inode^.Block[Slot]);
      if Result <> StatusSuccess then
        Exit;
      AdjustBlockCount(Node, -1);
      Inode^.Block[Slot] := 0;
    end;
  end;

  FirstLogical := DirectBlockCount;
  for Level := 1 to 3 do
  begin
    Slot := SingleIndirectSlot + Level - 1;
    if Inode^.Block[Slot] <> 0 then
    begin
      Result := ReleaseInTable(Node, Inode^.Block[Slot], Level, FirstLogical, KeepBlocks, TableIsEmpty);
      if Result <> StatusSuccess then
        Exit;
      if TableIsEmpty then
      begin
        Result := FreeBlock(Volume, Inode^.Block[Slot]);
        if Result <> StatusSuccess then
          Exit;
        AdjustBlockCount(Node, -1);
        Inode^.Block[Slot] := 0;
      end;
    end;
    FirstLogical := FirstLogical + BlocksCoveredPerEntry(Ext, Level) * PointersPerBlock;
  end;
  Result := StatusSuccess;
end;

{ --- Writing: extent lists ------------------------------------------- }

function GrowExtentList(var List: TExtentList): Boolean;
var
  NewCapacity: LongWord;
  NewExtents: PExtentRecord;
begin
  NewCapacity := List.Capacity * 2;
  if NewCapacity < 16 then
    NewCapacity := 16;
  NewExtents := PExtentRecord(AllocateKernelMemory(NewCapacity * SizeOf(TExtentRecord)));
  if NewExtents = nil then
    Exit(False);
  if List.Count > 0 then
    CopyMemory(NewExtents, List.Extents, List.Count * SizeOf(TExtentRecord));
  FreeKernelMemory(List.Extents);
  List.Extents := NewExtents;
  List.Capacity := NewCapacity;
  Result := True;
end;

function AppendExtentRecord(var List: TExtentList; const Entry: TExtentEntry): Boolean;
begin
  if (List.Count >= List.Capacity) and not GrowExtentList(List) then
    Exit(False);
  List.Extents[List.Count].LogicalBlock := Entry.LogicalBlock;
  List.Extents[List.Count].RawLength := Entry.Length;
  List.Extents[List.Count].PhysicalBlock := Entry.StartLow or (QWord(Entry.StartHigh) shl 32);
  Inc(List.Count);
  Result := True;
end;

procedure FreeExtentList(var List: TExtentList);
begin
  FreeKernelMemory(List.Extents);
  List.Extents := nil;
  List.Count := 0;
  List.Capacity := 0;
end;

function LoadExtentList(Node: PExtNode; out List: TExtentList): TFileSystemStatus;
var
  Ext: PExtVolume;
  Volume: PVolume;
  Root: PExtentHeader;
  RootEntries: PExtentEntry;
  Leaf: TExtentHeader;
  Entry: TExtentEntry;
  RootIndex: Integer;
  LeafIndex: Integer;
  LeafBlock: QWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Volume := Node^.Common.Volume;
  FillMemory(@List, SizeOf(List), 0);

  Root := PExtentHeader(@InodeRecord(Node)^.Block[0]);
  RootEntries := PExtentEntry(PByte(Root) + ExtentHeaderSize);
  if Root^.Magic <> ExtentMagic then
    Exit(StatusCorrupted);
  if Root^.Depth > 1 then
    Exit(StatusUnsupported);

  for RootIndex := 0 to Integer(Root^.Entries) - 1 do
  begin
    if Root^.Depth = 0 then
    begin
      if not AppendExtentRecord(List, RootEntries[RootIndex]) then
        Exit(StatusOutOfMemory);
      Continue;
    end;

    LeafBlock := RootEntries[RootIndex].ChildLow or (QWord(RootEntries[RootIndex].ChildHigh) shl 32);
    if (LeafBlock = 0) or (LeafBlock >= Ext^.BlockCount) then
      Exit(StatusCorrupted);
    List.TreeBlocks[List.TreeBlockCount] := LeafBlock;
    Inc(List.TreeBlockCount);
    if not ReadExtentHeader(Volume, LeafBlock * Ext^.BlockSize, Leaf) or (Leaf.Depth <> 0) then
      Exit(StatusCorrupted);
    for LeafIndex := 0 to Integer(Leaf.Entries) - 1 do
    begin
      if not VolumeRead(Volume, LeafBlock * Ext^.BlockSize + ExtentHeaderSize +
        QWord(LeafIndex) * ExtentEntrySize, ExtentEntrySize, @Entry) then
        Exit(StatusIoError);
      if not AppendExtentRecord(List, Entry) then
        Exit(StatusOutOfMemory);
    end;
  end;
  Result := StatusSuccess;
end;

procedure EncodeExtent(const Extent: TExtentRecord; out Entry: TExtentEntry);
begin
  Entry.LogicalBlock := Extent.LogicalBlock;
  Entry.Length := Extent.RawLength;
  Entry.StartHigh := Word(Extent.PhysicalBlock shr 32);
  Entry.StartLow := LongWord(Extent.PhysicalBlock);
end;

function LeafCapacity(Ext: PExtVolume): LongWord;
begin
  Result := LongWord((Ext^.BlockSize - ExtentHeaderSize) div ExtentEntrySize);
end;

function WriteLeafBlock(Node: PExtNode; Block: QWord; const List: TExtentList; First: LongWord;
  Count: LongWord): TFileSystemStatus;
var
  Ext: PExtVolume;
  Buffer: PByte;
  Header: PExtentHeader;
  Entries: PExtentEntry;
  Index: LongWord;
  Capacity: LongWord;
  TailOffset: QWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Buffer := PByte(AllocateZeroedKernelMemory(Ext^.BlockSize));
  if Buffer = nil then
    Exit(StatusOutOfMemory);

  Capacity := LeafCapacity(Ext);
  Header := PExtentHeader(Buffer);
  Header^.Magic := ExtentMagic;
  Header^.Entries := Word(Count);
  Header^.Maximum := Word(Capacity);
  Header^.Depth := 0;
  Entries := PExtentEntry(Buffer + ExtentHeaderSize);
  for Index := 0 to Count - 1 do
    EncodeExtent(List.Extents[First + Index], Entries[Index]);

  if Ext^.HasMetadataChecksums then
  begin
    TailOffset := ExtentHeaderSize + QWord(Capacity) * ExtentEntrySize;
    PLongWord(Buffer + TailOffset)^ := NodeBlockChecksum(Node, Buffer, TailOffset);
  end;

  if VolumeWrite(Node^.Common.Volume, Block * Ext^.BlockSize, Ext^.BlockSize, Buffer) then
    Result := StatusSuccess
  else
    Result := StatusIoError;
  FreeKernelMemory(Buffer);
end;

{ Writes List back as the node's extent tree, reusing the tree blocks it
  came from where possible. }
function StoreExtentList(Node: PExtNode; var List: TExtentList): TFileSystemStatus;
var
  Ext: PExtVolume;
  Volume: PVolume;
  Root: PExtentHeader;
  RootEntries: PExtentEntry;
  Capacity: LongWord;
  LeafCount: LongWord;
  LeafIndex: LongWord;
  First: LongWord;
  CountInLeaf: LongWord;
  LeafBlock: QWord;
  NewBlock: QWord;
  Index: LongWord;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Volume := Node^.Common.Volume;
  Root := PExtentHeader(@InodeRecord(Node)^.Block[0]);
  RootEntries := PExtentEntry(PByte(Root) + ExtentHeaderSize);
  Capacity := LeafCapacity(Ext);

  if List.Count <= ExtentRootCapacity then
    LeafCount := 0
  else
    LeafCount := (List.Count + Capacity - 1) div Capacity;
  if LeafCount > ExtentRootCapacity then
    Exit(StatusUnsupported); { would need a deeper tree }

  { Get exactly LeafCount tree blocks. }
  while LongWord(List.TreeBlockCount) < LeafCount do
  begin
    Result := AllocateBlock(Volume, GoalNear(Node, 0), NewBlock);
    if Result <> StatusSuccess then
      Exit;
    AdjustBlockCount(Node, 1);
    List.TreeBlocks[List.TreeBlockCount] := NewBlock;
    Inc(List.TreeBlockCount);
  end;
  while LongWord(List.TreeBlockCount) > LeafCount do
  begin
    Dec(List.TreeBlockCount);
    Result := FreeBlock(Volume, List.TreeBlocks[List.TreeBlockCount]);
    if Result <> StatusSuccess then
      Exit;
    AdjustBlockCount(Node, -1);
  end;

  FillMemory(@InodeRecord(Node)^.Block[0], BlockPointerSlots * 4, 0);
  Root^.Magic := ExtentMagic;
  Root^.Maximum := ExtentRootCapacity;

  if LeafCount = 0 then
  begin
    Root^.Depth := 0;
    Root^.Entries := Word(List.Count);
    for Index := 1 to List.Count do
      EncodeExtent(List.Extents[Index - 1], RootEntries[Index - 1]);
    Exit(StatusSuccess);
  end;

  Root^.Depth := 1;
  Root^.Entries := Word(LeafCount);
  First := 0;
  for LeafIndex := 0 to LeafCount - 1 do
  begin
    CountInLeaf := List.Count - First;
    if CountInLeaf > Capacity then
      CountInLeaf := Capacity;
    LeafBlock := List.TreeBlocks[LeafIndex];
    Result := WriteLeafBlock(Node, LeafBlock, List, First, CountInLeaf);
    if Result <> StatusSuccess then
      Exit;
    RootEntries[LeafIndex].LogicalBlock := List.Extents[First].LogicalBlock;
    RootEntries[LeafIndex].ChildLow := LongWord(LeafBlock);
    RootEntries[LeafIndex].ChildHigh := Word(LeafBlock shr 32);
    RootEntries[LeafIndex].Unused := 0;
    First := First + CountInLeaf;
  end;
  Result := StatusSuccess;
end;

{ Records that LogicalBlock now lives at PhysicalBlock, extending the
  extent before it when they are adjacent. The list stays sorted. }
function AddBlockToList(var List: TExtentList; LogicalBlock: LongWord; PhysicalBlock: QWord): Boolean;
var
  InsertAt: LongWord;
  Previous: PExtentRecord;
  Index: LongWord;
begin
  InsertAt := 0;
  while (InsertAt < List.Count) and (List.Extents[InsertAt].LogicalBlock < LogicalBlock) do
    Inc(InsertAt);

  if InsertAt > 0 then
  begin
    Previous := @List.Extents[InsertAt - 1];
    if (Previous^.RawLength < ExtentMaximumLength) and
       (Previous^.LogicalBlock + Previous^.RawLength = LogicalBlock) and
       (Previous^.PhysicalBlock + Previous^.RawLength = PhysicalBlock) then
    begin
      Inc(Previous^.RawLength);
      Exit(True);
    end;
  end;

  if (List.Count >= List.Capacity) and not GrowExtentList(List) then
    Exit(False);
  Index := List.Count;
  while Index > InsertAt do
  begin
    List.Extents[Index] := List.Extents[Index - 1];
    Dec(Index);
  end;
  List.Extents[InsertAt].LogicalBlock := LogicalBlock;
  List.Extents[InsertAt].RawLength := 1;
  List.Extents[InsertAt].PhysicalBlock := PhysicalBlock;
  Inc(List.Count);
  Result := True;
end;

function ListMapsBlock(const List: TExtentList; LogicalBlock: LongWord): Boolean;
var
  Index: LongWord;
begin
  Index := 0;
  while Index < List.Count do
  begin
    if (LogicalBlock >= List.Extents[Index].LogicalBlock) and
       (LogicalBlock < List.Extents[Index].LogicalBlock + ExtentLength(List.Extents[Index].RawLength)) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

function GoalFromList(Node: PExtNode; const List: TExtentList; LogicalBlock: LongWord): QWord;
var
  Index: LongWord;
  Extent: PExtentRecord;
begin
  { Right after the extent that ends just before this block, if any. }
  Index := 0;
  while Index < List.Count do
  begin
    Extent := @List.Extents[Index];
    if Extent^.LogicalBlock + ExtentLength(Extent^.RawLength) = LogicalBlock then
      Exit(Extent^.PhysicalBlock + ExtentLength(Extent^.RawLength));
    Inc(Index);
  end;
  Result := GoalNear(Node, 0);
end;

function AllocateExtentRange(Node: PExtNode; FirstLogical: LongWord; Count: LongWord): TFileSystemStatus;
var
  List: TExtentList;
  Offset: LongWord;
  LogicalBlock: LongWord;
  NewBlock: QWord;
  Changed: Boolean;
begin
  Result := LoadExtentList(Node, List);
  if Result <> StatusSuccess then
  begin
    FreeExtentList(List);
    Exit;
  end;

  Changed := False;
  Offset := 0;
  while Offset < Count do
  begin
    LogicalBlock := FirstLogical + Offset;
    if not ListMapsBlock(List, LogicalBlock) then
    begin
      Result := AllocateBlock(Node^.Common.Volume, GoalFromList(Node, List, LogicalBlock), NewBlock);
      if Result <> StatusSuccess then
        Break;
      AdjustBlockCount(Node, 1);
      if not AddBlockToList(List, LogicalBlock, NewBlock) then
      begin
        Result := StatusOutOfMemory;
        Break;
      end;
      Changed := True;
    end;
    Inc(Offset);
  end;

  { Store even after a failure, so blocks already taken are recorded. }
  if Changed then
  begin
    if Result = StatusSuccess then
      Result := StoreExtentList(Node, List)
    else
      StoreExtentList(Node, List);
  end;
  FreeExtentList(List);
end;

function ReleaseExtentsFrom(Node: PExtNode; KeepBlocks: LongWord): TFileSystemStatus;
var
  List: TExtentList;
  Index: LongWord;
  WriteIndex: LongWord;
  Extent: TExtentRecord;
  Length: LongWord;
  KeepLength: LongWord;
  BlockIndex: LongWord;
  IsUnwritten: Boolean;
begin
  Result := LoadExtentList(Node, List);
  if Result <> StatusSuccess then
  begin
    FreeExtentList(List);
    Exit;
  end;

  WriteIndex := 0;
  Index := 0;
  while Index < List.Count do
  begin
    Extent := List.Extents[Index];
    Length := ExtentLength(Extent.RawLength);
    IsUnwritten := Extent.RawLength > ExtentMaximumLength;

    if Extent.LogicalBlock >= KeepBlocks then
      KeepLength := 0
    else if Extent.LogicalBlock + Length > KeepBlocks then
      KeepLength := KeepBlocks - Extent.LogicalBlock
    else
      KeepLength := Length;

    BlockIndex := KeepLength;
    while BlockIndex < Length do
    begin
      Result := FreeBlock(Node^.Common.Volume, Extent.PhysicalBlock + BlockIndex);
      if Result <> StatusSuccess then
      begin
        FreeExtentList(List);
        Exit;
      end;
      AdjustBlockCount(Node, -1);
      Inc(BlockIndex);
    end;

    if KeepLength > 0 then
    begin
      if IsUnwritten then
        Extent.RawLength := Word(KeepLength + ExtentMaximumLength)
      else
        Extent.RawLength := Word(KeepLength);
      List.Extents[WriteIndex] := Extent;
      Inc(WriteIndex);
    end;
    Inc(Index);
  end;
  List.Count := WriteIndex;

  Result := StoreExtentList(Node, List);
  FreeExtentList(List);
end;

procedure InitializeEmptyExtentTree(Node: PExtNode);
var
  Root: PExtentHeader;
begin
  FillMemory(@InodeRecord(Node)^.Block[0], BlockPointerSlots * 4, 0);
  Root := PExtentHeader(@InodeRecord(Node)^.Block[0]);
  Root^.Magic := ExtentMagic;
  Root^.Entries := 0;
  Root^.Maximum := ExtentRootCapacity;
  Root^.Depth := 0;
  InodeRecord(Node)^.Flags := InodeRecord(Node)^.Flags or InodeFlagExtents;
end;

{ --- Public allocation routines -------------------------------------- }

function AllocateBlockRange(Node: PExtNode; FirstLogical: LongWord; Count: LongWord): TFileSystemStatus;
var
  Offset: LongWord;
  PhysicalBlock: QWord;
begin
  if Count = 0 then
    Exit(StatusSuccess);
  if (InodeRecord(Node)^.Flags and InodeFlagInlineData) <> 0 then
    Exit(StatusUnsupported);
  if NodeUsesExtents(Node) then
    Exit(AllocateExtentRange(Node, FirstLogical, Count));

  Offset := 0;
  while Offset < Count do
  begin
    Result := MapThroughBlockPointers(Node, FirstLogical + Offset, PhysicalBlock);
    if Result <> StatusSuccess then
      Exit;
    if PhysicalBlock = 0 then
    begin
      Result := AllocateBlockPointer(Node, FirstLogical + Offset);
      if Result <> StatusSuccess then
        Exit;
    end;
    Inc(Offset);
  end;
  Result := StatusSuccess;
end;

function ReleaseBlocksFrom(Node: PExtNode; KeepBlocks: LongWord): TFileSystemStatus;
begin
  if (InodeRecord(Node)^.Flags and InodeFlagInlineData) <> 0 then
    Exit(StatusUnsupported);
  if NodeUsesExtents(Node) then
    Result := ReleaseExtentsFrom(Node, KeepBlocks)
  else
    Result := ReleaseBlockPointers(Node, KeepBlocks);
end;

{ --- Data access ----------------------------------------------------- }

function TransferNodeData(Node: PExtNode; Offset: QWord; ByteCount: QWord; Buffer: PByte;
  IsWrite: Boolean): TFileSystemStatus;
var
  Ext: PExtVolume;
  Volume: PVolume;
  LogicalBlock: QWord;
  OffsetInBlock: QWord;
  ChunkBytes: QWord;
  PhysicalBlock: QWord;
  Succeeded: Boolean;
begin
  Ext := ExtVolumeOf(@Node^.Common);
  Volume := Node^.Common.Volume;

  if (InodeRecord(Node)^.Flags and InodeFlagInlineData) <> 0 then
  begin
    { Small files may live entirely inside the inode's block array. Data
      beyond that spills into an extended attribute, not supported yet. }
    if IsWrite or (Offset + ByteCount > InlineDataCapacity) then
      Exit(StatusUnsupported);
    CopyMemory(Buffer, PByte(@InodeRecord(Node)^.Block[0]) + Offset, ByteCount);
    Exit(StatusSuccess);
  end;

  while ByteCount > 0 do
  begin
    LogicalBlock := Offset div Ext^.BlockSize;
    if LogicalBlock > High(LongWord) then
      Exit(StatusCorrupted);
    OffsetInBlock := Offset mod Ext^.BlockSize;
    ChunkBytes := Ext^.BlockSize - OffsetInBlock;
    if ChunkBytes > ByteCount then
      ChunkBytes := ByteCount;

    Result := MapLogicalBlock(Node, LongWord(LogicalBlock), PhysicalBlock);
    if Result <> StatusSuccess then
      Exit;

    if PhysicalBlock = 0 then
    begin
      if IsWrite then
        Exit(StatusCorrupted); { the caller should have allocated it }
      ZeroMemory(Buffer, ChunkBytes);
    end
    else
    begin
      if not IsWrite then
        Succeeded := VolumeRead(Volume, PhysicalBlock * Ext^.BlockSize + OffsetInBlock, ChunkBytes, Buffer)
      else if Buffer <> nil then
        Succeeded := VolumeWrite(Volume, PhysicalBlock * Ext^.BlockSize + OffsetInBlock, ChunkBytes, Buffer)
      else
        Succeeded := VolumeWriteZeros(Volume, PhysicalBlock * Ext^.BlockSize + OffsetInBlock, ChunkBytes);
      if not Succeeded then
        Exit(StatusIoError);
    end;

    if Buffer <> nil then
      Buffer := Buffer + ChunkBytes;
    Offset := Offset + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
  end;
  Result := StatusSuccess;
end;

function ReadNodeData(Node: PExtNode; Offset: QWord; ByteCount: QWord; Buffer: PByte): TFileSystemStatus;
begin
  Result := TransferNodeData(Node, Offset, ByteCount, Buffer, False);
end;

function WriteNodeData(Node: PExtNode; Offset: QWord; ByteCount: QWord; Source: PByte): TFileSystemStatus;
begin
  Result := TransferNodeData(Node, Offset, ByteCount, Source, True);
end;

end.
