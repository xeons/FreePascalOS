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
  Broadcom GENET v5 Gigabit Ethernet (the BCM2711 of the Raspberry Pi 4),
  the ACPI platform device BCM6E4E. Written against the published
  register layout (Drivers.Genet.Registers) and NOT TESTED on hardware:
  QEMU has no GENET.

  Starting: the version register must say v5. The MAC is reset (receive
  buffer flushed, software reset), its counters cleared, the largest
  frame set; the receive buffer puts two bytes of padding before each
  frame (so the IP header is aligned) and no status block; the port is
  an external gigabit PHY over RGMII, the MAC adding the transmit clock
  delay and the PHY the receive delay ("rgmii-rxid", Drivers.Genet.Phy).
  The Ethernet address is the _DSD's "local-mac-address" (or
  "mac-address"), else the firmware's (VideoCore mailbox), else what the
  MAC holds already. The MAC runs promiscuous: the network layer keeps
  what is for it (as with the other cards, which take every multicast).

  DMA: only ring 16, the default queue, each way, over all 256
  descriptors. The descriptors are registers of the controller; each
  receive descriptor points at a 2 KiB buffer of the driver's own, two to
  a page, streaming DMA memory of the device (Io.Dma): cleaned and
  invalidated before the controller may write it, invalidated before a
  frame in it is read. The controller produces received frames and moves
  the ring's producer index; the driver reads up to it and gives the
  buffers back by moving the consumer index. Transmitting copies the
  frame into the slot's own buffer (padded to 60 bytes), cleans it,
  writes the descriptor (start and end of packet, append the check
  sequence) and moves the producer index; the controller's consumer
  index says how far it got.

  Interrupts: the first _CRS interrupt (INTRL2_0: receive and transmit
  done on the default queue). The handler acknowledges and queues a
  deferred call that does the work; without the interrupt a timer polls.
  The link is the PHY's, looked at every second; when it changes the
  MAC's speed and duplex and the RGMII link bit follow it.
}
unit Drivers.Genet;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every GENET v5 controller the firmware describes; returns how
  many. }
function InitializeGenetAdapters: Integer;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Memory.Layout,
  Memory.KernelHeap,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.Clock,
  Io.PlatformProperties,
  Io.Dma,
  Io.PlatformDevices,
  Io.NetworkAdapters,
  Drivers.NetworkCards,
  Drivers.VideoCoreMailbox,
  Drivers.Genet.Registers,
  Drivers.Genet.Phy,
  Drivers.EthernetPhy,
  Debug.Output;

const
  RingSize = DmaDescriptorCount;
  RingMask = RingSize - 1;
  BuffersPerPage = PageSize div GenetReceiveBufferBytes;
  PagesPerRing = RingSize div BuffersPerPage;
  PollIntervalMilliseconds = 10;
  WatchIntervalMilliseconds = 1000;
  DmaStopTimeoutNanoseconds = 5000000;
  { Most frames handled in one go before the others get a turn. }
  ReceiveBudget = 64;
  SmallestReceivedLength = ReceiveAlignmentPadBytes + 14;
  InterruptsUsed = InterruptReceiveDmaDone or InterruptTransmitDmaDone;
  Description = 'Broadcom GENET v5';

type
  TRingPages = array[0..PagesPerRing - 1] of TDmaBuffer;

  PGenetCard = ^TGenetCard;
  TGenetCard = record
    Card: TNetworkCard;
    Device: PPlatformDevice;
    Registers: PByte;
    Dma: TDmaAttributes;
    Address: TEthernetAddress;
    Mdio: TMdioBus;
    PhyAddress: LongWord;
    PhyId: LongWord;
    UsesInterrupts: Boolean;
    { The link the MAC was last set up for. }
    MacLink: TNetworkLinkState;

    ReceivePages: TRingPages;
    { Counts up in 16 bits like the controller's indexes. }
    ReceiveConsumer: LongWord;
    ReceiveDiscards: LongWord;
    ReceiveLock: TSpinLock;

    TransmitPages: TRingPages;
    TransmitProducer: LongWord;
    TransmitConsumer: LongWord;
    WaitingForRoom: Boolean;
    TransmitLock: TSpinLock;

    PendingStatus: PtrUInt;
    ServiceCall: TDeferredCall;
    PollTimer: TTimer;
    WatchCall: TDeferredCall;
    WatchTimer: TTimer;
  end;

{ --- Registers -------------------------------------------------------------- }

function ReadRegister(Card: PGenetCard; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Card^.Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteRegister(Card: PGenetCard; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Card^.Registers + Offset)^ := Value;
end;

procedure WaitMicroseconds(Microseconds: QWord);
var
  Deadline: QWord;
begin
  Deadline := ClockNanoseconds + Microseconds * 1000;
  while ClockNanoseconds < Deadline do
    CpuRelax;
end;

function ReceiveRing(Register: LongWord): LongWord;
begin
  Result := GenetReceiveDmaBlock + RingRegisterOffset(DmaDefaultRing, Register);
end;

function TransmitRing(Register: LongWord): LongWord;
begin
  Result := GenetTransmitDmaBlock + RingRegisterOffset(DmaDefaultRing, Register);
end;

{ The buffer of slot Index of a ring, and its bus address. }
function SlotBuffer(var Pages: TRingPages; Index: LongWord): PByte;
begin
  Result := Pages[Index div BuffersPerPage].Address + (Index mod BuffersPerPage) * GenetReceiveBufferBytes;
end;

function SlotBusAddress(var Pages: TRingPages; Index: LongWord): QWord;
begin
  Result := Pages[Index div BuffersPerPage].DeviceAddress + (Index mod BuffersPerPage) * GenetReceiveBufferBytes;
end;

procedure WriteDescriptorAddress(Card: PGenetCard; DmaBlock: LongWord; Index: LongWord; BusAddress: QWord);
begin
  WriteRegister(Card, DmaBlock + DescriptorOffset(Index) + DescriptorAddressLow, LongWord(BusAddress));
  WriteRegister(Card, DmaBlock + DescriptorOffset(Index) + DescriptorAddressHigh, LongWord(BusAddress shr 32));
end;

{ --- The MAC ------------------------------------------------------------------ }

function ControllerIsVersion5(Card: PGenetCard; out Major, Minor: LongWord): Boolean;
var
  Revision: LongWord;
begin
  Revision := ReadRegister(Card, SystemRevisionControl);
  Major := (Revision shr RevisionMajorShift) and RevisionMajorMask;
  Minor := (Revision shr RevisionMinorShift) and RevisionMinorMask;
  Result := Major = RevisionMajorOfVersion5;
end;

procedure ResetMac(Card: PGenetCard);
var
  Value: LongWord;
begin
  { Out of power down (the bias and the DLL of the RGMII block). }
  Value := ReadRegister(Card, ExtensionPowerManagement);
  WriteRegister(Card, ExtensionPowerManagement, Value and not (PowerDownBias or PowerDownDll));
  { Flush the receive buffer. }
  Value := ReadRegister(Card, SystemReceiveBufferFlushControl);
  WriteRegister(Card, SystemReceiveBufferFlushControl, Value or ReceiveBufferFlush);
  WaitMicroseconds(10);
  WriteRegister(Card, SystemReceiveBufferFlushControl, Value and not ReceiveBufferFlush);
  WaitMicroseconds(10);
  WriteRegister(Card, SystemReceiveBufferFlushControl, 0);
  WaitMicroseconds(10);
  { Software reset, the MAC stopped while it is set up. }
  WriteRegister(Card, MacCommand, CommandSoftwareReset);
  WaitMicroseconds(10);
  WriteRegister(Card, MacCommand, 0);
  WaitMicroseconds(10);
  WriteRegister(Card, MacTransmitFlush, 1);
  WaitMicroseconds(10);
  WriteRegister(Card, MacTransmitFlush, 0);
  { Counters cleared. }
  WriteRegister(Card, MacCounterControl, CounterResetReceive or CounterResetRunt or CounterResetTransmit);
  WriteRegister(Card, MacCounterControl, 0);
  WriteRegister(Card, MacMaximumFrameLength, GenetMaximumFrameLength);
  { No status blocks; two bytes of padding before each received frame. }
  Value := ReadRegister(Card, ReceiveBufferControl);
  Value := (Value and not ReceiveBuffer64ByteStatus) or ReceiveBufferAlign2Bytes;
  WriteRegister(Card, ReceiveBufferControl, Value);
  WriteRegister(Card, TransmitBufferControl,
    ReadRegister(Card, TransmitBufferControl) and not TransmitBuffer64ByteStatus);
  WriteRegister(Card, ReceiveBufferSizeControl, 1);
  { Every interrupt masked and cleared, in both controllers. }
  WriteRegister(Card, GenetInterrupt0Block + InterruptMaskSet, $FFFFFFFF);
  WriteRegister(Card, GenetInterrupt0Block + InterruptClear, $FFFFFFFF);
  WriteRegister(Card, GenetInterrupt1Block + InterruptMaskSet, $FFFFFFFF);
  WriteRegister(Card, GenetInterrupt1Block + InterruptClear, $FFFFFFFF);
end;

{ An external gigabit PHY over RGMII; the MAC delays the transmit clock
  (the identification delay mode stays on: "rgmii-rxid"). }
procedure SetUpPort(Card: PGenetCard);
var
  Value: LongWord;
begin
  WriteRegister(Card, SystemPortControl, PortModeExternalGigabitPhy);
  Value := ReadRegister(Card, ExtensionRgmiiOutOfBandControl);
  Value := (Value or RgmiiModeEnable) and not RgmiiIdModeDisable;
  WriteRegister(Card, ExtensionRgmiiOutOfBandControl, Value);
end;

procedure WriteMacAddress(Card: PGenetCard);
begin
  WriteRegister(Card, MacAddress0, (LongWord(Card^.Address[0]) shl 24) or (LongWord(Card^.Address[1]) shl 16) or
    (LongWord(Card^.Address[2]) shl 8) or Card^.Address[3]);
  WriteRegister(Card, MacAddress1, (LongWord(Card^.Address[4]) shl 8) or Card^.Address[5]);
end;

procedure ReadMacRegisters(Card: PGenetCard; var Address: TEthernetAddress);
var
  High: LongWord;
  Low: LongWord;
begin
  High := ReadRegister(Card, MacAddress0);
  Low := ReadRegister(Card, MacAddress1);
  Address[0] := Byte(High shr 24);
  Address[1] := Byte(High shr 16);
  Address[2] := Byte(High shr 8);
  Address[3] := Byte(High);
  Address[4] := Byte(Low shr 8);
  Address[5] := Byte(Low);
end;

{ The Ethernet address: the firmware tables', the firmware's, or the
  MAC's own. }
function FindMacAddress(Card: PGenetCard): Boolean;
var
  Length: LongWord;
begin
  if PlatformPropertyBytes(Card^.Device, 'local-mac-address', @Card^.Address[0],
       EthernetAddressLength, Length) and (Length = EthernetAddressLength) and
     EthernetAddressIsUsable(Card^.Address) then
    Exit(True);
  if PlatformPropertyBytes(Card^.Device, 'mac-address', @Card^.Address[0],
       EthernetAddressLength, Length) and (Length = EthernetAddressLength) and
     EthernetAddressIsUsable(Card^.Address) then
    Exit(True);
  if QueryBoardMacAddress(@Card^.Address[0]) and EthernetAddressIsUsable(Card^.Address) then
    Exit(True);
  ReadMacRegisters(Card, Card^.Address);
  Result := EthernetAddressIsUsable(Card^.Address);
end;

{ Sets the MAC's speed and duplex for Link and runs it. }
procedure ConfigureMacForLink(Card: PGenetCard; const Link: TNetworkLinkState);
var
  Command: LongWord;
  Speed: LongWord;
  OutOfBand: LongWord;
begin
  case Link.SpeedMegabits of
    10: Speed := CommandSpeed10;
    100: Speed := CommandSpeed100;
  else
    Speed := CommandSpeed1000;
  end;
  OutOfBand := ReadRegister(Card, ExtensionRgmiiOutOfBandControl) and not RgmiiOutOfBandDisable;
  if Link.IsUp then
    OutOfBand := OutOfBand or RgmiiLink
  else
    OutOfBand := OutOfBand and not RgmiiLink;
  WriteRegister(Card, ExtensionRgmiiOutOfBandControl, OutOfBand);
  Command := ReadRegister(Card, MacCommand);
  Command := Command and not ((CommandSpeedMask shl CommandSpeedShift) or CommandHalfDuplex or CommandCrcForward);
  Command := Command or (Speed shl CommandSpeedShift) or CommandReceivePauseIgnore or
    CommandTransmitPauseIgnore or CommandPromiscuous or CommandTransmitEnable or CommandReceiveEnable;
  if Link.IsUp and not Link.FullDuplex then
    Command := Command or CommandHalfDuplex;
  WriteRegister(Card, MacCommand, Command);
  Card^.MacLink := Link;
end;

{ --- DMA ---------------------------------------------------------------------- }

function StopDmaEngine(Card: PGenetCard; DmaBlock: LongWord): Boolean;
var
  Deadline: QWord;
begin
  WriteRegister(Card, DmaBlock + DmaEngineRegistersStart + DmaControl,
    ReadRegister(Card, DmaBlock + DmaEngineRegistersStart + DmaControl) and not DmaEnable);
  Deadline := ClockNanoseconds + DmaStopTimeoutNanoseconds;
  while (ReadRegister(Card, DmaBlock + DmaEngineRegistersStart + DmaStatus) and DmaDisabled) = 0 do
  begin
    if ClockNanoseconds > Deadline then
      Exit(False);
    CpuRelax;
  end;
  WriteRegister(Card, DmaBlock + DmaEngineRegistersStart + DmaControl, 0);
  WriteRegister(Card, DmaBlock + DmaEngineRegistersStart + DmaRingConfiguration, 0);
  Result := True;
end;

{ Ring 16 over all the descriptors, its indexes at zero. }
procedure SetUpRing(Card: PGenetCard; DmaBlock: LongWord; IsReceive: Boolean);
var
  Ring: LongWord;
begin
  Ring := DmaBlock + RingRegisterOffset(DmaDefaultRing, 0);
  WriteRegister(Card, Ring + RingBufferSize, (LongWord(RingSize) shl RingSizeShift) or GenetReceiveBufferBytes);
  WriteRegister(Card, Ring + RingStartAddress, 0);
  WriteRegister(Card, Ring + RingStartAddressHigh, 0);
  WriteRegister(Card, Ring + RingEndAddress, RingSize * DmaWordsPerDescriptor - 1);
  WriteRegister(Card, Ring + RingEndAddressHigh, 0);
  WriteRegister(Card, Ring + RingReceiveWritePointer, 0);
  WriteRegister(Card, Ring + RingReceiveReadPointer, 0);
  WriteRegister(Card, Ring + RingReceiveProducerIndex, 0);
  WriteRegister(Card, Ring + RingReceiveConsumerIndex, 0);
  WriteRegister(Card, Ring + RingBuffersDoneThreshold, 1);
  if IsReceive then
    WriteRegister(Card, Ring + RingReceiveFlowThresholds, (RingFlowOff shl RingFlowOffShift) or RingFlowOn)
  else
    WriteRegister(Card, Ring + RingTransmitFlowPeriod, 0);
end;

procedure StartDmaEngine(Card: PGenetCard; DmaBlock: LongWord);
begin
  WriteRegister(Card, DmaBlock + DmaEngineRegistersStart + DmaRingConfiguration,
    LongWord(1) shl DmaDefaultRing);
  WriteRegister(Card, DmaBlock + DmaEngineRegistersStart + DmaBurstSize, DmaMaximumBurst);
  WriteRegister(Card, DmaBlock + DmaEngineRegistersStart + DmaControl,
    DmaEnable or (LongWord(1) shl (DmaDefaultRing + DmaRingBufferEnableShift)));
end;

function SetUpDma(Card: PGenetCard): Boolean;
var
  Index: LongWord;
begin
  Result := StopDmaEngine(Card, GenetReceiveDmaBlock) and StopDmaEngine(Card, GenetTransmitDmaBlock);
  if not Result then
    Exit;
  SetUpRing(Card, GenetReceiveDmaBlock, True);
  SetUpRing(Card, GenetTransmitDmaBlock, False);
  for Index := 0 to RingSize - 1 do
  begin
    PrepareDmaFromDevice(Card^.Dma, SlotBuffer(Card^.ReceivePages, Index), GenetReceiveBufferBytes);
    WriteDescriptorAddress(Card, GenetReceiveDmaBlock, Index, SlotBusAddress(Card^.ReceivePages, Index));
    WriteRegister(Card, GenetReceiveDmaBlock + DescriptorOffset(Index) + DescriptorLengthStatus, 0);
    WriteDescriptorAddress(Card, GenetTransmitDmaBlock, Index, SlotBusAddress(Card^.TransmitPages, Index));
    WriteRegister(Card, GenetTransmitDmaBlock + DescriptorOffset(Index) + DescriptorLengthStatus, 0);
  end;
  Card^.ReceiveConsumer := 0;
  Card^.ReceiveDiscards := 0;
  Card^.TransmitProducer := 0;
  Card^.TransmitConsumer := 0;
  StartDmaEngine(Card, GenetReceiveDmaBlock);
  StartDmaEngine(Card, GenetTransmitDmaBlock);
end;

function AllocateRingPages(Card: PGenetCard; var Pages: TRingPages): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to PagesPerRing - 1 do
    if not AllocateDmaBuffer(Card^.Dma, PageSize, DmaStreaming, Pages[Index]) then
      Exit(False);
  Result := True;
end;

{ --- Receiving and transmitting ------------------------------------------------ }

{ The controller counts the frames it had no buffer for in the upper
  half of the producer register (16 bits, wrapping). }
procedure CountDiscards(Card: PGenetCard; Producer: LongWord);
var
  Discards: LongWord;
begin
  Discards := (Producer shr 16) and RingIndexMask;
  Inc(Card^.Card.Statistics.ReceiveMissed, (Discards - Card^.ReceiveDiscards) and RingIndexMask);
  Card^.ReceiveDiscards := Discards;
end;

procedure ReceiveFrames(Card: PGenetCard);
var
  PreviousLevel: TPriorityLevel;
  Producer: LongWord;
  Slot: LongWord;
  LengthStatus: LongWord;
  Length: LongWord;
  Status: LongWord;
  Buffer: PByte;
  Frames: Integer;
begin
  PreviousLevel := AcquireSpinLock(Card^.ReceiveLock);
  Producer := ReadRegister(Card, ReceiveRing(RingReceiveProducerIndex));
  CountDiscards(Card, Producer);
  Producer := Producer and RingIndexMask;
  Frames := 0;
  while (Card^.ReceiveConsumer <> Producer) and (Frames < ReceiveBudget) do
  begin
    Slot := Card^.ReceiveConsumer and RingMask;
    LengthStatus := ReadRegister(Card, GenetReceiveDmaBlock + DescriptorOffset(Slot) + DescriptorLengthStatus);
    Length := (LengthStatus shr DescriptorLengthShift) and DescriptorLengthMask;
    Status := LengthStatus and $FFFF;
    Buffer := SlotBuffer(Card^.ReceivePages, Slot);
    if Length > GenetReceiveBufferBytes then
      Length := GenetReceiveBufferBytes;
    FinishDmaFromDevice(Card^.Dma, Buffer, Length);
    if ((Status and DescriptorReceiveErrors) <> 0) or
       ((Status and (DescriptorStartOfPacket or DescriptorEndOfPacket)) <>
         (DescriptorStartOfPacket or DescriptorEndOfPacket)) or
       (Length < SmallestReceivedLength) or (Length - ReceiveAlignmentPadBytes > MaximumFrameBytes + 4) then
      Inc(Card^.Card.Statistics.ReceiveErrors)
    else
    begin
      Length := Length - ReceiveAlignmentPadBytes;
      { (The check sequence is stripped: the MAC does not forward it.) }
      if Length > MaximumFrameBytes then
        Length := MaximumFrameBytes;
      Inc(Card^.Card.Statistics.FramesReceived);
      Inc(Card^.Card.Statistics.BytesReceived, Length);
      NetworkFrameReceived(Card^.Card.Adapter, Buffer + ReceiveAlignmentPadBytes, Length);
    end;
    { The buffer goes back to the controller as it is. }
    PrepareDmaFromDevice(Card^.Dma, Buffer, GenetReceiveBufferBytes);
    Card^.ReceiveConsumer := (Card^.ReceiveConsumer + 1) and RingIndexMask;
    Inc(Frames);
  end;
  if Frames > 0 then
    WriteRegister(Card, ReceiveRing(RingReceiveConsumerIndex), Card^.ReceiveConsumer);
  ReleaseSpinLock(Card^.ReceiveLock, PreviousLevel);
  { More waiting: another turn. }
  if Frames = ReceiveBudget then
    QueueDeferredCall(Card^.ServiceCall);
end;

function TransmitsInFlight(Card: PGenetCard): LongWord;
begin
  Result := (Card^.TransmitProducer - Card^.TransmitConsumer) and RingIndexMask;
end;

{ Transmit lock held. }
procedure ReclaimFinished(Card: PGenetCard);
var
  Consumer: LongWord;
begin
  Consumer := ReadRegister(Card, TransmitRing(RingTransmitConsumerIndex)) and RingIndexMask;
  { Only what was handed out can be done. }
  if ((Consumer - Card^.TransmitConsumer) and RingIndexMask) <= TransmitsInFlight(Card) then
    Card^.TransmitConsumer := Consumer;
end;

procedure ReclaimTransmits(Card: PGenetCard);
var
  PreviousLevel: TPriorityLevel;
  TellNetworkLayer: Boolean;
begin
  TellNetworkLayer := False;
  PreviousLevel := AcquireSpinLock(Card^.TransmitLock);
  ReclaimFinished(Card);
  if Card^.WaitingForRoom and (TransmitsInFlight(Card) < RingSize - 1) then
  begin
    Card^.WaitingForRoom := False;
    TellNetworkLayer := True;
  end;
  ReleaseSpinLock(Card^.TransmitLock, PreviousLevel);
  if TellNetworkLayer then
    NetworkTransmitReady(Card^.Card.Adapter);
end;

function TransmitFrame(Context: Pointer; Frame: PByte; Length: LongWord): Boolean;
var
  Card: PGenetCard;
  PreviousLevel: TPriorityLevel;
  Slot: LongWord;
  Buffer: PByte;
  SentLength: LongWord;
begin
  Card := PGenetCard(Context);
  Result := False;
  PreviousLevel := AcquireSpinLock(Card^.TransmitLock);
  if (Length = 0) or (Length > MaximumFrameBytes) then
  begin
    Inc(Card^.Card.Statistics.TransmitErrors);
    Result := True;
  end
  else
  begin
    if TransmitsInFlight(Card) >= RingSize - 1 then
      ReclaimFinished(Card);
    if TransmitsInFlight(Card) < RingSize - 1 then
    begin
      Slot := Card^.TransmitProducer and RingMask;
      Buffer := SlotBuffer(Card^.TransmitPages, Slot);
      CopyMemory(Buffer, Frame, Length);
      SentLength := Length;
      if SentLength < MinimumFrameBytes then
      begin
        ZeroMemory(Buffer + SentLength, MinimumFrameBytes - SentLength);
        SentLength := MinimumFrameBytes;
      end;
      PrepareDmaToDevice(Card^.Dma, Buffer, SentLength);
      WriteRegister(Card, GenetTransmitDmaBlock + DescriptorOffset(Slot) + DescriptorLengthStatus,
        (SentLength shl DescriptorLengthShift) or
        (DescriptorTransmitQueueTagMask shl DescriptorTransmitQueueTagShift) or DescriptorTransmitAppendCrc or
        DescriptorStartOfPacket or DescriptorEndOfPacket);
      Card^.TransmitProducer := (Card^.TransmitProducer + 1) and RingIndexMask;
      WriteRegister(Card, TransmitRing(RingTransmitProducerIndex), Card^.TransmitProducer);
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
begin
  Result := PGenetCard(Context)^.Card.Link.IsUp;
end;

{ --- Interrupts and the deferred routines ------------------------------------- }

procedure HandleGenetInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Card: PGenetCard;
  Status: LongWord;
begin
  Card := PGenetCard(Context);
  Status := ReadRegister(Card, GenetInterrupt0Block + InterruptStatus) and
    not ReadRegister(Card, GenetInterrupt0Block + InterruptMaskStatus);
  if Status = 0 then
    Exit;
  WriteRegister(Card, GenetInterrupt0Block + InterruptClear, Status);
  AtomicOr(Card^.PendingStatus, Status);
  QueueDeferredCall(Card^.ServiceCall);
end;

procedure ServiceCard(Context: Pointer);
var
  Card: PGenetCard;
begin
  Card := PGenetCard(Context);
  AtomicExchange(Card^.PendingStatus, 0);
  ReceiveFrames(Card);
  ReclaimTransmits(Card);
  if not Card^.UsesInterrupts then
    SetTimer(Card^.PollTimer, PollIntervalMilliseconds, Card^.ServiceCall);
end;

function LinksDiffer(const First, Second: TNetworkLinkState): Boolean;
begin
  Result := (First.IsUp <> Second.IsUp) or (First.SpeedMegabits <> Second.SpeedMegabits) or
    (First.FullDuplex <> Second.FullDuplex);
end;

procedure WatchCard(Context: Pointer);
var
  Card: PGenetCard;
  Link: TNetworkLinkState;
begin
  Card := PGenetCard(Context);
  ReadPhyLink(Card^.Mdio, Card^.PhyAddress, Link);
  if LinksDiffer(Link, Card^.MacLink) then
    ConfigureMacForLink(Card, Link);
  UpdateNetworkCardLink(@Card^.Card, Link);
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
end;

{ --- Finding controllers ------------------------------------------------------- }

procedure ReportFailure(Device: PPlatformDevice; Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('genet');
  DebugWrite(@Device^.Path[0]);
  DebugWrite(': ');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

procedure ReportVersion(Device: PPlatformDevice; Major, Minor: LongWord);
begin
  DebugBeginMessage;
  DebugWriteTag('genet');
  DebugWrite(@Device^.Path[0]);
  DebugWrite(': version register says major ');
  DebugWriteDecimal(Major);
  DebugWrite(' minor ');
  DebugWriteDecimal(Minor);
  DebugWriteLine(', not GENET v5: left alone');
  DebugEndMessage;
end;

procedure ReportPhy(Card: PGenetCard);
begin
  DebugBeginMessage;
  DebugWriteTag('genet');
  DebugWrite(@Card^.Device^.Path[0]);
  DebugWrite(': PHY ');
  DebugWriteHex(Card^.PhyId, 8);
  DebugWrite(' at address ');
  DebugWriteDecimal(Card^.PhyAddress);
  if (Card^.PhyId and PhyIdRevisionMask) = Bcm54213PhyId then
    DebugWrite(' (BCM54213PE)');
  DebugWrite(', ');
  DebugWriteLine(DmaCoherenceText(Card^.Dma));
  DebugEndMessage;
end;

function ProbeGenet(Device: PPlatformDevice): Boolean;
var
  Card: PGenetCard;
  Length: QWord;
  Major: LongWord;
  Minor: LongWord;
  Routines: TNetworkDriverRoutines;
  PhyStep: PChar;
begin
  Result := False;
  Card := PGenetCard(AllocateZeroedKernelMemory(SizeOf(TGenetCard)));
  if Card = nil then
    Exit;
  Card^.Device := Device;
  Card^.Dma := Device^.Dma;
  { 32-bit bus addresses keep clear of any doubt about the address's
    high word. }
  LimitDmaBusAddresses(Card^.Dma, QWord(1) shl 32);
  Card^.Registers := PByte(MapPlatformMemory(Device, 0, Length));
  if Card^.Registers = nil then
  begin
    ReportFailure(Device, 'its registers could not be mapped');
    Exit;
  end;
  if Length < GenetTransmitDmaBlock + DmaEngineRegistersStart + $40 then
  begin
    ReportFailure(Device, 'its register range is too short');
    Exit;
  end;
  if not ControllerIsVersion5(Card, Major, Minor) then
  begin
    ReportVersion(Device, Major, Minor);
    Exit;
  end;
  InitializeSpinLock(Card^.ReceiveLock);
  InitializeSpinLock(Card^.TransmitLock);
  InitializeDeferredCall(Card^.ServiceCall, @ServiceCard, Card);
  InitializeDeferredCall(Card^.WatchCall, @WatchCard, Card);
  InitializeTimer(Card^.PollTimer);
  InitializeTimer(Card^.WatchTimer);

  if not FindMacAddress(Card) then
  begin
    ReportFailure(Device, 'no usable Ethernet address');
    Exit;
  end;
  if not AllocateRingPages(Card, Card^.ReceivePages) or not AllocateRingPages(Card, Card^.TransmitPages) then
  begin
    ReportFailure(Device, 'not enough DMA memory');
    Exit;
  end;
  ResetMac(Card);
  SetUpPort(Card);
  WriteMacAddress(Card);
  Card^.Mdio := GenetMdioBus(Card^.Registers);
  if not FindPhy(Card^.Mdio, DefaultPhyAddress, Card^.PhyAddress, Card^.PhyId) then
  begin
    ReportFailure(Device, 'no PHY answers on the MDIO bus');
    Exit;
  end;
  ReportPhy(Card);
  if not StartPhy(Card^.Mdio, Card^.PhyAddress, Card^.PhyId, RgmiiReceiveDelay, PhyStep) then
  begin
    ReportFailure(Device, 'the PHY could not be reset');
    Exit;
  end;
  if not SetUpDma(Card) then
  begin
    ReportFailure(Device, 'the DMA engines did not stop');
    Exit;
  end;
  { Running at gigabit speed with the link down until the PHY says. }
  ReadPhyLink(Card^.Mdio, Card^.PhyAddress, Card^.Card.Link);
  ConfigureMacForLink(Card, Card^.Card.Link);

  Card^.UsesInterrupts := ConnectPlatformInterrupt(Device, 0, @HandleGenetInterrupt, Card);
  if Card^.UsesInterrupts then
    Card^.Card.InterruptDescription := 'line'
  else
    Card^.Card.InterruptDescription := 'polling';

  Routines.Transmit := @TransmitFrame;
  Routines.LinkUp := @LinkIsUp;
  Routines.Kind := NetworkAdapterKindEthernet;
  { Takes all multicast; the network layer filters by group. }
  Routines.SetMulticastFilter := nil;
  if not AddNetworkCard(@Card^.Card, Routines, Card, Card^.Address, Description) then
  begin
    WriteRegister(Card, MacCommand, 0);
    ReportFailure(Device, 'the adapter could not be registered');
    Exit;
  end;
  if Card^.UsesInterrupts then
    WriteRegister(Card, GenetInterrupt0Block + InterruptMaskClear, InterruptsUsed)
  else
    SetTimer(Card^.PollTimer, PollIntervalMilliseconds, Card^.ServiceCall);
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
  Result := True;
end;

const
  GenetIds: array[0..1] of PChar = ('BCM6E4E', nil);
  GenetDriver: TPlatformDriver = (
    Name: 'genet';
    Ids: @GenetIds[0];
    Probe: @ProbeGenet);

function InitializeGenetAdapters: Integer;
begin
  Result := BindPlatformDriver(GenetDriver);
end;

end.
