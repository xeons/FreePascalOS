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
  The BCM2712's PCIe root complexes (brcm,bcm2712-pcie): pcie2, where
  RP1 sits, and pcie1, the external connector (disabled in the tree
  unless config.txt asks for it). Each is a platform device of the
  device tree; bringing one up (Drivers.BrcmPcie.Setup):

  - a link the firmware left up (it network booted through RP1, or
    config.txt has enable_rp1_uart=1) is kept, its windows written
    again; the kernel option "pcireset" brings it up from cold instead;
  - otherwise the full sequence, ending with the link wait.

  Then the bus: the root port's own configuration space (registers
  0-FFFh) is bus 0 device 0; its bridge registers get bus 1 and the
  windows; the endpoint's configuration space is shown at 8000h for the
  bus/device/function in the index register at 9000h. Only one
  function at a time can be shown, so device 0 function 0 of bus 1 is
  selected for good and handed to Io.Pci (other functions, and buses
  behind a switch, are reported but not used). Its BARs get addresses
  in the host's windows, largest first from the window's start, as
  Linux places them (RP1: BAR1 4 MiB at bus address 0, BAR2 64 KiB at
  40_0000h, BAR0 16 KiB at 41_0000h - where the tree's "rp1" ranges
  expect them). The windows become Io.Pci's address translations, and
  "msi-parent", if it names a MIP (Drivers.Bcm2712Mip), becomes the
  segment's message controller.

  Every step logs a line tagged "pcie"; failures say "FAILED at" the
  step with the status register decoded.
}
unit Drivers.BrcmPcie;

{$mode objfpc}
{$pointermath on}

interface

{ Brings up every enabled brcm,bcm2712-pcie root complex and adds the
  functions behind it to Io.Pci; returns how many links are up. }
function InitializeBrcmPcieHosts: Integer;

implementation

uses
  Runtime.Atomic,
  Memory.KernelHeap,
  Kernel.Options,
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.DeviceTree,
  Firmware.DeviceTreePci,
  Io.Pci,
  Io.PciMessageInterrupts,
  Io.PlatformDevices,
  Drivers.BrcmPcie.Registers,
  Drivers.BrcmPcie.Setup,
  Drivers.Bcm2712Mip,
  Debug.Output;

const
  OptionPciReset = 'pcireset';
  EndpointBus = 1;
  BarCount = 6;
  InvalidVendor = $FFFF;
  HeaderTypeOffset = $0E;
  HeaderMultiFunction = $80;
  BridgeBusNumbers = $18;
  BridgeIoBaseLimit = $1C;
  BridgeMemoryBaseLimit = $20;
  BridgePrefetchBaseLimit = $24;
  BridgePrefetchBaseUpper = $28;
  BridgePrefetchLimitUpper = $2C;
  BarPrefetchable = $8;

var
  LinksUp: Integer;

{ --- The root port as a PCI bridge ------------------------------------------------ }

procedure ConfigureRootPort(Host: PBrcmPcieHost);
var
  Index: Integer;
  Window: TPciHostWindow;
  Start: QWord;
  Last: QWord;
begin
  { Primary 0, secondary and subordinate 1. }
  WriteHostRegister(Host, BridgeBusNumbers, (ReadHostRegister(Host, BridgeBusNumbers) and $FF000000) or
    (EndpointBus shl 16) or (EndpointBus shl 8));
  { No I/O. }
  WriteHostRegister16(Host, BridgeIoBaseLimit, $00F0);
  for Index := 0 to Host^.PciHost.WindowCount - 1 do
  begin
    Window := Host^.PciHost.Windows[Index];
    Start := Window.BusAddress;
    Last := Window.BusAddress + Window.Size - 1;
    if Window.Space = PciSpaceMemory32 then
      WriteHostRegister(Host, BridgeMemoryBaseLimit,
        (LongWord(Start shr 16) and $FFF0) or (LongWord(Last) and $FFF00000))
    else if Window.Space = PciSpaceMemory64 then
    begin
      WriteHostRegister(Host, BridgePrefetchBaseLimit,
        (LongWord(Start shr 16) and $FFF0) or (LongWord(Last) and $FFF00000));
      WriteHostRegister(Host, BridgePrefetchBaseUpper, LongWord(Start shr 32));
      WriteHostRegister(Host, BridgePrefetchLimitUpper, LongWord(Last shr 32));
    end;
  end;
  WriteHostRegister16(Host, PciConfigurationCommand,
    ReadHostRegister16(Host, PciConfigurationCommand) or PciCommandMemorySpace or PciCommandBusMaster);
end;

{ --- Addresses for the endpoint's BARs ---------------------------------------------- }

type
  TBarRequest = record
    Index: Integer;
    Size: QWord;
    Is64Bit: Boolean;
    Prefetchable: Boolean;
  end;

  TWindowCursor = record
    Present: Boolean;
    Next: QWord;
    Limit: QWord;
    PhysicalOffset: QWord;
  end;

procedure OpenCursor(constref Host: TBrcmPcieHost; Space: LongWord; out Cursor: TWindowCursor);
var
  Index: Integer;
begin
  Cursor.Present := False;
  Cursor.Next := 0;
  Cursor.Limit := 0;
  Cursor.PhysicalOffset := 0;
  for Index := 0 to Host.PciHost.WindowCount - 1 do
    if (Host.PciHost.Windows[Index].Space = Space) and not Cursor.Present then
    begin
      Cursor.Present := True;
      Cursor.Next := Host.PciHost.Windows[Index].BusAddress;
      Cursor.Limit := Host.PciHost.Windows[Index].BusAddress + Host.PciHost.Windows[Index].Size;
      Cursor.PhysicalOffset := Host.PciHost.Windows[Index].PhysicalAddress - Host.PciHost.Windows[Index].BusAddress;
    end;
end;

function TakeFrom(var Cursor: TWindowCursor; Size: QWord; out BusAddress: QWord): Boolean;
var
  Aligned: QWord;
begin
  BusAddress := 0;
  Result := False;
  if not Cursor.Present or (Size = 0) then
    Exit;
  Aligned := (Cursor.Next + Size - 1) and not (Size - 1);
  if (Aligned < Cursor.Next) or (Aligned + Size > Cursor.Limit) then
    Exit;
  BusAddress := Aligned;
  Cursor.Next := Aligned + Size;
  Result := True;
end;

procedure ReportBar(Host: PBrcmPcieHost; constref Request: TBarRequest; Previous, BusAddress, Physical: QWord);
begin
  DebugBeginMessage;
  DebugWriteTag('pcie');
  DebugWrite(Host^.Name);
  DebugWrite(': 01:00.0 BAR');
  DebugWriteDecimal(Request.Index);
  DebugWrite(' ');
  DebugWriteSize(Request.Size);
  DebugWrite(' bus 0x');
  DebugWriteHex(BusAddress, 1);
  DebugWrite(' = 0x');
  DebugWriteHex(Physical, 1);
  if Previous <> BusAddress then
  begin
    DebugWrite(' (was 0x');
    DebugWriteHex(Previous, 1);
    DebugWrite(')');
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

function ReadBarBusAddress(Pci: PPciDevice; Index: Integer; Is64Bit: Boolean): QWord;
begin
  Result := PciRead32(Pci, PciConfigurationBar0 + Word(Index) * 4) and $FFFFFFF0;
  if Is64Bit then
    Result := Result or (QWord(PciRead32(Pci, PciConfigurationBar0 + Word(Index) * 4 + 4)) shl 32);
end;

{ Every memory BAR gets an address, largest first, prefetchable 64-bit
  ones in the 64-bit window, the rest in the 32-bit one. }
procedure AssignEndpointBars(Host: PBrcmPcieHost; Pci: PPciDevice);
var
  Requests: array[0..BarCount - 1] of TBarRequest;
  Count: Integer;
  Index: Integer;
  Other: Integer;
  Swap: TBarRequest;
  Bar: TPciBar;
  Window32: TWindowCursor;
  Window64: TWindowCursor;
  BusAddress: QWord;
  Previous: QWord;
  Offset: Word;
  Taken: Boolean;
  Command: Word;
  PhysicalOffset: QWord;
begin
  Count := 0;
  Index := 0;
  while Index < BarCount do
  begin
    if PciReadBar(Pci, Index, Bar) and not Bar.IsIoPort then
    begin
      Requests[Count].Index := Index;
      Requests[Count].Size := Bar.SizeInBytes;
      Requests[Count].Is64Bit := Bar.Is64Bit;
      Requests[Count].Prefetchable :=
        (PciRead32(Pci, PciConfigurationBar0 + Word(Index) * 4) and BarPrefetchable) <> 0;
      Inc(Count);
    end;
    if Bar.Is64Bit then
      Inc(Index);
    Inc(Index);
  end;
  { Largest first (a handful: a plain exchange sort). }
  for Index := 0 to Count - 2 do
    for Other := Index + 1 to Count - 1 do
      if Requests[Other].Size > Requests[Index].Size then
      begin
        Swap := Requests[Index];
        Requests[Index] := Requests[Other];
        Requests[Other] := Swap;
      end;
  OpenCursor(Host^, PciSpaceMemory32, Window32);
  OpenCursor(Host^, PciSpaceMemory64, Window64);
  Command := PciRead16(Pci, PciConfigurationCommand);
  PciWrite16(Pci, PciConfigurationCommand, Command and not (PciCommandMemorySpace or PciCommandIoSpace));
  for Index := 0 to Count - 1 do
  begin
    Offset := PciConfigurationBar0 + Word(Requests[Index].Index) * 4;
    Previous := ReadBarBusAddress(Pci, Requests[Index].Index, Requests[Index].Is64Bit);
    Taken := False;
    PhysicalOffset := 0;
    if Requests[Index].Is64Bit and Requests[Index].Prefetchable then
    begin
      Taken := TakeFrom(Window64, Requests[Index].Size, BusAddress);
      PhysicalOffset := Window64.PhysicalOffset;
    end;
    if not Taken then
    begin
      Taken := TakeFrom(Window32, Requests[Index].Size, BusAddress);
      PhysicalOffset := Window32.PhysicalOffset;
    end;
    if not Taken then
    begin
      ReportHost(Host, 'no room in the windows for a BAR of size', Int64(Requests[Index].Size));
      Continue;
    end;
    PciWrite32(Pci, Offset, (PciRead32(Pci, Offset) and $F) or LongWord(BusAddress));
    if Requests[Index].Is64Bit then
      PciWrite32(Pci, Offset + 4, LongWord(BusAddress shr 32));
    ReportBar(Host, Requests[Index], Previous, BusAddress, BusAddress + PhysicalOffset);
  end;
  PciWrite16(Pci, PciConfigurationCommand, Command);
end;

{ --- The bus behind the root port --------------------------------------------------- }

procedure SelectFunction(Host: PBrcmPcieHost; Bus, Device, FunctionNumber: Byte);
begin
  WriteHostRegister(Host, ConfigurationIndex, (LongWord(Bus) shl 20) or (LongWord(Device) shl 15) or
    (LongWord(FunctionNumber) shl 12));
end;

function ReadEndpoint32(Host: PBrcmPcieHost; Offset: LongWord): LongWord;
begin
  Result := ReadHostRegister(Host, ConfigurationData + Offset);
end;

procedure ReportOtherFunctions(Host: PBrcmPcieHost);
var
  FunctionNumber: Byte;
  Identity: LongWord;
begin
  for FunctionNumber := 1 to 7 do
  begin
    SelectFunction(Host, EndpointBus, 0, FunctionNumber);
    Identity := ReadEndpoint32(Host, PciConfigurationVendorId);
    if (Identity and $FFFF) <> InvalidVendor then
    begin
      DebugBeginMessage;
      DebugWriteTag('pcie');
      DebugWrite(Host^.Name);
      DebugWrite(': 01:00.');
      DebugWriteDecimal(FunctionNumber);
      DebugWrite(' ');
      DebugWriteHex(Identity and $FFFF, 4);
      DebugWrite(':');
      DebugWriteHex(Identity shr 16, 4);
      DebugWriteLine(' not used (one function at a time through the window)');
      DebugEndMessage;
    end;
  end;
  SelectFunction(Host, EndpointBus, 0, 0);
end;

{ Bus 0 (the root port) and bus 1 device 0 function 0 into Io.Pci. }
function AddFunctions(Host: PBrcmPcieHost): PPciDevice;
var
  Identity: LongWord;
  Header: Byte;
  Segment: Word;
begin
  Result := nil;
  Segment := Host^.PciHost.Segment;
  AddPciFunction(Segment, 0, 0, 0, Host^.Registers);
  SelectFunction(Host, EndpointBus, 0, 0);
  Identity := ReadEndpoint32(Host, PciConfigurationVendorId);
  if ((Identity and $FFFF) = InvalidVendor) or ((Identity and $FFFF) = 0) then
  begin
    ReportHost(Host, 'the link is up but nothing answers at 01:00.0, read', Identity);
    Exit;
  end;
  Header := Byte(ReadEndpoint32(Host, HeaderTypeOffset and not 3) shr 16);
  if (Header and HeaderMultiFunction) <> 0 then
    ReportOtherFunctions(Host);
  if (Header and $7F) <> 0 then
    ReportHost(Host, 'a bridge or switch at 01:00.0 (buses behind it are not scanned), header', Header);
  Result := AddPciFunction(Segment, EndpointBus, 0, 0, Host^.Registers + ConfigurationData);
  if Result = nil then
    Exit;
  DebugBeginMessage;
  DebugWriteTag('pcie');
  DebugWrite(Host^.Name);
  DebugWrite(': 01:00.0 ');
  DebugWriteHex(Result^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(Result^.DeviceId, 4);
  DebugWrite(' rev ');
  DebugWriteHex(Result^.Revision, 2);
  DebugWrite(' class ');
  DebugWriteHex(Result^.ClassCode, 2);
  DebugWriteHex(Result^.Subclass, 2);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ --- Messages ------------------------------------------------------------------------- }

procedure ConnectMessageController(Host: PBrcmPcieHost);
var
  Tree: PDeviceTree;
  Phandle: LongWord;
  Node: LongInt;
  Mip: PMipController;
begin
  Tree := SystemDeviceTree;
  if not ReadCellProperty(Tree^, Host^.Node, 'msi-parent', Phandle) then
  begin
    ReportHost(Host, 'no msi-parent: devices get no message interrupts', -1);
    Exit;
  end;
  Node := FindNodeByPhandle(Tree^, Phandle);
  if Node = Host^.Node then
  begin
    ReportHost(Host, 'its own MSI controller is not driven: no message interrupts', -1);
    Exit;
  end;
  if (Node = NoNode) or not NodeIsCompatible(Tree^, Node, 'brcm,bcm2712-mip') then
  begin
    ReportHost(Host, 'msi-parent is not a brcm,bcm2712-mip: no message interrupts', -1);
    Exit;
  end;
  Mip := OpenMipController(Node);
  if Mip <> nil then
    RegisterPciMessageController(Host^.PciHost.Segment, @ConnectMipVector, Mip);
end;

{ --- Probing ---------------------------------------------------------------------------- }

procedure ReportLink(Host: PBrcmPcieHost);
begin
  DebugBeginMessage;
  DebugWriteTag('pcie');
  DebugWrite(Host^.Name);
  if Host^.KeptFirmwareLink then
    DebugWrite(': link kept from firmware, gen ')
  else
    DebugWrite(': link up, gen ');
  DebugWriteDecimal(Host^.LinkSpeed);
  DebugWrite(' x');
  DebugWriteDecimal(Host^.LinkWidth);
  DebugWrite(', segment ');
  DebugWriteDecimal(Host^.PciHost.Segment);
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure ReportFirstLook(Host: PBrcmPcieHost; Status: LongWord);
begin
  DebugBeginMessage;
  DebugWriteTag('pcie');
  DebugWrite(Host^.Name);
  DebugWrite(': rev 0x');
  DebugWriteHex(ReadHostRegister(Host, MiscRevision), 1);
  DebugWrite(', status 0x');
  DebugWriteHex(Status, 2);
  if ((Status and StatusPhyLinkUp) <> 0) and ((Status and StatusDataLinkActive) <> 0) then
    DebugWriteLine(': the firmware left the link up')
  else
    DebugWriteLine(': link down, starting it');
  DebugEndMessage;
end;

procedure AddTranslations(Host: PBrcmPcieHost);
var
  Index: Integer;
begin
  for Index := 0 to Host^.PciHost.WindowCount - 1 do
    if Host^.PciHost.Windows[Index].Space >= PciSpaceMemory32 then
      AddPciAddressTranslation(Host^.PciHost.Segment, Host^.PciHost.Windows[Index].BusAddress,
        Host^.PciHost.Windows[Index].Size, Host^.PciHost.Windows[Index].PhysicalAddress);
end;

function ProbeBrcmPcie(Device: PPlatformDevice): Boolean;
var
  Host: PBrcmPcieHost;
  Length: QWord;
  Status: LongWord;
  Generation: LongWord;
  Endpoint: PPciDevice;
begin
  Result := False;
  Host := PBrcmPcieHost(AllocateZeroedKernelMemory(SizeOf(TBrcmPcieHost)));
  if Host = nil then
    Exit;
  Host^.Device := Device;
  Host^.Node := Device^.DeviceTreeNode;
  Host^.Name := NodeName(SystemDeviceTree^, Host^.Node);
  Host^.Registers := PByte(MapPlatformMemory(Device, 0, Length));
  if (Host^.Registers = nil) or (Length < BrcmPcieRegisterBytes) then
  begin
    ReportHost(Host, 'FAILED: registers missing or too short, length', Int64(Length));
    Exit;
  end;
  DescribeDeviceTreePciHost(Host^.Node, 0, Host^.PciHost);
  if ReadCellProperty(SystemDeviceTree^, Host^.Node, 'max-link-speed', Generation) then
    Host^.Generation := Generation;
  Result := True;

  Status := ReadHostRegister(Host, PcieStatus);
  ReportFirstLook(Host, Status);
  if HostLinkIsUp(Host) and not KernelOptionIsSet(OptionPciReset) then
  begin
    Host^.KeptFirmwareLink := True;
    RefreshKeptLink(Host);
  end
  else if not ResetAndSetUpBridge(Host) or not StartLink(Host) then
    Exit;
  ReadLinkState(Host);
  ReportLink(Host);
  Inc(LinksUp);

  ConfigureRootPort(Host);
  AddTranslations(Host);
  Endpoint := AddFunctions(Host);
  if Endpoint = nil then
    Exit;
  AssignEndpointBars(Host, Endpoint);
  ConnectMessageController(Host);
end;

const
  BrcmPcieIds: array[0..1] of PChar = ('brcm,bcm2712-pcie', nil);
  BrcmPcieDriver: TPlatformDriver = (
    Name: 'brcm-pcie';
    Ids: @BrcmPcieIds[0];
    Probe: @ProbeBrcmPcie);

function InitializeBrcmPcieHosts: Integer;
begin
  LinksUp := 0;
  BindPlatformDriver(BrcmPcieDriver);
  Result := LinksUp;
end;

end.
