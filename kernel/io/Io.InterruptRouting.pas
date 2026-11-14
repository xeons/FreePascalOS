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
  Connecting device interrupts to handlers.

  At startup the I/O APICs listed in the ACPI MADT are set up with every
  input masked (without a MADT, the standard single I/O APIC at
  0xFEC00000 is assumed). A driver then asks for its interrupt; it gets
  one of the device vectors (0x30-0x3F) and its handler runs there, at
  device level.

  Interrupts are spread over the processors: each connection goes to the
  next processor in turn, leaving out the boot processor (which also
  keeps time) when there are others. Drivers connect after the other
  processors were started, so they are all there to choose from.

  A PCI device can instead signal its interrupt by writing a message (a
  value to an address) that the processor's local APIC receives
  directly, with no I/O APIC in between. ConnectMessageInterrupt gives
  the address and value to program into the device
  (Io.PciMessageInterrupts).
}
unit Io.InterruptRouting;

{$mode objfpc}

interface

uses
  Kernel.Interrupts;

type
  { What a device writes, and where, to raise its interrupt. }
  TInterruptMessage = record
    Address: QWord;
    Data: LongWord;
  end;

procedure InitializeInterruptRouting;
function InterruptRoutingIsAvailable: Boolean;

{ Connects ISA IRQ Irq (0-15) to Handler. Returns False if no vector is
  free or the IRQ cannot be routed. }
function ConnectIsaInterrupt(Irq: Byte; Handler: TInterruptHandler; Context: Pointer): Boolean;

{ Connects a message signalled interrupt to Handler. Returns False if no
  vector is free. }
function ConnectMessageInterrupt(Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;

implementation

uses
  Memory.Layout,
  Memory.DeviceMapping,
  Hal.InterruptVectors,
  Hal.IoApic,
  Firmware.Madt,
  Kernel.Processors,
  Debug.Output;

const
  StandardIoApicAddress = $FEC00000;
  { Messages written into this window reach a local APIC; bits 12-19
    pick which one. The data is the vector (fixed delivery, edge). }
  MessageAddressBase = $FEE00000;
  MessageDestinationShift = 12;
  IoApicRegisterWindowSize = $1000;

var
  Available: Boolean = False;
  { The processor the last interrupt was given to. }
  LastTargetIndex: LongWord = 0;
  NextVector: Integer = DeviceInterruptVectorFirst;

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

procedure InitializeInterruptRouting;
var
  Index: Integer;
  Description: TIoApicDescription;
begin
  if ParseMadt then
    for Index := 0 to IoApicCount - 1 do
    begin
      Description := IoApicDescription(Index);
      AddMappedIoApic(Description.PhysicalAddress, Description.GlobalInterruptBase);
    end
  else
    AddMappedIoApic(StandardIoApicAddress, 0);

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

function InterruptRoutingIsAvailable: Boolean;
begin
  Result := Available;
end;

{ The next processor to take a device interrupt. }
function ChooseTargetProcessor: PProcessor;
var
  Steps: LongWord;
begin
  if OnlineProcessorCount <= 1 then
    Exit(CurrentProcessor);
  Steps := 0;
  repeat
    LastTargetIndex := (LastTargetIndex + 1) mod ProcessorTotal;
    Result := ProcessorByIndex(LastTargetIndex);
    Inc(Steps);
  until ((LastTargetIndex <> 0) and Result^.IsOnline) or (Steps > ProcessorTotal);
  if not Result^.IsOnline then
    Result := CurrentProcessor;
end;

procedure ReportConnection(Source: PChar; Number: LongInt; Vector: Byte; Target: PProcessor);
begin
  DebugBeginMessage;
  DebugWriteTag('interrupts');
  DebugWrite(Source);
  if Number >= 0 then
  begin
    DebugWrite(' ');
    DebugWriteDecimal(Number);
  end;
  DebugWrite(' on vector 0x');
  DebugWriteHex(Vector, 2);
  DebugWrite(', processor ');
  DebugWriteDecimal(Target^.Index);
  DebugWriteLine('');
  DebugEndMessage;
end;

function AllocateVector(Handler: TInterruptHandler; Context: Pointer; out Vector: Byte): Boolean;
begin
  Vector := 0;
  if NextVector >= DeviceInterruptVectorFirst + DeviceInterruptVectorCount then
    Exit(False);
  Vector := Byte(NextVector);
  if not RegisterInterruptHandler(Vector, Handler, Context) then
    Exit(False);
  Inc(NextVector);
  Result := True;
end;

{ Gives back the vector just allocated. }
procedure ReleaseLastVector(Vector: Byte);
begin
  UnregisterInterruptHandler(Vector);
  Dec(NextVector);
end;

function ConnectIsaInterrupt(Irq: Byte; Handler: TInterruptHandler; Context: Pointer): Boolean;
var
  Routing: TIsaInterruptRouting;
  Vector: Byte;
  Target: PProcessor;
begin
  if not Available or not AllocateVector(Handler, Context, Vector) then
    Exit(False);
  Routing := RoutingOfIsaInterrupt(Irq);
  Target := ChooseTargetProcessor;
  if not RouteGlobalInterrupt(Routing.GlobalInterrupt, Vector, Byte(Target^.ApicId),
    Routing.ActiveLow, Routing.LevelTriggered) then
  begin
    ReleaseLastVector(Vector);
    Exit(False);
  end;
  ReportConnection('IRQ', Irq, Vector, Target);
  Result := True;
end;

function ConnectMessageInterrupt(Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;
var
  Vector: Byte;
  Target: PProcessor;
begin
  Message.Address := 0;
  Message.Data := 0;
  if not AllocateVector(Handler, Context, Vector) then
    Exit(False);
  Target := ChooseTargetProcessor;
  Message.Address := MessageAddressBase or (QWord(Target^.ApicId and $FF) shl MessageDestinationShift);
  Message.Data := Vector;
  ReportConnection('Message interrupt', -1, Vector, Target);
  Result := True;
end;

end.
