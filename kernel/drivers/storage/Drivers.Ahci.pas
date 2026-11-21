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
  AHCI (Serial ATA) storage driver: finding controllers and disks.

  An AHCI controller is a PCI device whose registers (the "HBA memory")
  live behind BAR 5. It has up to 32 ports, each of which may have a SATA
  disk attached (ATAPI optical drives are not supported). For each disk
  the driver sets up the port (Drivers.AhciPort), identifies the disk,
  creates its device object (Drivers.AhciRequests) and a block device
  "diskN" on top of it.

  When all disks of a controller are known, the controller's interrupt
  is connected by MSI and the ports switch from polling to interrupt
  driven requests. A controller without MSI keeps polling.
}
unit Drivers.Ahci;

{$mode objfpc}
{$pointermath on}

interface

{ Finds every AHCI controller and registers a block device per disk.
  Returns the number of disks found. }
function InitializeAhciControllers: Integer;

implementation

uses
  Io.PowerManagement,
  Runtime.Memory,
  Runtime.Text,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.DeviceMapping,
  Memory.KernelHeap,
  Io.Pci,
  Io.PciMessageInterrupts,
  Io.BlockDevice,
  Drivers.AhciPort,
  Drivers.AhciRequests,
  Debug.Output;

const
  AhciBarIndex = 5;

  SataStatusDetectionMask = $0F;
  SataStatusDevicePresent = $03;
  SataStatusPowerMask = $F00;
  SataStatusPowerActive = $100;

  SignatureSataDisk = LongWord($00000101);
  SignatureAtapi = LongWord($EB140101);

{ --- Port setup ------------------------------------------------------ }

function StopPort(Port: PAhciPort): Boolean;
var
  Command: LongWord;
begin
  Command := ReadRegister(Port^.Registers, PortCommand);
  WriteRegister(Port^.Registers, PortCommand, Command and not PortCommandStart);
  Result := WaitForRegister(Port^.Registers, PortCommand, PortCommandListRunning, 0,
    RegisterTimeoutMilliseconds);
  if not Result then
    Exit;

  Command := ReadRegister(Port^.Registers, PortCommand);
  WriteRegister(Port^.Registers, PortCommand, Command and not PortCommandFisReceiveEnable);
  Result := WaitForRegister(Port^.Registers, PortCommand, PortCommandFisReceiveRunning, 0,
    RegisterTimeoutMilliseconds);
end;

function StartPort(Port: PAhciPort): Boolean;
var
  Command: LongWord;
begin
  Command := ReadRegister(Port^.Registers, PortCommand);
  WriteRegister(Port^.Registers, PortCommand, Command or PortCommandFisReceiveEnable);

  Result := WaitForRegister(Port^.Registers, PortTaskFileData,
    TaskFileBusy or TaskFileDataRequest, 0, RegisterTimeoutMilliseconds);
  if not Result then
    Exit;

  Command := ReadRegister(Port^.Registers, PortCommand);
  WriteRegister(Port^.Registers, PortCommand, Command or PortCommandStart);
end;

function AllocatePortMemory(Port: PAhciPort): Boolean;
var
  PageIndex: Integer;
begin
  Port^.ControlPagePhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Port^.ControlPagePhysical = 0 then
    Exit(False);
  Port^.ControlPage := PByte(PhysicalToVirtual(Port^.ControlPagePhysical));

  for PageIndex := 0 to BounceBufferPages - 1 do
  begin
    Port^.BouncePagesPhysical[PageIndex] := AllocateZeroedPhysicalPage(PageUsageGeneral);
    if Port^.BouncePagesPhysical[PageIndex] = 0 then
      Exit(False);
  end;
  for PageIndex := 0 to TablePageCount - 1 do
  begin
    Port^.TablePagesPhysical[PageIndex] := AllocateZeroedPhysicalPage(PageUsageGeneral);
    if Port^.TablePagesPhysical[PageIndex] = 0 then
      Exit(False);
  end;
  Result := True;
end;

function ConfigurePort(Port: PAhciPort): Boolean;
var
  CommandListPhysical: QWord;
  FisPhysical: QWord;
begin
  Result := False;
  if not StopPort(Port) then
    Exit;

  CommandListPhysical := Port^.ControlPagePhysical + CommandListOffset;
  FisPhysical := Port^.ControlPagePhysical + ReceivedFisOffset;
  WriteRegister(Port^.Registers, PortCommandListBase, LongWord(CommandListPhysical));
  WriteRegister(Port^.Registers, PortCommandListBaseUpper, LongWord(CommandListPhysical shr 32));
  WriteRegister(Port^.Registers, PortFisBase, LongWord(FisPhysical));
  WriteRegister(Port^.Registers, PortFisBaseUpper, LongWord(FisPhysical shr 32));

  { Interrupts stay off until every disk is identified; clear any stale
    status. }
  WriteRegister(Port^.Registers, PortInterruptEnable, 0);
  WriteRegister(Port^.Registers, PortSataError, $FFFFFFFF);
  WriteRegister(Port^.Registers, PortInterruptStatus, $FFFFFFFF);

  Result := StartPort(Port);
end;

{ --- Device identification ------------------------------------------- }

{ ATA strings store two characters per word with the bytes swapped. }
procedure DecodeAtaString(Words: PWord; FirstWord, WordCount: Integer; Destination: PChar;
  Capacity: Integer);
var
  WordIndex: Integer;
  Length: Integer;
begin
  Length := 0;
  for WordIndex := FirstWord to FirstWord + WordCount - 1 do
  begin
    if Length + 2 >= Capacity then
      Break;
    Destination[Length] := Char(Words[WordIndex] shr 8);
    Destination[Length + 1] := Char(Words[WordIndex] and $FF);
    Inc(Length, 2);
  end;
  while (Length > 0) and (Destination[Length - 1] = ' ') do
    Dec(Length);
  Destination[Length] := #0;
end;

function IdentifyDisk(Port: PAhciPort; Device: PBlockDevice; ControllerQueues: Boolean): Boolean;
const
  WordQueueDepth = 75;
  WordSataCapabilities = 76;
  SataNativeCommandQueuing = Word(1) shl 8;
  WordCommandSetsSupported = 83;
  CommandSetLba48 = Word(1) shl 10;
  WordSectorSize = 106;
  WordDataSetManagement = 169;
  DataSetManagementTrimSupported = Word(1) shl 0;
  SectorSizeInfoValid = Word(1) shl 14;
  SectorSizeLongLogical = Word(1) shl 12;
var
  Identify: PWord;
  SectorSize: LongWord;
begin
  Result := False;
  if not ExecuteCommand(Port, AtaCommandIdentifyDevice, 0, 0, 512, False) then
    Exit;

  Identify := PWord(PhysicalToVirtual(Port^.BouncePagesPhysical[0]));

  if (Identify[WordCommandSetsSupported] and CommandSetLba48) = 0 then
    Exit; { only LBA48 capable disks are supported }

  Device^.BlockCount := QWord(Identify[100]) or (QWord(Identify[101]) shl 16) or
    (QWord(Identify[102]) shl 32) or (QWord(Identify[103]) shl 48);

  SectorSize := 512;
  if ((Identify[WordSectorSize] and (SectorSizeInfoValid or $8000)) = SectorSizeInfoValid) and
     ((Identify[WordSectorSize] and SectorSizeLongLogical) <> 0) then
    SectorSize := 2 * (LongWord(Identify[117]) or (LongWord(Identify[118]) shl 16));
  Device^.BlockSize := SectorSize;

  DecodeAtaString(Identify, 27, 20, @Device^.Model[0], BlockDeviceModelLength);

  Port^.SupportsTrim := (Identify[WordDataSetManagement] and DataSetManagementTrimSupported) <> 0;
  Device^.SupportsDiscard := Port^.SupportsTrim;
  Device^.MaximumDiscardBlocks := TrimRangesPerCommand * TrimSectorsPerRange;
  Port^.QueueDepth := 0;
  if ControllerQueues and ((Identify[WordSataCapabilities] and SataNativeCommandQueuing) <> 0) and
     (Identify[WordSataCapabilities] <> $FFFF) then
  begin
    Port^.QueueDepth := (Identify[WordQueueDepth] and $1F) + 1;
    if Port^.QueueDepth > Port^.SlotCount then
      Port^.QueueDepth := Port^.SlotCount;
  end;
  Result := Device^.BlockCount > 0;
end;

{ --- Controller setup ------------------------------------------------ }

procedure TakeOwnershipFromFirmware(Registers: PByte);
begin
  if (ReadRegister(Registers, RegisterCapabilities2) and Capabilities2BiosHandoff) = 0 then
    Exit;
  WriteRegister(Registers, RegisterHandoffControl,
    ReadRegister(Registers, RegisterHandoffControl) or HandoffOsOwnership);
  WaitForRegister(Registers, RegisterHandoffControl, HandoffBiosOwnership, 0, 2000);
end;

{ True if a disk or an ATAPI device is attached and talking; IsPacket
  tells which. }
function PortHasDevice(PortRegisters: PByte; out IsPacket: Boolean): Boolean;
var
  SataStatus: LongWord;
  Signature: LongWord;
begin
  SataStatus := ReadRegister(PortRegisters, PortSataStatus);
  Signature := ReadRegister(PortRegisters, PortSignature);
  IsPacket := Signature = SignatureAtapi;
  Result := ((SataStatus and SataStatusDetectionMask) = SataStatusDevicePresent) and
    ((SataStatus and SataStatusPowerMask) = SataStatusPowerActive) and
    ((Signature = SignatureSataDisk) or IsPacket);
end;

{ An ATAPI device: its model, and the size of the medium in it (READ
  CAPACITY). False if there is no readable medium. }
function IdentifyPacketDevice(Port: PAhciPort; Device: PBlockDevice): Boolean;
var
  Identify: PWord;
  Capacity: PByte;
  Packet: TPacket;
  LastBlock: LongWord;
begin
  Result := False;
  if not ExecuteCommand(Port, AtaCommandIdentifyPacketDevice, 0, 0, 512, False) then
    Exit;
  Identify := PWord(PhysicalToVirtual(Port^.BouncePagesPhysical[0]));
  DecodeAtaString(Identify, 27, 20, @Device^.Model[0], BlockDeviceModelLength);

  FillMemory(@Packet[0], PacketSize, 0);
  Packet[0] := ScsiReadCapacity10;
  { A drive just started reports a unit attention first; ask again. }
  if not ExecutePacketCommand(Port, Packet, 8) then
  begin
    RecoverPort(Port);
    if not ExecutePacketCommand(Port, Packet, 8) then
      Exit;
  end;
  Capacity := PByte(PhysicalToVirtual(Port^.BouncePagesPhysical[0]));
  LastBlock := (LongWord(Capacity[0]) shl 24) or (LongWord(Capacity[1]) shl 16) or
    (LongWord(Capacity[2]) shl 8) or Capacity[3];
  Device^.BlockSize := (LongWord(Capacity[4]) shl 24) or (LongWord(Capacity[5]) shl 16) or
    (LongWord(Capacity[6]) shl 8) or Capacity[7];
  Device^.BlockCount := QWord(LastBlock) + 1;
  Device^.WriteProtected := True;
  Port^.IsPacketDevice := True;
  Port^.QueueDepth := 0;
  Result := (Device^.BlockSize >= 512) and (Device^.BlockSize <= 4096);
end;

{ Sets up the disk on port PortNumber; returns its port, or nil. }
function SetUpDisk(Registers: PByte; PortNumber: LongWord; IsPacket: Boolean): PAhciPort;
var
  Port: PAhciPort;
  Disk: PBlockDevice;
  Name: array[0..BlockDeviceNameLength - 1] of Char;
begin
  Result := nil;
  Port := PAhciPort(AllocateZeroedKernelMemory(SizeOf(TAhciPort)));
  if Port = nil then
    Exit;
  Port^.Registers := Registers + PortRegisterBase + PortNumber * PortRegisterStride;
  Port^.PortNumber := PortNumber;
  Port^.SlotCount := ((ReadRegister(Registers, RegisterCapabilities) shr CapabilityCommandSlotsShift) and
    CapabilityCommandSlotsMask) + 1;

  if not AllocatePortMemory(Port) then
    Exit;
  if not ConfigurePort(Port) then
    Exit;
  if not CreateAhciDevice(Port) then
    Exit;

  GenerateDiskName(@Name[0]);
  Disk := CreateBlockDevice(@Name[0]);
  if Disk = nil then
    Exit;
  { Nothing else uses the port yet, so no lock is needed. }
  if IsPacket then
  begin
    if not IdentifyPacketDevice(Port, Disk) then
    begin
      DebugBeginMessage;
      DebugWriteTag('ahci');
      DebugWrite('Port ');
      DebugWriteDecimal(PortNumber);
      DebugWriteLine(': ATAPI device without a readable medium, left alone');
      DebugEndMessage;
      Exit;
    end;
  end
  else if not IdentifyDisk(Port, Disk,
    (ReadRegister(Registers, RegisterCapabilities) and CapabilityNativeCommandQueuing) <> 0) then
    Exit;
  Port^.BlockSize := Disk^.BlockSize;
  Port^.BlockCount := Disk^.BlockCount;
  Port^.Device^.SizeInBytes := BlockDeviceSizeInBytes(Disk);

  Disk^.StorageDevice := Port^.Device;
  RegisterBlockDevice(Disk);
  WriteBlockDeviceDescription(Disk);
  DebugBeginMessage;
  DebugWriteTag('ahci');
  DebugWrite('Port ');
  DebugWriteDecimal(PortNumber);
  DebugWrite(': ');
  DebugWriteDecimal(Port^.SlotCount);
  if Port^.IsPacketDevice then
    DebugWriteLine(' command slots, ATAPI (read only)')
  else if Port^.QueueDepth > 0 then
  begin
    DebugWrite(' command slots, native command queuing to depth ');
    DebugWriteDecimal(Port^.QueueDepth);
    DebugWriteLine('');
  end
  else
    DebugWriteLine(' command slots, no native command queuing');
  DebugEndMessage;
  Result := Port;
end;

{ Connects the controller's interrupt and switches its ports to it.
  Returns False (the ports keep polling) if that is not possible. }
function EnableControllerInterrupts(PciDevice: PPciDevice; Controller: PAhciController): Boolean;
var
  PortNumber: LongWord;
  Port: PAhciPort;
begin
  Result := ConnectPciMessageInterrupt(PciDevice, @HandleAhciInterrupt, Controller);
  if not Result then
    Exit;
  for PortNumber := 0 to MaximumPorts - 1 do
  begin
    Port := Controller^.Ports[PortNumber];
    if Port = nil then
      Continue;
    UseInterruptsForPort(Port);
    WriteRegister(Port^.Registers, PortInterruptStatus, $FFFFFFFF);
    WriteRegister(Port^.Registers, PortInterruptEnable, PortInterruptsWanted);
  end;
  WriteRegister(Controller^.Registers, RegisterInterruptStatus, $FFFFFFFF);
  WriteRegister(Controller^.Registers, RegisterGlobalControl,
    ReadRegister(Controller^.Registers, RegisterGlobalControl) or GlobalControlInterruptEnable);
end;

procedure WriteControllerDescription(PciDevice: PPciDevice; Version, PortsImplemented: LongWord);
begin
  DebugBeginMessage;
  DebugWriteTag('ahci');
  DebugWrite('Controller ');
  DebugWriteHex(PciDevice^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(PciDevice^.DeviceId, 4);
  DebugWrite(', AHCI ');
  DebugWriteDecimal(Version shr 16);
  DebugWrite('.');
  DebugWriteDecimal((Version shr 8) and $FF);
  DebugWrite(', ports 0x');
  DebugWriteHex(PortsImplemented, 8);
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure WriteInterruptMode(UsesInterrupts: Boolean);
begin
  DebugBeginMessage;
  DebugWriteTag('ahci');
  if UsesInterrupts then
    DebugWriteLine('Requests complete by interrupt (MSI)')
  else
    DebugWriteLine('No MSI; requests are polled');
  DebugEndMessage;
end;

{ --- Suspend to RAM -------------------------------------------------------- }

{ Block I/O is stopped before (no command is in flight): the ports stop. }
procedure SuspendController(Context: Pointer);
var
  Controller: PAhciController;
  PortNumber: LongWord;
begin
  Controller := PAhciController(Context);
  for PortNumber := 0 to MaximumPorts - 1 do
    if Controller^.Ports[PortNumber] <> nil then
      StopPort(Controller^.Ports[PortNumber]);
end;

{ Waking reset the controller: AHCI mode, then each port pointed at its
  command list and FIS area again (still in memory) and started, then
  the interrupts as they were. }
procedure ResumeController(Context: Pointer);
var
  Controller: PAhciController;
  PortNumber: LongWord;
  Port: PAhciPort;
begin
  Controller := PAhciController(Context);
  WriteRegister(Controller^.Registers, RegisterGlobalControl,
    ReadRegister(Controller^.Registers, RegisterGlobalControl) or GlobalControlAhciEnable);
  for PortNumber := 0 to MaximumPorts - 1 do
  begin
    Port := Controller^.Ports[PortNumber];
    if Port = nil then
      Continue;
    WaitForRegister(Port^.Registers, PortSataStatus, SataStatusDetectionMask, SataStatusDevicePresent,
      RegisterTimeoutMilliseconds);
    ConfigurePort(Port);
    if Controller^.UsesInterrupts then
    begin
      WriteRegister(Port^.Registers, PortInterruptStatus, $FFFFFFFF);
      WriteRegister(Port^.Registers, PortInterruptEnable, PortInterruptsWanted);
    end;
  end;
  if Controller^.UsesInterrupts then
  begin
    WriteRegister(Controller^.Registers, RegisterInterruptStatus, $FFFFFFFF);
    WriteRegister(Controller^.Registers, RegisterGlobalControl,
      ReadRegister(Controller^.Registers, RegisterGlobalControl) or GlobalControlInterruptEnable);
  end;
end;

function InitializeController(PciDevice: PPciDevice): Integer;
var
  Bar: TPciBar;
  Registers: PByte;
  PortsImplemented: LongWord;
  PortNumber: LongWord;
  PortRegisters: PByte;
  Controller: PAhciController;
  IsPacket: Boolean;
begin
  Result := 0;
  if (not PciReadBar(PciDevice, AhciBarIndex, Bar)) or Bar.IsIoPort then
    Exit;
  Controller := PAhciController(AllocateZeroedKernelMemory(SizeOf(TAhciController)));
  if Controller = nil then
    Exit;

  PciEnableDevice(PciDevice, True);
  Registers := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  if Registers = nil then
    Exit;
  Controller^.Registers := Registers;

  TakeOwnershipFromFirmware(Registers);
  WriteRegister(Registers, RegisterGlobalControl,
    ReadRegister(Registers, RegisterGlobalControl) or GlobalControlAhciEnable);
  PortsImplemented := ReadRegister(Registers, RegisterPortsImplemented);
  WriteControllerDescription(PciDevice, ReadRegister(Registers, RegisterVersion), PortsImplemented);

  for PortNumber := 0 to MaximumPorts - 1 do
  begin
    if (PortsImplemented and (LongWord(1) shl PortNumber)) = 0 then
      Continue;
    PortRegisters := Registers + PortRegisterBase + PortNumber * PortRegisterStride;
    if not PortHasDevice(PortRegisters, IsPacket) then
      Continue;
    Controller^.Ports[PortNumber] := SetUpDisk(Registers, PortNumber, IsPacket);
    if Controller^.Ports[PortNumber] <> nil then
      Inc(Result);
  end;

  if Result > 0 then
  begin
    Controller^.UsesInterrupts := EnableControllerInterrupts(PciDevice, Controller);
    WriteInterruptMode(Controller^.UsesInterrupts);
    RegisterPowerHandler('AHCI', PowerStageDevices, @SuspendController, @ResumeController, Controller);
  end;
end;

function InitializeAhciControllers: Integer;
var
  DeviceIndex: Integer;
begin
  Result := 0;
  CreateAhciDriver;
  DeviceIndex := FindPciDeviceByClass(PciClassMassStorage, PciSubclassSata, PciInterfaceAhci, 0);
  while DeviceIndex >= 0 do
  begin
    Result := Result + InitializeController(PciDeviceAt(DeviceIndex));
    DeviceIndex := FindPciDeviceByClass(PciClassMassStorage, PciSubclassSata, PciInterfaceAhci,
      DeviceIndex + 1);
  end;
end;

end.
