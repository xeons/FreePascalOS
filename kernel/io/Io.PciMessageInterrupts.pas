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
  asserting an interrupt line. That needs no routing tables (lines are
  routed with the ACPI namespace: Io.PciLineInterrupts), and the
  interrupt is never shared with another device, so drivers prefer it.

  The capability: a message control word at offset 2 (bit 0 enables
  MSI, bit 7 means 64-bit addresses, bits 4-6 how many vectors are in
  use - left at one), then the address (low, and high if 64-bit) and the
  16-bit data value.

  Where the messages go: by default to the interrupt routing's own
  receiver (Io.InterruptRouting: the local APIC, a GICv2m frame). A host
  bridge whose devices write their messages somewhere else (the Pi 5's
  PCIe, into the BCM2712's MIP) registers a message controller for its
  segment (RegisterPciMessageController), and every vector of a device
  on that segment comes from it.
}
unit Io.PciMessageInterrupts;

{$mode objfpc}

interface

uses
  Kernel.Interrupts,
  Io.InterruptRouting,
  Io.Pci;

type
  TPciInterruptKind = (PciInterruptNone, PciInterruptMessage, PciInterruptExtendedMessage);

  { Connects Handler to a fresh vector of a message controller and says
    what a device writes, and where, to raise it. }
  TPciMessageControllerConnect = function(Controller: Pointer; Handler: TInterruptHandler; Context: Pointer;
    out Message: TInterruptMessage): Boolean;

{ The messages of the devices on Segment go to Controller. }
procedure RegisterPciMessageController(Segment: Word; Connect: TPciMessageControllerConnect;
  Controller: Pointer);

{ A vector for Device, from its segment's message controller (or the
  interrupt routing's): Handler runs when Device writes Message. For
  drivers that program the device's table themselves (RP1's MSI-X). }
function ConnectPciMessageVector(Device: PPciDevice; Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;

{ Connects Handler to Device's interrupt by MSI and turns its legacy
  interrupt line off. Returns False if the device has no MSI capability
  or no vector is free. }
function ConnectPciMessageInterrupt(Device: PPciDevice; Handler: TInterruptHandler;
  Context: Pointer): Boolean;

{ Connects Handler to entry 0 of Device's MSI-X table (all other entries
  stay masked) and turns MSI-X on. False if the device has no MSI-X
  capability or no vector is free. A device then signals the interrupts
  it is told to send through entry 0. }
function ConnectPciExtendedMessageInterrupt(Device: PPciDevice; Handler: TInterruptHandler;
  Context: Pointer): Boolean;

{ MSI-X if the device has it, else MSI. }
function ConnectPciInterrupt(Device: PPciDevice; Handler: TInterruptHandler;
  Context: Pointer): TPciInterruptKind;

{ MSI-X tables are in device memory, which waking from suspend to RAM
  resets (MSI lives in configuration space, which Io.Pci restores):
  every table entry programmed is written again. }
procedure RegisterMessageInterruptPowerHandler;

implementation

uses
  Memory.DeviceMapping,
  Io.PowerManagement;

const
  MaximumMessageControllers = 8;

type
  TMessageControllerEntry = record
    Segment: Word;
    Connect: TPciMessageControllerConnect;
    Controller: Pointer;
  end;

var
  MessageControllers: array[0..MaximumMessageControllers - 1] of TMessageControllerEntry;
  MessageControllerCount: Integer;

procedure RegisterPciMessageController(Segment: Word; Connect: TPciMessageControllerConnect;
  Controller: Pointer);
begin
  if MessageControllerCount >= MaximumMessageControllers then
    Exit;
  MessageControllers[MessageControllerCount].Segment := Segment;
  MessageControllers[MessageControllerCount].Connect := Connect;
  MessageControllers[MessageControllerCount].Controller := Controller;
  Inc(MessageControllerCount);
end;

function ConnectPciMessageVector(Device: PPciDevice; Handler: TInterruptHandler; Context: Pointer;
  out Message: TInterruptMessage): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to MessageControllerCount - 1 do
    if MessageControllers[Index].Segment = Device^.Segment then
      Exit(MessageControllers[Index].Connect(MessageControllers[Index].Controller, Handler, Context, Message));
  Result := ConnectMessageInterrupt(Handler, Context, Message);
end;

const
  MessageControlOffset = 2;
  MessageAddressOffset = 4;
  MessageControlEnable = $0001;
  MessageControl64Bit = $0080;
  MessageControlVectorsInUse = $0070;

  ExtendedControlTableSizeMask = $07FF;
  ExtendedControlFunctionMask = $4000;
  ExtendedControlEnable = $8000;
  ExtendedTableOffset = 4;
  ExtendedTableBarMask = $7;
  ExtendedEntrySize = 16;
  ExtendedEntryAddressLow = 0;
  ExtendedEntryAddressHigh = 4;
  ExtendedEntryData = 8;
  ExtendedEntryVectorControl = 12;
  ExtendedEntryMasked = 1;

function ConnectPciMessageInterrupt(Device: PPciDevice; Handler: TInterruptHandler;
  Context: Pointer): Boolean;
var
  Capability: Word;
  Control: Word;
  Message: TInterruptMessage;
  DataOffset: Word;
begin
  Result := False;
  Capability := FindPciCapability(Device, PciCapabilityMessageInterrupts);
  if Capability = 0 then
    Exit;
  if not ConnectPciMessageVector(Device, Handler, Context, Message) then
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

type
  { An MSI-X table this unit programmed. }
  TProgrammedTable = record
    Device: PPciDevice;
    Capability: Word;
    Table: PByte;
    EntryCount: LongWord;
    Message: TInterruptMessage;
  end;

const
  MaximumProgrammedTables = 32;

var
  ProgrammedTables: array[0..MaximumProgrammedTables - 1] of TProgrammedTable;
  ProgrammedTableCount: Integer;

{ Fills Table: every entry masked but the first, which sends Message;
  then MSI-X on (the legacy line off). }
procedure ProgramExtendedTable(const Programmed: TProgrammedTable);
var
  Control: Word;
  Entry: LongWord;
begin
  Control := PciRead16(Programmed.Device, Programmed.Capability + MessageControlOffset);
  { Masked as a whole while the table is filled in. }
  PciWrite16(Programmed.Device, Programmed.Capability + MessageControlOffset,
    Control or ExtendedControlFunctionMask or ExtendedControlEnable);
  for Entry := 0 to Programmed.EntryCount - 1 do
    PLongWord(Programmed.Table + Entry * ExtendedEntrySize + ExtendedEntryVectorControl)^ := ExtendedEntryMasked;
  PLongWord(Programmed.Table + ExtendedEntryAddressLow)^ := LongWord(Programmed.Message.Address);
  PLongWord(Programmed.Table + ExtendedEntryAddressHigh)^ := LongWord(Programmed.Message.Address shr 32);
  PLongWord(Programmed.Table + ExtendedEntryData)^ := Programmed.Message.Data;
  PLongWord(Programmed.Table + ExtendedEntryVectorControl)^ := 0;
  PciWrite16(Programmed.Device, PciConfigurationCommand,
    PciRead16(Programmed.Device, PciConfigurationCommand) or PciCommandInterruptDisable);
  PciWrite16(Programmed.Device, Programmed.Capability + MessageControlOffset,
    (Control and not ExtendedControlFunctionMask) or ExtendedControlEnable);
end;

procedure ReprogramTables(Context: Pointer);
var
  Index: Integer;
begin
  for Index := 0 to ProgrammedTableCount - 1 do
    ProgramExtendedTable(ProgrammedTables[Index]);
end;

procedure RegisterMessageInterruptPowerHandler;
begin
  { After Io.PCI's handler (registered earlier, same stage). }
  RegisterPowerHandler('MSI-X tables', PowerStagePlatform, nil, @ReprogramTables, nil);
end;

function ConnectPciExtendedMessageInterrupt(Device: PPciDevice; Handler: TInterruptHandler;
  Context: Pointer): Boolean;
var
  Capability: Word;
  Control: Word;
  TableLocation: LongWord;
  Bar: TPciBar;
  EntryCount: LongWord;
  TableBytes: QWord;
  MapStart: QWord;
  MapOffset: QWord;
  Table: PByte;
  Message: TInterruptMessage;
  Programmed: TProgrammedTable;
begin
  Result := False;
  Capability := FindPciCapability(Device, PciCapabilityExtendedMessageInterrupts);
  if Capability = 0 then
    Exit;
  Control := PciRead16(Device, Capability + MessageControlOffset);
  TableLocation := PciRead32(Device, Capability + ExtendedTableOffset);
  if not PciReadBar(Device, Integer(TableLocation and ExtendedTableBarMask), Bar) or Bar.IsIoPort then
    Exit;
  EntryCount := (Control and ExtendedControlTableSizeMask) + 1;
  TableBytes := QWord(EntryCount) * ExtendedEntrySize;
  { Mapped from its page; the table stays mapped while the device lives. }
  MapStart := (Bar.PhysicalAddress + (TableLocation and not ExtendedTableBarMask)) and not QWord($FFF);
  MapOffset := (Bar.PhysicalAddress + (TableLocation and not ExtendedTableBarMask)) and QWord($FFF);
  Table := PByte(MapDeviceMemory(MapStart, MapOffset + TableBytes));
  if Table = nil then
    Exit;
  Table := Table + MapOffset;
  if not ConnectPciMessageVector(Device, Handler, Context, Message) then
    Exit;

  Programmed.Device := Device;
  Programmed.Capability := Capability;
  Programmed.Table := Table;
  Programmed.EntryCount := EntryCount;
  Programmed.Message := Message;
  ProgramExtendedTable(Programmed);
  if ProgrammedTableCount < MaximumProgrammedTables then
  begin
    ProgrammedTables[ProgrammedTableCount] := Programmed;
    Inc(ProgrammedTableCount);
  end;
  Result := True;
end;

function ConnectPciInterrupt(Device: PPciDevice; Handler: TInterruptHandler;
  Context: Pointer): TPciInterruptKind;
begin
  if ConnectPciExtendedMessageInterrupt(Device, Handler, Context) then
    Result := PciInterruptExtendedMessage
  else if ConnectPciMessageInterrupt(Device, Handler, Context) then
    Result := PciInterruptMessage
  else
    Result := PciInterruptNone;
end;

end.
