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
  Host test of the ACPI platform device discovery (make acpi-device-test):

    - the kernel's AML interpreter loads a DSDT that make-table.py
      assembles, laid out like the Raspberry Pi 4 firmware's, and
      Firmware.AcpiDeviceWalk walks it: which devices are found (not the
      absent one, nor its child), their ids (strings and EISA ids, _CID
      as a package), _UID, _CRS (fixed and quad word memory, interrupts,
      I/O ports, a _CRS that is a method), _CCA and _DMA inherited from
      the container, _SEG;
    - Firmware.AcpiProperties reads the Ethernet controller's _DSD;
    - Firmware.AcpiResourceList decodes descriptors the table does not
      have (IRQ, fixed I/O, 24-bit memory, word and extended address
      space) and stops at a damaged template.

  Prints every failed check and exits with 1 if there was one. With
  "--list" after the table it also lists the devices it found.
}
program AcpiDeviceTest;

{$mode objfpc}
{$pointermath on}

uses
  Firmware.AmlHost,
  Firmware.AmlValues,
  Firmware.AmlNamespace,
  Firmware.AmlInterpreter,
  Firmware.AcpiResourceList,
  Firmware.AcpiProperties,
  Firmware.AcpiDeviceWalk;

const
  MaximumDevices = 16;

var
  Devices: array[0..MaximumDevices - 1] of TAcpiDeviceDescription;
  DeviceCount: Integer;
  Failures: Integer;

{ --- The host ------------------------------------------------------------------ }

function HostAllocate(ByteCount: PtrUInt): Pointer;
begin
  Result := AllocMem(ByteCount);
end;

procedure HostFree(Block: Pointer);
begin
  FreeMem(Block);
end;

function HostRead(Space: Byte; Address: QWord; Width: Byte; out Value: QWord): Boolean;
begin
  Value := 0;
  Result := False;
end;

function HostWrite(Space: Byte; Address: QWord; Width: Byte; Value: QWord): Boolean;
begin
  Result := False;
end;

procedure HostSleep(Milliseconds: QWord);
begin
end;

procedure HostStall(Microseconds: QWord);
begin
end;

function HostTimer: QWord;
begin
  Result := 0;
end;

procedure HostLog(Text: PChar);
begin
  WriteLn('log: ', Text);
end;

procedure SetUpHost;
begin
  AmlHost.Allocate := @HostAllocate;
  AmlHost.Free := @HostFree;
  AmlHost.ReadSpace := @HostRead;
  AmlHost.WriteSpace := @HostWrite;
  AmlHost.Sleep := @HostSleep;
  AmlHost.Stall := @HostStall;
  AmlHost.Timer := @HostTimer;
  AmlHost.Log := @HostLog;
end;

function ReadTable(FileName: string): PByte;
var
  TableFile: File;
  Size: Int64;
begin
  Assign(TableFile, FileName);
  Reset(TableFile, 1);
  Size := FileSize(TableFile);
  Result := GetMem(Size);
  BlockRead(TableFile, Result^, Size);
  Close(TableFile);
end;

{ --- Checking ---------------------------------------------------------------- }

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('FAILED: ', What);
    Inc(Failures);
  end;
end;

procedure CheckNumber(Actual, Expected: QWord; const What: string);
begin
  if Actual <> Expected then
  begin
    WriteLn('FAILED: ', What, ': $', HexStr(Actual, 16), ' instead of $', HexStr(Expected, 16));
    Inc(Failures);
  end;
end;

procedure RememberDevice(var Description: TAcpiDeviceDescription; Context: Pointer);
begin
  if DeviceCount < MaximumDevices then
  begin
    Devices[DeviceCount] := Description;
    Inc(DeviceCount);
  end;
end;

function DeviceAt(Path: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to DeviceCount - 1 do
    if string(PChar(@Devices[Index].Path[0])) = Path then
      Exit(Index);
  WriteLn('FAILED: no device ', Path);
  Inc(Failures);
  Result := -1;
end;

procedure CheckMailbox;
var
  Index: Integer;
begin
  Index := DeviceAt('\_SB_.GDV0.RPIQ');
  if Index < 0 then
    Exit;
  with Devices[Index] do
  begin
    Check(string(PChar(@HardwareId[0])) = 'BCM2849', 'mailbox hardware id');
    CheckNumber(Resources.MemoryCount, 1, 'mailbox memory ranges');
    CheckNumber(Resources.Memory[0].Start, $FE00B880, 'mailbox registers');
    CheckNumber(Resources.Memory[0].Length, $24, 'mailbox register length');
    Check(HasCoherency and not Coherent, 'mailbox inherits _CCA 0');
    Check(HasDma, 'mailbox inherits _DMA');
    CheckNumber(DmaRanges.MemoryCount, 1, 'DMA windows');
    CheckNumber(DmaRanges.Memory[0].Start, 0, 'DMA window processor address');
    CheckNumber(DmaRanges.Memory[0].BusStart, $C0000000, 'DMA window bus address');
    CheckNumber(DmaRanges.Memory[0].Length, $40000000, 'DMA window length');
  end;
end;

procedure CheckSdController;
var
  Index: Integer;
begin
  Index := DeviceAt('\_SB_.GDV0.SDC3');
  if Index < 0 then
    Exit;
  with Devices[Index] do
  begin
    Check(string(PChar(@HardwareId[0])) = 'BRCME88C', 'EMMC2 hardware id');
    CheckNumber(UniqueId, 1, 'EMMC2 _UID');
    CheckNumber(Resources.MemoryCount, 1, 'EMMC2 memory ranges (from a _CRS method)');
    CheckNumber(Resources.Memory[0].Start, $FE340000, 'EMMC2 registers');
    CheckNumber(Resources.InterruptCount, 1, 'EMMC2 interrupts');
    CheckNumber(Resources.Interrupts[0].Number, $9E, 'EMMC2 interrupt');
    Check(Resources.Interrupts[0].LevelTriggered and not Resources.Interrupts[0].ActiveLow and
      not Resources.Interrupts[0].IsIsaIrq, 'EMMC2 interrupt: level, active high, a GSI');
  end;
end;

procedure CheckEthernet;
var
  Index: Integer;
  Address: array[0..7] of Byte;
  Length: LongWord;
  Text: array[0..31] of Char;
  Number: QWord;
begin
  Index := DeviceAt('\_SB_.GDV0.ETH0');
  if Index < 0 then
    Exit;
  with Devices[Index] do
  begin
    CheckNumber(CompatibleIdCount, 1, 'GENET compatible ids (a single string)');
    Check(string(PChar(@CompatibleIds[0][0])) = 'BCM6E4E', 'GENET compatible id');
    CheckNumber(Resources.InterruptCount, 2, 'GENET interrupts');
    CheckNumber(Resources.Interrupts[1].Number, $BE, 'GENET second interrupt');
    Check(Properties.Kind = AmlPackage, 'GENET _DSD kept');
    Check(DevicePropertyBytes(Properties, 'local-mac-address', @Address[0], SizeOf(Address), Length),
      'local-mac-address found');
    CheckNumber(Length, 6, 'local-mac-address length');
    CheckNumber(Address[0], $DC, 'local-mac-address first byte');
    CheckNumber(Address[5], $03, 'local-mac-address last byte');
    Check(DevicePropertyText(Properties, 'phy-mode', @Text[0], SizeOf(Text)) and
      (string(PChar(@Text[0])) = 'rgmii-rxid'), 'phy-mode text');
    Check(DevicePropertyInteger(Properties, 'phy-address', Number) and (Number = 1), 'phy-address integer');
    Check(DevicePropertyBytes(Properties, 'byte-list', @Address[0], SizeOf(Address), Length) and
      (Length = 3) and (Address[2] = 3), 'a package of integers as bytes');
    Check(not DevicePropertyInteger(Properties, 'missing', Number), 'a missing property');
    Check(not DevicePropertyInteger(Properties, 'phy-mode', Number), 'a text property is no integer');
  end;
end;

procedure CheckXhci;
var
  Index: Integer;
begin
  Index := DeviceAt('\_SB_.XHC0');
  if Index < 0 then
    Exit;
  with Devices[Index] do
  begin
    Check(string(PChar(@HardwareId[0])) = 'PNP0D10', 'xHCI EISA hardware id');
    CheckNumber(CompatibleIdCount, 2, 'xHCI compatible ids (a package)');
    Check(string(PChar(@CompatibleIds[1][0])) = 'XHCI0001', 'xHCI second compatible id');
    Check(HasCoherency and Coherent, 'xHCI _CCA 1');
    Check(not HasDma, 'xHCI has no _DMA');
    CheckNumber(Resources.MemoryCount, 1, 'xHCI memory ranges');
    CheckNumber(Resources.Memory[0].Start, $600000000, 'xHCI registers above 4 GiB');
    CheckNumber(Resources.Memory[0].Length, $1000, 'xHCI register length');
    Check(not Resources.Memory[0].IsProducer, 'xHCI range consumed');
    CheckNumber(Resources.Interrupts[0].Number, 175, 'xHCI interrupt');
  end;
end;

procedure CheckRootBridge;
var
  Index: Integer;
begin
  Index := DeviceAt('\_SB_.PCI0');
  if Index < 0 then
    Exit;
  with Devices[Index] do
  begin
    Check(string(PChar(@HardwareId[0])) = 'PNP0A08', 'root bridge hardware id');
    Check(string(PChar(@CompatibleIds[0][0])) = 'PNP0A03', 'root bridge compatible id');
    CheckNumber(Segment, 1, 'root bridge _SEG');
    Check(not HasCoherency, 'root bridge has no _CCA');
    CheckNumber(Resources.MemoryCount, 1, 'root bridge memory windows');
    Check(Resources.Memory[0].IsProducer, 'root bridge window produced');
    CheckNumber(Resources.Memory[0].Length, $2EFF0000, 'root bridge window length');
    CheckNumber(Resources.IoCount, 1, 'root bridge I/O ranges');
    CheckNumber(Resources.Io[0].Start, $CF8, 'root bridge I/O ports');
    CheckNumber(Resources.Io[0].Length, 8, 'root bridge I/O length');
  end;
end;

procedure CheckWalk;
var
  Index: Integer;
begin
  CheckNumber(DeviceCount, 6, 'devices found');
  for Index := 0 to DeviceCount - 1 do
    Check(Copy(string(PChar(@Devices[Index].HardwareId[0])), 1, 4) <> 'TEST',
      'an absent device (or its child) was found: ' + string(PChar(@Devices[Index].Path[0])));
  Index := DeviceAt('\_SB_.GDV0');
  if Index >= 0 then
    Check(Devices[Index].HasDma and Devices[Index].HasCoherency, 'the container has _DMA and _CCA');
  CheckMailbox;
  CheckSdController;
  CheckEthernet;
  CheckXhci;
  CheckRootBridge;
end;

{ --- Descriptors the table does not have ----------------------------------------- }

procedure CheckDescriptors;
const
  { IRQ 5 and 7, level, active low, shared; fixed I/O 3F8h (8 ports);
    24-bit memory D0000h (64 KiB); a word I/O range 1000h-10FFh with
    translation 4000h; an extended memory range 8000000000h (1 MiB);
    the end tag. }
  Template: array[0..99] of Byte = (
    $23, $A0, $00, $18,
    $4B, $F8, $03, $08,
    $81, $09, $00, $01, $00, $0D, $00, $0D, $00, $00, $00, $01,
    $88, $0D, $00, $01, $0D, $00, $00, $00, $00, $10, $FF, $10, $00, $40, $00, $01,
    $8B, $35, $00, $00, $0D, $01, $01, $00,
      $00, $00, $00, $00, $00, $00, $00, $00,
      $00, $00, $00, $00, $80, $00, $00, $00,
      $FF, $FF, $0F, $00, $80, $00, $00, $00,
      $00, $00, $00, $00, $00, $00, $00, $00,
      $00, $00, $10, $00, $00, $00, $00, $00,
      $00, $00, $00, $00, $00, $00, $00, $00,
    $79, $00, $00, $00, $00, $00, $00, $00);
  { A large descriptor whose length runs past the end. }
  Damaged: array[0..5] of Byte = ($86, $20, $00, $01, $00, $00);
var
  List: TAcpiResourceList;
begin
  Check(ParseResourceTemplate(@Template[0], SizeOf(Template), List), 'the descriptor template decodes');
  CheckNumber(List.InterruptCount, 2, 'IRQ descriptor interrupts');
  CheckNumber(List.Interrupts[0].Number, 5, 'first IRQ');
  CheckNumber(List.Interrupts[1].Number, 7, 'second IRQ');
  Check(List.Interrupts[0].IsIsaIrq and List.Interrupts[0].LevelTriggered and List.Interrupts[0].ActiveLow and
    List.Interrupts[0].Shared, 'IRQ flags');
  CheckNumber(List.IoCount, 2, 'I/O ranges');
  CheckNumber(List.Io[0].Start, $3F8, 'fixed I/O base');
  CheckNumber(List.Io[0].Length, 8, 'fixed I/O length');
  CheckNumber(List.Io[1].Start, $5000, 'word I/O range, translated');
  CheckNumber(List.Io[1].BusStart, $1000, 'word I/O range on the bus');
  CheckNumber(List.Io[1].Length, $100, 'word I/O range length');
  CheckNumber(List.MemoryCount, 2, 'memory ranges');
  CheckNumber(List.Memory[0].Start, $D0000, '24-bit memory base');
  CheckNumber(List.Memory[0].Length, $10000, '24-bit memory length');
  CheckNumber(List.Memory[1].Start, $8000000000, 'extended memory base');
  CheckNumber(List.Memory[1].Length, $100000, 'extended memory length');
  Check(not ParseResourceTemplate(@Damaged[0], SizeOf(Damaged), List), 'a damaged template is refused');
end;

var
  Table: PByte;
  Index: Integer;
begin
  SetUpHost;
  if ParamCount < 1 then
  begin
    WriteLn('usage: AcpiDeviceTest <table.aml>');
    Halt(2);
  end;
  Check(InitializeNamespace, 'namespace made');
  Table := ReadTable(ParamStr(1));
  Check(LoadAmlTable(Table), 'table loaded');
  WalkAcpiDevices(@RememberDevice, nil);
  { --list: what was found (for looking at another machine's table). }
  if (ParamCount >= 2) and (ParamStr(2) = '--list') then
    for Index := 0 to DeviceCount - 1 do
      WriteLn(PChar(@Devices[Index].Path[0]), ' ', PChar(@Devices[Index].HardwareId[0]));
  CheckWalk;
  CheckDescriptors;
  if Failures > 0 then
  begin
    WriteLn('ACPI DEVICE TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('ACPI DEVICE TEST PASSED');
end.
