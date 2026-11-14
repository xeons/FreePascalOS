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
  Message signalled interrupts (MSI) for PCI devices.

  A device that has the MSI capability in its configuration space can
  raise its interrupt by writing a value to an address, instead of
  asserting an interrupt line. That needs no routing tables (the legacy
  lines of PCI devices could only be routed with the ACPI namespace,
  which this kernel does not interpret), and the interrupt is never
  shared with another device.

  The capability: a message control word at offset 2 (bit 0 enables
  MSI, bit 7 means 64-bit addresses, bits 4-6 how many vectors are in
  use - left at one), then the address (low, and high if 64-bit) and the
  16-bit data value.
}
unit Io.PciMessageInterrupts;

{$mode objfpc}

interface

uses
  Kernel.Interrupts,
  Io.Pci;

{ Connects Handler to Device's interrupt by MSI and turns its legacy
  interrupt line off. Returns False if the device has no MSI capability
  or no vector is free. }
function ConnectPciMessageInterrupt(Device: PPciDevice; Handler: TInterruptHandler;
  Context: Pointer): Boolean;

implementation

uses
  Io.InterruptRouting;

const
  PciConfigurationCapabilitiesPointer = $34;
  PciStatusHasCapabilities = $0010;
  CapabilityMessageInterrupts = $05;
  MaximumCapabilities = 48;

  MessageControlOffset = 2;
  MessageAddressOffset = 4;
  MessageControlEnable = $0001;
  MessageControl64Bit = $0080;
  MessageControlVectorsInUse = $0070;

{ The offset of capability CapabilityId in Device's configuration space,
  or 0. }
function FindCapability(Device: PPciDevice; CapabilityId: Byte): Word;
var
  Offset: Word;
  Steps: Integer;
begin
  Result := 0;
  if (PciRead16(Device, PciConfigurationStatus) and PciStatusHasCapabilities) = 0 then
    Exit;
  Offset := PciRead8(Device, PciConfigurationCapabilitiesPointer) and $FC;
  Steps := 0;
  { The list is linked through the second byte of each entry; the step
    limit guards against a broken, circular list. }
  while (Offset <> 0) and (Steps < MaximumCapabilities) do
  begin
    if PciRead8(Device, Offset) = CapabilityId then
      Exit(Offset);
    Offset := PciRead8(Device, Offset + 1) and $FC;
    Inc(Steps);
  end;
end;

function ConnectPciMessageInterrupt(Device: PPciDevice; Handler: TInterruptHandler;
  Context: Pointer): Boolean;
var
  Capability: Word;
  Control: Word;
  Message: TInterruptMessage;
  DataOffset: Word;
begin
  Result := False;
  Capability := FindCapability(Device, CapabilityMessageInterrupts);
  if Capability = 0 then
    Exit;
  if not ConnectMessageInterrupt(Handler, Context, Message) then
    Exit;

  Control := PciRead16(Device, Capability + MessageControlOffset);
  PciWrite32(Device, Capability + MessageAddressOffset, LongWord(Message.Address));
  if (Control and MessageControl64Bit) <> 0 then
  begin
    PciWrite32(Device, Capability + MessageAddressOffset + 4, LongWord(Message.Address shr 32));
    DataOffset := Capability + MessageAddressOffset + 8;
  end
  else
    DataOffset := Capability + MessageAddressOffset + 4;
  PciWrite16(Device, DataOffset, Word(Message.Data));

  PciWrite16(Device, PciConfigurationCommand,
    PciRead16(Device, PciConfigurationCommand) or PciCommandInterruptDisable);
  Control := (Control and not MessageControlVectorsInUse) or MessageControlEnable;
  PciWrite16(Device, Capability + MessageControlOffset, Control);
  Result := True;
end;

end.
