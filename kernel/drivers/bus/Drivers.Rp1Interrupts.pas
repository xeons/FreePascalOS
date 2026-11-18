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
  RP1's interrupts, as Linux's drivers/mfd/rp1.c drives them.

  Each of RP1's 61 interrupt sources (Firmware.DeviceTreeRp1) raises the
  MSI-X vector of the same number. RP1 keeps a configuration word per
  source in its PCIe block (PCIE_APBS, at 10_8000h in BAR1), MSIX_CFG(n)
  at 8h + 4n, with set and clear aliases at +800h and +C00h:

    bit 0  enable: the source sends its vector
    bit 2  IACK: written (set alias) after a level interrupt was handled;
           if the source still asserts it, the vector is sent again
    bit 3  IACK_EN: the source is level triggered (needs the IACK)

  Connecting a source (what ConnectPlatformInterrupt does for RP1's
  peripherals): a vector from pcie2's message controller (the MIP, one
  GIC SPI each), the MSI-X table entry of that number written and
  unmasked, the source's trigger and enable set. The kernel's handler
  for the vector calls the peripheral driver's, then acknowledges a
  level source.

  Each source has one handler; RP1's few shared sources (the display
  outputs) are left to whoever comes first.
}
unit Drivers.Rp1Interrupts;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Interrupts,
  Io.Pci,
  Io.PlatformDevices,
  Firmware.DeviceTreeRp1;

type
  PRp1Interrupts = ^TRp1Interrupts;

  PRp1Source = ^TRp1Source;
  TRp1Source = record
    Owner: PRp1Interrupts;
    Number: LongWord;
    LevelTriggered: Boolean;
    Connected: Boolean;
    Handler: TInterruptHandler;
    Context: Pointer;
    Fired: QWord;
  end;

  TRp1Interrupts = record
    Pci: PPciDevice;
    { RP1's PCIe block (BAR1 + 10_8000h), mapped. }
    PcieBlock: PByte;
    Capability: Word;
    Table: PByte;
    TableEntries: LongWord;
    Sources: array[0..Rp1InterruptCount - 1] of TRp1Source;
  end;

{ Finds the MSI-X table, masks every entry, turns MSI-X on. False (with
  a line saying why) if the device has none or it cannot be mapped. }
function StartRp1Interrupts(Interrupts: PRp1Interrupts): Boolean;

{ The TPlatformInterruptConnect of RP1's peripherals (Controller: the
  PRp1Interrupts). }
function ConnectRp1Interrupt(Controller: Pointer; Device: PPlatformDevice; Index: Integer;
  Handler: TInterruptHandler; Context: Pointer): Boolean;

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.TrapFrame,
  Memory.DeviceMapping,
  Io.InterruptRouting,
  Io.PciMessageInterrupts,
  Debug.Output;

const
  RegisterSetAlias = $800;
  RegisterClearAlias = $C00;
  MsixConfigFirst = $8;
  MsixConfigEnable = $1;
  MsixConfigAcknowledge = $4;
  MsixConfigAcknowledgeEnable = $8;

  MessageControlOffset = 2;
  ExtendedControlTableSizeMask = $07FF;
  ExtendedControlFunctionMask = $4000;
  ExtendedControlEnable = $8000;
  ExtendedTableOffset = 4;
  ExtendedTableBarMask = $7;
  ExtendedEntrySize = 16;
  ExtendedEntryVectorControl = 12;
  ExtendedEntryMasked = 1;

procedure WriteMsixConfig(Interrupts: PRp1Interrupts; Alias: LongWord; Number: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Interrupts^.PcieBlock + Alias + MsixConfigFirst + Number * 4)^ := Value;
end;

function ReadMsixConfig(Interrupts: PRp1Interrupts; Number: LongWord): LongWord;
begin
  Result := PLongWord(Interrupts^.PcieBlock + MsixConfigFirst + Number * 4)^;
  FullMemoryBarrier;
end;

procedure WriteTable(Interrupts: PRp1Interrupts; Entry, Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Interrupts^.Table + Entry * ExtendedEntrySize + Offset)^ := Value;
end;

procedure ReportInterrupts(Text: PChar; Value: Int64);
begin
  DebugBeginMessage;
  DebugWriteTag('rp1');
  DebugWrite(Text);
  if Value >= 0 then
  begin
    DebugWrite(' 0x');
    DebugWriteHex(QWord(Value), 1);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

function StartRp1Interrupts(Interrupts: PRp1Interrupts): Boolean;
var
  Pci: PPciDevice;
  Control: Word;
  Location: LongWord;
  Bar: TPciBar;
  Start: QWord;
  Entry: LongWord;
  Number: LongWord;
begin
  Result := False;
  Pci := Interrupts^.Pci;
  for Number := 0 to Rp1InterruptCount - 1 do
  begin
    Interrupts^.Sources[Number].Owner := Interrupts;
    Interrupts^.Sources[Number].Number := Number;
  end;
  Interrupts^.Capability := FindPciCapability(Pci, PciCapabilityExtendedMessageInterrupts);
  if Interrupts^.Capability = 0 then
  begin
    ReportInterrupts('FAILED: no MSI-X capability, status', PciRead16(Pci, PciConfigurationStatus));
    Exit;
  end;
  Control := PciRead16(Pci, Interrupts^.Capability + MessageControlOffset);
  Location := PciRead32(Pci, Interrupts^.Capability + ExtendedTableOffset);
  Interrupts^.TableEntries := (Control and ExtendedControlTableSizeMask) + 1;
  if not PciReadBar(Pci, Integer(Location and ExtendedTableBarMask), Bar) or Bar.IsIoPort or
     (Bar.PhysicalAddress = 0) then
  begin
    ReportInterrupts('FAILED: the MSI-X table''s BAR has no address, table word', Location);
    Exit;
  end;
  Start := Bar.PhysicalAddress + (Location and not LongWord(ExtendedTableBarMask));
  Interrupts^.Table := PByte(MapDeviceMemory(Start, QWord(Interrupts^.TableEntries) * ExtendedEntrySize));
  if Interrupts^.Table = nil then
  begin
    ReportInterrupts('FAILED: the MSI-X table could not be mapped at', Int64(Start));
    Exit;
  end;
  { Masked as a whole while every entry is masked one by one. }
  PciWrite16(Pci, Interrupts^.Capability + MessageControlOffset,
    Control or ExtendedControlFunctionMask or ExtendedControlEnable);
  Entry := 0;
  while Entry < Interrupts^.TableEntries do
  begin
    WriteTable(Interrupts, Entry, ExtendedEntryVectorControl, ExtendedEntryMasked);
    Inc(Entry);
  end;
  { The sources the firmware left enabled stop until connected. }
  for Number := 0 to Rp1InterruptCount - 1 do
    WriteMsixConfig(Interrupts, RegisterClearAlias, Number, MsixConfigEnable);
  PciWrite16(Pci, PciConfigurationCommand, PciRead16(Pci, PciConfigurationCommand) or PciCommandInterruptDisable);
  PciWrite16(Pci, Interrupts^.Capability + MessageControlOffset,
    (Control and not ExtendedControlFunctionMask) or ExtendedControlEnable);

  DebugBeginMessage;
  DebugWriteTag('rp1');
  DebugWrite('MSI-X on: ');
  DebugWriteDecimal(Interrupts^.TableEntries);
  DebugWrite(' vectors, table in BAR');
  DebugWriteDecimal(Location and ExtendedTableBarMask);
  DebugWrite(' at 0x');
  DebugWriteHex(Start, 1);
  DebugWriteLine('');
  DebugEndMessage;
  Result := True;
end;

procedure HandleRp1Vector(Frame: PTrapFrame; Context: Pointer);
var
  Source: PRp1Source;
begin
  Source := PRp1Source(Context);
  Inc(Source^.Fired);
  if Assigned(Source^.Handler) then
    Source^.Handler(Frame, Source^.Context);
  if Source^.LevelTriggered then
    WriteMsixConfig(Source^.Owner, RegisterSetAlias, Source^.Number, MsixConfigAcknowledge);
end;

procedure ReportConnection(Device: PPlatformDevice; Source: PRp1Source; constref Message: TInterruptMessage);
begin
  DebugBeginMessage;
  DebugWriteTag('rp1');
  DebugWrite('interrupt ');
  DebugWriteDecimal(Source^.Number);
  DebugWrite(' (');
  DebugWrite(@Device^.Path[0]);
  DebugWrite('): MSI-X data 0x');
  DebugWriteHex(Message.Data, 1);
  DebugWrite(' to 0x');
  DebugWriteHex(Message.Address, 1);
  if Source^.LevelTriggered then
    DebugWrite(', level')
  else
    DebugWrite(', edge');
  DebugWrite(', cfg 0x');
  DebugWriteHex(ReadMsixConfig(Source^.Owner, Source^.Number), 1);
  DebugWriteLine('');
  DebugEndMessage;
end;

function ConnectRp1Interrupt(Controller: Pointer; Device: PPlatformDevice; Index: Integer;
  Handler: TInterruptHandler; Context: Pointer): Boolean;
var
  Interrupts: PRp1Interrupts;
  Number: LongWord;
  Source: PRp1Source;
  Message: TInterruptMessage;
begin
  Result := False;
  Interrupts := PRp1Interrupts(Controller);
  if (Interrupts = nil) or (Interrupts^.Table = nil) or (Index < 0) or
     (Index >= Device^.Resources.InterruptCount) then
    Exit;
  Number := Device^.Resources.Interrupts[Index].Number;
  if (Number >= Rp1InterruptCount) or (Number >= Interrupts^.TableEntries) then
    Exit;
  Source := @Interrupts^.Sources[Number];
  if Source^.Connected then
  begin
    ReportInterrupts('interrupt already taken by another peripheral:', Number);
    Exit;
  end;
  Source^.LevelTriggered := Device^.Resources.Interrupts[Index].LevelTriggered;
  Source^.Handler := Handler;
  Source^.Context := Context;
  if not ConnectPciMessageVector(Interrupts^.Pci, @HandleRp1Vector, Source, Message) then
  begin
    ReportInterrupts('FAILED: no message vector left for interrupt', Number);
    Exit;
  end;
  Source^.Connected := True;
  WriteTable(Interrupts, Number, 0, LongWord(Message.Address));
  WriteTable(Interrupts, Number, 4, LongWord(Message.Address shr 32));
  WriteTable(Interrupts, Number, 8, Message.Data);
  WriteTable(Interrupts, Number, ExtendedEntryVectorControl, 0);
  if Source^.LevelTriggered then
    WriteMsixConfig(Interrupts, RegisterSetAlias, Number, MsixConfigAcknowledgeEnable)
  else
    WriteMsixConfig(Interrupts, RegisterClearAlias, Number, MsixConfigAcknowledgeEnable);
  WriteMsixConfig(Interrupts, RegisterSetAlias, Number, MsixConfigEnable);
  ReportConnection(Device, Source, Message);
  Result := True;
end;

end.
