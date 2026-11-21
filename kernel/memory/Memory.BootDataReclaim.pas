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
  Giving the loader's boot data pages back once start-up is done with
  them.

  The loader (or the native boot stub) puts three things in boot data
  pages (MemoryRegionBootData): the boot information record with the
  memory map, the boot stack, and on a native boot a copy of the device
  tree. The kernel reads the boot information during start-up (the
  options, the memory map, the firmware tables, the framebuffer and the
  RAM disk are copied or used by then); the boot stack is the boot
  processor's idle thread's stack for good, and the device tree stays in
  use by the drivers. Everything else of the boot data is free memory
  after phase 1, so ReclaimBootData frees it; the boot information must
  not be used afterwards.
}
unit Memory.BootDataReclaim;

{$mode objfpc}

interface

uses
  Boot.Information;

{ Frees every boot data page but the boot stack's and the device
  tree's. Returns the number of pages freed. }
function ReclaimBootData(BootInformation: PBootInformation): QWord;

implementation

uses
  Memory.Layout,
  Memory.PhysicalPages,
  Debug.Output;

const
  MaximumBootDataRegions = 32;
  { Pages below 1 MiB are never handed out (Memory.PhysicalPages). }
  LowestReclaimedAddress = QWord($100000);

type
  TPhysicalRange = record
    First: TPhysicalAddress;
    Limit: TPhysicalAddress;
  end;

  TReclaimPlan = record
    Regions: array[0..MaximumBootDataRegions - 1] of TPhysicalRange;
    RegionCount: LongWord;
    BootStack: TPhysicalRange;
    DeviceTree: TPhysicalRange;
  end;

function PageRange(Start, SizeInBytes: QWord): TPhysicalRange;
begin
  Result.First := RoundDownToPage(Start);
  Result.Limit := RoundUpToPage(Start + SizeInBytes);
  if SizeInBytes = 0 then
    Result.Limit := Result.First;
end;

function IsInside(Address: TPhysicalAddress; const Range: TPhysicalRange): Boolean;
begin
  Result := (Address >= Range.First) and (Address < Range.Limit);
end;

{ Everything needed is copied out first: the boot information lives in
  the pages that are about to be freed. }
procedure MakePlan(BootInformation: PBootInformation; out Plan: TReclaimPlan);
var
  Index: QWord;
  Region: PMemoryRegion;
begin
  Plan.RegionCount := 0;
  Plan.BootStack := PageRange(BootInformation^.BootStackPhysicalBase, BootInformation^.BootStackSizeInBytes);
  Plan.DeviceTree := PageRange(BootInformation^.DeviceTreePhysicalBase, BootInformation^.DeviceTreeSizeInBytes);
  Index := 0;
  while (Index < BootInformation^.MemoryRegionCount) and (Plan.RegionCount < MaximumBootDataRegions) do
  begin
    Region := @BootInformation^.MemoryRegions[Index];
    if Region^.Kind = MemoryRegionBootData then
    begin
      Plan.Regions[Plan.RegionCount] := PageRange(Region^.PhysicalStart, Region^.PageCount * PageSize);
      Inc(Plan.RegionCount);
    end;
    Inc(Index);
  end;
end;

function MayBeFreed(const Plan: TReclaimPlan; Page: TPhysicalAddress): Boolean;
begin
  Result := (Page >= LowestReclaimedAddress) and not IsInside(Page, Plan.BootStack) and
    not IsInside(Page, Plan.DeviceTree) and (PageUsageOf(Page) = PageUsageBootData);
end;

procedure WriteReclaimSummary(const Plan: TReclaimPlan; FreedPages: QWord);
begin
  DebugBeginMessage;
  DebugWriteTag('memory');
  DebugWrite('Boot data given back: ');
  DebugWriteSize(FreedPages * PageSize);
  DebugWrite(' (kept: boot stack ');
  DebugWriteSize(Plan.BootStack.Limit - Plan.BootStack.First);
  if Plan.DeviceTree.Limit > Plan.DeviceTree.First then
  begin
    DebugWrite(', device tree ');
    DebugWriteSize(Plan.DeviceTree.Limit - Plan.DeviceTree.First);
  end;
  DebugWriteLine(')');
  DebugEndMessage;
end;

function ReclaimBootData(BootInformation: PBootInformation): QWord;
var
  Plan: TReclaimPlan;
  RegionIndex: LongWord;
  Page: TPhysicalAddress;
begin
  Result := 0;
  MakePlan(BootInformation, Plan);
  RegionIndex := 0;
  while RegionIndex < Plan.RegionCount do
  begin
    Page := Plan.Regions[RegionIndex].First;
    while Page < Plan.Regions[RegionIndex].Limit do
    begin
      if MayBeFreed(Plan, Page) then
      begin
        FreePhysicalPage(Page);
        Inc(Result);
      end;
      Page := Page + PageSize;
    end;
    Inc(RegionIndex);
  end;
  WriteReclaimSummary(Plan, Result);
end;

end.
