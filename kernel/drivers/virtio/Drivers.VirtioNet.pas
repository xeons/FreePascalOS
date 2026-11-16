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
  Virtio network cards (the network card of QEMU and other hypervisors).

  Each card becomes a network adapter (Io.NetworkAdapters). It has two
  queues: the receive queue, which always holds a buffer of 2 KiB per
  descriptor for the card to fill (a 12-byte virtio header, then the
  frame), and the transmit queue, where each frame goes as one buffer
  with its header in front. No offloads are asked for (no checksum or
  segmentation offload, no merged buffers), so every frame is a plain
  Ethernet frame of at most 1514 bytes.

  Both queues and configuration changes (the link) interrupt through
  MSI-X entry 0; the deferred routine hands each received frame to the
  network layer and gives its buffer back, takes back the transmit
  buffers the card is done with, and reports a changed link. A card
  without MSI-X is polled every 10 ms by a timer. Transmit runs at any
  level up to dispatch: it takes a free transmit buffer (or says it has
  none, and the deferred routine says when it has one again).

  Suspend to RAM: the card is marked suspended (Transmit refuses
  frames, which wait in the network layer); waking resets it, gives it
  its queues and receive buffers again and reports it ready.
}
unit Drivers.VirtioNet;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every virtio network card found on PCI; returns how many. }
function InitializeVirtioNetDevices: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Io.Pci,
  Io.PowerManagement,
  Io.NetworkAdapters,
  Drivers.VirtioPci,
  Debug.Output;

const
  TransitionalNetworkDeviceId = $1000;
  FeatureMac = 5;
  FeatureStatus = 16;
  { struct virtio_net_hdr with num_buffers (always there in virtio 1.0). }
  NetHeaderBytes = 12;
  ReceiveQueueIndex = 0;
  TransmitQueueIndex = 1;
  BufferBytes = 2048;
  BuffersPerPage = 4096 div BufferBytes;
  ConfigurationStatusOffset = 6;
  StatusLinkUp = 1;
  PollMilliseconds = 10;

type
  TBufferSet = record
    Buffers: array[0..MaximumQueueSize - 1] of PByte;
    Physical: array[0..MaximumQueueSize - 1] of QWord;
  end;

  PVirtioNetCard = ^TVirtioNetCard;
  TVirtioNetCard = record
    Virtio: TVirtioDevice;
    ReceiveQueue: TVirtqueue;
    TransmitQueue: TVirtqueue;
    ReceiveBuffers: TBufferSet;
    TransmitBuffers: TBufferSet;
    { Transmit descriptors not in use. }
    TransmitFree: array[0..MaximumQueueSize - 1] of Word;
    TransmitFreeCount: Integer;
    TransmitLock: TSpinLock;
    ReceiveLock: TSpinLock;
    { Transmit said it had no room: the network layer waits to hear. }
    TransmitWasRefused: Boolean;
    Suspended: Boolean;
    HasStatus: Boolean;
    LinkWasUp: Boolean;
    Address: TEthernetAddress;
    Adapter: PNetworkAdapter;
    Completion: TDeferredCall;
    PollTimer: TTimer;
    PollCall: TDeferredCall;
  end;

function AllocateBuffers(var BufferSet: TBufferSet; Count: Integer): Boolean;
var
  Index: Integer;
  Page: QWord;
begin
  Index := 0;
  while Index < Count do
  begin
    Page := AllocateZeroedPhysicalPage(PageUsageGeneral);
    if Page = 0 then
      Exit(False);
    BufferSet.Physical[Index] := Page;
    BufferSet.Buffers[Index] := PByte(PhysicalToVirtual(Page));
    if Index + 1 < Count then
    begin
      BufferSet.Physical[Index + 1] := Page + BufferBytes;
      BufferSet.Buffers[Index + 1] := PByte(PhysicalToVirtual(Page)) + BufferBytes;
    end;
    Index := Index + BuffersPerPage;
  end;
  Result := True;
end;

{ Gives the card every receive buffer (descriptor N holds buffer N). }
procedure OfferAllReceiveBuffers(Card: PVirtioNetCard);
var
  Index: Word;
  Descriptor: PVirtqueueDescriptor;
begin
  Index := 0;
  while Index < Card^.ReceiveQueue.Size do
  begin
    Descriptor := @Card^.ReceiveQueue.Descriptors[Index];
    Descriptor^.Address := Card^.ReceiveBuffers.Physical[Index];
    Descriptor^.Length := BufferBytes;
    Descriptor^.Flags := VirtqueueDescriptorWrite;
    Descriptor^.Next := 0;
    OfferVirtqueueChain(Card^.ReceiveQueue, Index);
    Inc(Index);
  end;
end;

procedure FreeAllTransmitBuffers(Card: PVirtioNetCard);
var
  Index: Integer;
begin
  Card^.TransmitFreeCount := 0;
  for Index := Card^.TransmitQueue.Size - 1 downto 0 do
  begin
    Card^.TransmitFree[Card^.TransmitFreeCount] := Word(Index);
    Inc(Card^.TransmitFreeCount);
  end;
end;

function LinkIsUpNow(Card: PVirtioNetCard): Boolean;
begin
  if not Card^.HasStatus then
    Exit(True);
  FullMemoryBarrier;
  Result := (PWord(Card^.Virtio.DeviceConfiguration + ConfigurationStatusOffset)^ and StatusLinkUp) <> 0;
end;

{ Takes back the transmit buffers the card is done with (TransmitLock
  held). True if Transmit had refused a frame and there is room now. }
function ReclaimTransmitBuffersLocked(Card: PVirtioNetCard): Boolean;
var
  Head: Word;
  Length: LongWord;
begin
  while TakeVirtqueueUsedChain(Card^.TransmitQueue, Head, Length) do
  begin
    if (Head < Card^.TransmitQueue.Size) and (Card^.TransmitFreeCount < Card^.TransmitQueue.Size) then
    begin
      Card^.TransmitFree[Card^.TransmitFreeCount] := Head;
      Inc(Card^.TransmitFreeCount);
    end;
  end;
  Result := Card^.TransmitWasRefused and (Card^.TransmitFreeCount > 0);
  if Result then
    Card^.TransmitWasRefused := False;
end;

procedure HandleReceivedFrames(Card: PVirtioNetCard);
var
  Head: Word;
  Length: LongWord;
  Offered: Boolean;
  PreviousLevel: TPriorityLevel;
begin
  Offered := False;
  PreviousLevel := AcquireSpinLock(Card^.ReceiveLock);
  while TakeVirtqueueUsedChain(Card^.ReceiveQueue, Head, Length) do
  begin
    if Head >= Card^.ReceiveQueue.Size then
      Continue;
    if (Length > NetHeaderBytes) and (Card^.Adapter <> nil) then
      NetworkFrameReceived(Card^.Adapter, Card^.ReceiveBuffers.Buffers[Head] + NetHeaderBytes,
        Length - NetHeaderBytes);
    OfferVirtqueueChain(Card^.ReceiveQueue, Head);
    Offered := True;
  end;
  if Offered then
    NotifyVirtqueue(Card^.ReceiveQueue);
  ReleaseSpinLock(Card^.ReceiveLock, PreviousLevel);
end;

{ The deferred routine: what the card finished, and the link. }
procedure HandleCompletion(Context: Pointer);
var
  Card: PVirtioNetCard;
  RoomAgain: Boolean;
  LinkNow: Boolean;
  PreviousLevel: TPriorityLevel;
begin
  Card := PVirtioNetCard(Context);
  if Card^.Suspended then
    Exit;
  HandleReceivedFrames(Card);
  PreviousLevel := AcquireSpinLock(Card^.TransmitLock);
  RoomAgain := ReclaimTransmitBuffersLocked(Card);
  ReleaseSpinLock(Card^.TransmitLock, PreviousLevel);
  if RoomAgain and (Card^.Adapter <> nil) then
    NetworkTransmitReady(Card^.Adapter);
  LinkNow := LinkIsUpNow(Card);
  if LinkNow <> Card^.LinkWasUp then
  begin
    Card^.LinkWasUp := LinkNow;
    if Card^.Adapter <> nil then
      NetworkLinkChanged(Card^.Adapter);
  end;
end;

procedure HandleVirtioNetInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  QueueDeferredCall(PVirtioNetCard(Context)^.Completion);
end;

{ Without MSI-X: the timer's deferred routine looks, and sets itself
  again. }
procedure PollCard(Context: Pointer);
var
  Card: PVirtioNetCard;
begin
  Card := PVirtioNetCard(Context);
  if Card^.Suspended then
    Exit;
  HandleCompletion(Card);
  SetTimer(Card^.PollTimer, PollMilliseconds, Card^.PollCall);
end;

function TransmitFrame(Context: Pointer; Frame: PByte; Length: LongWord): Boolean;
var
  Card: PVirtioNetCard;
  Head: Word;
  Buffer: PByte;
  FrameLength: LongWord;
  Descriptor: PVirtqueueDescriptor;
  PreviousLevel: TPriorityLevel;
begin
  Card := PVirtioNetCard(Context);
  if (Length = 0) or (Length > MaximumFrameBytes) then
    Exit(True);
  PreviousLevel := AcquireSpinLock(Card^.TransmitLock);
  if not Card^.Suspended then
    ReclaimTransmitBuffersLocked(Card);
  if Card^.Suspended or (Card^.TransmitFreeCount = 0) then
  begin
    Card^.TransmitWasRefused := True;
    ReleaseSpinLock(Card^.TransmitLock, PreviousLevel);
    Exit(False);
  end;
  Dec(Card^.TransmitFreeCount);
  Head := Card^.TransmitFree[Card^.TransmitFreeCount];
  Buffer := Card^.TransmitBuffers.Buffers[Head];
  FillMemory(Buffer, NetHeaderBytes, 0);
  CopyMemory(Buffer + NetHeaderBytes, Frame, Length);
  FrameLength := Length;
  if FrameLength < MinimumFrameBytes then
  begin
    FillMemory(Buffer + NetHeaderBytes + Length, MinimumFrameBytes - Length, 0);
    FrameLength := MinimumFrameBytes;
  end;
  Descriptor := @Card^.TransmitQueue.Descriptors[Head];
  Descriptor^.Address := Card^.TransmitBuffers.Physical[Head];
  Descriptor^.Length := NetHeaderBytes + FrameLength;
  Descriptor^.Flags := 0;
  Descriptor^.Next := 0;
  OfferVirtqueueChain(Card^.TransmitQueue, Head);
  NotifyVirtqueue(Card^.TransmitQueue);
  ReleaseSpinLock(Card^.TransmitLock, PreviousLevel);
  Result := True;
end;

function ReportLink(Context: Pointer): Boolean;
begin
  Result := LinkIsUpNow(PVirtioNetCard(Context));
end;

procedure SuspendCard(Context: Pointer);
var
  Card: PVirtioNetCard;
  PreviousLevel: TPriorityLevel;
begin
  Card := PVirtioNetCard(Context);
  PreviousLevel := AcquireSpinLock(Card^.TransmitLock);
  Card^.Suspended := True;
  ReleaseSpinLock(Card^.TransmitLock, PreviousLevel);
  if not Card^.Virtio.UsesInterrupts then
  begin
    { Twice: a call that was running may have set the timer again. }
    CancelTimer(Card^.PollTimer);
    CancelDeferredCall(Card^.PollCall);
    CancelTimer(Card^.PollTimer);
  end;
  CancelDeferredCall(Card^.Completion);
end;

procedure ResumeCard(Context: Pointer);
var
  Card: PVirtioNetCard;
  Queues: array[0..1] of PVirtqueue;
  PreviousLevel: TPriorityLevel;
begin
  Card := PVirtioNetCard(Context);
  Queues[0] := @Card^.ReceiveQueue;
  Queues[1] := @Card^.TransmitQueue;
  if not RestartVirtioDeviceQueues(Card^.Virtio, @Queues[0], 2) then
    Exit;
  PreviousLevel := AcquireSpinLock(Card^.ReceiveLock);
  OfferAllReceiveBuffers(Card);
  NotifyVirtqueue(Card^.ReceiveQueue);
  ReleaseSpinLock(Card^.ReceiveLock, PreviousLevel);
  PreviousLevel := AcquireSpinLock(Card^.TransmitLock);
  FreeAllTransmitBuffers(Card);
  Card^.TransmitWasRefused := False;
  Card^.Suspended := False;
  ReleaseSpinLock(Card^.TransmitLock, PreviousLevel);
  if not Card^.Virtio.UsesInterrupts then
    SetTimer(Card^.PollTimer, PollMilliseconds, Card^.PollCall);
  Card^.LinkWasUp := LinkIsUpNow(Card);
  NetworkLinkChanged(Card^.Adapter);
  NetworkTransmitReady(Card^.Adapter);
end;

procedure ReadAddress(Card: PVirtioNetCard; Accepted: QWord);
var
  Index: Integer;
  Random: QWord;
begin
  if (Accepted and (QWord(1) shl FeatureMac)) <> 0 then
  begin
    for Index := 0 to EthernetAddressLength - 1 do
      Card^.Address[Index] := Card^.Virtio.DeviceConfiguration[Index];
    Exit;
  end;
  { None given: a locally administered one of our own. }
  if not ReadHardwareRandom(Random) then
    Random := ReadTimeStampCounter;
  Card^.Address[0] := $52;
  Card^.Address[1] := $54;
  Card^.Address[2] := $00;
  Card^.Address[3] := Byte(Random);
  Card^.Address[4] := Byte(Random shr 8);
  Card^.Address[5] := Byte(Random shr 16);
end;

function SetUpCard(Card: PVirtioNetCard; Pci: PPciDevice): Boolean;
var
  Accepted: QWord;
  Queues: array[0..1] of PVirtqueue;
begin
  Result := False;
  if not OpenVirtioDevice(Pci, Card^.Virtio) then
    Exit;
  if not NegotiateVirtioFeatures(Card^.Virtio, (QWord(1) shl FeatureMac) or (QWord(1) shl FeatureStatus),
       Accepted) or
     not SetUpVirtqueue(Card^.Virtio, ReceiveQueueIndex, Card^.ReceiveQueue) or
     not SetUpVirtqueue(Card^.Virtio, TransmitQueueIndex, Card^.TransmitQueue) or
     not AllocateBuffers(Card^.ReceiveBuffers, Card^.ReceiveQueue.Size) or
     not AllocateBuffers(Card^.TransmitBuffers, Card^.TransmitQueue.Size) then
  begin
    FailVirtioDevice(Card^.Virtio);
    Exit;
  end;
  Card^.HasStatus := (Accepted and (QWord(1) shl FeatureStatus)) <> 0;
  ReadAddress(Card, Accepted);
  InitializeSpinLock(Card^.TransmitLock);
  InitializeSpinLock(Card^.ReceiveLock);
  InitializeDeferredCall(Card^.Completion, @HandleCompletion, Card);
  InitializeTimer(Card^.PollTimer);
  InitializeDeferredCall(Card^.PollCall, @PollCard, Card);
  FreeAllTransmitBuffers(Card);
  OfferAllReceiveBuffers(Card);
  Queues[0] := @Card^.ReceiveQueue;
  Queues[1] := @Card^.TransmitQueue;
  ConnectVirtioQueuesInterrupt(Card^.Virtio, @Queues[0], 2, True, @HandleVirtioNetInterrupt, Card);
  StartVirtioDevice(Card^.Virtio);
  NotifyVirtqueue(Card^.ReceiveQueue);
  Card^.LinkWasUp := LinkIsUpNow(Card);
  Result := True;
end;

function StartCard(Pci: PPciDevice): Boolean;
var
  Card: PVirtioNetCard;
  Routines: TNetworkDriverRoutines;
begin
  Result := False;
  Card := PVirtioNetCard(AllocateZeroedKernelMemory(SizeOf(TVirtioNetCard)));
  if Card = nil then
    Exit;
  if not SetUpCard(Card, Pci) then
    Exit;
  Routines.Transmit := @TransmitFrame;
  Routines.LinkUp := @ReportLink;
  Routines.Kind := NetworkAdapterKindEthernet;
  Card^.Adapter := RegisterNetworkAdapter(Routines, Card, Card^.Address, 'virtio network device');
  if Card^.Adapter = nil then
  begin
    FailVirtioDevice(Card^.Virtio);
    Exit;
  end;
  if not Card^.Virtio.UsesInterrupts then
    SetTimer(Card^.PollTimer, PollMilliseconds, Card^.PollCall);

  DebugBeginMessage;
  DebugWriteTag('virtio');
  DebugWrite(@Card^.Adapter^.Name[0]);
  if Card^.Virtio.UsesInterrupts then
    DebugWrite(': network card, interrupts by MSI-X')
  else
    DebugWrite(': network card, polled');
  if Card^.LinkWasUp then
    DebugWriteLine(', link up')
  else
    DebugWriteLine(', link down');
  DebugEndMessage;
  RegisterPowerHandler('virtio network', PowerStageDevices, @SuspendCard, @ResumeCard, Card);
  Result := True;
end;

function InitializeVirtioNetDevices: Integer;
var
  Index: Integer;
  Pci: PPciDevice;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Pci := PciDeviceAt(Index);
    if (Pci^.VendorId <> VirtioVendorId) or
       ((Pci^.DeviceId <> VirtioModernDeviceIdBase + VirtioDeviceTypeNetwork) and
        (Pci^.DeviceId <> TransitionalNetworkDeviceId)) then
      Continue;
    if StartCard(Pci) then
      Inc(Result);
  end;
end;

end.
