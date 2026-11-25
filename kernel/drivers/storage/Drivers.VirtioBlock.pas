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

  DMA (Io.Dma): the header page (header, discard segment, status byte)
  is shared DMA memory; the bounce pages are streaming DMA memory,
  cleaned before the device reads them and invalidated around its
  writes. The device is given device addresses throughout. The copies
  between the bounce pages and the request's buffer may run at dispatch
  level (the deferred call): that is safe because request buffers are
  always resident kernel memory (Io.Manager; user data comes through
  the kernel's transfer buffers, and only user addresses are paged).

  One request runs at a time; others wait in a queue. Completion comes by
  MSI-X interrupt, finished by a deferred call; a device without MSI-X
  is polled. A polled request that times out resets the device before
  anything else is sent, so it cannot finish late into pages (and a
  used ring) a later request uses; if the reset fails, the disk fails
  every request from then on.

  A device offering VIRTIO_BLK_F_DISCARD takes discard requests: the
  header (type discard) is followed by one segment (first sector,
  sector count) instead of data, at most max_discard_sectors a request.
}
unit Drivers.VirtioBlock;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every virtio block device found on PCI; returns how many. }
function InitializeVirtioBlockDevices: Integer;

implementation

uses
  Io.PowerManagement,
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
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
  Io.Dma,
  Drivers.VirtioPci,
  Debug.Output;

const
  TransitionalBlockDeviceId = $1001;
  SectorSize = 512;
  BouncePageCount = 32;
  PageBytes = 4096;
  PollTimeoutMilliseconds = 5000;
  { A header, a data page and a status: the shortest useful chain. }
  MinimumQueueSize = 3;

  FeatureReadOnly = 5;
  FeatureFlush = 9;
  FeatureDiscard = 13;

  RequestTypeRead = 0;
  RequestTypeWrite = 1;
  RequestTypeFlush = 4;
  RequestTypeDiscard = 11;
  RequestStatusOk = 0;

  SegmentOffsetInHeaderPage = 64;
  StatusOffsetInHeaderPage = 256;
  { Where the device configuration says how many sectors a discard may
    cover. }
  ConfigurationMaximumDiscardSectors = 36;

type
  TBlockRequestHeader = packed record
    RequestType: LongWord;
    Reserved: LongWord;
    Sector: QWord;
  end;
  PBlockRequestHeader = ^TBlockRequestHeader;

  { struct virtio_blk_discard_write_zeroes }
  TDiscardSegment = packed record
    Sector: QWord;
    SectorCount: LongWord;
    Flags: LongWord;
  end;
  PDiscardSegment = ^TDiscardSegment;

  PVirtioDisk = ^TVirtioDisk;
  TVirtioDisk = record
    Virtio: TVirtioDevice;
    Queue: TVirtqueue;
    Device: PDeviceObject;
    SectorCount: QWord;
    SupportsFlush: Boolean;
    SupportsDiscard: Boolean;
    MaximumDiscardSectors: QWord;
    HeaderPage: PByte;
    HeaderMemory: TDmaBuffer;
    BouncePages: array[0..BouncePageCount - 1] of PByte;
    BounceMemory: array[0..BouncePageCount - 1] of TDmaBuffer;
    { Interrupt driven requests. }
    StateLock: TSpinLock;
    Waiting: TRequestQueue;
    Current: PIoRequest;
    CurrentDone: QWord;
    CurrentPiece: QWord;
    FinishCommand: TDeferredCall;
    { Polled requests. }
    PollingLock: TMutex;
    { Bounce pages one chain may carry: a header and a status descriptor
      besides them must fit the queue. }
    PagesPerPiece: Integer;
    { A timed out request could not be stopped by a reset: every request
      fails. }
    IsBroken: Boolean;
  end;

var
  VirtioBlockDriver: PDriverObject;

{ --- Commands ------------------------------------------------------------- }

function DiskOf(Device: PDeviceObject): PVirtioDisk;
begin
  Result := PVirtioDisk(Device^.Extension);
end;

function PieceLength(Request: PIoRequest; Done: QWord): QWord;
var
  Disk: PVirtioDisk;
begin
  Result := Request^.Length - Done;
  Disk := DiskOf(Request^.Device);
  if Request^.Operation = IoFunctionDiscard then
  begin
    if Result div SectorSize > Disk^.MaximumDiscardSectors then
      Result := Disk^.MaximumDiscardSectors * SectorSize;
    Exit;
  end;
  if Result > QWord(Disk^.PagesPerPiece) * PageBytes then
    Result := QWord(Disk^.PagesPerPiece) * PageBytes;
end;

{ The chain of a discard: header, segment, status. }
procedure SubmitDiscard(Disk: PVirtioDisk; Request: PIoRequest; Done, Piece: QWord);
var
  Header: PBlockRequestHeader;
  Segment: PDiscardSegment;
  Descriptor: PVirtqueueDescriptor;
begin
  Header := PBlockRequestHeader(Disk^.HeaderPage);
  Header^.RequestType := RequestTypeDiscard;
  Header^.Reserved := 0;
  Header^.Sector := 0;
  Segment := PDiscardSegment(Disk^.HeaderPage + SegmentOffsetInHeaderPage);
  Segment^.Sector := (Request^.Offset + Done) div SectorSize;
  Segment^.SectorCount := LongWord(Piece div SectorSize);
  Segment^.Flags := 0;
  Disk^.HeaderPage[StatusOffsetInHeaderPage] := $FF;
  Descriptor := Disk^.Queue.Descriptors;
  Descriptor[0].Address := Disk^.HeaderMemory.DeviceAddress;
  Descriptor[0].Length := SizeOf(TBlockRequestHeader);
  Descriptor[0].Flags := VirtqueueDescriptorNext;
  Descriptor[0].Next := 1;
  Descriptor[1].Address := Disk^.HeaderMemory.DeviceAddress + SegmentOffsetInHeaderPage;
  Descriptor[1].Length := SizeOf(TDiscardSegment);
  Descriptor[1].Flags := VirtqueueDescriptorNext;
  Descriptor[1].Next := 2;
  Descriptor[2].Address := Disk^.HeaderMemory.DeviceAddress + StatusOffsetInHeaderPage;
  Descriptor[2].Length := 1;
  Descriptor[2].Flags := VirtqueueDescriptorWrite;
  Descriptor[2].Next := 0;
  SubmitVirtqueueChain(Disk^.Queue);
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
  if Request^.Operation = IoFunctionDiscard then
  begin
    SubmitDiscard(Disk, Request, Done, Piece);
    Exit;
  end;
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
  Descriptor[0].Address := Disk^.HeaderMemory.DeviceAddress;
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
    begin
      CopyMemory(Disk^.BouncePages[PageIndex], PByte(Request^.Buffer) + Done + QWord(PageIndex) * PageBytes,
        Chunk);
      PrepareDmaToDevice(Disk^.Virtio.Dma, Disk^.BouncePages[PageIndex], Chunk);
    end
    else
      PrepareDmaFromDevice(Disk^.Virtio.Dma, Disk^.BouncePages[PageIndex], Chunk);
    Descriptor[Count].Address := Disk^.BounceMemory[PageIndex].DeviceAddress;
    Descriptor[Count].Length := LongWord(Chunk);
    Descriptor[Count].Flags := VirtqueueDescriptorNext;
    if IsRead then
      Descriptor[Count].Flags := Descriptor[Count].Flags or VirtqueueDescriptorWrite;
    Descriptor[Count].Next := Count + 1;
    Inc(Count);
    Inc(PageIndex);
    Remaining := Remaining - Chunk;
  end;
  Descriptor[Count].Address := Disk^.HeaderMemory.DeviceAddress + StatusOffsetInHeaderPage;
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
    FinishDmaFromDevice(Disk^.Virtio.Dma, Disk^.BouncePages[PageIndex], Chunk);
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
  if Disk^.IsBroken then
  begin
    ReleaseMutex(Disk^.PollingLock);
    Request.Information := 0;
    Exit(ErrorIo);
  end;
  repeat
    Piece := PieceLength(@Request, Done);
    SubmitPiece(Disk, @Request, Done, Piece);
    if not WaitForCompletion(Disk) then
    begin
      { The device may still finish the chain: reset it before the pages
        and the queue are used again. }
      if not RestartVirtioDevice(Disk^.Virtio, Disk^.Queue) then
        Disk^.IsBroken := True;
      Result := ErrorIo;
      Break;
    end;
    if not FinishPiece(Disk, @Request, Done, Piece) then
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
  if (Request.Operation = IoFunctionDiscard) and not Disk^.SupportsDiscard then
    Exit(False);
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
  Dispatch[IoFunctionDiscard] := @TransferVirtioBlock;
  VirtioBlockDriver := CreateDriver('virtio-blk', Dispatch);
end;

function AllocateDiskPages(Disk: PVirtioDisk): Boolean;
var
  Index: Integer;
begin
  { The header and status the device reads and writes while it runs:
    shared memory. }
  if not AllocateDmaBuffer(Disk^.Virtio.Dma, PageBytes, DmaShared, Disk^.HeaderMemory) then
    Exit(False);
  Disk^.HeaderPage := Disk^.HeaderMemory.Address;
  for Index := 0 to BouncePageCount - 1 do
  begin
    if not AllocateDmaBuffer(Disk^.Virtio.Dma, PageBytes, DmaStreaming, Disk^.BounceMemory[Index]) then
      Exit(False);
    Disk^.BouncePages[Index] := Disk^.BounceMemory[Index].Address;
  end;
  Result := True;
end;

procedure FreeDiskPages(Disk: PVirtioDisk);
var
  Index: Integer;
begin
  FreeDmaBuffer(Disk^.HeaderMemory);
  Disk^.HeaderPage := nil;
  for Index := 0 to BouncePageCount - 1 do
  begin
    FreeDmaBuffer(Disk^.BounceMemory[Index]);
    Disk^.BouncePages[Index] := nil;
  end;
end;

{ Waking from suspend to RAM reset the device (block I/O was stopped
  before, so nothing was in flight). }
procedure ResumeDisk(Context: Pointer);
var
  Disk: PVirtioDisk;
begin
  Disk := PVirtioDisk(Context);
  RestartVirtioDevice(Disk^.Virtio, Disk^.Queue);
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
  begin
    FreeKernelMemory(Disk);
    Exit;
  end;
  if not NegotiateVirtioFeatures(Disk^.Virtio,
       (QWord(1) shl FeatureReadOnly) or (QWord(1) shl FeatureFlush) or (QWord(1) shl FeatureDiscard),
       Accepted) or
     not AllocateDiskPages(Disk) or not SetUpVirtqueue(Disk^.Virtio, 0, Disk^.Queue) or
     (Disk^.Queue.Size < MinimumQueueSize) then
  begin
    { The device never started: nothing of this memory is in its hands
      (the queue's own pages stay with the failed device). }
    FailVirtioDevice(Disk^.Virtio);
    FreeDiskPages(Disk);
    FreeKernelMemory(Disk);
    Exit;
  end;
  Disk^.PagesPerPiece := Disk^.Queue.Size - 2;
  if Disk^.PagesPerPiece > BouncePageCount then
    Disk^.PagesPerPiece := BouncePageCount;
  Disk^.SupportsFlush := (Accepted and (QWord(1) shl FeatureFlush)) <> 0;
  Disk^.SectorCount := PQWord(Disk^.Virtio.DeviceConfiguration)^;
  Disk^.SupportsDiscard := (Accepted and (QWord(1) shl FeatureDiscard)) <> 0;
  if Disk^.SupportsDiscard then
  begin
    Disk^.MaximumDiscardSectors :=
      PLongWord(PByte(Disk^.Virtio.DeviceConfiguration) + ConfigurationMaximumDiscardSectors)^;
    if Disk^.MaximumDiscardSectors = 0 then
      Disk^.SupportsDiscard := False;
  end;

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
  BlockDevice^.SupportsDiscard := Disk^.SupportsDiscard;
  BlockDevice^.MaximumDiscardBlocks := Disk^.MaximumDiscardSectors;
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
  if Disk^.SupportsDiscard then
    DebugWrite(', discards');
  DebugWriteLine('');
  DebugEndMessage;
  RegisterPowerHandler('virtio block', PowerStageDevices, nil, @ResumeDisk, Disk);
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
