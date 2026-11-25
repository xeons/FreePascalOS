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

var
  Available: Boolean = False;
  { The boot processor's APIC id: where an interrupt for a processor
    that cannot be named goes instead. }
  FallbackApicId: LongWord = 0;

{ TargetProcessorId if a device can name it, else the boot processor
  (an x2APIC id above 255 would be cut to its low 8 bits: another
  processor, or none). }
function ReachableApicId(TargetProcessorId: LongWord): LongWord;
begin
  if TargetProcessorId <= HighestReachableApicId then
    Result := TargetProcessorId
  else
    Result := FallbackApicId;
end;

procedure AddMappedIoApic(PhysicalAddress: TPhysicalAddress; GlobalInterruptBase: LongWord);
var
  Registers: Pointer;
begin
  Registers := MapDeviceMemory(PhysicalAddress, IoApicRegisterWindowSize);
  if Registers = nil then
    Exit;
  if AddIoApic(Registers, GlobalInterruptBase) then
    Available := True;
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
      AddMappedIoApic(Description.PhysicalAddress, Description.GlobalInterruptBase);
    end
  else
    AddMappedIoApic(StandardIoApicAddress, 0);
  Result := Available;
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

function RouteDeviceInterrupt(Gsi: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  ActiveLow, LevelTriggered: Boolean): Boolean;
begin
  Result := RouteGlobalInterrupt(Gsi, Vector, Byte(ReachableApicId(TargetProcessorId)), ActiveLow,
    LevelTriggered);
end;

function ComposeMessageInterrupt(RequesterId: LongWord; Vector: Byte; TargetProcessorId: LongWord;
  out Address: QWord; out Data: LongWord): Boolean;
begin
  Address := MessageAddressBase or (QWord(ReachableApicId(TargetProcessorId)) shl MessageDestinationShift);
  Data := Vector;
  Result := True;
end;

end.
