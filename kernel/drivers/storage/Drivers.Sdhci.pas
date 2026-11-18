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
  SD cards as disks: the "sdhci" driver.

  SD host controllers are found
    - on PCI: class 08h, subclass 05h (programming interface 0 or 1),
      the first slot (its BAR from the slot information register),
      interrupts by MSI if the controller has it, else its line
      (QEMU's sdhci-pci);
    - as ACPI platform devices: the Raspberry Pi 4's EMMC2 (BRCME88C,
      the SD card slot) and its Arasan controller (BCM2847, usually
      wired to the Wi-Fi chip, but the firmware can route the SD card to
      it), with their quirks (Drivers.Sdhci.Host): the base clock from
      the VideoCore firmware, no card detect, DMA only below 1 GiB
      without a _DMA saying more (EMMC2); 32-bit register writes with a
      pause after each, no DMA, no high speed bit, 3.3 V (Arasan);
    - as device tree platform devices: the Raspberry Pi 5's SD card slot
      (brcm,bcm2712-sdhci, Drivers.Sdhci.Bcm2712: its cfg block set for
      SD and presence forced, the card taken as present, the base clock
      from the capabilities or the tree's clock).

  The card in a slot (Drivers.Sdhci.Card) becomes a whole disk of 512-byte
  blocks (disk0, disk1, ...; partitions and file systems follow as for
  any disk). Requests run in the caller's thread, one at a time per
  slot; flushes have nothing to do (SD cards write through).

  Card detect: where the slot has it, a card inserted or removed raises
  an interrupt (or is noticed once a second without one) that wakes the
  slot's thread: a removed card's disk fails its requests and goes away
  (Io.DiskArrival), an inserted one is brought up and arrives.
}
unit Drivers.Sdhci;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every SD host controller (PCI, then ACPI platform) and the card
  in it; returns how many cards became disks. }
function InitializeSdhciControllers: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  Kernel.Mutex,
  Kernel.Events,
  Kernel.Threads,
  Kernel.Scheduler,
  Processes.Thread,
  Io.Manager,
  Io.BlockDevice,
  Io.DiskArrival,
  Io.Pci,
  Io.PciMessageInterrupts,
  Io.PciLineInterrupts,
  Io.PlatformDevices,
  Io.Dma,
  Drivers.Sdhci.Registers,
  Drivers.Sdhci.Host,
  Drivers.Sdhci.Card,
  Drivers.Sdhci.Bcm2712,
  Drivers.VideoCoreMailbox,
  Debug.Output;

const
  PciClassBaseSystem = $08;
  PciSubclassSdHost = $05;
  { The slot information register: the first slot's BAR in bits 0-2. }
  PciSlotInformation = $40;

  CardSettleMilliseconds = 100;
  CardWatchMilliseconds = 1000;

  { The Raspberry Pi's EMMC2 base clock if the firmware does not say. }
  Emmc2FallbackClockHertz = 100000000;

type
  PSdSlot = ^TSdSlot;

  { One card, while it is in its slot. }
  PSdDisk = ^TSdDisk;
  TSdDisk = record
    Slot: PSdSlot;
    Card: TSdCard;
    Device: PDeviceObject;
    BlockDevice: PBlockDevice;
    IsGone: Boolean;
  end;

  TSdSlot = record
    Host: TSdhciHost;
    { How it was found. }
    Pci: PPciDevice;
    Platform: PPlatformDevice;
    { Held while a request or card change runs. }
    Lock: TMutex;
    Disk: PSdDisk;
  end;

var
  SdhciDriver: PDriverObject;

{ --- Requests ----------------------------------------------------------------- }

function TransferSdCard(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Disk: PSdDisk;
  FirstBlock: QWord;
  BlockCount: QWord;
  Moved: Boolean;
begin
  Disk := PSdDisk(Device^.Extension);
  AcquireMutex(Disk^.Slot^.Lock);
  Result := ErrorNone;
  if Disk^.IsGone then
    Result := ErrorIo
  else if Request.Operation = IoFunctionFlush then
    Result := ErrorNone
  else if (Request.Length = 0) or (Request.Length mod SdBlockSize <> 0) or
          (Request.Offset mod SdBlockSize <> 0) or
          ((Request.Offset + Request.Length) div SdBlockSize > Disk^.Card.BlockCount) then
    Result := ErrorInvalidArgument
  else
  begin
    FirstBlock := Request.Offset div SdBlockSize;
    BlockCount := Request.Length div SdBlockSize;
    if Request.Operation = IoFunctionWrite then
      Moved := WriteCardBlocks(@Disk^.Slot^.Host, Disk^.Card, FirstBlock, LongWord(BlockCount),
        PByte(Request.Buffer))
    else
      Moved := ReadCardBlocks(@Disk^.Slot^.Host, Disk^.Card, FirstBlock, LongWord(BlockCount),
        PByte(Request.Buffer));
    if Moved then
      Request.Information := Int64(Request.Length)
    else
      Result := ErrorIo;
  end;
  ReleaseMutex(Disk^.Slot^.Lock);
end;

procedure CreateSdhciDriver;
var
  Dispatch: TDispatchTable;
begin
  if SdhciDriver <> nil then
    Exit;
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @TransferSdCard;
  Dispatch[IoFunctionWrite] := @TransferSdCard;
  Dispatch[IoFunctionFlush] := @TransferSdCard;
  SdhciDriver := CreateDriver('sdhci', Dispatch);
end;

{ --- Cards ------------------------------------------------------------------- }

procedure WriteSlotName(Slot: PSdSlot);
begin
  if Slot^.Pci <> nil then
  begin
    DebugWriteHex(Slot^.Pci^.VendorId, 4);
    DebugWrite(':');
    DebugWriteHex(Slot^.Pci^.DeviceId, 4);
  end
  else
  begin
    DebugWrite(@Slot^.Platform^.Path[0]);
    if Slot^.Platform^.DeviceTreeNode = NoDeviceTreeNode then
      DebugWrite(' (ACPI ')
    else
      DebugWrite(' (DT ');
    DebugWrite(@Slot^.Platform^.HardwareId[0]);
    DebugWrite(')');
  end;
end;

procedure ReportCard(Slot: PSdSlot; Disk: PSdDisk);
var
  Host: PSdhciHost;
begin
  Host := @Slot^.Host;
  DebugBeginMessage;
  DebugWriteTag('sdhci');
  DebugWrite(@Disk^.BlockDevice^.Name[0]);
  DebugWrite(': ');
  DebugWrite(CardKindText(Disk^.Card));
  DebugWrite(' card "');
  DebugWrite(@Disk^.Card.ProductName[0]);
  DebugWrite('", ');
  DebugWriteDecimal(Disk^.Card.BlockCount div 2048);
  DebugWrite(' MiB, on ');
  WriteSlotName(Slot);
  DebugWrite(' (SDHCI ');
  DebugWriteDecimal(Host^.Version + 1);
  DebugWrite('.00), ');
  if Host^.UsesAdma then
    DebugWrite('ADMA2')
  else
    DebugWrite('PIO');
  if Disk^.Card.FourBitBus then
    DebugWrite(', 4-bit')
  else
    DebugWrite(', 1-bit');
  if Disk^.Card.HighSpeed then
    DebugWrite(' high speed');
  DebugWrite(' at ');
  DebugWriteDecimal(Host^.ClockHertz div 1000000);
  DebugWrite(' MHz, ');
  if Host^.UsesInterrupts then
    DebugWrite('interrupts')
  else
    DebugWrite('polled');
  if not Host^.Dma.Coherent then
  begin
    DebugWrite(', ');
    DebugWrite(DmaCoherenceText(Host^.Dma));
  end;
  if Disk^.BlockDevice^.WriteProtected then
    DebugWrite(', write protected');
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure ReportNoCard(Slot: PSdSlot; Reason: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('sdhci');
  DebugWrite('Slot on ');
  WriteSlotName(Slot);
  DebugWrite(': ');
  DebugWriteLine(Reason);
  DebugEndMessage;
end;

{ Builds the model text: "SD card <product name>". }
procedure MakeModel(Disk: PSdDisk; Model: PChar; Capacity: PtrUInt);
begin
  CopyText(Model, 'SD card ', Capacity);
  if TextLength(Model) + 6 < Capacity then
    CopyText(Model + TextLength(Model), @Disk^.Card.ProductName[0], Capacity - TextLength(Model));
end;

{ Brings up the card in the slot and makes it a disk (registered, not
  announced). Caller holds the slot's lock. }
function BringUpCard(Slot: PSdSlot): PSdDisk;
var
  Disk: PSdDisk;
  Failure: PChar;
  Name: array[0..BlockDeviceNameLength - 1] of Char;
begin
  Result := nil;
  if not CardIsInserted(@Slot^.Host) then
  begin
    ReportNoCard(Slot, 'no card');
    Exit;
  end;
  Disk := PSdDisk(AllocateZeroedKernelMemory(SizeOf(TSdDisk)));
  if Disk = nil then
    Exit;
  Disk^.Slot := Slot;
  if not PowerUpCard(@Slot^.Host) or not InitializeCard(@Slot^.Host, Disk^.Card, Failure) then
  begin
    ReportNoCard(Slot, 'the card did not come up:');
    ReportNoCard(Slot, Failure);
    PowerDownCard(@Slot^.Host);
    FreeKernelMemory(Disk);
    Exit;
  end;
  CreateSdhciDriver;
  Disk^.Device := CreateDevice(SdhciDriver, nil, DeviceKindBlock, 0, 0);
  if Disk^.Device = nil then
    Exit;
  Disk^.Device^.Extension := Disk;
  Disk^.Device^.SizeInBytes := Disk^.Card.BlockCount * SdBlockSize;
  GenerateDiskName(@Name[0]);
  Disk^.BlockDevice := CreateBlockDevice(@Name[0]);
  if Disk^.BlockDevice = nil then
    Exit;
  MakeModel(Disk, @Disk^.BlockDevice^.Model[0], BlockDeviceModelLength);
  Disk^.BlockDevice^.BlockSize := SdBlockSize;
  Disk^.BlockDevice^.BlockCount := Disk^.Card.BlockCount;
  Disk^.BlockDevice^.WriteProtected := CardIsWriteProtected(@Slot^.Host);
  Disk^.BlockDevice^.IsRemovable := (Slot^.Host.Quirks.Flags and QuirkBrokenCardDetect) = 0;
  Disk^.BlockDevice^.StorageDevice := Disk^.Device;
  RegisterBlockDevice(Disk^.BlockDevice);
  WriteBlockDeviceDescription(Disk^.BlockDevice);
  ReportCard(Slot, Disk);
  Result := Disk;
end;

{ --- Card detect -------------------------------------------------------------- }

procedure TakeCardAway(Slot: PSdSlot);
var
  Disk: PSdDisk;
begin
  AcquireMutex(Slot^.Lock);
  Disk := Slot^.Disk;
  Slot^.Disk := nil;
  if Disk <> nil then
    Disk^.IsGone := True;
  PowerDownCard(@Slot^.Host);
  ReleaseMutex(Slot^.Lock);
  if Disk = nil then
    Exit;
  ReportNoCard(Slot, 'card removed');
  { The disk record stays: the block cache and file systems may hold it. }
  AnnounceDiskRemoval(Disk^.BlockDevice);
end;

procedure TakeCardIn(Slot: PSdSlot);
var
  Disk: PSdDisk;
begin
  AcquireMutex(Slot^.Lock);
  Disk := BringUpCard(Slot);
  Slot^.Disk := Disk;
  ReleaseMutex(Slot^.Lock);
  if Disk <> nil then
    AnnounceDiskArrival(Disk^.BlockDevice);
end;

{ The slot's thread: follows cards coming and going. }
procedure WatchSlot(Context: Pointer);
var
  Slot: PSdSlot;
begin
  Slot := PSdSlot(Context);
  while True do
  begin
    WaitForEventWithOptions(Slot^.Host.CardChanged, CardWatchMilliseconds, False);
    if CardIsInserted(@Slot^.Host) = (Slot^.Disk <> nil) then
      Continue;
    SleepMilliseconds(CardSettleMilliseconds);
    if CardIsInserted(@Slot^.Host) then
    begin
      if Slot^.Disk = nil then
        TakeCardIn(Slot);
    end
    else if Slot^.Disk <> nil then
      TakeCardAway(Slot);
  end;
end;

{ --- Controllers -------------------------------------------------------------- }

{ MSI or the line on PCI, the _CRS interrupt of a platform device;
  False if the slot is to be polled. }
function ConnectSlotInterrupt(Slot: PSdSlot): Boolean;
begin
  if Slot^.Pci <> nil then
    Result := (ConnectPciInterrupt(Slot^.Pci, @HandleSdhciInterrupt, @Slot^.Host) <> PciInterruptNone) or
      ConnectPciLineInterrupt(Slot^.Pci, @HandleSdhciInterrupt, @Slot^.Host)
  else
    Result := ConnectPlatformInterrupt(Slot^.Platform, 0, @HandleSdhciInterrupt, @Slot^.Host);
end;

{ Sets the slot's host up (registers mapped, quirks and Dma filled in),
  connects its interrupt and brings up its card. True if a card became
  a disk. }
function StartSlot(Slot: PSdSlot): Boolean;
begin
  Result := False;
  InitializeMutex(Slot^.Lock);
  if not InitializeHost(@Slot^.Host) then
  begin
    ReportNoCard(Slot, 'the controller did not reset, or has no base clock');
    Exit;
  end;
  Slot^.Host.UsesInterrupts := ConnectSlotInterrupt(Slot);
  AcquireMutex(Slot^.Lock);
  Slot^.Disk := BringUpCard(Slot);
  ReleaseMutex(Slot^.Lock);
  Result := Slot^.Disk <> nil;
  if (Slot^.Host.Quirks.Flags and QuirkBrokenCardDetect) = 0 then
    CreateSystemThread(@WatchSlot, Slot, DefaultThreadPriority + 4, 'SdCards', False);
end;

function StartPciSlot(Pci: PPciDevice): Boolean;
var
  Slot: PSdSlot;
  Bar: TPciBar;
  BarIndex: Integer;
begin
  Result := False;
  BarIndex := PciRead8(Pci, PciSlotInformation) and 7;
  if (BarIndex > 5) or not PciReadBar(Pci, BarIndex, Bar) or Bar.IsIoPort or
     (Bar.SizeInBytes < SdhciRegisterSpan) then
    Exit;
  Slot := PSdSlot(AllocateZeroedKernelMemory(SizeOf(TSdSlot)));
  if Slot = nil then
    Exit;
  Slot^.Pci := Pci;
  PciEnableDevice(Pci, True);
  Slot^.Host.Registers := PByte(MapDeviceMemory(Bar.PhysicalAddress, SdhciRegisterSpan));
  if Slot^.Host.Registers = nil then
    Exit;
  GetPciDmaAttributes(Pci, Slot^.Host.Dma);
  Result := StartSlot(Slot);
end;

var
  { Cards the platform probe brought up, for the caller. }
  PlatformCardsFound: Integer;

{ The quirks of the platform devices this driver takes. }
procedure SetPlatformQuirks(Device: PPlatformDevice; var Quirks: TSdhciQuirks);
var
  TreeClockHertz: LongWord;
begin
  if PlatformDeviceHasId(Device, 'brcm,bcm2712-sdhci') then
  begin
    PrepareBcm2712Slot(Device, TreeClockHertz);
    Quirks.Flags := QuirkBrokenCardDetect;
    Quirks.FallbackClockHertz := TreeClockHertz;
  end
  else if PlatformDeviceHasId(Device, 'BRCME88C') then
  begin
    Quirks.Flags := QuirkBrokenCardDetect or QuirkClockFromFirmware;
    if not Device^.HasDmaObject then
      Quirks.Flags := Quirks.Flags or QuirkDmaBelow1GiB;
    Quirks.FirmwareClockId := FirmwareClockEmmc2;
    Quirks.FallbackClockHertz := Emmc2FallbackClockHertz;
  end
  else if PlatformDeviceHasId(Device, 'BCM2847') then
  begin
    Quirks.Flags := QuirkRegisters32Bit or QuirkWriteDelay or QuirkBrokenCardDetect or QuirkNoHighSpeedBit or
      QuirkNoDma or QuirkVoltage33Only or QuirkClockFromFirmware;
    Quirks.FirmwareClockId := FirmwareClockEmmc;
  end;
end;

function ProbePlatformSlot(Device: PPlatformDevice): Boolean;
var
  Slot: PSdSlot;
  Length: QWord;
begin
  Result := False;
  if PlatformDeviceHasId(Device, 'brcm,bcm2712-sdhci') and Bcm2712SlotHoldsSdioDevice(Device) then
    Exit;
  Slot := PSdSlot(AllocateZeroedKernelMemory(SizeOf(TSdSlot)));
  if Slot = nil then
    Exit;
  Slot^.Platform := Device;
  Slot^.Host.Registers := PByte(MapPlatformMemory(Device, 0, Length));
  if (Slot^.Host.Registers = nil) or (Length < SdhciRegisterSpan) then
    Exit;
  Slot^.Host.Dma := Device^.Dma;
  SetPlatformQuirks(Device, Slot^.Host.Quirks);
  if StartSlot(Slot) then
    Inc(PlatformCardsFound);
  { Taken even without a card: the slot is this driver's. }
  Result := True;
end;

const
  PlatformSlotIds: array[0..3] of PChar = ('BRCME88C', 'BCM2847', 'brcm,bcm2712-sdhci', nil);
  PlatformSlotDriver: TPlatformDriver = (
    Name: 'sdhci';
    Ids: @PlatformSlotIds[0];
    Probe: @ProbePlatformSlot);

function InitializeSdhciControllers: Integer;
var
  Index: Integer;
  Pci: PPciDevice;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Pci := PciDeviceAt(Index);
    if (Pci^.ClassCode = PciClassBaseSystem) and (Pci^.Subclass = PciSubclassSdHost) and
       (Pci^.ProgrammingInterface <= 1) and StartPciSlot(Pci) then
      Inc(Result);
  end;
  PlatformCardsFound := 0;
  BindPlatformDriver(PlatformSlotDriver);
  Result := Result + PlatformCardsFound;
end;

end.
