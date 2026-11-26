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
  Routing device interrupts on x86-64: the I/O APICs the ACPI MADT lists
  (or the standard one at FEC00000h), and message signalled interrupts
  written straight into a local APIC's window. Io.InterruptRouting picks
  the vectors and processors; this unit programs the hardware.
}
unit Hal.InterruptController;

{$mode objfpc}

interface

{ Finds and maps the interrupt controllers. Call after ParseMadt.
  False if device interrupts cannot be routed. }
function InitializeDeviceInterruptRouting(MadtWasParsed: Boolean): Boolean;

{ Describes the routing for the boot log ("I/O APIC routing, 24 inputs"). }
procedure WriteDeviceInterruptRouting;

{ Sends global system interrupt Gsi to processor TargetProcessorId as
  Vector, triggered and polarized as given, and unmasks it. }
function RouteDeviceInterrupt(Gsi: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  ActiveLow, LevelTriggered: Boolean): Boolean;

{ Keeps global system interrupt Gsi for a timer of the platform (the
  HPET's comparator, Hal.HpetInterrupts) and routes it to processor
  TargetProcessorId as Vector: RouteDeviceInterrupt refuses it from
  then on, so a driver cannot take the line over. False if it cannot be
  routed or is kept already. }
function RoutePlatformTimerInterrupt(Gsi: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  ActiveLow, LevelTriggered: Boolean): Boolean;
{ Masks a kept input and gives it up again. }
procedure ReleasePlatformTimerInterrupt(Gsi: LongWord);
{ Whether Gsi exists on an I/O APIC and nothing keeps it. }
function DeviceInterruptIsFree(Gsi: LongWord): Boolean;

{ After a device interrupt's end at the local APIC: level triggered
  lines remapped by an AMD IOMMU (whose messages reach the local APIC as
  edge triggered, so it broadcasts no end of interrupt) get theirs at
  the I/O APIC. }
procedure EndRemappedLevelInterrupt;

{ What a device writes, and where, to raise Vector on processor
  TargetProcessorId. False if the platform has no message interrupts. }
function ComposeMessageInterrupt(RequesterId: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  out Address: QWord; out Data: LongWord): Boolean;

implementation

uses
  Memory.Layout,
  Memory.DeviceMapping,
  Firmware.Madt,
  Hal.IoApic,
  Hal.LocalApic,
  Hal.InterruptRemapping,
  Debug.Output;

const
  StandardIoApicAddress = $FEC00000;
  IoApicRegisterWindowSize = $1000;
  { Messages written into this window reach a local APIC; bits 12-19
    pick which one. The data is the vector (fixed delivery, edge). }
  MessageAddressBase = $FEE00000;
  MessageDestinationShift = 12;

  { Without interrupt remapping, I/O APIC entries and messages name a
    processor in 8 bits. }
  HighestReachableApicId = 255;

  MaximumIoApics = 8;

var
  Available: Boolean = False;
  { The I/O APICs' ids, in the order added (Hal.IoApic's numbers). }
  IoApicIds: array[0..MaximumIoApics - 1] of Byte;
  IoApicIdCount: Integer = 0;
  { Per vector: the GSI of an AMD-remapped level line on it, +1 (0:
    none), and the I/O APIC entry's vector field. }
  LevelLineOfVector: array[0..255] of LongWord;
  LevelEntryVector: array[0..255] of Byte;
  LevelLinesRemapped: Boolean = False;
  { The boot processor's APIC id: where an interrupt for a processor
    that cannot be named goes instead. }
  FallbackApicId: LongWord = 0;
  { The inputs platform timers keep (RoutePlatformTimerInterrupt). }
  KeptInputs: array[0..7] of LongWord;
  KeptInputCount: Integer = 0;

{ TargetProcessorId if a device can name it, else the boot processor
  (an x2APIC id above 255 would be cut to its low 8 bits: another
  processor, or none). With interrupt remapping every id can be named. }
function ReachableApicId(TargetProcessorId: LongWord): LongWord;
begin
  if (TargetProcessorId <= HighestReachableApicId) or (InterruptRemappingKind <> RemappingNone) then
    Result := TargetProcessorId
  else
    Result := FallbackApicId;
end;

procedure AddMappedIoApic(PhysicalAddress: TPhysicalAddress; GlobalInterruptBase: LongWord; Id: Byte);
var
  Registers: Pointer;
begin
  Registers := MapDeviceMemory(PhysicalAddress, IoApicRegisterWindowSize);
  if Registers = nil then
    Exit;
  if AddIoApic(Registers, GlobalInterruptBase) then
  begin
    Available := True;
    if IoApicIdCount < MaximumIoApics then
    begin
      IoApicIds[IoApicIdCount] := Id;
      Inc(IoApicIdCount);
    end;
  end;
end;

function InitializeDeviceInterruptRouting(MadtWasParsed: Boolean): Boolean;
var
  Index: Integer;
  Description: TIoApicDescription;
begin
  { On the boot processor. }
  FallbackApicId := LocalApicId;
  if MadtWasParsed then
    for Index := 0 to IoApicCount - 1 do
    begin
      Description := IoApicDescription(Index);
      AddMappedIoApic(Description.PhysicalAddress, Description.GlobalInterruptBase, Description.Id);
    end
  else
    AddMappedIoApic(StandardIoApicAddress, 0, 0);
  Result := Available;
  if Result then
    StartInterruptRemapping;
end;

procedure WriteDeviceInterruptRouting;
begin
  DebugBeginMessage;
  DebugWriteTag('interrupts');
  if Available then
  begin
    DebugWrite('I/O APIC routing, ');
    DebugWriteDecimal(IoApicInputCount);
    DebugWriteLine(' inputs');
  end
  else
    DebugWriteLine('No I/O APIC; device interrupts unavailable');
  DebugEndMessage;
end;

function InputIsKept(Gsi: LongWord): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to KeptInputCount - 1 do
    if KeptInputs[Index] = Gsi then
      Exit(True);
  Result := False;
end;

function DeviceInterruptIsFree(Gsi: LongWord): Boolean;
begin
  Result := Available and (IoApicIndexOfGsi(Gsi) >= 0) and not InputIsKept(Gsi);
end;

function RouteUnkeptInterrupt(Gsi: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  ActiveLow, LevelTriggered: Boolean): Boolean; forward;

function RoutePlatformTimerInterrupt(Gsi: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  ActiveLow, LevelTriggered: Boolean): Boolean;
begin
  if not DeviceInterruptIsFree(Gsi) or (KeptInputCount > High(KeptInputs)) then
    Exit(False);
  Result := RouteUnkeptInterrupt(Gsi, Vector, TargetProcessorId, ActiveLow, LevelTriggered);
  if Result then
  begin
    KeptInputs[KeptInputCount] := Gsi;
    Inc(KeptInputCount);
  end;
end;

procedure ReleasePlatformTimerInterrupt(Gsi: LongWord);
var
  Index: Integer;
begin
  MaskGlobalInterrupt(Gsi);
  for Index := 0 to KeptInputCount - 1 do
    if KeptInputs[Index] = Gsi then
    begin
      KeptInputs[Index] := KeptInputs[KeptInputCount - 1];
      Dec(KeptInputCount);
      Exit;
    end;
end;

function RouteDeviceInterrupt(Gsi: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  ActiveLow, LevelTriggered: Boolean): Boolean;
begin
  if InputIsKept(Gsi) then
    Exit(False);
  Result := RouteUnkeptInterrupt(Gsi, Vector, TargetProcessorId, ActiveLow, LevelTriggered);
end;

function RouteUnkeptInterrupt(Gsi: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  ActiveLow, LevelTriggered: Boolean): Boolean;
var
  Index: Integer;
  Low: LongWord;
  High: LongWord;
begin
  if InterruptRemappingKind <> RemappingNone then
  begin
    Index := IoApicIndexOfGsi(Gsi);
    Result := (Index >= 0) and (Index < IoApicIdCount) and
      RemapIoApicEntry(IoApicIds[Index], Vector, TargetProcessorId, ActiveLow, LevelTriggered, Low, High) and
      WriteGlobalInterruptEntry(Gsi, Low, High);
    if Result and LevelTriggered and (InterruptRemappingKind = RemappingAmd) then
    begin
      LevelEntryVector[Vector] := Byte(Low);
      LevelLineOfVector[Vector] := Gsi + 1;
      LevelLinesRemapped := True;
    end;
    Exit;
  end;
  Result := RouteGlobalInterrupt(Gsi, Vector, Byte(ReachableApicId(TargetProcessorId)), ActiveLow,
    LevelTriggered);
end;

procedure EndRemappedLevelInterrupt;
var
  Vector: LongInt;
begin
  if not LevelLinesRemapped then
    Exit;
  Vector := LocalApicVectorInService;
  if (Vector >= 0) and (LevelLineOfVector[Vector] <> 0) then
    EndIoApicInterrupt(LevelLineOfVector[Vector] - 1, LevelEntryVector[Vector]);
end;

function ComposeMessageInterrupt(RequesterId: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  out Address: QWord; out Data: LongWord): Boolean;
begin
  if InterruptRemappingKind <> RemappingNone then
    Exit(RemapMessage(RequesterId, Vector, TargetProcessorId, Address, Data));
  Address := MessageAddressBase or (QWord(ReachableApicId(TargetProcessorId)) shl MessageDestinationShift);
  Data := Vector;
  Result := True;
end;

end.
