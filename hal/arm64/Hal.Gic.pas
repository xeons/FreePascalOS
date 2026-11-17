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

  GICv3 (system register CPU interface, redistributors, affinity
  routing; the Raspberry Pi 5 has none, but servers do) is for later.
}
unit Hal.Gic;

{$mode objfpc}

interface

const
  SoftwareInterruptDispatch = 0;
  SoftwareInterruptRequest = 1;
  SoftwareInterruptStop = 2;
  FirstSharedInterrupt = 32;
  SpuriousInterruptId = 1023;

{ Maps the GIC the MADT describes and sets up the distributor and this
  processor's CPU interface. False if there is none (or not version 2). }
function InitializeGic: Boolean;
{ Sets up a secondary processor's CPU interface and private interrupts. }
procedure InitializeGicOnThisProcessor;

function GicInterruptCount: LongWord;

{ Gives INTID Interrupt the kernel's Vector (a private interrupt on
  every processor, or an SPI) with its level's priority, its trigger,
  and enables it. SPIs go to the processor with id TargetProcessorId. }
function ConnectGicInterrupt(Interrupt: LongWord; Vector: Byte; LevelTriggered: Boolean;
  TargetProcessorId: LongWord): Boolean;
procedure DisableGicInterrupt(Interrupt: LongWord);

{ Acknowledges the highest pending interrupt and returns its vector
  (SpuriousInterruptVector if none, or it has none). }
function AcknowledgeGicInterrupt: Byte;
{ Ends the interrupt this processor acknowledged last. }
procedure EndGicInterrupt;

{ Sends software generated interrupt Number to one processor, to this
  one, or to all others. }
procedure SendSoftwareInterrupt(Number: LongWord; TargetProcessorId: LongWord);
procedure SendSoftwareInterruptToSelf(Number: LongWord);
procedure SendSoftwareInterruptToOthers(Number: LongWord);

function GicIsAvailable: Boolean;

implementation

uses
  Firmware.Madt,
  Memory.DeviceMapping,
  Hal.InterruptVectors,
  Kernel.Arch.Cpu,
  Kernel.Arch.PriorityLevel,
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
  MaximumInterrupts = 1020;
  TargetFilterSelf = LongWord(2) shl 24;
  TargetFilterOthers = LongWord(1) shl 24;
  TargetListShift = 16;

  MaximumKnownProcessors = 8;

var
  Distributor: PByte = nil;
  CpuInterface: PByte = nil;
  InterruptTotal: LongWord = 0;
  VectorOfInterrupt: array[0..MaximumInterrupts - 1] of Byte;
  LastAcknowledged: array[0..MaximumProcessors - 1] of LongWord;
  KnownIds: array[0..MaximumKnownProcessors - 1] of LongWord;
  KnownMasks: array[0..MaximumKnownProcessors - 1] of Byte;
  KnownCount: LongWord = 0;

function GicIsAvailable: Boolean;
begin
  Result := Distributor <> nil;
end;

function GicInterruptCount: LongWord;
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

procedure DisableGicInterrupt(Interrupt: LongWord);
begin
  if (Distributor = nil) or (Interrupt >= InterruptTotal) then
    Exit;
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

procedure InitializeGicOnThisProcessor;
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

function InitializeGic: Boolean;
var
  Description: TGicDescription;
  Index: LongWord;
begin
  Result := False;
  for Index := 0 to MaximumInterrupts - 1 do
    VectorOfInterrupt[Index] := SpuriousInterruptVector;
  if not ParseMadt then
    Exit;
  Description := GicDescription;
  if (Description.DistributorAddress = 0) or (Description.CpuInterfaceAddress = 0) then
    Exit;
  { Version 0 means "not given" (older firmware); 2 is GICv2. }
  if (Description.Version <> 0) and (Description.Version <> 2) then
    Exit;
  Distributor := PByte(MapDeviceMemory(Description.DistributorAddress, DistributorSize));
  CpuInterface := PByte(MapDeviceMemory(Description.CpuInterfaceAddress, CpuInterfaceSize));
  if (Distributor = nil) or (CpuInterface = nil) then
  begin
    Distributor := nil;
    Exit;
  end;

  VectorOfInterrupt[SoftwareInterruptDispatch] := DispatchInterruptVector;
  VectorOfInterrupt[SoftwareInterruptRequest] := InterProcessorInterruptVector;
  VectorOfInterrupt[SoftwareInterruptStop] := InterProcessorInterruptVector + 1;

  InitializeDistributor;
  InitializeGicOnThisProcessor;
  Result := True;
end;

function ConnectGicInterrupt(Interrupt: LongWord; Vector: Byte; LevelTriggered: Boolean;
  TargetProcessorId: LongWord): Boolean;
var
  Mask: Byte;
begin
  Result := False;
  if (Distributor = nil) or (Interrupt >= InterruptTotal) then
    Exit;
  VectorOfInterrupt[Interrupt] := Vector;
  SetPriority(Interrupt, Vector);
  SetTrigger(Interrupt, LevelTriggered);
  if Interrupt >= FirstSharedInterrupt then
  begin
    Mask := CpuMaskOf(TargetProcessorId);
    if Mask = 0 then
      Mask := OwnCpuMask;
    WriteDistributorByte(DistributorTargets + Interrupt, Mask);
  end;
  EnableInterrupt(Interrupt);
  Result := True;
end;

function AcknowledgeGicInterrupt: Byte;
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
    DisableGicInterrupt(Interrupt);
    Exit;
  end;
  LastAcknowledged[CurrentProcessorIndexOrZero] := Acknowledge;
end;

procedure EndGicInterrupt;
begin
  WriteCpuInterface(CpuEndOfInterrupt, LastAcknowledged[CurrentProcessorIndexOrZero]);
end;

procedure SendSoftwareInterrupt(Number: LongWord; TargetProcessorId: LongWord);
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

procedure SendSoftwareInterruptToSelf(Number: LongWord);
begin
  if Distributor = nil then
    Exit;
  DataSynchronizationBarrier;
  WriteDistributor(DistributorSoftwareInterrupt, TargetFilterSelf or Number);
end;

procedure SendSoftwareInterruptToOthers(Number: LongWord);
begin
  if Distributor = nil then
    Exit;
  DataSynchronizationBarrier;
  WriteDistributor(DistributorSoftwareInterrupt, TargetFilterOthers or Number);
end;

end.
