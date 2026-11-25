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
  The ARM generic interrupt controller, version 3 (servers, QEMU's virt
  machine with gic-version=3).

  Unlike GICv2 it addresses processors by affinity (MPIDR), for any
  number of them:

  - the distributor, in affinity routing mode (GICD_CTLR.ARE), holds the
    SPIs: priority, trigger, group and the processor each goes to
    (GICD_IROUTERn);
  - each processor's redistributor (Hal.GicV3Redistributors) holds its
    SGIs and PPIs and its LPI tables;
  - the CPU interface is system registers (ICC_*_EL1,
    GicSystemRegisters.s): acknowledge (IAR1), end (EOIR1), the priority
    mask (PMR, the kernel's priority level), and software generated
    interrupts are sent through ICC_SGI1R_EL1 to an affinity and a
    target list, to all others, or to oneself;
  - message interrupts are LPIs through the ITS (Hal.GicV3Its).

  Every interrupt is in group 1 (non-secure), delivered as IRQ; group 0
  would arrive as FIQ, which the kernel does not take.
}
unit Hal.GicV3;

{$mode objfpc}

interface

uses
  Firmware.Madt;

function InitializeGicV3(constref Description: TGicDescription): Boolean;
procedure InitializeGicV3OnThisProcessor;
procedure RestoreGicV3AfterSleep;

function GicV3InterruptCount: LongWord;

function ConnectGicV3Interrupt(Interrupt: LongWord; Vector: Byte; LevelTriggered: Boolean;
  TargetProcessorId: LongWord): Boolean;
procedure DisableGicV3Interrupt(Interrupt: LongWord);

function AcknowledgeGicV3Interrupt: Byte;
procedure EndGicV3Interrupt;

procedure SendGicV3SoftwareInterrupt(Number: LongWord; TargetProcessorId: LongWord);
procedure SendGicV3SoftwareInterruptToSelf(Number: LongWord);
procedure SendGicV3SoftwareInterruptToOthers(Number: LongWord);

{ Sets up the ITS (Hal.GicV3Its) and LPIs on this processor; False
  without an ITS. }
function InitializeGicV3MessageInterrupts(constref Description: TGicDescription): Boolean;
{ An LPI for the device RequesterId, raising Vector on processor
  TargetProcessorId. }
function ComposeGicV3MessageInterrupt(RequesterId: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  out Address: QWord; out Data: LongWord): Boolean;

implementation

uses
  Memory.DeviceMapping,
  Hal.GicDefinitions,
  Hal.GicV3Redistributors,
  Hal.GicV3Its,
  Hal.InterruptVectors,
  Kernel.Arch.Cpu,
  Kernel.Arch.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Processors;

const
  DistributorSize = $10000;

  DistributorControl = $0000;
  DistributorType = $0004;
  DistributorGroup = $0080;
  DistributorSetEnable = $0100;
  DistributorClearEnable = $0180;
  DistributorClearPending = $0280;
  DistributorPriority = $0400;
  DistributorConfiguration = $0C00;
  DistributorGroupModifier = $0D00;
  DistributorRouter = $6000;

  ControlEnableGroup1 = 2;
  ControlAffinityRouting = $10;
  ControlWritePending = LongWord($80000000);

  SystemRegisterEnable = 1;
  InterruptIdMask = $FFFFFF;
  FirstSpecialId = 1020;

  SoftwareInterruptIdShift = 24;
  SoftwareInterruptAff1Shift = 16;
  SoftwareInterruptAff2Shift = 32;
  SoftwareInterruptRangeShift = 44;
  SoftwareInterruptToOthers = QWord(1) shl 40;

  WaitSpins = 10000000;

type
  PRedistributorRecord = ^TRedistributor;

var
  Distributor: PByte = nil;
  InterruptTotal: LongWord = 0;
  VectorOfInterrupt: TInterruptVectorTable;
  LevelTriggeredOf: array[0..MaximumInterrupts - 1] of Boolean;
  TargetOf: array[0..MaximumInterrupts - 1] of LongWord;
  { False once masked (DisableGicV3Interrupt): waking leaves it so. }
  EnabledOf: array[0..MaximumInterrupts - 1] of Boolean;
  { Serializes the read-modify-write of GICD_ICFGR (sixteen interrupts a
    word), taken with interrupts off. }
  ConfigurationLock: TSpinLock;
  LastAcknowledged: array[0..MaximumProcessors - 1] of LongWord;
  Redistributors: array[0..MaximumProcessors - 1] of TRedistributor;

function ArchEnableGicSystemRegisters: QWord; external name 'ArchEnableGicSystemRegisters';
function ArchAcknowledgeGicInterrupt: QWord; external name 'ArchAcknowledgeGicInterrupt';
procedure ArchEndGicInterrupt(IntId: QWord); external name 'ArchEndGicInterrupt';
procedure ArchWriteGicBinaryPoint(Value: QWord); external name 'ArchWriteGicBinaryPoint';
procedure ArchWriteGicControl(Value: QWord); external name 'ArchWriteGicControl';
procedure ArchWriteGicGroup1Enable(Value: QWord); external name 'ArchWriteGicGroup1Enable';
procedure ArchWriteGicPriorityMask(Value: QWord); external name 'ArchWriteGicPriorityMask';
procedure ArchSendGicSoftwareInterrupt(Value: QWord); external name 'ArchSendGicSoftwareInterrupt';

function GicV3InterruptCount: LongWord;
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

procedure WaitForDistributorWrites;
var
  Spins: LongWord;
begin
  Spins := 0;
  while ((ReadDistributor(DistributorControl) and ControlWritePending) <> 0) and (Spins < WaitSpins) do
  begin
    CpuRelax;
    Inc(Spins);
  end;
end;

{ --- Private interrupts (this processor's redistributor) -------------------- }

function OwnRedistributor: PRedistributorRecord;
begin
  Result := @Redistributors[CurrentProcessorIndexOrZero];
end;

procedure SetPrivatePriority(constref Redistributor: TRedistributor; Interrupt: LongWord; Vector: Byte);
begin
  PByte(Redistributor.Registers + RedistributorPriority + Interrupt)^ :=
    GicPriorityOfLevel(ArchPriorityLevelOfVector(Vector));
end;

procedure SetPrivateTrigger(constref Redistributor: TRedistributor; Interrupt: LongWord; LevelTriggered: Boolean);
var
  Offset: LongWord;
  Shift: LongWord;
  Value: LongWord;
begin
  if Interrupt < FirstPrivatePeripheralInterrupt then
    Exit;
  Offset := RedistributorConfiguration + (Interrupt div 16) * 4;
  Shift := (Interrupt mod 16) * 2 + 1;
  Value := ReadRedistributor(Redistributor, Offset);
  if LevelTriggered then
    Value := Value and not (LongWord(1) shl Shift)
  else
    Value := Value or (LongWord(1) shl Shift);
  WriteRedistributor(Redistributor, Offset, Value);
end;

procedure EnablePrivate(constref Redistributor: TRedistributor; Interrupt: LongWord);
begin
  WriteRedistributor(Redistributor, RedistributorSetEnable, LongWord(1) shl Interrupt);
end;

procedure InitializePrivateInterrupts(constref Redistributor: TRedistributor);
var
  Interrupt: LongWord;
begin
  WriteRedistributor(Redistributor, RedistributorClearEnable, $FFFFFFFF);
  WaitForRedistributorWrites(Redistributor);
  WriteRedistributor(Redistributor, RedistributorClearPending, $FFFFFFFF);
  WriteRedistributor(Redistributor, RedistributorClearActive, $FFFFFFFF);
  WriteRedistributor(Redistributor, RedistributorGroup, $FFFFFFFF);
  WriteRedistributor(Redistributor, RedistributorGroupModifier, 0);
  for Interrupt := 0 to FirstSharedInterrupt - 1 do
    if VectorOfInterrupt[Interrupt] <> SpuriousInterruptVector then
    begin
      SetPrivatePriority(Redistributor, Interrupt, VectorOfInterrupt[Interrupt]);
      EnablePrivate(Redistributor, Interrupt);
    end;
  WaitForRedistributorWrites(Redistributor);
end;

procedure InitializeCpuInterface;
begin
  ArchEnableGicSystemRegisters;
  { Everything masked until the kernel lowers its level; every priority
    bit decides preemption; ending an interrupt also deactivates it. }
  ArchWriteGicPriorityMask(0);
  ArchWriteGicBinaryPoint(0);
  ArchWriteGicControl(0);
  ArchWriteGicGroup1Enable(1);
  UseSystemRegisterPriorityMask;
end;

procedure InitializeGicV3OnThisProcessor;
var
  Redistributor: PRedistributorRecord;
begin
  if Distributor = nil then
    Exit;
  Redistributor := OwnRedistributor;
  if Redistributor^.Registers = nil then
    if not FindRedistributor(CurrentProcessor^.ApicId, Redistributor^) then
      Exit;
  WakeRedistributor(Redistributor^);
  InitializePrivateInterrupts(Redistributor^);
  InitializeCpuInterface;
  EnableLpisOn(Redistributor^);
end;

{ --- The distributor ----------------------------------------------------------- }

procedure InitializeDistributor;
var
  Index: LongWord;
begin
  WriteDistributor(DistributorControl, 0);
  WaitForDistributorWrites;
  InterruptTotal := ((ReadDistributor(DistributorType) and $1F) + 1) * 32;
  if InterruptTotal > MaximumInterrupts then
    InterruptTotal := MaximumInterrupts;
  Index := FirstSharedInterrupt;
  while Index < InterruptTotal do
  begin
    WriteDistributor(DistributorClearEnable + (Index div 32) * 4, $FFFFFFFF);
    WriteDistributor(DistributorClearPending + (Index div 32) * 4, $FFFFFFFF);
    WriteDistributor(DistributorGroup + (Index div 32) * 4, $FFFFFFFF);
    WriteDistributor(DistributorGroupModifier + (Index div 32) * 4, 0);
    Index := Index + 32;
  end;
  WaitForDistributorWrites;
  { Affinity routing first, then the group enabled with it set. }
  WriteDistributor(DistributorControl, ControlAffinityRouting);
  WaitForDistributorWrites;
  WriteDistributor(DistributorControl, ControlAffinityRouting or ControlEnableGroup1);
  WaitForDistributorWrites;
end;

function InitializeGicV3(constref Description: TGicDescription): Boolean;
begin
  Result := False;
  ResetInterruptVectorTable(VectorOfInterrupt);
  InitializeSpinLock(ConfigurationLock);
  if (Description.DistributorAddress = 0) or not MapRedistributorRegions(Description) then
    Exit;
  Distributor := PByte(MapDeviceMemory(Description.DistributorAddress, DistributorSize));
  if Distributor = nil then
    Exit;
  InitializeDistributor;
  InitializeGicV3OnThisProcessor;
  if OwnRedistributor^.Registers = nil then
  begin
    Distributor := nil;
    Exit;
  end;
  Result := True;
end;

function InitializeGicV3MessageInterrupts(constref Description: TGicDescription): Boolean;
begin
  Result := (Distributor <> nil) and InitializeTranslationService(Description.ItsAddress);
  if Result then
    EnableLpisOn(OwnRedistributor^);
end;

{ The GICD_IROUTERn value of MPIDR affinity Aff2.Aff1.Aff0. }
function RouterValue(ProcessorId: LongWord): QWord;
begin
  Result := ProcessorId and $FFFFFF;
end;

{ Writes SPI Interrupt's priority, trigger and route as recorded, and
  enables it if Enable. }
procedure ProgramSharedInterrupt(Interrupt: LongWord; Enable: Boolean);
var
  Offset: LongWord;
  Shift: LongWord;
  Value: LongWord;
  InterruptsWereEnabled: Boolean;
begin
  InterruptsWereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(ConfigurationLock);
  PByte(Distributor + DistributorPriority + Interrupt)^ :=
    GicPriorityOfLevel(ArchPriorityLevelOfVector(VectorOfInterrupt[Interrupt]));
  Offset := DistributorConfiguration + (Interrupt div 16) * 4;
  Shift := (Interrupt mod 16) * 2 + 1;
  Value := ReadDistributor(Offset);
  if LevelTriggeredOf[Interrupt] then
    Value := Value and not (LongWord(1) shl Shift)
  else
    Value := Value or (LongWord(1) shl Shift);
  WriteDistributor(Offset, Value);
  PQWord(Distributor + DistributorRouter + Interrupt * 8)^ := RouterValue(TargetOf[Interrupt]);
  if Enable then
    WriteDistributor(DistributorSetEnable + (Interrupt div 32) * 4, LongWord(1) shl (Interrupt mod 32));
  ReleaseSpinLockAtCurrentLevel(ConfigurationLock);
  RestoreInterrupts(InterruptsWereEnabled);
end;

function ConnectGicV3Interrupt(Interrupt: LongWord; Vector: Byte; LevelTriggered: Boolean;
  TargetProcessorId: LongWord): Boolean;
var
  Redistributor: PRedistributorRecord;
begin
  Result := False;
  if (Distributor = nil) or (Interrupt >= InterruptTotal) then
    Exit;
  VectorOfInterrupt[Interrupt] := Vector;
  LevelTriggeredOf[Interrupt] := LevelTriggered;
  TargetOf[Interrupt] := TargetProcessorId;
  if Interrupt < FirstSharedInterrupt then
  begin
    { Private: this processor's now, the others' as each starts. }
    Redistributor := OwnRedistributor;
    if Redistributor^.Registers = nil then
      Exit;
    SetPrivatePriority(Redistributor^, Interrupt, Vector);
    SetPrivateTrigger(Redistributor^, Interrupt, LevelTriggered);
    EnablePrivate(Redistributor^, Interrupt);
    WaitForRedistributorWrites(Redistributor^);
    Exit(True);
  end;
  EnabledOf[Interrupt] := True;
  ProgramSharedInterrupt(Interrupt, True);
  Result := True;
end;

procedure RestoreGicV3AfterSleep;
var
  Interrupt: LongWord;
begin
  if Distributor = nil then
    Exit;
  if (ReadDistributor(DistributorControl) and ControlAffinityRouting) = 0 then
  begin
    InitializeDistributor;
    Interrupt := FirstSharedInterrupt;
    while Interrupt < InterruptTotal do
    begin
      if VectorOfInterrupt[Interrupt] <> SpuriousInterruptVector then
        ProgramSharedInterrupt(Interrupt, EnabledOf[Interrupt]);
      Inc(Interrupt);
    end;
  end;
  RestoreTranslationService;
  InitializeGicV3OnThisProcessor;
end;

procedure DisableGicV3Interrupt(Interrupt: LongWord);
var
  Redistributor: PRedistributorRecord;
begin
  if Distributor = nil then
    Exit;
  if Interrupt >= FirstLpi then
    DisableLpi(Interrupt)
  else if Interrupt < FirstSharedInterrupt then
  begin
    Redistributor := OwnRedistributor;
    if Redistributor^.Registers <> nil then
      WriteRedistributor(Redistributor^, RedistributorClearEnable, LongWord(1) shl Interrupt);
  end
  else if Interrupt < InterruptTotal then
  begin
    EnabledOf[Interrupt] := False;
    WriteDistributor(DistributorClearEnable + (Interrupt div 32) * 4, LongWord(1) shl (Interrupt mod 32));
  end;
end;

function AcknowledgeGicV3Interrupt: Byte;
var
  Interrupt: LongWord;
begin
  Interrupt := LongWord(ArchAcknowledgeGicInterrupt and InterruptIdMask);
  if (Interrupt >= FirstSpecialId) and (Interrupt < FirstLpi) then
    Exit(SpuriousInterruptVector);
  if Interrupt >= FirstLpi then
    Result := VectorOfLpi(Interrupt)
  else
    Result := VectorOfInterrupt[Interrupt];
  if Result = SpuriousInterruptVector then
  begin
    { Nobody asked for it: end it; a stray SPI or PPI is masked too. }
    ArchEndGicInterrupt(Interrupt);
    if Interrupt < FirstLpi then
      DisableGicV3Interrupt(Interrupt);
    Exit;
  end;
  LastAcknowledged[CurrentProcessorIndexOrZero] := Interrupt;
end;

procedure EndGicV3Interrupt;
begin
  ArchEndGicInterrupt(LastAcknowledged[CurrentProcessorIndexOrZero]);
end;

{ ICC_SGI1R_EL1 for SGI Number to the processor with affinity Id. }
function SoftwareInterruptValue(Number: LongWord; Id: LongWord): QWord;
var
  Aff0: LongWord;
begin
  Aff0 := Id and $FF;
  Result := (QWord(Number and $F) shl SoftwareInterruptIdShift) or
    (QWord((Id shr 8) and $FF) shl SoftwareInterruptAff1Shift) or
    (QWord((Id shr 16) and $FF) shl SoftwareInterruptAff2Shift) or
    (QWord(Aff0 shr 4) shl SoftwareInterruptRangeShift) or
    (QWord(1) shl (Aff0 and $F));
end;

procedure SendGicV3SoftwareInterrupt(Number: LongWord; TargetProcessorId: LongWord);
begin
  if Distributor = nil then
    Exit;
  ArchSendGicSoftwareInterrupt(SoftwareInterruptValue(Number, TargetProcessorId));
end;

procedure SendGicV3SoftwareInterruptToSelf(Number: LongWord);
begin
  if Distributor = nil then
    Exit;
  ArchSendGicSoftwareInterrupt(SoftwareInterruptValue(Number, LongWord(ReadProcessorAffinity and $FFFFFF)));
end;

procedure SendGicV3SoftwareInterruptToOthers(Number: LongWord);
begin
  if Distributor = nil then
    Exit;
  ArchSendGicSoftwareInterrupt((QWord(Number and $F) shl SoftwareInterruptIdShift) or SoftwareInterruptToOthers);
end;

function ProcessorIndexOf(ProcessorId: LongWord): LongWord;
var
  Index: LongWord;
begin
  Index := 0;
  while Index < ProcessorTotal do
  begin
    if ProcessorByIndex(Index)^.ApicId = ProcessorId then
      Exit(Index);
    Inc(Index);
  end;
  Result := 0;
end;

function ComposeGicV3MessageInterrupt(RequesterId: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  out Address: QWord; out Data: LongWord): Boolean;
var
  Target: TRedistributor;
begin
  Address := 0;
  Data := 0;
  if not TranslationServiceIsReady or not FindRedistributor(TargetProcessorId, Target) then
    Exit(False);
  Result := MapMessageInterrupt(RequesterId, Vector, Target, ProcessorIndexOf(TargetProcessorId), Address, Data);
end;

end.
