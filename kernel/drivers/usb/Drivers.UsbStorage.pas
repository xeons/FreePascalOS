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
  only). Its requests are carried out synchronously by the thread that
  sends them, one at a time, up to UsbMaximumTransfer bytes per command.
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
  Drivers.Xhci,
  Debug.Output;

const
  ClassMassStorage = $08;
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
    BulkIn: Byte;
    BulkOut: Byte;
    NextTag: LongWord;
    BlockSize: LongWord;
    BlockCount: QWord;
    Lock: TMutex;
    Device: PDeviceObject;
  end;

var
  UsbStorageDriver: PDriverObject;

{ --- Bulk-Only Transport ------------------------------------------------------ }

{ Runs one SCSI command: Command (CommandLength bytes), then DataLength
  bytes in (IsIn) or out of Data, then the status. True if the device
  reports success. }
function RunScsiCommand(Disk: PUsbDisk; const Command: TScsiCommand; CommandLength: Byte;
  Data: Pointer; DataLength: LongWord; IsIn: Boolean): Boolean;
var
  Block: TCommandBlock;
  Status: TCommandStatus;
  Transferred: LongWord;
  Endpoint: Byte;
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
  if not UsbBulkTransfer(Disk^.Usb, Disk^.BulkOut, @Block, CommandBlockSize, Transferred) or
     (Transferred <> CommandBlockSize) then
    Exit(False);
  if DataLength > 0 then
  begin
    if IsIn then
      Endpoint := Disk^.BulkIn
    else
      Endpoint := Disk^.BulkOut;
    if not UsbBulkTransfer(Disk^.Usb, Endpoint, Data, DataLength, Transferred) then
      Exit(False);
  end;
  if not UsbBulkTransfer(Disk^.Usb, Disk^.BulkIn, @Status, CommandStatusSize, Transferred) or
     (Transferred <> CommandStatusSize) then
    Exit(False);
  Result := (Status.Signature = CommandStatusSignature) and (Status.Tag = Block.Tag) and
    (Status.Status = 0) and (Status.Residue = 0);
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
  Disk^.BlockCount := QWord(GetBigEndian32(@Capacity[0])) + 1;
  Disk^.BlockSize := GetBigEndian32(@Capacity[4]);
  Result := (Disk^.BlockSize >= 512) and (Disk^.BlockSize <= 4096);
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
  if Request.Operation = IoFunctionFlush then
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

{ Looks through the configuration for a Bulk-Only SCSI interface and its
  two bulk endpoints. }
function FindStorageInterface(Usb: PUsbDevice; out BulkIn, BulkOut: Byte;
  out InPacket, OutPacket: Word): Boolean;
const
  EndpointTransferBulk = 2;
var
  Position: LongWord;
  Length: Byte;
  Kind: Byte;
  Descriptor: PByte;
  InStorageInterface: Boolean;
begin
  BulkIn := 0;
  BulkOut := 0;
  InPacket := 0;
  OutPacket := 0;
  InStorageInterface := False;
  Position := 0;
  while Position + 2 <= Usb^.ConfigurationLength do
  begin
    Descriptor := Usb^.Configuration + Position;
    Length := Descriptor[0];
    Kind := Descriptor[1];
    if (Length < 2) or (Position + Length > Usb^.ConfigurationLength) then
      Break;
    if (Kind = UsbDescriptorInterface) and (Length >= 9) then
      InStorageInterface := (Descriptor[5] = ClassMassStorage) and (Descriptor[6] = SubclassScsi) and
        (Descriptor[7] = ProtocolBulkOnly)
    else if InStorageInterface and (Kind = UsbDescriptorEndpoint) and (Length >= 7) and
            ((Descriptor[3] and 3) = EndpointTransferBulk) then
    begin
      if (Descriptor[2] and $80) <> 0 then
      begin
        BulkIn := Descriptor[2];
        InPacket := Descriptor[4] or (Word(Descriptor[5]) shl 8);
      end
      else
      begin
        BulkOut := Descriptor[2];
        OutPacket := Descriptor[4] or (Word(Descriptor[5]) shl 8);
      end;
    end;
    Position := Position + Length;
  end;
  Result := (BulkIn <> 0) and (BulkOut <> 0);
end;

{ After waking from suspend to RAM: the disk was reset, and answers its
  first command with "unit attention"; it is asked until it is ready
  (the sense read clears that). }
procedure ResumeStorage(Usb: PUsbDevice; Context: Pointer);
begin
  WaitUntilReady(PUsbDisk(Context));
end;

function ProbeUsbStorage(Usb: PUsbDevice): Boolean;
var
  Disk: PUsbDisk;
  InPacket: Word;
  OutPacket: Word;
  BlockDevice: PBlockDevice;
  Name: array[0..BlockDeviceNameLength - 1] of Char;
begin
  Result := False;
  Disk := PUsbDisk(AllocateZeroedKernelMemory(SizeOf(TUsbDisk)));
  if Disk = nil then
    Exit;
  Disk^.Usb := Usb;
  if not FindStorageInterface(Usb, Disk^.BulkIn, Disk^.BulkOut, InPacket, OutPacket) then
  begin
    FreeKernelMemory(Disk);
    Exit;
  end;
  Result := True;
  InitializeMutex(Disk^.Lock);
  if not UsbOpenBulkEndpoints(Usb, Disk^.BulkIn, Disk^.BulkOut, InPacket, OutPacket) or
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
  RegisterBlockDevice(BlockDevice);
  WriteBlockDeviceDescription(BlockDevice);
  UsbSetResumeHandler(Usb, @ResumeStorage, Disk);
end;

procedure RegisterUsbStorageDriver;
begin
  RegisterUsbClassDriver(@ProbeUsbStorage);
end;

end.
