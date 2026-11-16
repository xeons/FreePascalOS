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
  Self test of the kernel heap checks (Memory.HeapChecks), run at
  startup when the option "heapchecks" asks for the quarantine.

  A real write after free or double free stops the system, so the test
  does the damage on purpose and asks the same functions the heap uses
  before it panics whether they see it; then it repairs the damage, so
  the block passes when it leaves the quarantine. It checks:

    * a new block holds the allocation fill, and the guard follows it;
    * a freed block holds the free fill and is quarantined (so freeing
      it again is a double free);
    * a byte written into a quarantined block is found, at its offset;
    * a byte written past the end of a block is found in the guard;
    * zeroed memory is zero.
}
unit Kernel.HeapCheckTest;

{$mode objfpc}
{$pointermath on}

interface

procedure RunHeapCheckSelfTest;

implementation

uses
  Runtime.Memory,
  Memory.HeapChecks,
  Memory.KernelHeap,
  Memory.KernelHeapChecks,
  Kernel.SelfTest;

const
  { 40 bytes in the 64-byte class: 48 usable, so 8 bytes of guard. }
  TestBlockBytes = 40;
  TestUsableBytes = 48;
  DamagedOffset = 5;

procedure TestNewBlock;
var
  Block: PByte;
  Zeroed: PByte;
begin
  Block := PByte(AllocateKernelMemory(TestBlockBytes));
  Check(Block <> nil, 'heap checks: allocation failed');
  Check(FindByteNotEqual(Block, TestBlockBytes, HeapAllocationFill) = TestBlockBytes,
    'heap checks: a new block does not hold the allocation fill');
  Check(FindByteNotEqual(Block + TestBlockBytes, TestUsableBytes - TestBlockBytes, HeapGuardFill) =
    TestUsableBytes - TestBlockBytes, 'heap checks: the guard does not follow a new block');
  FreeKernelMemory(Block);

  Zeroed := PByte(AllocateZeroedKernelMemory(TestBlockBytes));
  Check(FindByteNotEqual(Zeroed, TestBlockBytes, 0) = TestBlockBytes,
    'heap checks: zeroed memory is not zero');
  FreeKernelMemory(Zeroed);
end;

procedure TestWriteAfterFree;
var
  Block: PByte;
  Offset: QWord;
begin
  Block := PByte(AllocateKernelMemory(TestBlockBytes));
  Check(Block <> nil, 'heap checks: allocation failed');
  FreeKernelMemory(Block);

  { Reading freed memory on purpose. }
  Check(KernelHeapBlockIsQuarantined(Block), 'heap checks: a freed block is not quarantined');
  Check(FindByteNotEqual(Block, TestUsableBytes, HeapFreeFill) = TestUsableBytes,
    'heap checks: a freed block does not hold the free fill');
  Check(not FindKernelHeapDamage(Block, Offset), 'heap checks: an untouched freed block looks damaged');

  Block[DamagedOffset] := 0;
  Check(FindKernelHeapDamage(Block, Offset) and (Offset = DamagedOffset),
    'heap checks: a write after free is not found');
  Block[DamagedOffset] := HeapFreeFill;
  Check(not FindKernelHeapDamage(Block, Offset), 'heap checks: a repaired freed block still looks damaged');
end;

procedure TestWritePastEnd;
var
  Block: PByte;
  Offset: QWord;
begin
  Block := PByte(AllocateKernelMemory(TestBlockBytes));
  Check(Block <> nil, 'heap checks: allocation failed');
  Check(not FindKernelHeapDamage(Block, Offset), 'heap checks: an untouched block looks damaged');
  Block[TestBlockBytes] := 0;
  Check(FindKernelHeapDamage(Block, Offset) and (Offset = TestBlockBytes),
    'heap checks: a write past the end of a block is not found');
  Block[TestBlockBytes] := HeapGuardFill;
  FreeKernelMemory(Block);
end;

procedure RunHeapCheckSelfTest;
begin
  if KernelHeapCheckLevel <> HeapChecksQuarantine then
    Exit;
  TestNewBlock;
  TestWriteAfterFree;
  TestWritePastEnd;
  { Every block the test freed leaves the quarantine now, checked. }
  FlushKernelHeapQuarantine;
  ReportPassed('kernel heap checks');
end;

end.
