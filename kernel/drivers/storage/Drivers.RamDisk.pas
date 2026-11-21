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
  The RAM disk: a disk image the loader read into memory, offered as a
  writable block device named "ramdisk0".

  A network boot brings the system volume this way (the loader fetches
  the image from the server, Loader.NetworkBoot), so a rebuilt userland
  takes effect at the next reset. Writes change only the memory: they
  are gone at the next boot. The image's pages are a MemoryRegionRamDisk
  region of the boot memory map, never given to anyone else, and the
  physical memory window already maps them.

  Its partitions (the system image has one) are scanned like any disk's,
  and the system volume is preferably the RAM disk's (Processes.Paths).

  A compressed image (xz or gzip: a Raspberry Pi 5 fetches it over slow
  TFTP) is unpacked first, into pages of its own, and the compressed
  copy's pages freed (Drivers.RamDiskDecompression).

  Discarding. The disk takes discard requests: each page of the image
  wholly inside a discarded range is given back to the page allocator
  (parts of pages are zeroed), and reads of it see zeros until a write
  gives it a fresh page. A table of the image's pages (their physical
  addresses, 0 for one given back) says where each is; one mutex
  covers every request, which only copy memory.
}
unit Drivers.RamDisk;

{$mode objfpc}
{$pointermath on}

interface

uses
  Boot.Information,
  Io.BlockDevice;

const
  RamDiskName = 'ramdisk0';

{ Notes where the loader put the image (in phase 0). }
procedure RecordBootRamDisk(const BootInformation: TBootInformation);

{ Registers the block device if there is an image; True if so. }
function InitializeRamDisk: Boolean;

{ True for the RAM disk and its partitions. }
function IsRamDiskDevice(Device: PBlockDevice): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Mutex,
  Io.Manager,
  Drivers.RamDiskDecompression,
  Debug.Output;

const
  SectorSize = 512;

var
  BootImage: TRamDiskImage;
  ImagePhysicalBase: QWord;
  ImageSizeInBytes: QWord;
  ImageContents: PByte;
  RamDiskDevice: PBlockDevice;
  { The image's pages (see the unit comment); nil if the image does not
    start on a page, and then nothing is discarded. }
  ImagePages: PQWord;
  ImagePageCount: QWord;
  TransferLock: TMutex;

procedure RecordBootRamDisk(const BootInformation: TBootInformation);
var
  Index: QWord;
  Region: PMemoryRegion;
  RegionEnd: QWord;
begin
  BootImage.PhysicalBase := BootInformation.RamDiskPhysicalBase;
  BootImage.SizeInBytes := BootInformation.RamDiskSizeInBytes;
  BootImage.RegionStart := 0;
  BootImage.RegionEnd := 0;
  { The memory map's region holding the image: its pages are freed once
    a compressed image is unpacked. }
  Index := 0;
  while Index < BootInformation.MemoryRegionCount do
  begin
    Region := @BootInformation.MemoryRegions[Index];
    RegionEnd := Region^.PhysicalStart + Region^.PageCount * Boot.Information.PageSize;
    if (Region^.Kind = MemoryRegionRamDisk) and (BootImage.PhysicalBase >= Region^.PhysicalStart) and
       (BootImage.PhysicalBase < RegionEnd) then
    begin
      BootImage.RegionStart := Region^.PhysicalStart;
      BootImage.RegionEnd := RegionEnd;
    end;
    Inc(Index);
  end;
end;

function RequestIsValid(var Request: TIoRequest): Boolean;
var
  SectorCount: QWord;
begin
  if Request.Operation = IoFunctionFlush then
    Exit(Request.Length = 0);
  if (Request.Operation = IoFunctionDiscard) and (ImagePages = nil) then
    Exit(False);
  SectorCount := ImageSizeInBytes div SectorSize;
  Result := (Request.Length > 0) and (Request.Length mod SectorSize = 0) and
    (Request.Offset mod SectorSize = 0) and (Request.Offset div SectorSize < SectorCount) and
    (Request.Length div SectorSize <= SectorCount - Request.Offset div SectorSize);
end;

{ The page of the image at page Index, given a fresh zeroed one if it
  was discarded and Create; nil if there is none. }
function ImagePage(Index: QWord; Create: Boolean): PByte;
var
  Physical: TPhysicalAddress;
begin
  Physical := ImagePages[Index];
  if (Physical = 0) and Create then
  begin
    Physical := AllocateZeroedPhysicalPage(PageUsageGeneral);
    ImagePages[Index] := Physical;
  end;
  if Physical = 0 then
    Exit(nil);
  Result := PByte(PhysicalToVirtual(Physical));
end;

{ Reads, writes or discards Length bytes at Offset page by page. }
function TransferThroughPages(var Request: TIoRequest): LongInt;
var
  Offset: QWord;
  Done: QWord;
  Chunk: QWord;
  Within: QWord;
  Page: PByte;
  Index: QWord;
begin
  Result := ErrorNone;
  Done := 0;
  while Done < Request.Length do
  begin
    Offset := Request.Offset + Done;
    Index := Offset div PageSize;
    Within := Offset mod PageSize;
    Chunk := PageSize - Within;
    if Chunk > Request.Length - Done then
      Chunk := Request.Length - Done;
    case Request.Operation of
      IoFunctionRead:
        begin
          Page := ImagePage(Index, False);
          if Page = nil then
            ZeroMemory(PByte(Request.Buffer) + Done, Chunk)
          else
            CopyMemory(PByte(Request.Buffer) + Done, Page + Within, Chunk);
        end;
      IoFunctionWrite:
        begin
          Page := ImagePage(Index, True);
          if Page = nil then
          begin
            Result := ErrorOutOfMemory;
            Break;
          end;
          CopyMemory(Page + Within, PByte(Request.Buffer) + Done, Chunk);
        end;
      IoFunctionDiscard:
        if (Within = 0) and (Chunk = PageSize) then
        begin
          if ImagePages[Index] <> 0 then
            FreePhysicalPage(ImagePages[Index]);
          ImagePages[Index] := 0;
        end
        else
        begin
          Page := ImagePage(Index, False);
          if Page <> nil then
            ZeroMemory(Page + Within, Chunk);
        end;
    end;
    Done := Done + Chunk;
  end;
  Request.Information := Int64(Done);
end;

function TransferRamDisk(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  if not RequestIsValid(Request) then
    Exit(ErrorInvalidArgument);
  if Request.Operation = IoFunctionFlush then
  begin
    Request.Information := 0;
    Exit(ErrorNone);
  end;
  if ImagePages <> nil then
  begin
    AcquireMutex(TransferLock);
    Result := TransferThroughPages(Request);
    ReleaseMutex(TransferLock);
    Exit;
  end;
  case Request.Operation of
    IoFunctionRead:
      CopyMemory(Request.Buffer, ImageContents + Request.Offset, Request.Length);
    IoFunctionWrite:
      CopyMemory(ImageContents + Request.Offset, Request.Buffer, Request.Length);
  end;
  Request.Information := Int64(Request.Length);
  Result := ErrorNone;
end;

{ The table of the image's pages, for discarding (if the image starts
  on a page). }
procedure SetUpImagePages;
var
  Index: QWord;
begin
  InitializeMutex(TransferLock);
  if (ImagePhysicalBase mod PageSize) <> 0 then
    Exit;
  ImagePageCount := (ImageSizeInBytes + PageSize - 1) div PageSize;
  ImagePages := PQWord(AllocateKernelMemory(ImagePageCount * SizeOf(QWord)));
  if ImagePages = nil then
    Exit;
  Index := 0;
  while Index < ImagePageCount do
  begin
    ImagePages[Index] := ImagePhysicalBase + Index * PageSize;
    Inc(Index);
  end;
end;

function CreateRamDiskDevice: PDeviceObject;
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @TransferRamDisk;
  Dispatch[IoFunctionWrite] := @TransferRamDisk;
  Dispatch[IoFunctionFlush] := @TransferRamDisk;
  Dispatch[IoFunctionDiscard] := @TransferRamDisk;
  Driver := CreateDriver('ramdisk', Dispatch);
  if Driver = nil then
    Exit(nil);
  Result := CreateDevice(Driver, nil, DeviceKindBlock, 0, 0);
end;

function InitializeRamDisk: Boolean;
var
  Device: PDeviceObject;
begin
  Result := False;
  if (BootImage.PhysicalBase = 0) or (BootImage.SizeInBytes < SectorSize) then
    Exit;
  if not ExpandRamDiskImage(BootImage) then
    Exit;
  ImagePhysicalBase := BootImage.PhysicalBase;
  ImageSizeInBytes := BootImage.SizeInBytes;
  ImageContents := PByte(PhysicalToVirtual(ImagePhysicalBase));
  SetUpImagePages;
  Device := CreateRamDiskDevice;
  if Device = nil then
    Exit;
  Device^.SizeInBytes := ImageSizeInBytes - ImageSizeInBytes mod SectorSize;

  RamDiskDevice := CreateBlockDevice(RamDiskName);
  if RamDiskDevice = nil then
    Exit;
  CopyText(@RamDiskDevice^.Model[0], 'RAM disk (loaded at boot)', BlockDeviceModelLength);
  RamDiskDevice^.BlockSize := SectorSize;
  RamDiskDevice^.BlockCount := ImageSizeInBytes div SectorSize;
  RamDiskDevice^.StorageDevice := Device;
  RamDiskDevice^.SupportsDiscard := ImagePages <> nil;
  RegisterBlockDevice(RamDiskDevice);
  WriteBlockDeviceDescription(RamDiskDevice);

  DebugBeginMessage;
  DebugWriteTag('ramdisk');
  DebugWrite(RamDiskName);
  DebugWrite(': ');
  DebugWriteDecimal(ImageSizeInBytes div 1024);
  DebugWrite(' KiB image at physical ');
  DebugWriteAddress(ImagePhysicalBase);
  DebugWriteLine(', writable, lost at reset');
  DebugEndMessage;
  Result := True;
end;

function IsRamDiskDevice(Device: PBlockDevice): Boolean;
begin
  Result := (RamDiskDevice <> nil) and (Device <> nil) and
    ((Device = RamDiskDevice) or (Device^.Parent = RamDiskDevice));
end;

end.
