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
  Virtio block devices (the fast disks of QEMU and other hypervisors).

  Every disk becomes a block device of 512-byte sectors and a device
  object of the driver "virtio-blk", like an AHCI disk. A request is a
  descriptor chain on queue 0: a header the device reads (type: read,
  write or flush; first sector), the data pages, and a status byte the
  device writes. Data goes through bounce pages of the driver's own (up
  to BouncePageCount pages per command; longer requests are split), so
  callers' buffers need not be physically contiguous.

  One request runs at a time; others wait in a queue. Completion comes by
  MSI-X interrupt, finished by a deferred call; a device without MSI-X
  is polled.
}
unit Drivers.VirtioBlock;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every virtio block device found on PCI; returns how many. }
function InitializeVirtioBlockDevices: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.DeferredCalls,
  Kernel.Mutex,
  Kernel.Clock,
  Io.Pci,
  Io.Manager,
  Io.BlockDevice,
  Drivers.VirtioPci,
  Debug.Output;

const
  TransitionalBlockDeviceId = $1001;
  SectorSize = 512;
  BouncePageCount = 32;
  PageBytes = 4096;
  PollTimeoutMilliseconds = 5000;

  FeatureReadOnly = 5;
  FeatureFlush = 9;

  RequestTypeRead = 0;
  RequestTypeWrite = 1;
  RequestTypeFlush = 4;
  RequestStatusOk = 0;

  StatusOffsetInHeaderPage = 256;

type
  TBlockRequestHeader = packed record
    RequestType: LongWord;
    Reserved: LongWord;
    Sector: QWord;
  end;
  PBlockRequestHeader = ^TBlockRequestHeader;

  PVirtioDisk = ^TVirtioDisk;
  TVirtioDisk = record
    Virtio: TVirtioDevice;
    Queue: TVirtqueue;
    Device: PDeviceObject;
    SectorCount: QWord;
    SupportsFlush: Boolean;
    HeaderPage: PByte;
    HeaderPagePhysical: QWord;
    BouncePages: array[0..BouncePageCount - 1] of PByte;
    BouncePagesPhysical: array[0..BouncePageCount - 1] of QWord;
    { Interrupt driven requests. }
    StateLock: TSpinLock;
    Waiting: TRequestQueue;
    Current: PIoRequest;
    CurrentDone: QWord;
    CurrentPiece: QWord;
    FinishCommand: TDeferredCall;
    { Polled requests. }
    PollingLock: TMutex;
  end;

var
  VirtioBlockDriver: PDriverObject;

{ --- Commands ------------------------------------------------------------- }

function DiskOf(Device: PDeviceObject): PVirtioDisk;
begin
  Result := PVirtioDisk(Device^.Extension);
end;

function PieceLength(Request: PIoRequest; Done: QWord): QWord;
begin
  Result := Request^.Length - Done;
  if Result > BouncePageCount * PageBytes then
    Result := BouncePageCount * PageBytes;
end;

{ Builds and submits the chain for the next Piece bytes of Request,
  Done bytes in (Piece 0 for a flush). }
procedure SubmitPiece(Disk: PVirtioDisk; Request: PIoRequest; Done, Piece: QWord);
var
  Header: PBlockRequestHeader;
  Descriptor: PVirtqueueDescriptor;
  Count: Word;
  PageIndex: Integer;
  Remaining: QWord;
  Chunk: QWord;
  IsRead: Boolean;
begin
  Header := PBlockRequestHeader(Disk^.HeaderPage);
  IsRead := Request^.Operation = IoFunctionRead;
  case Request^.Operation of
    IoFunctionRead: Header^.RequestType := RequestTypeRead;
    IoFunctionWrite: Header^.RequestType := RequestTypeWrite;
  else
    Header^.RequestType := RequestTypeFlush;
  end;
  Header^.Reserved := 0;
  Header^.Sector := (Request^.Offset + Done) div SectorSize;
  Disk^.HeaderPage[StatusOffsetInHeaderPage] := $FF;

  Descriptor := Disk^.Queue.Descriptors;
  Descriptor[0].Address := Disk^.HeaderPagePhysical;
  Descriptor[0].Length := SizeOf(TBlockRequestHeader);
  Descriptor[0].Flags := VirtqueueDescriptorNext;
  Descriptor[0].Next := 1;
  Count := 1;
  Remaining := Piece;
  PageIndex := 0;
  while Remaining > 0 do
  begin
    Chunk := Remaining;
    if Chunk > PageBytes then
      Chunk := PageBytes;
    if Request^.Operation = IoFunctionWrite then
      CopyMemory(Disk^.BouncePages[PageIndex], PByte(Request^.Buffer) + Done + QWord(PageIndex) * PageBytes,
        Chunk);
    Descriptor[Count].Address := Disk^.BouncePagesPhysical[PageIndex];
    Descriptor[Count].Length := LongWord(Chunk);
    Descriptor[Count].Flags := VirtqueueDescriptorNext;
    if IsRead then
      Descriptor[Count].Flags := Descriptor[Count].Flags or VirtqueueDescriptorWrite;
    Descriptor[Count].Next := Count + 1;
    Inc(Count);
    Inc(PageIndex);
    Remaining := Remaining - Chunk;
  end;
  Descriptor[Count].Address := Disk^.HeaderPagePhysical + StatusOffsetInHeaderPage;
  Descriptor[Count].Length := 1;
  Descriptor[Count].Flags := VirtqueueDescriptorWrite;
  Descriptor[Count].Next := 0;
  SubmitVirtqueueChain(Disk^.Queue);
end;

{ After the device finished a piece: copies read data out; True if the
  device reported success. }
function FinishPiece(Disk: PVirtioDisk; Request: PIoRequest; Done, Piece: QWord): Boolean;
var
  PageIndex: Integer;
  Remaining: QWord;
  Chunk: QWord;
begin
  Result := Disk^.HeaderPage[StatusOffsetInHeaderPage] = RequestStatusOk;
  if not Result or (Request^.Operation <> IoFunctionRead) then
    Exit;
  Remaining := Piece;
  PageIndex := 0;
  while Remaining > 0 do
  begin
    Chunk := Remaining;
    if Chunk > PageBytes then
      Chunk := PageBytes;
    CopyMemory(PByte(Request^.Buffer) + Done + QWord(PageIndex) * PageBytes, Disk^.BouncePages[PageIndex],
      Chunk);
    Inc(PageIndex);
    Remaining := Remaining - Chunk;
  end;
end;

{ --- Polled requests ------------------------------------------------------- }

function WaitForCompletion(Disk: PVirtioDisk): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(PollTimeoutMilliseconds);
  while not TakeVirtqueueCompletion(Disk^.Queue) do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

function TransferPolled(Disk: PVirtioDisk; var Request: TIoRequest): LongInt;
var
  Done: QWord;
  Piece: QWord;
begin
  Result := ErrorNone;
  Done := 0;
  AcquireMutex(Disk^.PollingLock);
  repeat
    Piece := PieceLength(@Request, Done);
    SubmitPiece(Disk, @Request, Done, Piece);
    if not WaitForCompletion(Disk) or not FinishPiece(Disk, @Request, Done, Piece) then
    begin
      Result := ErrorIo;
      Break;
    end;
    Done := Done + Piece;
  until Done >= Request.Length;
  ReleaseMutex(Disk^.PollingLock);
  Request.Information := Int64(Done);
end;

{ --- Interrupt driven requests ---------------------------------------------- }

{ Caller holds StateLock. }
procedure BeginRequestLocked(Disk: PVirtioDisk; Request: PIoRequest);
begin
  Disk^.Current := Request;
  Disk^.CurrentDone := 0;
  Disk^.CurrentPiece := PieceLength(Request, 0);
  SubmitPiece(Disk, Request, 0, Disk^.CurrentPiece);
end;

{ Deferred call after the queue interrupt. }
procedure FinishCommand(Context: Pointer);
var
  Disk: PVirtioDisk;
  Request: PIoRequest;
  Status: LongInt;
  PreviousLevel: TPriorityLevel;
begin
  Disk := PVirtioDisk(Context);
  PreviousLevel := AcquireSpinLock(Disk^.StateLock);
  Request := Disk^.Current;
  if (Request = nil) or not TakeVirtqueueCompletion(Disk^.Queue) then
  begin
    ReleaseSpinLock(Disk^.StateLock, PreviousLevel);
    Exit;
  end;
  if FinishPiece(Disk, Request, Disk^.CurrentDone, Disk^.CurrentPiece) then
  begin
    Disk^.CurrentDone := Disk^.CurrentDone + Disk^.CurrentPiece;
    if Disk^.CurrentDone < Request^.Length then
    begin
      Disk^.CurrentPiece := PieceLength(Request, Disk^.CurrentDone);
      SubmitPiece(Disk, Request, Disk^.CurrentDone, Disk^.CurrentPiece);
      ReleaseSpinLock(Disk^.StateLock, PreviousLevel);
      Exit;
    end;
    Status := ErrorNone;
  end
  else
    Status := ErrorIo;
  Request^.Information := Int64(Disk^.CurrentDone);
  Disk^.Current := TakeQueuedRequest(Disk^.Waiting);
  if Disk^.Current <> nil then
    BeginRequestLocked(Disk, Disk^.Current);
  ReleaseSpinLock(Disk^.StateLock, PreviousLevel);
  CompleteRequest(Request^, Status);
end;

procedure HandleVirtioBlockInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  QueueDeferredCall(PVirtioDisk(Context)^.FinishCommand);
end;

function TransferWithInterrupts(Disk: PVirtioDisk; var Request: TIoRequest): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  Result := StatusPending;
  PreviousLevel := AcquireSpinLock(Disk^.StateLock);
  if Disk^.Current = nil then
    BeginRequestLocked(Disk, @Request)
  else if not QueueRequest(Disk^.Waiting, Request) then
    Result := ErrorInterrupted;
  ReleaseSpinLock(Disk^.StateLock, PreviousLevel);
end;

{ --- The driver -------------------------------------------------------------- }

function RequestIsValid(Disk: PVirtioDisk; var Request: TIoRequest): Boolean;
begin
  if Request.Operation = IoFunctionFlush then
    Exit(Request.Length = 0);
  Result := (Request.Length > 0) and (Request.Length mod SectorSize = 0) and
    (Request.Offset mod SectorSize = 0) and (Request.Offset div SectorSize < Disk^.SectorCount) and
    (Request.Length div SectorSize <= Disk^.SectorCount - Request.Offset div SectorSize);
end;

function TransferVirtioBlock(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Disk: PVirtioDisk;
begin
  Disk := DiskOf(Device);
  if not RequestIsValid(Disk, Request) then
    Exit(ErrorInvalidArgument);
  { Without a volatile cache there is nothing to flush. }
  if (Request.Operation = IoFunctionFlush) and not Disk^.SupportsFlush then
    Exit(ErrorNone);
  if Disk^.Virtio.UsesInterrupts then
    Result := TransferWithInterrupts(Disk, Request)
  else
    Result := TransferPolled(Disk, Request);
end;

procedure CreateVirtioBlockDriver;
var
  Dispatch: TDispatchTable;
begin
  if VirtioBlockDriver <> nil then
    Exit;
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @TransferVirtioBlock;
  Dispatch[IoFunctionWrite] := @TransferVirtioBlock;
  Dispatch[IoFunctionFlush] := @TransferVirtioBlock;
  VirtioBlockDriver := CreateDriver('virtio-blk', Dispatch);
end;

function AllocateDiskPages(Disk: PVirtioDisk): Boolean;
var
  Index: Integer;
begin
  Disk^.HeaderPagePhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Disk^.HeaderPagePhysical = 0 then
    Exit(False);
  Disk^.HeaderPage := PByte(PhysicalToVirtual(Disk^.HeaderPagePhysical));
  for Index := 0 to BouncePageCount - 1 do
  begin
    Disk^.BouncePagesPhysical[Index] := AllocatePhysicalPage(PageUsageGeneral);
    if Disk^.BouncePagesPhysical[Index] = 0 then
      Exit(False);
    Disk^.BouncePages[Index] := PByte(PhysicalToVirtual(Disk^.BouncePagesPhysical[Index]));
  end;
  Result := True;
end;

function StartDisk(Pci: PPciDevice): Boolean;
var
  Disk: PVirtioDisk;
  Accepted: QWord;
  BlockDevice: PBlockDevice;
  Name: array[0..BlockDeviceNameLength - 1] of Char;
begin
  Result := False;
  Disk := PVirtioDisk(AllocateZeroedKernelMemory(SizeOf(TVirtioDisk)));
  if Disk = nil then
    Exit;
  if not OpenVirtioDevice(Pci, Disk^.Virtio) then
    Exit;
  if not NegotiateVirtioFeatures(Disk^.Virtio,
       (QWord(1) shl FeatureReadOnly) or (QWord(1) shl FeatureFlush), Accepted) or
     not AllocateDiskPages(Disk) or not SetUpVirtqueue(Disk^.Virtio, 0, Disk^.Queue) then
  begin
    FailVirtioDevice(Disk^.Virtio);
    Exit;
  end;
  Disk^.SupportsFlush := (Accepted and (QWord(1) shl FeatureFlush)) <> 0;
  Disk^.SectorCount := PQWord(Disk^.Virtio.DeviceConfiguration)^;

  InitializeSpinLock(Disk^.StateLock);
  InitializeMutex(Disk^.PollingLock);
  InitializeRequestQueue(Disk^.Waiting);
  InitializeDeferredCall(Disk^.FinishCommand, @FinishCommand, Disk);
  ConnectVirtioInterrupt(Disk^.Virtio, Disk^.Queue, @HandleVirtioBlockInterrupt, Disk);
  StartVirtioDevice(Disk^.Virtio);

  Disk^.Device := CreateDevice(VirtioBlockDriver, nil, DeviceKindBlock, 0, 0);
  if Disk^.Device = nil then
    Exit;
  Disk^.Device^.Extension := Disk;
  Disk^.Device^.SizeInBytes := Disk^.SectorCount * SectorSize;

  GenerateDiskName(@Name[0]);
  BlockDevice := CreateBlockDevice(@Name[0]);
  if BlockDevice = nil then
    Exit;
  CopyText(@BlockDevice^.Model[0], 'virtio block device', BlockDeviceModelLength);
  BlockDevice^.BlockSize := SectorSize;
  BlockDevice^.BlockCount := Disk^.SectorCount;
  BlockDevice^.WriteProtected := (Accepted and (QWord(1) shl FeatureReadOnly)) <> 0;
  BlockDevice^.StorageDevice := Disk^.Device;
  RegisterBlockDevice(BlockDevice);
  WriteBlockDeviceDescription(BlockDevice);

  DebugBeginMessage;
  DebugWriteTag('virtio');
  DebugWrite(@Name[0]);
  if Disk^.Virtio.UsesInterrupts then
    DebugWrite(': interrupts by MSI-X')
  else
    DebugWrite(': polled');
  if Disk^.SupportsFlush then
    DebugWrite(', write cache flushed on request');
  DebugWriteLine('');
  DebugEndMessage;
  Result := True;
end;

function InitializeVirtioBlockDevices: Integer;
var
  Index: Integer;
  Pci: PPciDevice;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Pci := PciDeviceAt(Index);
    if (Pci^.VendorId <> VirtioVendorId) or
       ((Pci^.DeviceId <> VirtioModernDeviceIdBase + VirtioDeviceTypeBlock) and
        (Pci^.DeviceId <> TransitionalBlockDeviceId)) then
      Continue;
    CreateVirtioBlockDriver;
    if StartDisk(Pci) then
      Inc(Result);
  end;
end;

end.
