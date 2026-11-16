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
  The layout of kernel heap blocks: the header in front of every block,
  what its magic values mean, and the size classes of small blocks.
  Shared by the allocator (Memory.KernelHeap) and its checks
  (Memory.KernelHeapChecks).
}
unit Memory.KernelHeapBlocks;

{$mode objfpc}
{$pointermath on}

interface

const
  SizeClassCount = 7;
  SizeClassBytes: array[0..SizeClassCount - 1] of QWord = (32, 64, 128, 256, 512, 1024, 2048);
  LargestSmallBlock = 2048;

  HeaderMagicSmallAllocated = LongWord($AB5A110C);
  HeaderMagicLargeAllocated = LongWord($AB1A110C);
  HeaderMagicFree = LongWord($AB0FF4EE);
  { Freed with heap checks on, waiting in the quarantine. }
  HeaderMagicQuarantined = LongWord($AB0DEAD0);

type
  { Exactly 16 bytes so that the memory after it stays 16-byte aligned. }
  TBlockHeader = record
    Magic: LongWord;
    SizeClass: LongWord;
    case Integer of
      { Large blocks: the number of mapped pages. }
      0: (PageCount: QWord);
      { Free and quarantined small blocks: the next block in the same
        list. }
      1: (NextFree: Pointer);
      { Allocated small blocks: the bytes asked for. With heap checks
        the rest of the block is a guard. }
      2: (RequestedBytes: QWord);
  end;
  PBlockHeader = ^TBlockHeader;

{ The memory after the header. }
function BlockData(Block: PBlockHeader): PByte;
function BlockOfData(Data: Pointer): PBlockHeader;
{ What a small block of the class can hold. }
function UsableBytesOfClass(ClassIndex: LongWord): QWord;

implementation

function BlockData(Block: PBlockHeader): PByte;
begin
  Result := PByte(Block + 1);
end;

function BlockOfData(Data: Pointer): PBlockHeader;
begin
  Result := PBlockHeader(Data) - 1;
end;

function UsableBytesOfClass(ClassIndex: LongWord): QWord;
begin
  Result := SizeClassBytes[ClassIndex] - SizeOf(TBlockHeader);
end;

end.
