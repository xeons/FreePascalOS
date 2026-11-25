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
  The ARM generic interrupt controller, version 2 (the Raspberry Pi 4's
  GIC-400, and QEMU's virt machine with gic-version=2).

  Its distributor (shared) routes the shared peripheral interrupts
  (SPIs, INTID 32 and up) to processors and holds every interrupt's
  priority, enable bit and trigger; each processor's CPU interface
  (banked at one address) acknowledges and ends interrupts and holds the
  priority mask, which is the kernel's priority level
  (Kernel.Arch.PriorityLevel). The addresses come from the ACPI MADT.

  The kernel's vectors (Hal.InterruptVectors) are given to the INTIDs
  the HAL uses: the dispatch and request SGIs, the timer's PPI, and the
  SPIs drivers connect (RouteSharedInterrupt). Each INTID gets the GIC
  priority of its vector's level.

  GICv2 addresses processors by CPU interface number (0-7), not by
  affinity: each processor learns its own from the distributor's banked
  target register and records it next to its id.

  Hal.Gic chooses between this and GICv3 (Hal.GicV3) and has the
  interface the rest of the HAL uses; the routines here are its GICv2
  halves.
}
unit Hal.GicV2;

{$mode objfpc}

interface

uses
  Firmware.Madt;

{ Maps the distributor and CPU interface Description gives and sets up
  the distributor and this processor's CPU interface. False if they
  cannot be mapped. }
function InitializeGicV2(constref Description: TGicDescription): Boolean;
{ Sets up a processor's CPU interface and private interrupts. }
procedure InitializeGicV2OnThisProcessor;
{ The distributor again with every SPI as it was connected, if waking
  reset it, then this processor's interface. }
procedure RestoreGicV2AfterSleep;

function GicV2InterruptCount: LongWord;

function ConnectGicV2Interrupt(Interrupt: LongWord; Vector: Byte; LevelTriggered: Boolean;
  TargetProcessorId: LongWord): Boolean;
procedure DisableGicV2Interrupt(Interrupt: LongWord);

function AcknowledgeGicV2Interrupt: Byte;
procedure EndGicV2Interrupt;

procedure SendGicV2SoftwareInterrupt(Number: LongWord; TargetProcessorId: LongWord);
procedure SendGicV2SoftwareInterruptToSelf(Number: LongWord);
procedure SendGicV2SoftwareInterruptToOthers(Number: LongWord);

implementation

uses
  Memory.DeviceMapping,
  Hal.GicDefinitions,
  Hal.InterruptVectors,
  Kernel.Arch.Cpu,
  Kernel.Arch.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Processors;

const
  DistributorSize = $1000;
  CpuInterfaceSize = $2000;

  DistributorControl = $000;
  DistributorType = $004;
  DistributorSetEnable = $100;
  DistributorClearEnable = $180;
  DistributorClearPending = $280;
  DistributorClearActive = $380;
  DistributorPriority = $400;
  DistributorTargets = $800;
  DistributorConfiguration = $C00;
  DistributorSoftwareInterrupt = $F00;

  CpuControl = $000;
  CpuPriorityMask = $004;
  CpuBinaryPoint = $008;
  CpuAcknowledge = $00C;
  CpuEndOfInterrupt = $010;

  InterruptIdMask = $3FF;
  TargetFilterSelf = LongWord(2) shl 24;
  TargetFilterOthers = LongWord(1) shl 24;
  TargetListShift = 16;

  MaximumKnownProcessors = 8;

var
  Distributor: PByte = nil;
  CpuInterface: PByte = nil;
  InterruptTotal: LongWord = 0;
  VectorOfInterrupt: TInterruptVectorTable;
  { How each SPI was connected, to connect it again after waking. }
  LevelTriggeredOf: array[0..MaximumInterrupts - 1] of Boolean;
  TargetOf: array[0..MaximumInterrupts - 1] of LongWord;
  { False once masked (DisableGicV2Interrupt): waking leaves it so. }
  EnabledOf: array[0..MaximumInterrupts - 1] of Boolean;
  { Serializes the read-modify-write of the shared configuration
    registers (GICD_ICFGR: sixteen interrupts a word), taken with
    interrupts off. }
  ConfigurationLock: TSpinLock;
  LastAcknowledged: array[0..MaximumProcessors - 1] of LongWord;
  KnownIds: array[0..MaximumKnownProcessors - 1] of LongWord;
  KnownMasks: array[0..MaximumKnownProcessors - 1] of Byte;
  KnownCount: LongWord = 0;

function GicV2InterruptCount: LongWord;
begin
  Result := InterruptTotal;
end;

function ReadDistributor(Offset: LongWord): LongWord;
begin
  Result := PLongWord(Distributor + Offset)^;
end;

procedure WriteDistributor(Offset: LongWord; Value: LongWord);
begin
  PLongWord(Distributor + Offset)^ := Value;
end;

procedure WriteCpuInterface(Offset: LongWord; Value: LongWord);
begin
  PLongWord(CpuInterface + Offset)^ := Value;
end;

function ReadCpuInterface(Offset: LongWord): LongWord;
begin
  Result := PLongWord(CpuInterface + Offset)^;
end;

procedure WriteDistributorByte(Offset: LongWord; Value: Byte);
begin
  PByte(Distributor + Offset)^ := Value;
end;

{ This processor's bit in the target registers: the banked targets of
  its private interrupts read as itself. }
function OwnCpuMask: Byte;
var
  Mask: LongWord;
begin
  Mask := ReadDistributor(DistributorTargets) and $FF;
  if Mask = 0 then
    Mask := 1;
  Result := Byte(Mask);
end;

procedure RecordOwnCpuMask;
var
  Id: LongWord;
  Index: LongWord;
begin
  Id := CurrentProcessor^.ApicId;
  Index := 0;
  while Index < KnownCount do
  begin
    if KnownIds[Index] = Id then
    begin
      KnownMasks[Index] := OwnCpuMask;
      Exit;
    end;
    Inc(Index);
  end;
  if KnownCount < MaximumKnownProcessors then
  begin
    KnownIds[KnownCount] := Id;
    KnownMasks[KnownCount] := OwnCpuMask;
    Inc(KnownCount);
  end;
end;

function CpuMaskOf(ProcessorId: LongWord): Byte;
var
  Index: LongWord;
begin
  Index := 0;
  while Index < KnownCount do
  begin
    if KnownIds[Index] = ProcessorId then
      Exit(KnownMasks[Index]);
    Inc(Index);
  end;
  Result := 0;
end;

procedure SetPriority(Interrupt: LongWord; Vector: Byte);
begin
  WriteDistributorByte(DistributorPriority + Interrupt,
    GicPriorityOfLevel(ArchPriorityLevelOfVector(Vector)));
end;

procedure SetTrigger(Interrupt: LongWord; LevelTriggered: Boolean);
var
  Offset: LongWord;
  Shift: LongWord;
  Value: LongWord;
begin
  { SGIs are always edge triggered; the trigger of PPIs may be fixed. }
  if Interrupt < 16 then
    Exit;
  Offset := DistributorConfiguration + (Interrupt div 16) * 4;
  Shift := (Interrupt mod 16) * 2 + 1;
  Value := ReadDistributor(Offset);
  if LevelTriggered then
    Value := Value and not (LongWord(1) shl Shift)
  else
    Value := Value or (LongWord(1) shl Shift);
  WriteDistributor(Offset, Value);
end;

procedure EnableInterrupt(Interrupt: LongWord);
begin
  WriteDistributor(DistributorSetEnable + (Interrupt div 32) * 4, LongWord(1) shl (Interrupt mod 32));
end;

procedure DisableGicV2Interrupt(Interrupt: LongWord);
begin
  if (Distributor = nil) or (Interrupt >= InterruptTotal) then
    Exit;
  EnabledOf[Interrupt] := False;
  WriteDistributor(DistributorClearEnable + (Interrupt div 32) * 4, LongWord(1) shl (Interrupt mod 32));
end;

{ Private interrupts (SGIs, PPIs) are banked: each processor sets its own. }
procedure InitializePrivateInterrupts;
var
  Interrupt: LongWord;
begin
  WriteDistributor(DistributorClearEnable, $FFFFFFFF);
  WriteDistributor(DistributorClearPending, $FFFFFFFF);
  WriteDistributor(DistributorClearActive, $FFFFFFFF);
  for Interrupt := 0 to FirstSharedInterrupt - 1 do
    if VectorOfInterrupt[Interrupt] <> SpuriousInterruptVector then
    begin
      SetPriority(Interrupt, VectorOfInterrupt[Interrupt]);
      EnableInterrupt(Interrupt);
    end;
end;

procedure InitializeCpuInterface;
begin
  { Everything masked until the kernel lowers its level; every priority
    bit decides preemption. }
  WriteCpuInterface(CpuPriorityMask, 0);
  WriteCpuInterface(CpuBinaryPoint, 0);
  WriteCpuInterface(CpuControl, 1);
  UsePriorityMaskRegister(PLongWord(CpuInterface + CpuPriorityMask));
end;

procedure InitializeGicV2OnThisProcessor;
begin
  if Distributor = nil then
    Exit;
  RecordOwnCpuMask;
  InitializePrivateInterrupts;
  InitializeCpuInterface;
end;

procedure InitializeDistributor;
var
  Index: LongWord;
begin
  WriteDistributor(DistributorControl, 0);
  InterruptTotal := ((ReadDistributor(DistributorType) and $1F) + 1) * 32;
  if InterruptTotal > MaximumInterrupts then
    InterruptTotal := MaximumInterrupts;
  Index := FirstSharedInterrupt;
  while Index < InterruptTotal do
  begin
    WriteDistributor(DistributorClearEnable + (Index div 32) * 4, $FFFFFFFF);
    WriteDistributor(DistributorClearPending + (Index div 32) * 4, $FFFFFFFF);
    Index := Index + 32;
  end;
  WriteDistributor(DistributorControl, 1);
end;

function InitializeGicV2(constref Description: TGicDescription): Boolean;
begin
  Result := False;
  ResetInterruptVectorTable(VectorOfInterrupt);
  if (Description.DistributorAddress = 0) or (Description.CpuInterfaceAddress = 0) then
    Exit;
  Distributor := PByte(MapDeviceMemory(Description.DistributorAddress, DistributorSize));
  CpuInterface := PByte(MapDeviceMemory(Description.CpuInterfaceAddress, CpuInterfaceSize));
  if (Distributor = nil) or (CpuInterface = nil) then
  begin
    Distributor := nil;
    Exit;
  end;

  InitializeSpinLock(ConfigurationLock);
  InitializeDistributor;
  InitializeGicV2OnThisProcessor;
  Result := True;
end;

{ Writes interrupt Interrupt's priority, trigger and target as recorded,
  and enables it if Enable. }
procedure ProgramInterrupt(Interrupt: LongWord; Enable: Boolean);
var
  Mask: Byte;
  InterruptsWereEnabled: Boolean;
begin
  InterruptsWereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(ConfigurationLock);
  SetPriority(Interrupt, VectorOfInterrupt[Interrupt]);
  SetTrigger(Interrupt, LevelTriggeredOf[Interrupt]);
  if Interrupt >= FirstSharedInterrupt then
  begin
    Mask := CpuMaskOf(TargetOf[Interrupt]);
    if Mask = 0 then
      Mask := OwnCpuMask;
    WriteDistributorByte(DistributorTargets + Interrupt, Mask);
  end;
  if Enable then
    EnableInterrupt(Interrupt);
  ReleaseSpinLockAtCurrentLevel(ConfigurationLock);
  RestoreInterrupts(InterruptsWereEnabled);
end;

function ConnectGicV2Interrupt(Interrupt: LongWord; Vector: Byte; LevelTriggered: Boolean;
  TargetProcessorId: LongWord): Boolean;
begin
  Result := False;
  if (Distributor = nil) or (Interrupt >= InterruptTotal) then
    Exit;
  VectorOfInterrupt[Interrupt] := Vector;
  LevelTriggeredOf[Interrupt] := LevelTriggered;
  TargetOf[Interrupt] := TargetProcessorId;
  EnabledOf[Interrupt] := True;
  ProgramInterrupt(Interrupt, True);
  Result := True;
end;

procedure RestoreGicV2AfterSleep;
var
  Interrupt: LongWord;
begin
  if Distributor = nil then
    Exit;
  if (ReadDistributor(DistributorControl) and 1) = 0 then
  begin
    InitializeDistributor;
    Interrupt := FirstSharedInterrupt;
    while Interrupt < InterruptTotal do
    begin
      if VectorOfInterrupt[Interrupt] <> SpuriousInterruptVector then
        ProgramInterrupt(Interrupt, EnabledOf[Interrupt]);
      Inc(Interrupt);
    end;
  end;
  InitializeGicV2OnThisProcessor;
end;

function AcknowledgeGicV2Interrupt: Byte;
var
  Acknowledge: LongWord;
  Interrupt: LongWord;
begin
  Acknowledge := ReadCpuInterface(CpuAcknowledge);
  Interrupt := Acknowledge and InterruptIdMask;
  if Interrupt >= MaximumInterrupts then
    Exit(SpuriousInterruptVector);
  Result := VectorOfInterrupt[Interrupt];
  if Result = SpuriousInterruptVector then
  begin
    { Nobody asked for it: end it and mask it. }
    WriteCpuInterface(CpuEndOfInterrupt, Acknowledge);
    DisableGicV2Interrupt(Interrupt);
    Exit;
  end;
  LastAcknowledged[CurrentProcessorIndexOrZero] := Acknowledge;
end;

procedure EndGicV2Interrupt;
begin
  WriteCpuInterface(CpuEndOfInterrupt, LastAcknowledged[CurrentProcessorIndexOrZero]);
end;

procedure SendGicV2SoftwareInterrupt(Number: LongWord; TargetProcessorId: LongWord);
var
  Mask: Byte;
begin
  if Distributor = nil then
    Exit;
  Mask := CpuMaskOf(TargetProcessorId);
  if Mask = 0 then
    Exit;
  DataSynchronizationBarrier;
  WriteDistributor(DistributorSoftwareInterrupt, (LongWord(Mask) shl TargetListShift) or Number);
end;

procedure SendGicV2SoftwareInterruptToSelf(Number: LongWord);
begin
  if Distributor = nil then
    Exit;
  DataSynchronizationBarrier;
  WriteDistributor(DistributorSoftwareInterrupt, TargetFilterSelf or Number);
end;

procedure SendGicV2SoftwareInterruptToOthers(Number: LongWord);
begin
  if Distributor = nil then
    Exit;
  DataSynchronizationBarrier;
  WriteDistributor(DistributorSoftwareInterrupt, TargetFilterOthers or Number);
end;

end.
