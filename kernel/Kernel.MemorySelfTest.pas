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
  Self tests of contiguous physical allocations (Memory.PhysicalPages'
  run search) and the DMA buffers made from them (Io.Dma), run once
  during startup:

    - runs with alignments up to 2 MiB, a boundary, a low limit and a
      lowest address come back as asked, zeroed, every page with one
      holder, and go back to the free list;
    - a run larger than its boundary, or with an alignment that is no
      power of two, is refused;
    - a DMA buffer for a device limited to 32-bit addresses, with a
      64 KiB boundary and an alignment, lies where the device reaches
      it, and one for a device with a window lies in the window and
      gets the window's bus address.
}
unit Kernel.MemorySelfTest;

{$mode objfpc}
{$pointermath on}

interface

procedure RunMemorySelfTests;

implementation

uses
  Memory.Layout,
  Memory.PhysicalPages,
  Io.Dma,
  Kernel.SelfTest;

function RunIsZeroed(First: TPhysicalAddress; PageCount: QWord): Boolean;
var
  Words: PQWord;
  Index: QWord;
begin
  Words := PQWord(PhysicalToVirtual(First));
  Index := 0;
  while Index < PageCount * PageSize div SizeOf(QWord) do
  begin
    if Words[Index] <> 0 then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

function RunHasOneHolderEach(First: TPhysicalAddress; PageCount: QWord): Boolean;
var
  Index: QWord;
begin
  Index := 0;
  while Index < PageCount do
  begin
    if (PageUsageOf(First + Index * PageSize) <> PageUsageGeneral) or
       (PhysicalPageHolderCount(First + Index * PageSize) <> 1) then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

{ Allocates a run as Constraints say, checks it and frees it. }
procedure CheckRun(constref Constraints: TPhysicalRunConstraints; Description: PChar);
var
  First: TPhysicalAddress;
  Alignment: QWord;
begin
  First := AllocatePhysicalRun(Constraints, PageUsageGeneral, True);
  Check(First <> 0, Description);
  Alignment := Constraints.AlignmentBytes;
  if Alignment < PageSize then
    Alignment := PageSize;
  Check((First and (Alignment - 1)) = 0, 'a contiguous run is not aligned as asked');
  if Constraints.BoundaryBytes <> 0 then
    Check(First div Constraints.BoundaryBytes =
      (First + Constraints.PageCount * PageSize - 1) div Constraints.BoundaryBytes,
      'a contiguous run crosses its boundary');
  Check(First >= Constraints.LowestAddress, 'a contiguous run lies below its lowest address');
  Check(First + Constraints.PageCount * PageSize - 1 <= Constraints.Limit, 'a contiguous run ends past its limit');
  Check(RunIsZeroed(First, Constraints.PageCount), 'a contiguous run is not zeroed');
  Check(RunHasOneHolderEach(First, Constraints.PageCount), 'a contiguous run''s pages are not the caller''s');
  FreePhysicalRun(First, Constraints.PageCount);
end;

procedure TestPhysicalRuns;
var
  Constraints: TPhysicalRunConstraints;
begin
  SetPhysicalRunConstraints(Constraints, 1);
  CheckRun(Constraints, 'no single page');
  SetPhysicalRunConstraints(Constraints, 17);
  CheckRun(Constraints, 'no run of 17 pages');
  SetPhysicalRunConstraints(Constraints, 8);
  Constraints.AlignmentBytes := 64 * 1024;
  CheckRun(Constraints, 'no 64 KiB aligned run');
  SetPhysicalRunConstraints(Constraints, 4);
  Constraints.AlignmentBytes := 2 * 1024 * 1024;
  CheckRun(Constraints, 'no 2 MiB aligned run');
  SetPhysicalRunConstraints(Constraints, 16);
  Constraints.BoundaryBytes := 64 * 1024;
  Constraints.LowestAddress := 16 * 1024 * 1024 + 3 * PageSize;
  CheckRun(Constraints, 'no run inside a 64 KiB boundary');
  SetPhysicalRunConstraints(Constraints, 3);
  Constraints.Limit := QWord($FFFFFFFF);
  CheckRun(Constraints, 'no run below 4 GiB');

  SetPhysicalRunConstraints(Constraints, 32);
  Constraints.BoundaryBytes := 64 * 1024;
  Check(AllocatePhysicalRun(Constraints, PageUsageGeneral, True) = 0, 'a run larger than its boundary was given');
  SetPhysicalRunConstraints(Constraints, 2);
  Constraints.AlignmentBytes := 3 * PageSize;
  Check(AllocatePhysicalRun(Constraints, PageUsageGeneral, True) = 0,
    'a run with an alignment that is no power of two was given');
  SetPhysicalRunConstraints(Constraints, 2);
  Constraints.LowestAddress := 64 * 1024 * 1024;
  Constraints.Limit := Constraints.LowestAddress + PageSize - 1;
  Check(AllocatePhysicalRun(Constraints, PageUsageGeneral, True) = 0, 'a run larger than its range was given');

  Check(LongestFreePhysicalRun > 0, 'no free run at all');
  ReportPassed('contiguous physical runs');
end;

procedure TestDmaBuffers;
var
  Attributes: TDmaAttributes;
  Buffer: TDmaBuffer;
begin
  SetDefaultDmaAttributes(Attributes);
  { Coherent here: the buffer stays in the physical window to check. }
  Attributes.Coherent := True;
  LimitDmaBusAddresses(Attributes, QWord($100000000));
  LimitDmaBoundary(Attributes, 64 * 1024);
  Check(AllocateAlignedDmaBuffer(Attributes, 5 * PageSize, 32 * 1024, DmaShared, Buffer), 'no 32-bit DMA buffer');
  Check(Buffer.Physical + Buffer.SizeInBytes <= QWord($100000000), 'a 32-bit DMA buffer lies above 4 GiB');
  Check((Buffer.Physical and (32 * 1024 - 1)) = 0, 'a DMA buffer is not aligned as asked');
  Check(Buffer.Physical div (64 * 1024) = (Buffer.Physical + Buffer.SizeInBytes - 1) div (64 * 1024),
    'a DMA buffer crosses the device''s boundary');
  Check(Buffer.DeviceAddress = Buffer.Physical, 'a DMA buffer without windows got another bus address');
  FreeDmaBuffer(Buffer);

  { A window: physical [32 MiB, 48 MiB) seen at bus address 3 GiB. }
  SetDefaultDmaAttributes(Attributes);
  Attributes.Coherent := True;
  Attributes.WindowCount := 1;
  Attributes.Windows[0].PhysicalStart := 32 * 1024 * 1024;
  Attributes.Windows[0].BusStart := QWord(3) * 1024 * 1024 * 1024;
  Attributes.Windows[0].Length := 16 * 1024 * 1024;
  if AllocateDmaBuffer(Attributes, 2 * PageSize, DmaStreaming, Buffer) then
  begin
    Check((Buffer.Physical >= 32 * 1024 * 1024) and (Buffer.Physical + Buffer.SizeInBytes <= 48 * 1024 * 1024),
      'a DMA buffer lies outside the device''s window');
    Check(Buffer.DeviceAddress = Attributes.Windows[0].BusStart + (Buffer.Physical - 32 * 1024 * 1024),
      'a DMA buffer in a window got the wrong bus address');
    FreeDmaBuffer(Buffer);
  end;
  ReportPassed('DMA buffers with alignment, boundary and windows');
end;

procedure RunMemorySelfTests;
begin
  TestPhysicalRuns;
  TestDmaBuffers;
end;

end.
