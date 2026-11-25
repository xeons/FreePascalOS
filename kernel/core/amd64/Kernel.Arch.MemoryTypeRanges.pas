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
  The memory type range registers (MTRRs) of every processor kept equal
  to the boot processor's.

  The firmware sets the MTRRs (which physical ranges are cached how:
  RAM write-back, device memory uncached) on every processor at start.
  Suspend to RAM takes the power away: the firmware puts the boot
  processor's back as it wakes, but a secondary processor started again
  with INIT and STARTUP afterwards may come up with them cleared - every
  access uncached, many times slower - or, on some firmware, not quite
  the same. So the boot processor's are read once at start
  (SaveBootMemoryTypeRanges: the default type, the fixed ranges below
  1 MiB, the variable ranges MTRRcap says it has), and every processor
  that starts or wakes compares its own with them
  (SynchronizeMemoryTypeRanges) and, where they differ, writes them by
  the processor manual's procedure: caches off (CR0.CD) and flushed
  (WBINVD), translations flushed (CR4.PGE toggled), MTRRs off, written,
  on again, flushed again, caches on. It runs with interrupts off, on a
  processor no other processor runs with yet, so the manual's "on every
  processor at once" is met.
}
unit Kernel.Arch.MemoryTypeRanges;

{$mode objfpc}
{$asmmode intel}

interface

{ On the boot processor at start. }
procedure SaveBootMemoryTypeRanges;
{ On a processor that starts or wakes, interrupts off: makes its MTRRs
  the boot processor's. True if they had to be written. }
function SynchronizeMemoryTypeRanges: Boolean;
{ How many times SynchronizeMemoryTypeRanges had to write them. }
function MemoryTypeRangeRestoreCount: LongWord;

implementation

uses
  Runtime.Atomic,
  Runtime.Memory,
  Kernel.Arch.Cpu;

const
  CpuidFeatures = 1;
  FeatureMtrrBit = LongWord(1) shl 12;
  MsrMtrrCapabilities = $FE;
  MsrMtrrDefaultType = $2FF;
  MsrVariableBase = $200;
  CapabilityVariableCountMask = $FF;
  CapabilityFixedBit = QWord(1) shl 8;
  DefaultTypeEnableBit = QWord(1) shl 11;
  MaximumVariableRanges = 32;
  FixedRangeCount = 11;
  FixedRangeRegisters: array[0..FixedRangeCount - 1] of LongWord = (
    $250, $258, $259, $268, $269, $26A, $26B, $26C, $26D, $26E, $26F);
  Cr0CacheDisable = QWord(1) shl 30;
  Cr0NotWriteThrough = QWord(1) shl 29;
  Cr4GlobalPages = QWord(1) shl 7;

type
  TMemoryTypeRanges = record
    DefaultType: QWord;
    Fixed: array[0..FixedRangeCount - 1] of QWord;
    { Base and mask of each variable range. }
    Variable: array[0..MaximumVariableRanges * 2 - 1] of QWord;
  end;

var
  Saved: TMemoryTypeRanges;
  HasRanges: Boolean = False;
  HasFixed: Boolean = False;
  VariableCount: LongWord = 0;
  RestoreCount: Int64 = 0;

procedure WriteBackAndInvalidateCaches; assembler; nostackframe;
asm
  wbinvd
end;

procedure ReadRanges(out Ranges: TMemoryTypeRanges);
var
  Index: LongWord;
begin
  ZeroMemory(@Ranges, SizeOf(Ranges));
  Ranges.DefaultType := ReadModelSpecificRegister(MsrMtrrDefaultType);
  if HasFixed then
    for Index := 0 to FixedRangeCount - 1 do
      Ranges.Fixed[Index] := ReadModelSpecificRegister(FixedRangeRegisters[Index]);
  Index := 0;
  while Index < VariableCount * 2 do
  begin
    Ranges.Variable[Index] := ReadModelSpecificRegister(MsrVariableBase + Index);
    Inc(Index);
  end;
end;

procedure SaveBootMemoryTypeRanges;
var
  Registers: TCpuidResult;
  Capabilities: QWord;
begin
  ExecuteCpuid(CpuidFeatures, 0, Registers);
  if (Registers.Edx and FeatureMtrrBit) = 0 then
    Exit;
  Capabilities := ReadModelSpecificRegister(MsrMtrrCapabilities);
  VariableCount := LongWord(Capabilities and CapabilityVariableCountMask);
  if VariableCount > MaximumVariableRanges then
    VariableCount := MaximumVariableRanges;
  HasFixed := (Capabilities and CapabilityFixedBit) <> 0;
  ReadRanges(Saved);
  HasRanges := True;
end;

function RangesAreEqual(const Left, Right: TMemoryTypeRanges): Boolean;
var
  Index: Integer;
begin
  if Left.DefaultType <> Right.DefaultType then
    Exit(False);
  for Index := 0 to FixedRangeCount - 1 do
    if Left.Fixed[Index] <> Right.Fixed[Index] then
      Exit(False);
  for Index := 0 to MaximumVariableRanges * 2 - 1 do
    if Left.Variable[Index] <> Right.Variable[Index] then
      Exit(False);
  Result := True;
end;

{ The manual's procedure (Intel SDM volume 3, 12.11.7.2). }
procedure WriteRanges(const Ranges: TMemoryTypeRanges);
var
  Control0: QWord;
  Control4: QWord;
  Index: LongWord;
begin
  Control0 := ReadControlRegister0;
  Control4 := ReadControlRegister4;
  WriteControlRegister0((Control0 or Cr0CacheDisable) and not Cr0NotWriteThrough);
  WriteBackAndInvalidateCaches;
  if (Control4 and Cr4GlobalPages) <> 0 then
    WriteControlRegister4(Control4 and not Cr4GlobalPages)
  else
    FlushEntireTlb;
  WriteModelSpecificRegister(MsrMtrrDefaultType, ReadModelSpecificRegister(MsrMtrrDefaultType) and
    not DefaultTypeEnableBit);
  if HasFixed then
    for Index := 0 to FixedRangeCount - 1 do
      WriteModelSpecificRegister(FixedRangeRegisters[Index], Ranges.Fixed[Index]);
  Index := 0;
  while Index < VariableCount * 2 do
  begin
    WriteModelSpecificRegister(MsrVariableBase + Index, Ranges.Variable[Index]);
    Inc(Index);
  end;
  { Last: it turns them on again. }
  WriteModelSpecificRegister(MsrMtrrDefaultType, Ranges.DefaultType);
  WriteBackAndInvalidateCaches;
  if (Control4 and Cr4GlobalPages) <> 0 then
    WriteControlRegister4(Control4)
  else
    FlushEntireTlb;
  WriteControlRegister0(Control0);
end;

function SynchronizeMemoryTypeRanges: Boolean;
var
  Current: TMemoryTypeRanges;
  InterruptsWereEnabled: Boolean;
begin
  Result := False;
  if not HasRanges then
    Exit;
  ReadRanges(Current);
  if RangesAreEqual(Current, Saved) then
    Exit;
  InterruptsWereEnabled := SaveAndDisableInterrupts;
  WriteRanges(Saved);
  RestoreInterrupts(InterruptsWereEnabled);
  AtomicIncrement(RestoreCount);
  Result := True;
end;

function MemoryTypeRangeRestoreCount: LongWord;
begin
  Result := LongWord(AtomicFetchAndAdd(RestoreCount, 0));
end;

end.
