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
  Realtek RTL8139 10/100 Ethernet cards (QEMU's rtl8139).

  Receiving: the card writes frames one after another into one ring of
  32 KiB of shared DMA memory (Io.Dma; the card puts out 32-bit bus
  addresses only, so it is below 4 GiB of those), each behind a
  four-byte header (status, length with the check sequence). The
  "wrap" mode lets a frame run on past the end, so the buffer has room
  for one more frame there and a frame is never split. The driver reads
  from its own offset while the card says the ring is not empty, and
  tells the card how far it read (minus 16, as the card wants). A broken
  header means the receiver lost its place: it is restarted.

  Transmitting: four slots, used strictly in turn, each with its own
  streaming buffer (2 KiB, Drivers.NetworkBuffers); writing a slot's
  status register with the length starts it, and its "OK", "underrun" or "aborted" bit says when
  it is done.

  Interrupts come on the PCI line (shared and level triggered: the
  handler checks and acknowledges the status register), else a timer
  polls. The link is the PHY's basic mode status; a link change raises
  the "packet underrun / link change" interrupt. Suspend to RAM is
  handled as by the e1000 driver: quiet, then reset and set up again.
}
unit Drivers.Rtl8139;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every RTL8139 card; returns how many. }
function InitializeRtl8139Adapters: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Memory.KernelHeap,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.Clock,
  Hal.PortIo,
  Io.Pci,
  Io.Dma,
  Io.PlatformDevices,
  Io.PciLineInterrupts,
  Io.PowerManagement,
  Io.NetworkAdapters,
  Drivers.NetworkCards,
  Drivers.NetworkBuffers,
  Drivers.Rtl8139.Registers,
  Debug.Output;

const
  ReceiveRingBytes = 32768;
  { The ring, its 16 spare bytes, and room for a frame past the end. }
  ReceiveBufferBytes = ReceiveRingBytes + 16 + 2048;
  TransmitSlotCount = 4;
  ResetTimeoutMilliseconds = 100;
  PollIntervalMilliseconds = 10;
  WatchIntervalMilliseconds = 2000;
  { A frame and its check sequence, as the card counts it. }
  LargestReceivedLength = MaximumFrameBytes + 4;
  SmallestReceivedLength = 14 + 4;
  CheckSequenceBytes = 4;
  { The card writes this length while a frame is still arriving. }
  LengthStillArriving = $FFF0;

type
  PRtl8139Card = ^TRtl8139Card;
  TRtl8139Card = record
    Card: TNetworkCard;
    Pci: PPciDevice;
    Ports: Word;
    Address: TEthernetAddress;
    UsesInterrupts: Boolean;
    IsSuspended: Boolean;

    ReceiveRing: PByte;
    ReceiveMemory: TDmaBuffer;
    Dma: TDmaAttributes;
    ReceiveOffset: LongWord;
    ReceiveLock: TSpinLock;

    TransmitBuffers: array[0..TransmitSlotCount - 1] of TNetworkBuffer;
    { Slots handed out and slots finished, counting up; the slot of
      either is the count mod 4. }
    TransmitIssued: LongWord;
    TransmitFinished: LongWord;
    WaitingForRoom: Boolean;
    TransmitLock: TSpinLock;

    PendingStatus: PtrUInt;
    ServiceCall: TDeferredCall;
    PollTimer: TTimer;
    WatchCall: TDeferredCall;
    WatchTimer: TTimer;
  end;

{ --- The hardware ----------------------------------------------------------- }

function ResetChip(Card: PRtl8139Card): Boolean;
var
  Deadline: QWord;
begin
  { Out of low-power mode. }
  WritePortByte(Card^.Ports + RegisterConfiguration1, 0);
  WritePortByte(Card^.Ports + RegisterCommand, CommandReset);
  Deadline := ClockTickCount + MillisecondsToTicks(ResetTimeoutMilliseconds) + 1;
  while (ReadPortByte(Card^.Ports + RegisterCommand) and CommandReset) <> 0 do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

procedure StartReceiver(Card: PRtl8139Card);
begin
  WritePortLongWord(Card^.Ports + RegisterReceiveBufferStart, LongWord(Card^.ReceiveMemory.DeviceAddress));
  WritePortByte(Card^.Ports + RegisterCommand, CommandReceiveEnable or CommandTransmitEnable);
  WritePortLongWord(Card^.Ports + RegisterReceiveConfiguration,
    ReceiveAcceptPhysicalMatch or ReceiveAcceptMulticast or ReceiveAcceptBroadcast or ReceiveWrap or
    ReceiveDmaUnlimited or ReceiveRing32K or ReceiveNoFifoThreshold);
  Card^.ReceiveOffset := 0;
end;

{ Everything from reset up to (not including) the interrupt mask. }
procedure PrepareChip(Card: PRtl8139Card);
var
  Index: Integer;
begin
  ResetChip(Card);
  for Index := 0 to EthernetAddressLength - 1 do
    WritePortByte(Card^.Ports + RegisterStationAddress + Word(Index), Card^.Address[Index]);
  { Every multicast group (the network layer filters). }
  for Index := 0 to 7 do
    WritePortByte(Card^.Ports + RegisterMulticast + Word(Index), $FF);
  for Index := 0 to TransmitSlotCount - 1 do
    WritePortLongWord(Card^.Ports + RegisterTransmitAddress0 + Word(Index) * 4,
      LongWord(Card^.TransmitBuffers[Index].DeviceAddress));
  Card^.TransmitIssued := 0;
  Card^.TransmitFinished := 0;
  StartReceiver(Card);
  WritePortLongWord(Card^.Ports + RegisterTransmitConfiguration, TransmitConfigurationValue);
  WritePortLongWord(Card^.Ports + RegisterMissedPackets, 0);
end;

procedure ReadLink(Card: PRtl8139Card; out Link: TNetworkLinkState);
begin
  { The status latches a lost link until read: the second read is now. }
  ReadPortWord(Card^.Ports + RegisterBasicModeStatus);
  Link.IsUp := (ReadPortWord(Card^.Ports + RegisterBasicModeStatus) and BasicModeStatusLinkUp) <> 0;
  Link.SpeedMegabits := 0;
  Link.FullDuplex := False;
  if not Link.IsUp then
    Exit;
  if (ReadPortByte(Card^.Ports + RegisterMediaStatus) and MediaStatusSpeed10) <> 0 then
    Link.SpeedMegabits := 10
  else
    Link.SpeedMegabits := 100;
  Link.FullDuplex := (ReadPortWord(Card^.Ports + RegisterBasicModeControl) and BasicModeControlFullDuplex) <> 0;
end;

{ --- Receiving and transmitting ------------------------------------------------ }

procedure ReceiveFrames(Card: PRtl8139Card);
var
  PreviousLevel: TPriorityLevel;
  Header: PByte;
  Status: Word;
  Length: LongWord;
  Frames: Integer;
begin
  PreviousLevel := AcquireSpinLock(Card^.ReceiveLock);
  Frames := 0;
  while not Card^.IsSuspended and ((ReadPortByte(Card^.Ports + RegisterCommand) and CommandBufferEmpty) = 0) and
        (Frames < ReceiveRingBytes div 64) do
  begin
    Header := Card^.ReceiveRing + Card^.ReceiveOffset;
    Status := PWord(Header)^;
    Length := PWord(Header + 2)^;
    if Length = LengthStillArriving then
      Break;
    if ((Status and ReceiveHeaderOk) = 0) or (Length < SmallestReceivedLength) or
       (Length > LargestReceivedLength) then
    begin
      Inc(Card^.Card.Statistics.ReceiveErrors);
      StartReceiver(Card);
      Break;
    end;
    Inc(Card^.Card.Statistics.FramesReceived);
    Inc(Card^.Card.Statistics.BytesReceived, Length - CheckSequenceBytes);
    NetworkFrameReceived(Card^.Card.Adapter, Header + 4, Length - CheckSequenceBytes);
    Card^.ReceiveOffset := ((Card^.ReceiveOffset + Length + 4 + 3) and not LongWord(3)) mod ReceiveRingBytes;
    WritePortWord(Card^.Ports + RegisterReceiveReadPointer, Word((Card^.ReceiveOffset - 16) and $FFFF));
    Inc(Frames);
  end;
  ReleaseSpinLock(Card^.ReceiveLock, PreviousLevel);
end;

{ Transmit lock held. }
procedure ReclaimFinished(Card: PRtl8139Card);
var
  Status: LongWord;
  Slot: LongWord;
begin
  while Card^.TransmitFinished <> Card^.TransmitIssued do
  begin
    Slot := Card^.TransmitFinished mod TransmitSlotCount;
    Status := ReadPortLongWord(Card^.Ports + RegisterTransmitStatus0 + Word(Slot) * 4);
    if (Status and (TransmitStatusOk or TransmitStatusUnderrun or TransmitStatusAborted)) = 0 then
      Break;
    if (Status and (TransmitStatusAborted or TransmitStatusOutOfWindowCollision)) <> 0 then
      Inc(Card^.Card.Statistics.TransmitErrors);
    Inc(Card^.Card.Statistics.Collisions,
      (Status shr TransmitStatusCollisionCountShift) and TransmitStatusCollisionCountMask);
    Inc(Card^.TransmitFinished);
  end;
end;

procedure ReclaimTransmits(Card: PRtl8139Card);
var
  PreviousLevel: TPriorityLevel;
  TellNetworkLayer: Boolean;
begin
  TellNetworkLayer := False;
  PreviousLevel := AcquireSpinLock(Card^.TransmitLock);
  if not Card^.IsSuspended then
  begin
    ReclaimFinished(Card);
    if Card^.WaitingForRoom and (Card^.TransmitIssued - Card^.TransmitFinished < TransmitSlotCount) then
    begin
      Card^.WaitingForRoom := False;
      TellNetworkLayer := True;
    end;
  end;
  ReleaseSpinLock(Card^.TransmitLock, PreviousLevel);
  if TellNetworkLayer then
    NetworkTransmitReady(Card^.Card.Adapter);
end;

function TransmitFrame(Context: Pointer; Frame: PByte; Length: LongWord): Boolean;
var
  Card: PRtl8139Card;
  PreviousLevel: TPriorityLevel;
  Slot: LongWord;
  Buffer: PByte;
  SentLength: LongWord;
begin
  Card := PRtl8139Card(Context);
  Result := False;
  PreviousLevel := AcquireSpinLock(Card^.TransmitLock);
  if (Length = 0) or (Length > MaximumFrameBytes) then
  begin
    Inc(Card^.Card.Statistics.TransmitErrors);
    Result := True;
  end
  else if not Card^.IsSuspended then
  begin
    if Card^.TransmitIssued - Card^.TransmitFinished = TransmitSlotCount then
      ReclaimFinished(Card);
    if Card^.TransmitIssued - Card^.TransmitFinished < TransmitSlotCount then
    begin
      Slot := Card^.TransmitIssued mod TransmitSlotCount;
      Buffer := Card^.TransmitBuffers[Slot].Data;
      CopyMemory(Buffer, Frame, Length);
      SentLength := Length;
      if SentLength < MinimumFrameBytes then
      begin
        ZeroMemory(Buffer + SentLength, MinimumFrameBytes - SentLength);
        SentLength := MinimumFrameBytes;
      end;
      PrepareTransmitBuffer(Card^.Dma, Card^.TransmitBuffers[Slot], SentLength);
      FullMemoryBarrier;
      { Writing the length (the "own" bit clear) starts the slot. }
      WritePortLongWord(Card^.Ports + RegisterTransmitStatus0 + Word(Slot) * 4,
        SentLength or TransmitEarlyThreshold256);
      Inc(Card^.TransmitIssued);
      Inc(Card^.Card.Statistics.FramesTransmitted);
      Inc(Card^.Card.Statistics.BytesTransmitted, SentLength);
      Result := True;
    end;
  end;
  if not Result then
    Card^.WaitingForRoom := True;
  ReleaseSpinLock(Card^.TransmitLock, PreviousLevel);
end;

function LinkIsUp(Context: Pointer): Boolean;
var
  Card: PRtl8139Card;
  Link: TNetworkLinkState;
begin
  Card := PRtl8139Card(Context);
  if Card^.IsSuspended then
    Exit(False);
  ReadLink(Card, Link);
  Result := Link.IsUp;
end;

{ --- Interrupts and the deferred routines ------------------------------------- }

procedure CheckLink(Card: PRtl8139Card);
var
  Link: TNetworkLinkState;
begin
  ReadLink(Card, Link);
  UpdateNetworkCardLink(@Card^.Card, Link);
end;

procedure HandleRtl8139Interrupt(Frame: PTrapFrame; Context: Pointer);
var
  Card: PRtl8139Card;
  Status: Word;
begin
  Card := PRtl8139Card(Context);
  Status := ReadPortWord(Card^.Ports + RegisterInterruptStatus);
  if (Status = 0) or (Status = $FFFF) then
    Exit;
  WritePortWord(Card^.Ports + RegisterInterruptStatus, Status);
  AtomicOr(Card^.PendingStatus, Status);
  QueueDeferredCall(Card^.ServiceCall);
end;

procedure ServiceCard(Context: Pointer);
var
  Card: PRtl8139Card;
  Status: PtrUInt;
begin
  Card := PRtl8139Card(Context);
  if Card^.IsSuspended then
    Exit;
  Status := AtomicExchange(Card^.PendingStatus, 0);
  ReceiveFrames(Card);
  ReclaimTransmits(Card);
  if ((Status and InterruptLinkChange) <> 0) or not Card^.UsesInterrupts then
    CheckLink(Card);
  if not Card^.UsesInterrupts then
    SetTimer(Card^.PollTimer, PollIntervalMilliseconds, Card^.ServiceCall);
end;

procedure WatchCard(Context: Pointer);
var
  Card: PRtl8139Card;
  PreviousLevel: TPriorityLevel;
begin
  Card := PRtl8139Card(Context);
  if Card^.IsSuspended then
    Exit;
  PreviousLevel := AcquireSpinLock(Card^.ReceiveLock);
  Inc(Card^.Card.Statistics.ReceiveMissed,
    ReadPortLongWord(Card^.Ports + RegisterMissedPackets) and $00FFFFFF);
  WritePortLongWord(Card^.Ports + RegisterMissedPackets, 0);
  ReleaseSpinLock(Card^.ReceiveLock, PreviousLevel);
  CheckLink(Card);
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
end;

procedure EnableInterrupts(Card: PRtl8139Card);
begin
  if Card^.UsesInterrupts then
    WritePortWord(Card^.Ports + RegisterInterruptMask, InterruptsUsed);
end;

procedure StartTimers(Card: PRtl8139Card);
begin
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
  if not Card^.UsesInterrupts then
    SetTimer(Card^.PollTimer, PollIntervalMilliseconds, Card^.ServiceCall);
end;

{ --- Suspend to RAM ------------------------------------------------------------ }

procedure SetSuspended(Card: PRtl8139Card; Suspended: Boolean);
var
  ReceiveLevel: TPriorityLevel;
  TransmitLevel: TPriorityLevel;
begin
  ReceiveLevel := AcquireSpinLock(Card^.ReceiveLock);
  TransmitLevel := AcquireSpinLock(Card^.TransmitLock);
  Card^.IsSuspended := Suspended;
  ReleaseSpinLock(Card^.TransmitLock, TransmitLevel);
  ReleaseSpinLock(Card^.ReceiveLock, ReceiveLevel);
end;

procedure SuspendCard(Context: Pointer);
var
  Card: PRtl8139Card;
begin
  Card := PRtl8139Card(Context);
  SetSuspended(Card, True);
  WritePortWord(Card^.Ports + RegisterInterruptMask, 0);
  WritePortByte(Card^.Ports + RegisterCommand, 0);
  CancelTimer(Card^.WatchTimer);
  CancelTimer(Card^.PollTimer);
  CancelDeferredCall(Card^.ServiceCall);
  CancelDeferredCall(Card^.WatchCall);
end;

procedure ResumeCard(Context: Pointer);
var
  Card: PRtl8139Card;
begin
  Card := PRtl8139Card(Context);
  PrepareChip(Card);
  Card^.PendingStatus := 0;
  NetworkCardWoke(@Card^.Card);
  SetSuspended(Card, False);
  EnableInterrupts(Card);
  StartTimers(Card);
  ReclaimTransmits(Card);
  AtomicOr(Card^.PendingStatus, InterruptLinkChange);
  QueueDeferredCall(Card^.ServiceCall);
end;

{ --- Finding cards ------------------------------------------------------------- }

procedure ReportFailure(Pci: PPciDevice; Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('rtl8139');
  DebugWriteHex(Pci^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(Pci^.DeviceId, 4);
  DebugWrite(': ');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

function AllocateMemory(Card: PRtl8139Card): Boolean;
begin
  { The card's DMA engine is 32-bit only. }
  GetPciDmaAttributes(Card^.Pci, Card^.Dma);
  LimitNetworkCardDma(Card^.Dma);
  { The card writes the ring while the driver reads it: shared memory. }
  if not AllocateDmaBuffer(Card^.Dma, ReceiveBufferBytes, DmaShared, Card^.ReceiveMemory) then
    Exit(False);
  Card^.ReceiveRing := Card^.ReceiveMemory.Address;
  Result := AllocateNetworkBuffers(Card^.Dma, @Card^.TransmitBuffers[0], TransmitSlotCount);
end;

function StartCard(Pci: PPciDevice): Boolean;
var
  Card: PRtl8139Card;
  Bar: TPciBar;
  Index: Integer;
  Routines: TNetworkDriverRoutines;
begin
  Result := False;
  if not PciReadBar(Pci, 0, Bar) or not Bar.IsIoPort then
    Exit;
  Card := PRtl8139Card(AllocateZeroedKernelMemory(SizeOf(TRtl8139Card)));
  if Card = nil then
    Exit;
  Card^.Pci := Pci;
  Card^.Ports := Word(Bar.PhysicalAddress);
  InitializeSpinLock(Card^.ReceiveLock);
  InitializeSpinLock(Card^.TransmitLock);
  PciEnableDevice(Pci, True);
  if not ResetChip(Card) then
  begin
    ReportFailure(Pci, 'the reset did not finish');
    Exit;
  end;
  for Index := 0 to EthernetAddressLength - 1 do
    Card^.Address[Index] := ReadPortByte(Card^.Ports + RegisterStationAddress + Word(Index));
  if not EthernetAddressIsUsable(Card^.Address) then
  begin
    ReportFailure(Pci, 'no valid station address');
    Exit;
  end;
  if not AllocateMemory(Card) then
  begin
    ReportFailure(Pci, 'not enough memory below 4 GiB');
    Exit;
  end;
  InitializeDeferredCall(Card^.ServiceCall, @ServiceCard, Card);
  InitializeDeferredCall(Card^.WatchCall, @WatchCard, Card);
  InitializeTimer(Card^.PollTimer);
  InitializeTimer(Card^.WatchTimer);
  { Nothing is received before the adapter is registered. }
  Card^.IsSuspended := True;
  PrepareChip(Card);
  Card^.UsesInterrupts := ConnectPciLineInterrupt(Pci, @HandleRtl8139Interrupt, Card);
  if Card^.UsesInterrupts then
    Card^.Card.InterruptDescription := 'line'
  else
    Card^.Card.InterruptDescription := 'polling';
  ReadLink(Card, Card^.Card.Link);

  Routines.Transmit := @TransmitFrame;
  Routines.LinkUp := @LinkIsUp;
  Routines.Kind := NetworkAdapterKindEthernet;
  { Takes all multicast; the network layer filters by group. }
  Routines.SetMulticastFilter := nil;
  if not AddNetworkCard(@Card^.Card, Routines, Card, Card^.Address, 'Realtek RTL8139') then
  begin
    WritePortByte(Card^.Ports + RegisterCommand, 0);
    ReportFailure(Pci, 'the adapter could not be registered');
    Exit;
  end;
  SetSuspended(Card, False);
  EnableInterrupts(Card);
  StartTimers(Card);
  RegisterPowerHandler('RTL8139', PowerStageDevices, @SuspendCard, @ResumeCard, Card);
  Result := True;
end;

function InitializeRtl8139Adapters: Integer;
var
  Index: Integer;
  Pci: PPciDevice;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Pci := PciDeviceAt(Index);
    if IsRtl8139(Pci^.VendorId, Pci^.DeviceId) and StartCard(Pci) then
      Inc(Result);
  end;
end;

end.
