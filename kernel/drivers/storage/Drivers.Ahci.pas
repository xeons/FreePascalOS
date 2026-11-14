{
  AHCI (Serial ATA) storage driver.

  An AHCI controller is a PCI device whose registers (the "HBA memory")
  live behind BAR 5. It has up to 32 ports, each of which may have a disk
  attached. Commands are submitted by filling a command header and a
  command table in memory and setting a bit in the port's command issue
  register; the controller then moves data directly to and from memory
  through the physical region descriptor table (PRDT).

  This first version:
    * uses one command slot per port and polls for completion,
    * transfers through a per-port bounce buffer of single pages, so the
      caller's buffer needs no particular alignment or physical layout,
    * supports SATA disks (not ATAPI optical drives).

  Each disk becomes a block device named "diskN".
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
  Runtime.Memory,
  Runtime.Text,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.DeviceMapping,
  Memory.KernelHeap,
  Kernel.Arch.Cpu,
  Kernel.Mutex,
  Kernel.Clock,
  Io.Pci,
  Io.BlockDevice,
  Debug.Output;

const
  AhciBarIndex = 5;
  MaximumPorts = 32;

  { Generic host control registers. }
  RegisterCapabilities = $00;
  RegisterGlobalControl = $04;
  RegisterPortsImplemented = $0C;
  RegisterVersion = $10;
  RegisterCapabilities2 = $24;
  RegisterHandoffControl = $28;

  GlobalControlAhciEnable = LongWord(1) shl 31;
  Capabilities2BiosHandoff = LongWord(1) shl 0;
  HandoffOsOwnership = LongWord(1) shl 1;
  HandoffBiosOwnership = LongWord(1) shl 0;

  { Port registers, relative to the port's register block. }
  PortRegisterBase = $100;
  PortRegisterStride = $80;
  PortCommandListBase = $00;
  PortCommandListBaseUpper = $04;
  PortFisBase = $08;
  PortFisBaseUpper = $0C;
  PortInterruptStatus = $10;
  PortInterruptEnable = $14;
  PortCommand = $18;
  PortTaskFileData = $20;
  PortSignature = $24;
  PortSataStatus = $28;
  PortSataError = $30;
  PortCommandIssue = $38;

  PortCommandStart = LongWord(1) shl 0;
  PortCommandFisReceiveEnable = LongWord(1) shl 4;
  PortCommandFisReceiveRunning = LongWord(1) shl 14;
  PortCommandListRunning = LongWord(1) shl 15;

  PortInterruptTaskFileError = LongWord(1) shl 30;

  TaskFileBusy = $80;
  TaskFileDataRequest = $08;
  TaskFileError = $01;

  SataStatusDetectionMask = $0F;
  SataStatusDevicePresent = $03;
  SataStatusPowerMask = $F00;
  SataStatusPowerActive = $100;

  SignatureSataDisk = LongWord($00000101);

  { ATA commands. }
  AtaCommandIdentifyDevice = $EC;
  AtaCommandReadDmaExtended = $25;
  AtaCommandWriteDmaExtended = $35;

  FisTypeRegisterHostToDevice = $27;
  FisCommandBit = $80;
  DeviceLbaMode = $40;

  { Layout of the per-port control page. }
  CommandListOffset = $000;  { 32 headers of 32 bytes, 1 KiB aligned }
  ReceivedFisOffset = $400;  { 256 bytes, 256 byte aligned }
  CommandTableOffset = $800; { 128 byte aligned }
  PrdtOffsetInTable = $80;

  BounceBufferPages = 16;
  MaximumBytesPerCommand = BounceBufferPages * PageSize;

  CommandTimeoutMilliseconds = 5000;
  RegisterTimeoutMilliseconds = 1000;

  CommandFisLengthInDoublewords = 5;
  CommandHeaderWrite = LongWord(1) shl 6;

type
  TCommandHeader = record
    Flags: LongWord;            { FIS length, write bit, PRDT length (high 16 bits) }
    BytesTransferred: LongWord;
    TableAddressLow: LongWord;
    TableAddressHigh: LongWord;
    Reserved: array[0..3] of LongWord;
  end;
  PCommandHeader = ^TCommandHeader;

  TPrdtEntry = record
    DataAddressLow: LongWord;
    DataAddressHigh: LongWord;
    Reserved: LongWord;
    ByteCountMinusOne: LongWord;
  end;
  PPrdtEntry = ^TPrdtEntry;

  PAhciPort = ^TAhciPort;
  TAhciPort = record
    Registers: PByte;
    PortNumber: LongWord;
    ControlPagePhysical: QWord;
    ControlPage: PByte;
    BouncePagesPhysical: array[0..BounceBufferPages - 1] of QWord;
    Lock: TMutex;
    Device: PBlockDevice;
  end;

{ --- Register access ------------------------------------------------- }

function ReadRegister(Base: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Base + Offset)^;
end;

procedure WriteRegister(Base: PByte; Offset: LongWord; Value: LongWord);
begin
  PLongWord(Base + Offset)^ := Value;
end;

{ Waits until (register and Mask) = Expected. Returns False on timeout. }
function WaitForRegister(Base: PByte; Offset: LongWord; Mask: LongWord; Expected: LongWord;
  TimeoutMilliseconds: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(TimeoutMilliseconds);
  while (ReadRegister(Base, Offset) and Mask) <> Expected do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

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

  { Polling only: no port interrupts, and clear any stale status. }
  WriteRegister(Port^.Registers, PortInterruptEnable, 0);
  WriteRegister(Port^.Registers, PortSataError, $FFFFFFFF);
  WriteRegister(Port^.Registers, PortInterruptStatus, $FFFFFFFF);

  Result := StartPort(Port);
end;

{ --- Command execution ----------------------------------------------- }

procedure BuildRegisterFis(Fis: PByte; Command: Byte; Lba: QWord; SectorCount: Word);
begin
  ZeroMemory(Fis, 64);
  Fis[0] := FisTypeRegisterHostToDevice;
  Fis[1] := FisCommandBit;
  Fis[2] := Command;
  Fis[4] := Byte(Lba);
  Fis[5] := Byte(Lba shr 8);
  Fis[6] := Byte(Lba shr 16);
  Fis[7] := DeviceLbaMode;
  Fis[8] := Byte(Lba shr 24);
  Fis[9] := Byte(Lba shr 32);
  Fis[10] := Byte(Lba shr 40);
  Fis[12] := Byte(SectorCount);
  Fis[13] := Byte(SectorCount shr 8);
end;

{ Runs one command on slot 0, transferring ByteCount bytes through the
  bounce buffer. The caller holds the port lock. }
function ExecuteCommand(Port: PAhciPort; Command: Byte; Lba: QWord; SectorCount: Word;
  ByteCount: QWord; IsWrite: Boolean): Boolean;
var
  Header: PCommandHeader;
  Table: PByte;
  Prdt: PPrdtEntry;
  TablePhysical: QWord;
  PrdtCount: LongWord;
  RemainingBytes: QWord;
  ChunkBytes: QWord;
  Deadline: QWord;
  Flags: LongWord;
begin
  Result := False;
  if not WaitForRegister(Port^.Registers, PortTaskFileData, TaskFileBusy or TaskFileDataRequest, 0,
    CommandTimeoutMilliseconds) then
    Exit;

  Table := Port^.ControlPage + CommandTableOffset;
  TablePhysical := Port^.ControlPagePhysical + CommandTableOffset;
  BuildRegisterFis(Table, Command, Lba, SectorCount);

  Prdt := PPrdtEntry(Table + PrdtOffsetInTable);
  PrdtCount := 0;
  RemainingBytes := ByteCount;
  while RemainingBytes > 0 do
  begin
    ChunkBytes := RemainingBytes;
    if ChunkBytes > PageSize then
      ChunkBytes := PageSize;
    Prdt[PrdtCount].DataAddressLow := LongWord(Port^.BouncePagesPhysical[PrdtCount]);
    Prdt[PrdtCount].DataAddressHigh := LongWord(Port^.BouncePagesPhysical[PrdtCount] shr 32);
    Prdt[PrdtCount].Reserved := 0;
    Prdt[PrdtCount].ByteCountMinusOne := LongWord(ChunkBytes - 1);
    RemainingBytes := RemainingBytes - ChunkBytes;
    Inc(PrdtCount);
  end;

  Flags := CommandFisLengthInDoublewords or (PrdtCount shl 16);
  if IsWrite then
    Flags := Flags or CommandHeaderWrite;

  Header := PCommandHeader(Port^.ControlPage + CommandListOffset);
  Header^.Flags := Flags;
  Header^.BytesTransferred := 0;
  Header^.TableAddressLow := LongWord(TablePhysical);
  Header^.TableAddressHigh := LongWord(TablePhysical shr 32);

  WriteRegister(Port^.Registers, PortInterruptStatus, $FFFFFFFF);
  WriteRegister(Port^.Registers, PortCommandIssue, 1);

  Deadline := ClockTickCount + MillisecondsToTicks(CommandTimeoutMilliseconds);
  while (ReadRegister(Port^.Registers, PortCommandIssue) and 1) <> 0 do
  begin
    if (ReadRegister(Port^.Registers, PortInterruptStatus) and PortInterruptTaskFileError) <> 0 then
      Exit;
    if ClockTickCount > Deadline then
      Exit;
    CpuRelax;
  end;

  if (ReadRegister(Port^.Registers, PortInterruptStatus) and PortInterruptTaskFileError) <> 0 then
    Exit;
  if (ReadRegister(Port^.Registers, PortTaskFileData) and TaskFileError) <> 0 then
    Exit;
  Result := True;
end;

procedure CopyFromBounceBuffer(Port: PAhciPort; Destination: PByte; ByteCount: QWord);
var
  PageIndex: Integer;
  ChunkBytes: QWord;
begin
  PageIndex := 0;
  while ByteCount > 0 do
  begin
    ChunkBytes := ByteCount;
    if ChunkBytes > PageSize then
      ChunkBytes := PageSize;
    CopyMemory(Destination, PhysicalToVirtual(Port^.BouncePagesPhysical[PageIndex]), ChunkBytes);
    Destination := Destination + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
    Inc(PageIndex);
  end;
end;

procedure CopyToBounceBuffer(Port: PAhciPort; Source: PByte; ByteCount: QWord);
var
  PageIndex: Integer;
  ChunkBytes: QWord;
begin
  PageIndex := 0;
  while ByteCount > 0 do
  begin
    ChunkBytes := ByteCount;
    if ChunkBytes > PageSize then
      ChunkBytes := PageSize;
    CopyMemory(PhysicalToVirtual(Port^.BouncePagesPhysical[PageIndex]), Source, ChunkBytes);
    Source := Source + ChunkBytes;
    ByteCount := ByteCount - ChunkBytes;
    Inc(PageIndex);
  end;
end;

{ --- Block device interface ------------------------------------------ }

function TransferBlocks(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: Pointer; IsWrite: Boolean): Boolean;
var
  Port: PAhciPort;
  BlocksPerCommand: LongWord;
  ChunkBlocks: LongWord;
  ChunkBytes: QWord;
  Position: PByte;
  Command: Byte;
begin
  Port := PAhciPort(Device^.DriverContext);
  BlocksPerCommand := MaximumBytesPerCommand div Device^.BlockSize;
  Position := PByte(Buffer);
  if IsWrite then
    Command := AtaCommandWriteDmaExtended
  else
    Command := AtaCommandReadDmaExtended;

  Result := True;
  AcquireMutex(Port^.Lock);
  while BlockCount > 0 do
  begin
    ChunkBlocks := BlockCount;
    if ChunkBlocks > BlocksPerCommand then
      ChunkBlocks := BlocksPerCommand;
    ChunkBytes := QWord(ChunkBlocks) * Device^.BlockSize;

    if IsWrite then
      CopyToBounceBuffer(Port, Position, ChunkBytes);

    if not ExecuteCommand(Port, Command, FirstBlock, Word(ChunkBlocks), ChunkBytes, IsWrite) then
    begin
      Result := False;
      Break;
    end;

    if not IsWrite then
      CopyFromBounceBuffer(Port, Position, ChunkBytes);

    Position := Position + ChunkBytes;
    FirstBlock := FirstBlock + ChunkBlocks;
    BlockCount := BlockCount - ChunkBlocks;
  end;
  ReleaseMutex(Port^.Lock);
end;

function AhciReadBlocks(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: Pointer): Boolean;
begin
  Result := TransferBlocks(Device, FirstBlock, BlockCount, Buffer, False);
end;

function AhciWriteBlocks(Device: PBlockDevice; FirstBlock: QWord; BlockCount: LongWord;
  Buffer: Pointer): Boolean;
begin
  Result := TransferBlocks(Device, FirstBlock, BlockCount, Buffer, True);
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

function IdentifyDisk(Port: PAhciPort; Device: PBlockDevice): Boolean;
const
  WordCommandSetsSupported = 83;
  CommandSetLba48 = Word(1) shl 10;
  WordSectorSize = 106;
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

function PortHasSataDisk(PortRegisters: PByte): Boolean;
var
  SataStatus: LongWord;
begin
  SataStatus := ReadRegister(PortRegisters, PortSataStatus);
  Result := ((SataStatus and SataStatusDetectionMask) = SataStatusDevicePresent) and
    ((SataStatus and SataStatusPowerMask) = SataStatusPowerActive) and
    (ReadRegister(PortRegisters, PortSignature) = SignatureSataDisk);
end;

function SetUpDisk(Registers: PByte; PortNumber: LongWord): Boolean;
var
  Port: PAhciPort;
  Device: PBlockDevice;
  Name: array[0..BlockDeviceNameLength - 1] of Char;
begin
  Result := False;
  Port := PAhciPort(AllocateZeroedKernelMemory(SizeOf(TAhciPort)));
  if Port = nil then
    Exit;

  Port^.Registers := Registers + PortRegisterBase + PortNumber * PortRegisterStride;
  Port^.PortNumber := PortNumber;
  InitializeMutex(Port^.Lock);

  if not AllocatePortMemory(Port) then
    Exit;
  if not ConfigurePort(Port) then
    Exit;

  GenerateDiskName(@Name[0]);
  Device := CreateBlockDevice(@Name[0]);
  if Device = nil then
    Exit;
  Device^.DriverContext := Port;
  Port^.Device := Device;

  AcquireMutex(Port^.Lock);
  Result := IdentifyDisk(Port, Device);
  ReleaseMutex(Port^.Lock);
  if not Result then
    Exit;

  Device^.ReadRoutine := @AhciReadBlocks;
  Device^.WriteRoutine := @AhciWriteBlocks;
  RegisterBlockDevice(Device);
  WriteBlockDeviceDescription(Device);
end;

function InitializeController(PciDevice: PPciDevice): Integer;
var
  Bar: TPciBar;
  Registers: PByte;
  PortsImplemented: LongWord;
  PortNumber: LongWord;
  PortRegisters: PByte;
  Version: LongWord;
begin
  Result := 0;
  if (not PciReadBar(PciDevice, AhciBarIndex, Bar)) or Bar.IsIoPort then
    Exit;

  PciEnableDevice(PciDevice, True);
  Registers := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  if Registers = nil then
    Exit;

  TakeOwnershipFromFirmware(Registers);
  WriteRegister(Registers, RegisterGlobalControl,
    ReadRegister(Registers, RegisterGlobalControl) or GlobalControlAhciEnable);

  Version := ReadRegister(Registers, RegisterVersion);
  PortsImplemented := ReadRegister(Registers, RegisterPortsImplemented);

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

  for PortNumber := 0 to MaximumPorts - 1 do
  begin
    if (PortsImplemented and (LongWord(1) shl PortNumber)) = 0 then
      Continue;
    PortRegisters := Registers + PortRegisterBase + PortNumber * PortRegisterStride;
    if not PortHasSataDisk(PortRegisters) then
      Continue;
    if SetUpDisk(Registers, PortNumber) then
      Inc(Result);
  end;
end;

function InitializeAhciControllers: Integer;
var
  DeviceIndex: Integer;
begin
  Result := 0;
  DeviceIndex := FindPciDeviceByClass(PciClassMassStorage, PciSubclassSata, PciInterfaceAhci, 0);
  while DeviceIndex >= 0 do
  begin
    Result := Result + InitializeController(PciDeviceAt(DeviceIndex));
    DeviceIndex := FindPciDeviceByClass(PciClassMassStorage, PciSubclassSata, PciInterfaceAhci,
      DeviceIndex + 1);
  end;
end;

end.
