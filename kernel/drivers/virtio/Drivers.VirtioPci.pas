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
  Virtio devices on PCI (virtio 1.0, "modern" devices).

  A virtio device describes its register areas through PCI vendor
  capabilities: the common configuration (features, status, queues),
  where to notify a queue, the interrupt status, and the device specific
  configuration. Each lies in one of the device's memory BARs.

  Starting a device: reset it, acknowledge it, agree on features (only
  ones both sides know, always including VIRTIO_F_VERSION_1), set up its
  queues, then tell it the driver is ready.

  Queues are "split" virtqueues: a descriptor table of buffers (physical
  address, length, flags, next), an available ring where the driver puts
  the first descriptor of each request, and a used ring where the device
  puts what it has finished. Each part gets a page of its own (virtio
  1.0 places them independently). A driver either keeps one request in
  flight per queue, starting at descriptor 0 (SubmitVirtqueueChain,
  TakeVirtqueueCompletion: the block driver), or offers many chains at
  once and takes each finished one back by its head (OfferVirtqueueChain,
  NotifyVirtqueue, TakeVirtqueueUsedChain: the network driver).

  Interrupts come by MSI-X: queue interrupts go through table entry 0,
  and configuration changes too if the driver asks for them (a network
  card's link).
}
unit Drivers.VirtioPci;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Pci,
  Kernel.Interrupts;

const
  VirtioVendorId = $1AF4;
  { Modern device ids are $1040 + the virtio device type. }
  VirtioModernDeviceIdBase = $1040;
  VirtioDeviceTypeNetwork = 1;
  VirtioDeviceTypeBlock = 2;

  VirtioFeatureVersion1 = 32;

  VirtqueueDescriptorNext = 1;
  VirtqueueDescriptorWrite = 2;

  MaximumQueueSize = 64;

type
  TVirtqueueDescriptor = packed record
    Address: QWord;
    Length: LongWord;
    Flags: Word;
    Next: Word;
  end;
  PVirtqueueDescriptor = ^TVirtqueueDescriptor;

  PVirtqueue = ^TVirtqueue;
  TVirtqueue = record
    Index: Word;
    Size: Word;
    Descriptors: PVirtqueueDescriptor;
    { flags, idx, ring[Size] }
    Available: PWord;
    { flags, idx, then (id: LongWord, length: LongWord) pairs }
    Used: PByte;
    NotifyAddress: PWord;
    LastSeenUsed: Word;
    DescriptorsPhysical: QWord;
    AvailablePhysical: QWord;
    UsedPhysical: QWord;
  end;

  PPVirtqueue = ^PVirtqueue;

  PVirtioDevice = ^TVirtioDevice;
  TVirtioDevice = record
    Pci: PPciDevice;
    Common: PByte;
    NotifyBase: PByte;
    NotifyMultiplier: LongWord;
    InterruptStatus: PByte;
    DeviceConfiguration: PByte;
    UsesInterrupts: Boolean;
    { Configuration changes come by interrupt too. }
    ConfigurationChangesSignalled: Boolean;
    { The features agreed on (for resetting the device again). }
    AcceptedFeatures: QWord;
  end;

{ Finds the register areas of a virtio PCI device and resets it.
  False if it is not a modern virtio device. }
function OpenVirtioDevice(Pci: PPciDevice; out Device: TVirtioDevice): Boolean;
{ Agrees on features: Wanted (bit numbers below 64) and'ed with what the
  device offers, plus VIRTIO_F_VERSION_1. Returns the accepted set, or
  False if the device refuses. }
function NegotiateVirtioFeatures(var Device: TVirtioDevice; Wanted: QWord; out Accepted: QWord): Boolean;
{ Sets up queue Index with up to MaximumQueueSize entries. }
function SetUpVirtqueue(var Device: TVirtioDevice; Index: Word; out Queue: TVirtqueue): Boolean;
{ Connects Handler to the device's queue interrupts (MSI-X); without
  MSI-X the driver polls. Call after the queues are set up. }
procedure ConnectVirtioInterrupt(var Device: TVirtioDevice; var Queue: TVirtqueue;
  Handler: TInterruptHandler; Context: Pointer);
{ The same for Count queues at once (Queues[0..Count-1]), and with
  WithConfigurationChanges for changes of the device's configuration
  too. }
procedure ConnectVirtioQueuesInterrupt(var Device: TVirtioDevice; Queues: PPVirtqueue; Count: Integer;
  WithConfigurationChanges: Boolean; Handler: TInterruptHandler; Context: Pointer);
{ Tells the device the driver is ready. }
procedure StartVirtioDevice(var Device: TVirtioDevice);
{ After waking from suspend to RAM reset the device: resets it, agrees
  on the same features, gives it Queue again (emptied) with its
  interrupt vector, and starts it. False if the device refuses. }
function RestartVirtioDevice(var Device: TVirtioDevice; var Queue: TVirtqueue): Boolean;
{ The same for Count queues (their descriptors emptied too: the driver
  writes them again). }
function RestartVirtioDeviceQueues(var Device: TVirtioDevice; Queues: PPVirtqueue; Count: Integer): Boolean;
procedure FailVirtioDevice(var Device: TVirtioDevice);

{ Makes the descriptor chain starting at descriptor 0 available and
  notifies the device. }
procedure SubmitVirtqueueChain(var Queue: TVirtqueue);
{ True if the device has finished a chain since the last call. }
function TakeVirtqueueCompletion(var Queue: TVirtqueue): Boolean;
{ Makes the chain starting at descriptor Head available, without telling
  the device yet. }
procedure OfferVirtqueueChain(var Queue: TVirtqueue; Head: Word);
{ Tells the device that chains were offered. }
procedure NotifyVirtqueue(var Queue: TVirtqueue);
{ The next chain the device finished: its head and the bytes it wrote
  into it. False if there is none. }
function TakeVirtqueueUsedChain(var Queue: TVirtqueue; out Head: Word; out Length: LongWord): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.DeviceMapping,
  Io.PciMessageInterrupts;

const
  PciConfigurationCapabilitiesPointer = $34;
  PciStatusHasCapabilities = $0010;
  CapabilityVendorSpecific = $09;
  MaximumCapabilities = 48;

  { Virtio capability: cfg_type at 3, bar at 4, offset at 8, length at 12. }
  CapabilityConfigurationType = 3;
  CapabilityBar = 4;
  CapabilityOffset = 8;
  CapabilityLength = 12;
  CapabilityNotifyMultiplier = 16;
  ConfigurationCommon = 1;
  ConfigurationNotify = 2;
  ConfigurationInterruptStatus = 3;
  ConfigurationDevice = 4;

  { Common configuration. }
  CommonDeviceFeatureSelect = 0;
  CommonDeviceFeature = 4;
  CommonDriverFeatureSelect = 8;
  CommonDriverFeature = 12;
  CommonConfigurationVector = 16;
  CommonDeviceStatus = 20;
  CommonQueueSelect = 22;
  CommonQueueSize = 24;
  CommonQueueVector = 26;
  CommonQueueEnable = 28;
  CommonQueueNotifyOffset = 30;
  CommonQueueDescriptors = 32;
  CommonQueueAvailable = 40;
  CommonQueueUsed = 48;

  StatusAcknowledge = 1;
  StatusDriver = 2;
  StatusDriverReady = 4;
  StatusFeaturesAccepted = 8;
  StatusFailed = 128;

  NoVector = $FFFF;

{ --- Register access ------------------------------------------------------ }

function Read8(Base: PByte; Offset: LongWord): Byte;
begin
  Result := PByte(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write8(Base: PByte; Offset: LongWord; Value: Byte);
begin
  FullMemoryBarrier;
  PByte(Base + Offset)^ := Value;
end;

function Read16(Base: PByte; Offset: LongWord): Word;
begin
  Result := PWord(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write16(Base: PByte; Offset: LongWord; Value: Word);
begin
  FullMemoryBarrier;
  PWord(Base + Offset)^ := Value;
end;

function Read32(Base: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write32(Base: PByte; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Base + Offset)^ := Value;
end;

procedure Write64(Base: PByte; Offset: LongWord; Value: QWord);
begin
  Write32(Base, Offset, LongWord(Value));
  Write32(Base, Offset + 4, LongWord(Value shr 32));
end;

{ --- Finding the register areas ------------------------------------------- }

{ Maps the area a virtio capability at CapabilityOffset describes. }
function MapCapabilityArea(Pci: PPciDevice; Capability: Word): PByte;
var
  Bar: TPciBar;
  Offset: LongWord;
  Length: LongWord;
  PageStart: QWord;
  WithinPage: QWord;
begin
  Result := nil;
  if not PciReadBar(Pci, PciRead8(Pci, Capability + CapabilityBar), Bar) or Bar.IsIoPort then
    Exit;
  Offset := PciRead32(Pci, Capability + CapabilityOffset);
  Length := PciRead32(Pci, Capability + CapabilityLength);
  PageStart := (Bar.PhysicalAddress + Offset) and not QWord($FFF);
  WithinPage := (Bar.PhysicalAddress + Offset) and QWord($FFF);
  Result := PByte(MapDeviceMemory(PageStart, WithinPage + Length));
  if Result <> nil then
    Result := Result + WithinPage;
end;

function OpenVirtioDevice(Pci: PPciDevice; out Device: TVirtioDevice): Boolean;
var
  Capability: Word;
  Steps: Integer;
begin
  FillMemory(@Device, SizeOf(Device), 0);
  Device.Pci := Pci;
  Result := False;
  if (Pci^.VendorId <> VirtioVendorId) or
     ((PciRead16(Pci, PciConfigurationStatus) and PciStatusHasCapabilities) = 0) then
    Exit;
  Capability := PciRead8(Pci, PciConfigurationCapabilitiesPointer) and $FC;
  Steps := 0;
  while (Capability <> 0) and (Steps < MaximumCapabilities) do
  begin
    if PciRead8(Pci, Capability) = CapabilityVendorSpecific then
    begin
      case PciRead8(Pci, Capability + CapabilityConfigurationType) of
        ConfigurationCommon:
          if Device.Common = nil then
            Device.Common := MapCapabilityArea(Pci, Capability);
        ConfigurationNotify:
          if Device.NotifyBase = nil then
          begin
            Device.NotifyBase := MapCapabilityArea(Pci, Capability);
            Device.NotifyMultiplier := PciRead32(Pci, Capability + CapabilityNotifyMultiplier);
          end;
        ConfigurationInterruptStatus:
          if Device.InterruptStatus = nil then
            Device.InterruptStatus := MapCapabilityArea(Pci, Capability);
        ConfigurationDevice:
          if Device.DeviceConfiguration = nil then
            Device.DeviceConfiguration := MapCapabilityArea(Pci, Capability);
      end;
    end;
    Capability := PciRead8(Pci, Capability + 1) and $FC;
    Inc(Steps);
  end;
  if (Device.Common = nil) or (Device.NotifyBase = nil) or (Device.DeviceConfiguration = nil) then
    Exit;

  PciEnableDevice(Pci, True);
  { Reset, then acknowledge. }
  Write8(Device.Common, CommonDeviceStatus, 0);
  while Read8(Device.Common, CommonDeviceStatus) <> 0 do
    CpuRelax;
  Write8(Device.Common, CommonDeviceStatus, StatusAcknowledge);
  Write8(Device.Common, CommonDeviceStatus, StatusAcknowledge or StatusDriver);
  Result := True;
end;

function NegotiateVirtioFeatures(var Device: TVirtioDevice; Wanted: QWord; out Accepted: QWord): Boolean;
var
  Offered: QWord;
begin
  Write32(Device.Common, CommonDeviceFeatureSelect, 0);
  Offered := Read32(Device.Common, CommonDeviceFeature);
  Write32(Device.Common, CommonDeviceFeatureSelect, 1);
  Offered := Offered or (QWord(Read32(Device.Common, CommonDeviceFeature)) shl 32);
  Accepted := Offered and (Wanted or (QWord(1) shl VirtioFeatureVersion1));
  Result := (Accepted and (QWord(1) shl VirtioFeatureVersion1)) <> 0;
  if not Result then
    Exit;
  Write32(Device.Common, CommonDriverFeatureSelect, 0);
  Write32(Device.Common, CommonDriverFeature, LongWord(Accepted));
  Write32(Device.Common, CommonDriverFeatureSelect, 1);
  Write32(Device.Common, CommonDriverFeature, LongWord(Accepted shr 32));
  Write8(Device.Common, CommonDeviceStatus,
    Read8(Device.Common, CommonDeviceStatus) or StatusFeaturesAccepted);
  Result := (Read8(Device.Common, CommonDeviceStatus) and StatusFeaturesAccepted) <> 0;
  Device.AcceptedFeatures := Accepted;
end;

{ --- Queues --------------------------------------------------------------- }

function AllocateQueuePage(out Physical: QWord): Pointer;
begin
  Physical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Physical = 0 then
    Exit(nil);
  Result := PhysicalToVirtual(Physical);
end;

{ Gives the device Queue's pages and enables it. }
procedure ProgramVirtqueue(var Device: TVirtioDevice; var Queue: TVirtqueue);
begin
  Write16(Device.Common, CommonQueueSelect, Queue.Index);
  Write16(Device.Common, CommonQueueSize, Queue.Size);
  Write16(Device.Common, CommonQueueVector, NoVector);
  Write64(Device.Common, CommonQueueDescriptors, Queue.DescriptorsPhysical);
  Write64(Device.Common, CommonQueueAvailable, Queue.AvailablePhysical);
  Write64(Device.Common, CommonQueueUsed, Queue.UsedPhysical);
  Queue.NotifyAddress := PWord(Device.NotifyBase +
    QWord(Read16(Device.Common, CommonQueueNotifyOffset)) * Device.NotifyMultiplier);
  Write16(Device.Common, CommonQueueEnable, 1);
end;

function SetUpVirtqueue(var Device: TVirtioDevice; Index: Word; out Queue: TVirtqueue): Boolean;
var
  DescriptorsPhysical: QWord;
  AvailablePhysical: QWord;
  UsedPhysical: QWord;
  Size: Word;
begin
  FillMemory(@Queue, SizeOf(Queue), 0);
  Result := False;
  Write16(Device.Common, CommonQueueSelect, Index);
  Size := Read16(Device.Common, CommonQueueSize);
  if Size = 0 then
    Exit;
  if Size > MaximumQueueSize then
    Size := MaximumQueueSize;
  Queue.Index := Index;
  Queue.Size := Size;
  Queue.Descriptors := PVirtqueueDescriptor(AllocateQueuePage(DescriptorsPhysical));
  Queue.Available := PWord(AllocateQueuePage(AvailablePhysical));
  Queue.Used := PByte(AllocateQueuePage(UsedPhysical));
  if (Queue.Descriptors = nil) or (Queue.Available = nil) or (Queue.Used = nil) then
    Exit;
  Queue.DescriptorsPhysical := DescriptorsPhysical;
  Queue.AvailablePhysical := AvailablePhysical;
  Queue.UsedPhysical := UsedPhysical;
  ProgramVirtqueue(Device, Queue);
  Result := True;
end;

procedure ConnectVirtioInterrupt(var Device: TVirtioDevice; var Queue: TVirtqueue;
  Handler: TInterruptHandler; Context: Pointer);
begin
  Device.UsesInterrupts := False;
  if not ConnectPciExtendedMessageInterrupt(Device.Pci, Handler, Context) then
    Exit;
  Write16(Device.Common, CommonConfigurationVector, NoVector);
  Write16(Device.Common, CommonQueueSelect, Queue.Index);
  Write16(Device.Common, CommonQueueVector, 0);
  { The device says NoVector if it cannot use the entry. }
  Device.UsesInterrupts := Read16(Device.Common, CommonQueueVector) = 0;
end;

procedure ConnectVirtioQueuesInterrupt(var Device: TVirtioDevice; Queues: PPVirtqueue; Count: Integer;
  WithConfigurationChanges: Boolean; Handler: TInterruptHandler; Context: Pointer);
var
  Index: Integer;
begin
  Device.UsesInterrupts := False;
  if not ConnectPciExtendedMessageInterrupt(Device.Pci, Handler, Context) then
    Exit;
  Device.UsesInterrupts := True;
  if WithConfigurationChanges then
    Write16(Device.Common, CommonConfigurationVector, 0)
  else
    Write16(Device.Common, CommonConfigurationVector, NoVector);
  Device.ConfigurationChangesSignalled := WithConfigurationChanges and
    (Read16(Device.Common, CommonConfigurationVector) = 0);
  for Index := 0 to Count - 1 do
  begin
    Write16(Device.Common, CommonQueueSelect, Queues[Index]^.Index);
    Write16(Device.Common, CommonQueueVector, 0);
    { The device says NoVector if it cannot use the entry. }
    if Read16(Device.Common, CommonQueueVector) <> 0 then
      Device.UsesInterrupts := False;
  end;
end;

procedure StartVirtioDevice(var Device: TVirtioDevice);
begin
  Write8(Device.Common, CommonDeviceStatus,
    Read8(Device.Common, CommonDeviceStatus) or StatusDriverReady);
end;

function RestartVirtioDevice(var Device: TVirtioDevice; var Queue: TVirtqueue): Boolean;
var
  Queues: array[0..0] of PVirtqueue;
begin
  Queues[0] := @Queue;
  Result := RestartVirtioDeviceQueues(Device, @Queues[0], 1);
end;

function RestartVirtioDeviceQueues(var Device: TVirtioDevice; Queues: PPVirtqueue; Count: Integer): Boolean;
var
  Accepted: QWord;
  Index: Integer;
  Queue: PVirtqueue;
begin
  Write8(Device.Common, CommonDeviceStatus, 0);
  while Read8(Device.Common, CommonDeviceStatus) <> 0 do
    CpuRelax;
  Write8(Device.Common, CommonDeviceStatus, StatusAcknowledge);
  Write8(Device.Common, CommonDeviceStatus, StatusAcknowledge or StatusDriver);
  Result := NegotiateVirtioFeatures(Device, Device.AcceptedFeatures, Accepted);
  if not Result then
    Exit;
  for Index := 0 to Count - 1 do
  begin
    Queue := Queues[Index];
    { Empty rings, counted from the start again. }
    FillMemory(Queue^.Descriptors, 4096, 0);
    FillMemory(Queue^.Available, 4096, 0);
    FillMemory(Queue^.Used, 4096, 0);
    Queue^.LastSeenUsed := 0;
    ProgramVirtqueue(Device, Queue^);
    if Device.UsesInterrupts then
    begin
      Write16(Device.Common, CommonQueueSelect, Queue^.Index);
      Write16(Device.Common, CommonQueueVector, 0);
    end;
  end;
  if Device.UsesInterrupts and Device.ConfigurationChangesSignalled then
    Write16(Device.Common, CommonConfigurationVector, 0)
  else
    Write16(Device.Common, CommonConfigurationVector, NoVector);
  StartVirtioDevice(Device);
end;

procedure FailVirtioDevice(var Device: TVirtioDevice);
begin
  if Device.Common <> nil then
    Write8(Device.Common, CommonDeviceStatus,
      Read8(Device.Common, CommonDeviceStatus) or StatusFailed);
end;

procedure OfferVirtqueueChain(var Queue: TVirtqueue; Head: Word);
var
  AvailableIndex: Word;
begin
  AvailableIndex := Queue.Available[1];
  Queue.Available[2 + (AvailableIndex mod Queue.Size)] := Head;
  { The descriptors and the ring entry before the index the device reads. }
  FullMemoryBarrier;
  Queue.Available[1] := Word(AvailableIndex + 1);
end;

procedure NotifyVirtqueue(var Queue: TVirtqueue);
begin
  FullMemoryBarrier;
  Queue.NotifyAddress^ := Queue.Index;
end;

procedure SubmitVirtqueueChain(var Queue: TVirtqueue);
begin
  OfferVirtqueueChain(Queue, 0);
  NotifyVirtqueue(Queue);
end;

function TakeVirtqueueUsedChain(var Queue: TVirtqueue; out Head: Word; out Length: LongWord): Boolean;
var
  UsedIndex: Word;
  Entry: PByte;
begin
  Head := 0;
  Length := 0;
  FullMemoryBarrier;
  UsedIndex := PWord(Queue.Used + 2)^;
  Result := UsedIndex <> Queue.LastSeenUsed;
  if not Result then
    Exit;
  { The entry is read after the index that says it is there. }
  FullMemoryBarrier;
  Entry := Queue.Used + 4 + QWord(Queue.LastSeenUsed mod Queue.Size) * 8;
  Head := Word(PLongWord(Entry)^);
  Length := PLongWord(Entry + 4)^;
  Queue.LastSeenUsed := Word(Queue.LastSeenUsed + 1);
end;

function TakeVirtqueueCompletion(var Queue: TVirtqueue): Boolean;
var
  UsedIndex: Word;
begin
  FullMemoryBarrier;
  UsedIndex := PWord(Queue.Used + 2)^;
  Result := UsedIndex <> Queue.LastSeenUsed;
  if Result then
    Queue.LastSeenUsed := UsedIndex;
end;

end.
