{
  The program heap.

  Small blocks (up to 4 KiB) come from size classes: the allocator asks
  the kernel for 64 KiB chunks and carves each into equal blocks, keeping
  freed blocks on a list per class. Larger blocks get their own run of
  pages straight from the kernel and are given back when freed.

  Every block starts with a 16-byte header recording its size, so blocks
  can be freed and resized with nothing but the pointer. Programs are
  single threaded, so no locking is needed.
}
unit Sys.Memory;

{$mode objfpc}
{$pointermath on}

interface

{ Returns nil if memory ran out. Blocks are 16-byte aligned. }
function AllocateMemory(ByteCount: QWord): Pointer;
function AllocateZeroedMemory(ByteCount: QWord): Pointer;
procedure FreeMemory(Block: Pointer);
{ Grows or shrinks a block, keeping its contents; may move it. }
function ReallocateMemory(Block: Pointer; NewByteCount: QWord): Pointer;
{ The usable size of a block. }
function MemoryBlockSize(Block: Pointer): QWord;

{ A heap copy of Text; nil if out of memory. }
function DuplicateText(Text: PChar): PChar;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Sys.Kernel;

const
  SizeClassCount = 9;
  SmallestClassSize = 16;
  LargestSmallBlock = 4096;
  ChunkSize = 64 * 1024;
  PageSize = 4096;
  HeaderSize = 16;

  MagicSmall = LongWord($5A11B10C);
  MagicLarge = LongWord($1A7CB10C);
  MagicFree = LongWord($F7EEB10C);

type
  PBlockHeader = ^TBlockHeader;
  TBlockHeader = record
    Magic: LongWord;
    SizeClass: LongWord;
    case Boolean of
      False: (TotalBytes: QWord);   { large blocks: bytes obtained }
      True: (NextFree: PBlockHeader); { free small blocks }
  end;

var
  FreeLists: array[0..SizeClassCount - 1] of PBlockHeader;

function ClassBytes(SizeClass: LongWord): QWord;
begin
  Result := QWord(SmallestClassSize) shl SizeClass;
end;

function SizeClassFor(TotalBytes: QWord): Integer;
var
  SizeClass: Integer;
begin
  for SizeClass := 0 to SizeClassCount - 1 do
  begin
    if TotalBytes <= ClassBytes(SizeClass) then
      Exit(SizeClass);
  end;
  Result := -1;
end;

function RefillClass(SizeClass: Integer): Boolean;
var
  Chunk: Int64;
  Offset: QWord;
  Block: PBlockHeader;
begin
  Chunk := KernelAllocateMemory(ChunkSize);
  if Chunk < 0 then
    Exit(False);
  Offset := 0;
  while Offset + ClassBytes(SizeClass) <= ChunkSize do
  begin
    Block := PBlockHeader(PByte(Chunk) + Offset);
    Block^.Magic := MagicFree;
    Block^.SizeClass := LongWord(SizeClass);
    Block^.NextFree := FreeLists[SizeClass];
    FreeLists[SizeClass] := Block;
    Offset := Offset + ClassBytes(SizeClass);
  end;
  Result := True;
end;

function AllocateMemory(ByteCount: QWord): Pointer;
var
  TotalBytes: QWord;
  SizeClass: Integer;
  Block: PBlockHeader;
  Address: Int64;
begin
  if ByteCount = 0 then
    ByteCount := 1;
  TotalBytes := ByteCount + HeaderSize;

  if TotalBytes <= LargestSmallBlock then
  begin
    SizeClass := SizeClassFor(TotalBytes);
    if (FreeLists[SizeClass] = nil) and not RefillClass(SizeClass) then
      Exit(nil);
    Block := FreeLists[SizeClass];
    FreeLists[SizeClass] := Block^.NextFree;
    Block^.Magic := MagicSmall;
    Block^.TotalBytes := 0;
    Exit(Pointer(PByte(Block) + HeaderSize));
  end;

  TotalBytes := (TotalBytes + PageSize - 1) and not QWord(PageSize - 1);
  Address := KernelAllocateMemory(TotalBytes);
  if Address < 0 then
    Exit(nil);
  Block := PBlockHeader(Address);
  Block^.Magic := MagicLarge;
  Block^.SizeClass := 0;
  Block^.TotalBytes := TotalBytes;
  Result := Pointer(PByte(Block) + HeaderSize);
end;

function AllocateZeroedMemory(ByteCount: QWord): Pointer;
begin
  Result := AllocateMemory(ByteCount);
  if Result <> nil then
    ZeroMemory(Result, ByteCount);
end;

function HeaderOf(Block: Pointer): PBlockHeader;
begin
  Result := PBlockHeader(PByte(Block) - HeaderSize);
end;

procedure FreeMemory(Block: Pointer);
var
  Header: PBlockHeader;
begin
  if Block = nil then
    Exit;
  Header := HeaderOf(Block);
  case Header^.Magic of
    MagicSmall:
      begin
        Header^.Magic := MagicFree;
        Header^.NextFree := FreeLists[Header^.SizeClass];
        FreeLists[Header^.SizeClass] := Header;
      end;
    MagicLarge:
      begin
        Header^.Magic := MagicFree;
        KernelFreeMemory(Header);
      end;
  end;
  { Anything else is not a heap block (or freed twice); ignore it rather
    than corrupt the heap. }
end;

function MemoryBlockSize(Block: Pointer): QWord;
var
  Header: PBlockHeader;
begin
  if Block = nil then
    Exit(0);
  Header := HeaderOf(Block);
  if Header^.Magic = MagicSmall then
    Result := ClassBytes(Header^.SizeClass) - HeaderSize
  else if Header^.Magic = MagicLarge then
    Result := Header^.TotalBytes - HeaderSize
  else
    Result := 0;
end;

function ReallocateMemory(Block: Pointer; NewByteCount: QWord): Pointer;
var
  OldSize: QWord;
begin
  if Block = nil then
    Exit(AllocateMemory(NewByteCount));
  OldSize := MemoryBlockSize(Block);
  if NewByteCount <= OldSize then
    Exit(Block);
  Result := AllocateMemory(NewByteCount);
  if Result = nil then
    Exit;
  CopyMemory(Result, Block, OldSize);
  FreeMemory(Block);
end;

function DuplicateText(Text: PChar): PChar;
var
  Length: PtrUInt;
begin
  if Text = nil then
    Text := '';
  Length := TextLength(Text);
  Result := PChar(AllocateMemory(Length + 1));
  if Result <> nil then
    CopyMemory(Result, Text, Length + 1);
end;

end.
