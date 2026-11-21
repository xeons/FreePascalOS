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
  The redistributors of a GICv3: one per processor, holding its private
  interrupts (SGIs and PPIs: their enable bits, priorities, groups and
  triggers) and its LPI tables.

  They lie one after the other in regions the firmware names (the
  MADT's GICR entries, else each processor's GICC entry; a device
  tree's second "reg"), each 128 KiB (RD_base, then SGI_base), or
  256 KiB where GICv4's virtual LPI frames follow (GICR_TYPER.VLPIS).
  GICR_TYPER says whose each is (its affinity) and whether it is the
  last of its region. A processor finds its own by its MPIDR affinity
  (FindRedistributor) and wakes it (GICR_WAKER).
}
unit Hal.GicV3Redistributors;

{$mode objfpc}

interface

uses
  Firmware.Madt;

const
  { RD_base frame. }
  RedistributorControl = $0000;
  RedistributorType = $0008;
  RedistributorWaker = $0014;
  RedistributorPropertiesBase = $0070;
  RedistributorPendingBase = $0078;
  { SGI_base frame, 64 KiB after RD_base. }
  SgiFrameOffset = $10000;
  RedistributorGroup = SgiFrameOffset + $0080;
  RedistributorSetEnable = SgiFrameOffset + $0100;
  RedistributorClearEnable = SgiFrameOffset + $0180;
  RedistributorClearPending = SgiFrameOffset + $0280;
  RedistributorClearActive = SgiFrameOffset + $0380;
  RedistributorPriority = SgiFrameOffset + $0400;
  RedistributorConfiguration = SgiFrameOffset + $0C00;
  RedistributorGroupModifier = SgiFrameOffset + $0D00;

  RedistributorControlEnableLpis = 1;
  RedistributorControlWritePending = 8;

type
  TRedistributor = record
    Registers: PByte;
    PhysicalAddress: QWord;
    { GICR_TYPER.Processor_Number, for an ITS that targets by it. }
    ProcessorNumber: LongWord;
  end;

{ Maps the regions Description lists. False if there are none. }
function MapRedistributorRegions(constref Description: TGicDescription): Boolean;
{ The redistributor of the processor with MPIDR affinity Affinity
  (Aff2.Aff1.Aff0). False if no region has one. }
function FindRedistributor(Affinity: LongWord; out Redistributor: TRedistributor): Boolean;
{ Wakes Redistributor (its processor is about to take interrupts). }
procedure WakeRedistributor(constref Redistributor: TRedistributor);
{ Waits until its writes to the private enables took effect. }
procedure WaitForRedistributorWrites(constref Redistributor: TRedistributor);

function ReadRedistributor(constref Redistributor: TRedistributor; Offset: LongWord): LongWord;
procedure WriteRedistributor(constref Redistributor: TRedistributor; Offset: LongWord; Value: LongWord);
function ReadRedistributor64(constref Redistributor: TRedistributor; Offset: LongWord): QWord;
procedure WriteRedistributor64(constref Redistributor: TRedistributor; Offset: LongWord; Value: QWord);

implementation

uses
  Memory.DeviceMapping,
  Kernel.Arch.Cpu;

const
  FrameSize = $20000;
  VirtualLpiFramesSize = $20000;
  TypeVirtualLpis = 2;
  TypeLast = $10;
  TypeProcessorNumberShift = 8;
  TypeAffinityShift = 32;
  AffinityMask = $FFFFFF;
  WakerProcessorSleep = 2;
  WakerChildrenAsleep = 4;
  WaitSpins = 10000000;
  { Most redistributors one region is looked through. }
  MaximumFramesPerRegion = 512;

type
  TMappedRegion = record
    Registers: PByte;
    PhysicalAddress: QWord;
    Length: QWord;
  end;

var
  Regions: array[0..MaximumRedistributorRegions - 1] of TMappedRegion;
  RegionCount: LongWord = 0;

function ReadRedistributor(constref Redistributor: TRedistributor; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Redistributor.Registers + Offset)^;
end;

procedure WriteRedistributor(constref Redistributor: TRedistributor; Offset: LongWord; Value: LongWord);
begin
  PLongWord(Redistributor.Registers + Offset)^ := Value;
end;

function ReadRedistributor64(constref Redistributor: TRedistributor; Offset: LongWord): QWord;
begin
  Result := PQWord(Redistributor.Registers + Offset)^;
end;

procedure WriteRedistributor64(constref Redistributor: TRedistributor; Offset: LongWord; Value: QWord);
begin
  PQWord(Redistributor.Registers + Offset)^ := Value;
end;

function MapRedistributorRegions(constref Description: TGicDescription): Boolean;
var
  Index: LongWord;
  Length: QWord;
  Registers: PByte;
begin
  RegionCount := 0;
  Index := 0;
  while Index < Description.RedistributorRegionCount do
  begin
    Length := Description.RedistributorRegions[Index].Length;
    { A single redistributor: room for the virtual LPI frames too. }
    if Length = 0 then
      Length := FrameSize + VirtualLpiFramesSize;
    Registers := PByte(MapDeviceMemory(Description.RedistributorRegions[Index].Base, Length));
    if Registers <> nil then
    begin
      Regions[RegionCount].Registers := Registers;
      Regions[RegionCount].PhysicalAddress := Description.RedistributorRegions[Index].Base;
      Regions[RegionCount].Length := Length;
      Inc(RegionCount);
    end;
    Inc(Index);
  end;
  Result := RegionCount > 0;
end;

function FindInRegion(constref Region: TMappedRegion; Affinity: LongWord;
  out Redistributor: TRedistributor): Boolean;
var
  Offset: QWord;
  Frames: LongWord;
  TypeValue: QWord;
begin
  Result := False;
  Offset := 0;
  Frames := 0;
  while (Offset + FrameSize <= Region.Length) and (Frames < MaximumFramesPerRegion) do
  begin
    TypeValue := PQWord(Region.Registers + Offset + RedistributorType)^;
    if LongWord((TypeValue shr TypeAffinityShift) and AffinityMask) = Affinity then
    begin
      Redistributor.Registers := Region.Registers + Offset;
      Redistributor.PhysicalAddress := Region.PhysicalAddress + Offset;
      Redistributor.ProcessorNumber := LongWord((TypeValue shr TypeProcessorNumberShift) and $FFFF);
      Exit(True);
    end;
    if (TypeValue and TypeLast) <> 0 then
      Exit;
    Offset := Offset + FrameSize;
    if (TypeValue and TypeVirtualLpis) <> 0 then
      Offset := Offset + VirtualLpiFramesSize;
    Inc(Frames);
  end;
end;

function FindRedistributor(Affinity: LongWord; out Redistributor: TRedistributor): Boolean;
var
  Index: LongWord;
begin
  Redistributor.Registers := nil;
  Redistributor.PhysicalAddress := 0;
  Redistributor.ProcessorNumber := 0;
  Index := 0;
  while Index < RegionCount do
  begin
    if FindInRegion(Regions[Index], Affinity and AffinityMask, Redistributor) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

procedure WakeRedistributor(constref Redistributor: TRedistributor);
var
  Spins: LongWord;
begin
  WriteRedistributor(Redistributor, RedistributorWaker,
    ReadRedistributor(Redistributor, RedistributorWaker) and not WakerProcessorSleep);
  Spins := 0;
  while ((ReadRedistributor(Redistributor, RedistributorWaker) and WakerChildrenAsleep) <> 0) and
        (Spins < WaitSpins) do
  begin
    CpuRelax;
    Inc(Spins);
  end;
end;

procedure WaitForRedistributorWrites(constref Redistributor: TRedistributor);
var
  Spins: LongWord;
begin
  Spins := 0;
  while ((ReadRedistributor(Redistributor, RedistributorControl) and RedistributorControlWritePending) <> 0) and
        (Spins < WaitSpins) do
  begin
    CpuRelax;
    Inc(Spins);
  end;
end;

end.
