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
  USB mass storage devices (class 08h, SCSI command set 06h, Bulk-Only
  Transport 50h): USB sticks and disks.

  Bulk-Only Transport: every SCSI command goes out as a 31-byte command
  block wrapper on the bulk OUT endpoint, its data (if any) follows on
  the bulk IN or OUT endpoint, and a 13-byte status wrapper comes back on
  bulk IN. The SCSI commands used: INQUIRY (the model), TEST UNIT READY
  with REQUEST SENSE (until the device is ready), READ CAPACITY(10),
  READ(10), WRITE(10) and SYNCHRONIZE CACHE(10).

  Each device becomes a disk of the driver "usb-storage" (logical unit 0
  only), marked removable. Its requests are carried out synchronously by
  the thread that sends them, one at a time, up to UsbMaximumTransfer
  bytes per command.

  Errors are recovered as the Bulk-Only Transport specification says
  (section 5.3): a stalled data stage has its endpoint's halt cleared
  and the status is still read; a stalled status read is cleared and
  tried once more; anything else (a failed or timed out command or
  status, a status that is not one or not this command's) gets reset
  recovery: the class's Bulk-Only Mass Storage Reset, then both bulk
  endpoints' halts cleared. So one stall or one confused command fails
  that command, not the disk.

  The capacity the device reports must be usable: a block size that is
  a power of two from 512 to 4096 bytes (so 64 KiB pieces hold whole
  blocks), and at most 2^32 - 1 blocks (READ(10) addresses 32 bits: a
  device reporting FFFFFFFFh as its last block is larger, and only that
  much of it is used).

  A disk plugged in after startup is announced (Io.DiskArrival), which
  mounts its volumes. When it is unplugged, its requests fail from then
  on and its removal is announced, which takes its volumes away.
}
unit Drivers.UsbStorage;

{$mode objfpc}
{$pointermath on}

interface

{ Registers the class driver with the USB core (before the controllers
  start). }
procedure RegisterUsbStorageDriver;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.Mutex,
  Kernel.Scheduler,
  Io.Manager,
  Io.BlockDevice,
  Io.DiskArrival,
  Drivers.Xhci,
  Drivers.UsbDescriptors,
  Drivers.UsbInterfaces,
  Debug.Output;

const
  SubclassScsi = $06;
  ProtocolBulkOnly = $50;

  CommandBlockSignature = LongWord($43425355);
  CommandStatusSignature = LongWord($53425355);
  CommandBlockSize = 31;
  CommandStatusSize = 13;
  DirectionIn = $80;

  ScsiTestUnitReady = $00;
  ScsiRequestSense = $03;
  ScsiInquiry = $12;
  ScsiReadCapacity10 = $25;
  ScsiRead10 = $28;
  ScsiWrite10 = $2A;
  ScsiSynchronizeCache10 = $35;

  ReadyAttempts = 10;

type
  TCommandBlock = packed record
    Signature: LongWord;
    Tag: LongWord;
    DataLength: LongWord;
    Flags: Byte;
    LogicalUnit: Byte;
    CommandLength: Byte;
    Command: array[0..15] of Byte;
  end;

  TCommandStatus = packed record
    Signature: LongWord;
    Tag: LongWord;
    Residue: LongWord;
    Status: Byte;
  end;

  TScsiCommand = array[0..15] of Byte;

  PUsbDisk = ^TUsbDisk;
  TUsbDisk = record
    Usb: PUsbDevice;
    InterfaceNumber: Byte;
    BulkIn: Byte;
    BulkOut: Byte;
    NextTag: LongWord;
    BlockSize: LongWord;
    BlockCount: QWord;
    Lock: TMutex;
    Device: PDeviceObject;
    BlockDevice: PBlockDevice;
    { Unplugged: requests fail. }
    IsGone: Boolean;
  end;

var
  UsbStorageDriver: PDriverObject;

{ --- Bulk-Only Transport ------------------------------------------------------ }

{ Reset recovery: the device's Bulk-Only state machine reset, and both
  endpoints' halts cleared (the controller's side of each is reset by
  the clearing's own stall recovery, if they stalled). }
procedure ResetRecovery(Disk: PUsbDisk);
const
  ClassToInterface = $21;
  RequestBulkOnlyReset = $FF;
begin
  UsbControlTransfer(Disk^.Usb, ClassToInterface, RequestBulkOnlyReset, 0, Disk^.InterfaceNumber, nil, 0);
  UsbClearEndpointHalt(Disk^.Usb, Disk^.BulkIn);
  UsbClearEndpointHalt(Disk^.Usb, Disk^.BulkOut);
end;

{ Reads the status wrapper; a stall is cleared and the read tried once
  more. }
function ReadCommandStatus(Disk: PUsbDisk; out Status: TCommandStatus): Boolean;
var
  Transferred: LongWord;
  Outcome: TUsbTransferStatus;
begin
  FillMemory(@Status, SizeOf(Status), 0);
  Outcome := UsbBulkTransfer(Disk^.Usb, Disk^.BulkIn, @Status, CommandStatusSize, Transferred);
  if Outcome = UsbTransferStalled then
  begin
    UsbClearEndpointHalt(Disk^.Usb, Disk^.BulkIn);
    Outcome := UsbBulkTransfer(Disk^.Usb, Disk^.BulkIn, @Status, CommandStatusSize, Transferred);
  end;
  Result := (Outcome = UsbTransferDone) and (Transferred = CommandStatusSize);
end;

{ Runs one SCSI command: Command (CommandLength bytes), then DataLength
  bytes in (IsIn) or out of Data, then the status. True if the device
  reports success. A failure is recovered from (see the unit's header)
  before returning. }
function RunScsiCommand(Disk: PUsbDisk; const Command: TScsiCommand; CommandLength: Byte;
  Data: Pointer; DataLength: LongWord; IsIn: Boolean): Boolean;
var
  Block: TCommandBlock;
  Status: TCommandStatus;
  Transferred: LongWord;
  Endpoint: Byte;
  Outcome: TUsbTransferStatus;
begin
  FillMemory(@Block, SizeOf(Block), 0);
  Inc(Disk^.NextTag);
  Block.Signature := CommandBlockSignature;
  Block.Tag := Disk^.NextTag;
  Block.DataLength := DataLength;
  if IsIn then
    Block.Flags := DirectionIn;
  Block.CommandLength := CommandLength;
  CopyMemory(@Block.Command[0], @Command[0], CommandLength);
  if (UsbBulkTransfer(Disk^.Usb, Disk^.BulkOut, @Block, CommandBlockSize, Transferred) <> UsbTransferDone) or
     (Transferred <> CommandBlockSize) then
  begin
    ResetRecovery(Disk);
    Exit(False);
  end;
  if DataLength > 0 then
  begin
    if IsIn then
      Endpoint := Disk^.BulkIn
    else
      Endpoint := Disk^.BulkOut;
    Outcome := UsbBulkTransfer(Disk^.Usb, Endpoint, Data, DataLength, Transferred);
    if Outcome = UsbTransferStalled then
      { The device ends the data stage early: its status still follows. }
      UsbClearEndpointHalt(Disk^.Usb, Endpoint)
    else if Outcome <> UsbTransferDone then
    begin
      ResetRecovery(Disk);
      Exit(False);
    end;
  end;
  if not ReadCommandStatus(Disk, Status) or (Status.Signature <> CommandStatusSignature) or
     (Status.Tag <> Block.Tag) or (Status.Status > 1) then
  begin
    { No status, not a status, not this command's, or a phase error. }
    ResetRecovery(Disk);
    Exit(False);
  end;
  Result := (Status.Status = 0) and (Status.Residue = 0);
end;

{ A power of two from 512 to 4096: whole blocks fit every piece. }
function UsbBlockSizeIsUsable(BlockSize: LongWord): Boolean;
begin
  Result := (BlockSize >= 512) and (BlockSize <= 4096) and ((BlockSize and (BlockSize - 1)) = 0);
end;

procedure ClearCommand(out Command: TScsiCommand);
begin
  FillMemory(@Command[0], SizeOf(Command), 0);
end;

procedure PutBigEndian32(Destination: PByte; Value: LongWord);
begin
  Destination[0] := Byte(Value shr 24);
  Destination[1] := Byte(Value shr 16);
  Destination[2] := Byte(Value shr 8);
  Destination[3] := Byte(Value);
end;

function GetBigEndian32(Source: PByte): LongWord;
begin
  Result := (LongWord(Source[0]) shl 24) or (LongWord(Source[1]) shl 16) or
    (LongWord(Source[2]) shl 8) or Source[3];
end;

{ Waits for the device to report itself ready; asking for the sense data
  after each refusal clears the condition (a fresh device starts with a
  "unit attention"). }
function WaitUntilReady(Disk: PUsbDisk): Boolean;
var
  Command: TScsiCommand;
  Sense: array[0..17] of Byte;
  Attempt: Integer;
begin
  for Attempt := 1 to ReadyAttempts do
  begin
    ClearCommand(Command);
    Command[0] := ScsiTestUnitReady;
    if RunScsiCommand(Disk, Command, 6, nil, 0, False) then
      Exit(True);
    ClearCommand(Command);
    Command[0] := ScsiRequestSense;
    Command[4] := SizeOf(Sense);
    RunScsiCommand(Disk, Command, 6, @Sense[0], SizeOf(Sense), True);
    SleepMilliseconds(50);
  end;
  Result := False;
end;

function ReadCapacity(Disk: PUsbDisk): Boolean;
var
  Command: TScsiCommand;
  Capacity: array[0..7] of Byte;
begin
  ClearCommand(Command);
  Command[0] := ScsiReadCapacity10;
  Result := RunScsiCommand(Disk, Command, 10, @Capacity[0], SizeOf(Capacity), True);
  if not Result then
    Exit;
  { A last block of FFFFFFFFh means more than READ(10) reaches: only
    what it reaches is used. }
  Disk^.BlockCount := GetBigEndian32(@Capacity[0]);
  if Disk^.BlockCount <> $FFFFFFFF then
    Inc(Disk^.BlockCount);
  Disk^.BlockSize := GetBigEndian32(@Capacity[4]);
  Result := UsbBlockSizeIsUsable(Disk^.BlockSize);
end;

{ Appends the Count characters at Source, without trailing spaces, to
  Model (Length characters so far). }
procedure AppendTrimmed(Model: PChar; var Length: Integer; Capacity: Integer; Source: PByte; Count: Integer);
var
  Index: Integer;
begin
  while (Count > 0) and (Source[Count - 1] = Ord(' ')) do
    Dec(Count);
  for Index := 0 to Count - 1 do
    if Length < Capacity - 1 then
    begin
      Model[Length] := Char(Source[Index]);
      Inc(Length);
    end;
end;

procedure ReadModel(Disk: PUsbDisk; Model: PChar; Capacity: Integer);
var
  Command: TScsiCommand;
  Inquiry: array[0..35] of Byte;
  Length: Integer;
begin
  CopyText(Model, 'USB mass storage', Capacity);
  ClearCommand(Command);
  Command[0] := ScsiInquiry;
  Command[4] := SizeOf(Inquiry);
  if not RunScsiCommand(Disk, Command, 6, @Inquiry[0], SizeOf(Inquiry), True) then
    Exit;
  { Vendor (8 bytes) and product (16 bytes), each padded with spaces. }
  Length := 0;
  AppendTrimmed(Model, Length, Capacity, @Inquiry[8], 8);
  if (Length > 0) and (Length < Capacity - 1) then
  begin
    Model[Length] := ' ';
    Inc(Length);
  end;
  AppendTrimmed(Model, Length, Capacity, @Inquiry[16], 16);
  Model[Length] := #0;
end;

{ --- Requests -------------------------------------------------------------------- }

function TransferPiece(Disk: PUsbDisk; IsWrite: Boolean; FirstBlock: QWord; Buffer: PByte;
  ByteCount: LongWord): Boolean;
var
  Command: TScsiCommand;
begin
  ClearCommand(Command);
  if IsWrite then
    Command[0] := ScsiWrite10
  else
    Command[0] := ScsiRead10;
  PutBigEndian32(@Command[2], LongWord(FirstBlock));
  Command[7] := Byte((ByteCount div Disk^.BlockSize) shr 8);
  Command[8] := Byte(ByteCount div Disk^.BlockSize);
  Result := RunScsiCommand(Disk, Command, 10, Buffer, ByteCount, not IsWrite);
end;

function TransferUsbStorage(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Disk: PUsbDisk;
  Done: QWord;
  Piece: QWord;
  Command: TScsiCommand;
begin
  Disk := PUsbDisk(Device^.Extension);
  AcquireMutex(Disk^.Lock);
  Result := ErrorNone;
  if Disk^.IsGone then
    Result := ErrorIo
  else if Request.Operation = IoFunctionFlush then
  begin
    ClearCommand(Command);
    Command[0] := ScsiSynchronizeCache10;
    if not RunScsiCommand(Disk, Command, 10, nil, 0, False) then
      Result := ErrorIo;
  end
  else if (Request.Length = 0) or (Request.Length mod Disk^.BlockSize <> 0) or
          (Request.Offset mod Disk^.BlockSize <> 0) or
          ((Request.Offset + Request.Length) div Disk^.BlockSize > Disk^.BlockCount) then
    Result := ErrorInvalidArgument
  else
  begin
    Done := 0;
    while Done < Request.Length do
    begin
      Piece := Request.Length - Done;
      if Piece > UsbMaximumTransfer then
        Piece := UsbMaximumTransfer;
      if not TransferPiece(Disk, Request.Operation = IoFunctionWrite,
        (Request.Offset + Done) div Disk^.BlockSize, PByte(Request.Buffer) + Done, LongWord(Piece)) then
      begin
        Result := ErrorIo;
        Break;
      end;
      Done := Done + Piece;
    end;
    Request.Information := Int64(Done);
  end;
  ReleaseMutex(Disk^.Lock);
end;

procedure CreateUsbStorageDriver;
var
  Dispatch: TDispatchTable;
begin
  if UsbStorageDriver <> nil then
    Exit;
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @TransferUsbStorage;
  Dispatch[IoFunctionWrite] := @TransferUsbStorage;
  Dispatch[IoFunctionFlush] := @TransferUsbStorage;
  UsbStorageDriver := CreateDriver('usb-storage', Dispatch);
end;

{ --- Finding the interface --------------------------------------------------------- }

{ True if the interface is Bulk-Only SCSI with its two bulk endpoints. }
function FindStorageEndpoints(UsbInterface: PUsbInterfaceInfo; out BulkIn, BulkOut: TUsbEndpointInfo): Boolean;
begin
  Result := (UsbInterface^.InterfaceClass = UsbClassMassStorage) and (UsbInterface^.Subclass = SubclassScsi) and
    (UsbInterface^.Protocol = ProtocolBulkOnly) and
    FindUsbEndpoint(UsbInterface^, UsbTransferBulk, True, BulkIn) and
    FindUsbEndpoint(UsbInterface^, UsbTransferBulk, False, BulkOut);
end;

{ After waking from suspend to RAM: the disk was reset, and answers its
  first command with "unit attention"; it is asked until it is ready
  (the sense read clears that). }
procedure ResumeStorage(Usb: PUsbDevice; Context: Pointer);
begin
  WaitUntilReady(PUsbDisk(Context));
end;

{ The disk was unplugged. Taking its lock waits for the request running
  (which fails, its transfers do); every later one fails at once. }
procedure RemoveStorage(Usb: PUsbDevice; Context: Pointer);
var
  Disk: PUsbDisk;
begin
  Disk := PUsbDisk(Context);
  AcquireMutex(Disk^.Lock);
  Disk^.IsGone := True;
  ReleaseMutex(Disk^.Lock);
  if Disk^.BlockDevice <> nil then
    AnnounceDiskRemoval(Disk^.BlockDevice);
end;

function ProbeUsbStorage(Usb: PUsbDevice; UsbInterface: PUsbInterfaceInfo): Boolean;
var
  Disk: PUsbDisk;
  BulkIn: TUsbEndpointInfo;
  BulkOut: TUsbEndpointInfo;
  BlockDevice: PBlockDevice;
  Name: array[0..BlockDeviceNameLength - 1] of Char;
begin
  Result := False;
  if not FindStorageEndpoints(UsbInterface, BulkIn, BulkOut) then
    Exit;
  Disk := PUsbDisk(AllocateZeroedKernelMemory(SizeOf(TUsbDisk)));
  if Disk = nil then
    Exit;
  Disk^.Usb := Usb;
  Disk^.InterfaceNumber := UsbInterface^.Number;
  Disk^.BulkIn := BulkIn.Address;
  Disk^.BulkOut := BulkOut.Address;
  Result := True;
  InitializeMutex(Disk^.Lock);
  if not UsbOpenBulkEndpoints(Usb, Disk^.BulkIn, Disk^.BulkOut, BulkIn.MaximumPacket, BulkOut.MaximumPacket) or
     not WaitUntilReady(Disk) or not ReadCapacity(Disk) then
  begin
    DebugBeginMessage;
    DebugWriteTag('usb');
    DebugWriteLine('Mass storage device not ready, left alone');
    DebugEndMessage;
    Exit;
  end;
  CreateUsbStorageDriver;
  Disk^.Device := CreateDevice(UsbStorageDriver, nil, DeviceKindBlock, 0, 0);
  if Disk^.Device = nil then
    Exit;
  Disk^.Device^.Extension := Disk;
  Disk^.Device^.SizeInBytes := Disk^.BlockCount * Disk^.BlockSize;
  GenerateDiskName(@Name[0]);
  BlockDevice := CreateBlockDevice(@Name[0]);
  if BlockDevice = nil then
    Exit;
  ReadModel(Disk, @BlockDevice^.Model[0], BlockDeviceModelLength);
  BlockDevice^.BlockSize := Disk^.BlockSize;
  BlockDevice^.BlockCount := Disk^.BlockCount;
  BlockDevice^.StorageDevice := Disk^.Device;
  BlockDevice^.IsRemovable := True;
  Disk^.BlockDevice := BlockDevice;
  RegisterBlockDevice(BlockDevice);
  WriteBlockDeviceDescription(BlockDevice);
  UsbAddResumeHandler(Usb, @ResumeStorage, Disk);
  UsbAddRemovalHandler(Usb, @RemoveStorage, Disk);
  if DiskArrivalIsEnabled then
    AnnounceDiskArrival(BlockDevice);
end;


procedure RegisterUsbStorageDriver;
begin
  RegisterUsbClassDriver('usb-storage', @ProbeUsbStorage);
end;

end.
