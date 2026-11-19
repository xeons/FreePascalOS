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
  The Cadence GEM Ethernet controller ("cdns,macb" in its GEM form;
  "raspberrypi,rp1-gem": the Raspberry Pi 5's, inside RP1, with a
  BCM54213PE PHY at MDIO address 1 wired "rgmii-id"). Written from
  Linux's macb_main.c and NOT TESTED on hardware: QEMU's Pi 5 does not
  exist.

  Starting (each step logs a line tagged "gem" if it fails, with the
  registers that tell why):
  - the module id must name a GEM, and its design must have 64-bit DMA
    addresses (RP1 sees RAM at 10_0000_0000 and up);
  - the Ethernet address: the device tree's "local-mac-address" (the
    firmware fills it in), else what the firmware left in the first
    specific address register;
  - reset: receive and transmit off, statistics cleared, every
    interrupt off; the MDC divider (RP1's 200 MHz system clock / 96),
    the bus width from the design, two bytes of padding before each
    received frame, the check sequence dropped, every frame kept
    (promiscuous: the network layer keeps what is for it), 1536-byte
    frames; RGMII; the AXI pipeline from "cdns,aw2w-max-pipe",
    "cdns,ar2r-max-pipe" and "cdns,use-aw2b-fill"; 50 us interrupt
    moderation; DMA: 2 KiB receive buffers, bursts of 16, full packet
    buffers, 64-bit descriptors, no timestamp words, no offloads;
  - the PHY (Drivers.EthernetPhy) through the management port: the one
    "phy-handle" names (its reg), else the first that answers; reset,
    its RGMII delays from "phy-mode", autonegotiation;
  - rings (Drivers.CadenceGem.Descriptors) of 128 descriptors each way
    in one shared DMA buffer (uncached for a device that does not
    snoop, so no cache maintenance on descriptors), 2 KiB streaming
    buffers two to a page; queues beyond the first (the design may
    have several) point at a descriptor that is never theirs;
  - the interrupt (through RP1, Drivers.Rp1Interrupts), else a 10 ms
    poll; the link checked every second, the MAC's speed and duplex set
    to match.

  Receiving: the GEM fills a buffer and sets "used" in word 0; the
  driver takes every filled descriptor in order (a frame must be in one
  buffer), hands the frame on, gives the descriptor back by clearing
  "used". Transmitting copies the frame into the slot's buffer (padded
  to 60 bytes), writes the descriptor (control word last, without
  "used") and sets "start transmission"; the GEM sets "used" again when
  it has sent it.

  The kernel option "gemdebug" logs the controller's counters every 10
  seconds; without it they are logged once if the link is up and no
  frame arrived in its first 10 seconds.
}
unit Drivers.CadenceGem;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every GEM the device tree describes; returns how many. }
function InitializeCadenceGemAdapters: Integer;

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
  Kernel.Options,
  DeviceTree.Blob,
  Firmware.DeviceTree,
  Io.PlatformProperties,
  Io.Dma,
  Io.PlatformDevices,
  Io.NetworkAdapters,
  Drivers.NetworkCards,
  Drivers.EthernetPhy,
  Drivers.CadenceGem.Registers,
  Drivers.CadenceGem.Descriptors,
  Drivers.CadenceGem.Mdio,
  Debug.Output;

const
  RingSize = 128;
  BufferBytes = 2048;
  BuffersPerPage = PageSize div BufferBytes;
  PagesPerRing = RingSize div BuffersPerPage;
  ReceiveRingOffset = 0;
  TransmitRingOffset = RingSize * GemDescriptorBytes;
  IdleDescriptorsOffset = 2 * RingSize * GemDescriptorBytes;
  DescriptorBufferBytes = IdleDescriptorsOffset + 2 * GemDescriptorBytes;
  ReceivePadBytes = 2;
  MaximumQueues = 16;
  PollIntervalMilliseconds = 10;
  WatchIntervalMilliseconds = 1000;
  SilenceReportSeconds = 10;
  ReceiveBudget = 64;
  { 50 us in the GEM's 800 ns units, both ways. }
  ModerationUnits = 62;
  OptionGemDebug = 'gemdebug';
  Description = 'Cadence GEM (RP1)';
  InterruptsUsed = InterruptReceiveComplete or InterruptReceiveUsedRead or InterruptReceiveOverrun or
    InterruptTransmitComplete or InterruptTransmitUnderrun or InterruptRetryLimit or InterruptTransmitError or
    InterruptBusError;

type
  TRingPages = array[0..PagesPerRing - 1] of TDmaBuffer;

  PGemCard = ^TGemCard;
  TGemCard = record
    Card: TNetworkCard;
    Device: PPlatformDevice;
    Name: PChar;
    Registers: PByte;
    Dma: TDmaAttributes;
    Address: TEthernetAddress;
    Mdio: TMdioBus;
    PhyAddress: LongWord;
    PhyId: LongWord;
    Delays: TRgmiiDelays;
    QueueCount: LongWord;
    ClearOnWrite: Boolean;
    UsesInterrupts: Boolean;
    MacLink: TNetworkLinkState;

    Descriptors: TDmaBuffer;
    ReceiveRing: PGemDescriptor;
    TransmitRing: PGemDescriptor;
    ReceivePages: TRingPages;
    TransmitPages: TRingPages;

    ReceiveIndex: LongWord;
    ReceiveLock: TSpinLock;
    TransmitProducer: LongWord;
    TransmitConsumer: LongWord;
    WaitingForRoom: Boolean;
    TransmitLock: TSpinLock;

    PendingStatus: PtrUInt;
    BusErrors: LongWord;
    SecondsWithLink: LongWord;
    SilenceReported: Boolean;
    ServiceCall: TDeferredCall;
    PollTimer: TTimer;
    WatchCall: TDeferredCall;
    WatchTimer: TTimer;
  end;

{ --- Registers -------------------------------------------------------------- }

function ReadGem(Card: PGemCard; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Card^.Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteGem(Card: PGemCard; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Card^.Registers + Offset)^ := Value;
end;

procedure ChangeGem(Card: PGemCard; Offset: LongWord; Clear, SetBits: LongWord);
begin
  WriteGem(Card, Offset, (ReadGem(Card, Offset) and not Clear) or SetBits);
end;

{ --- Lines for the log ----------------------------------------------------------- }

procedure ReportFailure(Card: PGemCard; Step: PChar; Value: Int64);
begin
  DebugBeginMessage;
  DebugWriteTag('gem');
  DebugWrite(Card^.Name);
  DebugWrite(': FAILED at ');
  DebugWrite(Step);
  if Value >= 0 then
  begin
    DebugWrite(' 0x');
    DebugWriteHex(QWord(Value), 1);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure ReportCounters(Card: PGemCard; Why: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('gem');
  DebugWrite(Card^.Name);
  DebugWrite(': ');
  DebugWrite(Why);
  DebugWrite(': rx ');
  DebugWriteDecimal(ReadGem(Card, GemFramesReceived));
  DebugWrite(' tx ');
  DebugWriteDecimal(ReadGem(Card, GemFramesTransmitted));
  DebugWrite(' fcs ');
  DebugWriteDecimal(ReadGem(Card, GemReceiveCheckSequenceErrors));
  DebugWrite(' nobuf ');
  DebugWriteDecimal(ReadGem(Card, GemReceiveResourceErrors));
  DebugWrite(' ovr ');
  DebugWriteDecimal(ReadGem(Card, GemReceiveOverruns));
  DebugWrite(' rsr 0x');
  DebugWriteHex(ReadGem(Card, GemReceiveStatus), 1);
  DebugWrite(' tsr 0x');
  DebugWriteHex(ReadGem(Card, GemTransmitStatus), 1);
  DebugWrite(' ncr 0x');
  DebugWriteHex(ReadGem(Card, GemNetworkControl), 1);
  DebugWrite(' cfg 0x');
  DebugWriteHex(ReadGem(Card, GemNetworkConfiguration), 1);
  DebugWrite(' imr 0x');
  DebugWriteHex(ReadGem(Card, GemInterruptMask), 1);
  DebugWrite(' bus errors ');
  DebugWriteDecimal(Card^.BusErrors);
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure ReportController(Card: PGemCard; ModuleId, Design1, Design6: LongWord);
begin
  DebugBeginMessage;
  DebugWriteTag('gem');
  DebugWrite(Card^.Name);
  DebugWrite(': id 0x');
  DebugWriteHex(ModuleId, 8);
  DebugWrite(', dcfg1 0x');
  DebugWriteHex(Design1, 8);
  DebugWrite(', dcfg6 0x');
  DebugWriteHex(Design6, 8);
  DebugWrite(', ');
  DebugWriteDecimal(Card^.QueueCount);
  DebugWrite(' queues, ');
  DebugWriteLine(DmaCoherenceText(Card^.Dma));
  DebugEndMessage;
end;

procedure ReportPhy(Card: PGemCard);
begin
  DebugBeginMessage;
  DebugWriteTag('gem');
  DebugWrite(Card^.Name);
  DebugWrite(': PHY 0x');
  DebugWriteHex(Card^.PhyId, 8);
  DebugWrite(' at ');
  DebugWriteDecimal(Card^.PhyAddress);
  if (Card^.PhyId and PhyIdRevisionMask) = Bcm54213PhyId then
    DebugWrite(' (BCM54213PE)');
  DebugWrite(', ');
  DebugWrite(RgmiiDelaysText(Card^.Delays));
  DebugWrite(', address ');
  DebugWriteEthernetAddress(Card^.Address);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ --- Ring slots ------------------------------------------------------------------ }

function SlotBuffer(var Pages: TRingPages; Index: LongWord): PByte;
begin
  Result := Pages[Index div BuffersPerPage].Address + (Index mod BuffersPerPage) * BufferBytes;
end;

function SlotBusAddress(var Pages: TRingPages; Index: LongWord): QWord;
begin
  Result := Pages[Index div BuffersPerPage].DeviceAddress + (Index mod BuffersPerPage) * BufferBytes;
end;

function DescriptorBusAddress(Card: PGemCard; Offset: LongWord): QWord;
begin
  Result := Card^.Descriptors.DeviceAddress + Offset;
end;

function AllocateRingPages(Card: PGemCard; var Pages: TRingPages): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to PagesPerRing - 1 do
    if not AllocateDmaBuffer(Card^.Dma, PageSize, DmaStreaming, Pages[Index]) then
      Exit(False);
  Result := True;
end;

{ Every receive descriptor the GEM's, every transmit one software's. }
procedure FillRings(Card: PGemCard);
var
  Index: LongWord;
  Descriptor: PGemDescriptor;
  Idle: PGemDescriptor;
begin
  for Index := 0 to RingSize - 1 do
  begin
    PrepareDmaFromDevice(Card^.Dma, SlotBuffer(Card^.ReceivePages, Index), BufferBytes);
    Descriptor := @Card^.ReceiveRing[Index];
    Descriptor^.Control := 0;
    Descriptor^.AddressHigh := AddressHighWord(SlotBusAddress(Card^.ReceivePages, Index));
    Descriptor^.Reserved := 0;
    Descriptor^.AddressLow := ReceiveAddressWord(SlotBusAddress(Card^.ReceivePages, Index), Index = RingSize - 1);
    Descriptor := @Card^.TransmitRing[Index];
    Descriptor^.AddressHigh := AddressHighWord(SlotBusAddress(Card^.TransmitPages, Index));
    Descriptor^.AddressLow := LongWord(SlotBusAddress(Card^.TransmitPages, Index));
    Descriptor^.Reserved := 0;
    Descriptor^.Control := TransmitIdleWord(Index = RingSize - 1);
  end;
  { The descriptors of the queues not used: never given to the GEM. }
  Idle := PGemDescriptor(Card^.Descriptors.Address + IdleDescriptorsOffset);
  Idle[0].AddressLow := ReceiveUsed or ReceiveWrap;
  Idle[0].Control := 0;
  Idle[0].AddressHigh := 0;
  Idle[1].AddressLow := 0;
  Idle[1].Control := TransmitIdleWord(True);
  Idle[1].AddressHigh := 0;
  FullMemoryBarrier;
  Card^.ReceiveIndex := 0;
  Card^.TransmitProducer := 0;
  Card^.TransmitConsumer := 0;
end;

procedure PointQueues(Card: PGemCard);
var
  Queue: LongWord;
begin
  WriteGem(Card, GemReceiveQueueHigh, AddressHighWord(DescriptorBusAddress(Card, ReceiveRingOffset)));
  WriteGem(Card, GemTransmitQueueHigh, AddressHighWord(DescriptorBusAddress(Card, TransmitRingOffset)));
  WriteGem(Card, GemReceiveQueue, LongWord(DescriptorBusAddress(Card, ReceiveRingOffset)));
  WriteGem(Card, GemTransmitQueue, LongWord(DescriptorBusAddress(Card, TransmitRingOffset)));
  Queue := 1;
  while Queue < Card^.QueueCount do
  begin
    WriteGem(Card, GemQueueReceiveFirst + (Queue - 1) * 4, LongWord(DescriptorBusAddress(Card, IdleDescriptorsOffset)));
    WriteGem(Card, GemQueueTransmitFirst + (Queue - 1) * 4,
      LongWord(DescriptorBusAddress(Card, IdleDescriptorsOffset + GemDescriptorBytes)));
    Inc(Queue);
  end;
end;

{ --- The MAC ---------------------------------------------------------------------- }

function FindMacAddress(Card: PGemCard): Boolean;
var
  Length: LongWord;
  Bottom: LongWord;
  Top: LongWord;
begin
  if PlatformPropertyBytes(Card^.Device, 'local-mac-address', @Card^.Address[0], EthernetAddressLength, Length) and
     (Length = EthernetAddressLength) and EthernetAddressIsUsable(Card^.Address) then
    Exit(True);
  Bottom := ReadGem(Card, GemSpecificAddress1Bottom);
  Top := ReadGem(Card, GemSpecificAddress1Top);
  Card^.Address[0] := Byte(Bottom);
  Card^.Address[1] := Byte(Bottom shr 8);
  Card^.Address[2] := Byte(Bottom shr 16);
  Card^.Address[3] := Byte(Bottom shr 24);
  Card^.Address[4] := Byte(Top);
  Card^.Address[5] := Byte(Top shr 8);
  Result := EthernetAddressIsUsable(Card^.Address);
end;

procedure WriteMacAddress(Card: PGemCard);
begin
  WriteGem(Card, GemSpecificAddress1Bottom, LongWord(Card^.Address[0]) or (LongWord(Card^.Address[1]) shl 8) or
    (LongWord(Card^.Address[2]) shl 16) or (LongWord(Card^.Address[3]) shl 24));
  WriteGem(Card, GemSpecificAddress1Top, LongWord(Card^.Address[4]) or (LongWord(Card^.Address[5]) shl 8));
end;

procedure ResetController(Card: PGemCard);
var
  Queue: LongWord;
begin
  ChangeGem(Card, GemNetworkControl, ControlReceiveEnable or ControlTransmitEnable, ControlClearStatistics);
  WriteGem(Card, GemTransmitStatus, $FFFFFFFF);
  WriteGem(Card, GemReceiveStatus, $FFFFFFFF);
  WriteGem(Card, GemReceivePartialStoreForward, 0);
  WriteGem(Card, GemInterruptDisable, $FFFFFFFF);
  ReadGem(Card, GemInterruptStatus);
  if Card^.ClearOnWrite then
    WriteGem(Card, GemInterruptStatus, $FFFFFFFF);
  { The other queues' interrupt registers: 400h status, 620h disable. }
  Queue := 1;
  while Queue < Card^.QueueCount do
  begin
    WriteGem(Card, $0620 + (Queue - 1) * 4, $FFFFFFFF);
    ReadGem(Card, $0400 + (Queue - 1) * 4);
    if Card^.ClearOnWrite then
      WriteGem(Card, $0400 + (Queue - 1) * 4, $FFFFFFFF);
    Inc(Queue);
  end;
end;

{ Queue 0 always, and one more for each bit of the design's queue mask
  above it. }
function QueuesOfDesign(Design6: LongWord): LongWord;
var
  Mask: LongWord;
begin
  Result := 0;
  Mask := (Design6 and Design6QueueMask) or 1;
  while Mask <> 0 do
  begin
    Inc(Result, Mask and 1);
    Mask := Mask shr 1;
  end;
end;

function DesignBusWidth(Design1: LongWord): LongWord;
begin
  case (Design1 shr Design1BusWidthShift) and Design1BusWidthMask of
    4: Result := BusWidth128;
    2: Result := BusWidth64;
  else
    Result := BusWidth32;
  end;
end;

procedure ConfigureController(Card: PGemCard; Design1: LongWord);
var
  Value: QWord;
  Pipeline: LongWord;
  Length: LongWord;
  Byte8: Byte;
begin
  WriteGem(Card, GemNetworkConfiguration, (MdcDivider96 shl ConfigurationMdcDividerShift) or
    (DesignBusWidth(Design1) shl ConfigurationBusWidthShift) or
    (ReceivePadBytes shl ConfigurationReceiveOffsetShift) or ConfigurationDiscardCheckSequence or
    ConfigurationCopyAllFrames or ConfigurationReceive1536 or ConfigurationFullDuplex or ConfigurationGigabit);
  WriteGem(Card, GemUserIo, UserIoRgmii);
  ChangeGem(Card, GemNetworkControl, 0, ControlManagementPortEnable);
  { The AXI pipeline as the tree says (one byte each). }
  Pipeline := ReadGem(Card, GemAxiPipeline);
  if PlatformPropertyBytes(Card^.Device, 'cdns,ar2r-max-pipe', @Byte8, 1, Length) and (Length >= 1) then
    Pipeline := (Pipeline and not LongWord(AxiReadPipelineMask)) or Byte8;
  if PlatformPropertyBytes(Card^.Device, 'cdns,aw2w-max-pipe', @Byte8, 1, Length) and (Length >= 1) then
    Pipeline := (Pipeline and not AxiWritePipelineMask) or (LongWord(Byte8) shl AxiWritePipelineShift);
  if PlatformHasProperty(Card^.Device, 'cdns,use-aw2b-fill') then
    Pipeline := Pipeline or AxiWriteFillBursts;
  WriteGem(Card, GemAxiPipeline, Pipeline);
  WriteGem(Card, GemInterruptModeration, (ModerationUnits shl 16) or ModerationUnits);
  Value := ReadGem(Card, GemDmaConfiguration);
  Value := Value and not QWord(DmaReceiveBufferSizeMask or DmaFixedBurstMask or DmaEndianSwapDescriptors or
    DmaEndianSwapPackets or DmaTransmitChecksumOffload or DmaExtendedReceiveDescriptors or
    DmaExtendedTransmitDescriptors);
  Value := Value or ((BufferBytes div DmaReceiveBufferUnit) shl DmaReceiveBufferSizeShift) or DmaBurst16 or
    DmaReceivePacketBufferFull or DmaTransmitPacketBufferFull or DmaAddress64;
  WriteGem(Card, GemDmaConfiguration, LongWord(Value));
  WriteMacAddress(Card);
end;

{ Sets the MAC's speed and duplex for Link and runs it. Turning
  receive and transmit off sends the GEM's queue pointers back to the
  rings' starts, so on every link up both rings start afresh (frames
  queued while the link was down are dropped), as Linux did before it
  learnt to rotate its rings. }
procedure ConfigureMacForLink(Card: PGemCard; const Link: TNetworkLinkState);
var
  Configuration: LongWord;
  ReceiveLevel: TPriorityLevel;
  TransmitLevel: TPriorityLevel;
  TellNetworkLayer: Boolean;
begin
  TellNetworkLayer := False;
  ReceiveLevel := AcquireSpinLock(Card^.ReceiveLock);
  TransmitLevel := AcquireSpinLock(Card^.TransmitLock);
  ChangeGem(Card, GemNetworkControl, ControlReceiveEnable or ControlTransmitEnable, 0);
  if Link.IsUp then
  begin
    Configuration := ReadGem(Card, GemNetworkConfiguration) and
      not (ConfigurationSpeed100 or ConfigurationFullDuplex or ConfigurationGigabit or ConfigurationPauseEnable);
    case Link.SpeedMegabits of
      100: Configuration := Configuration or ConfigurationSpeed100;
      10: ;
    else
      Configuration := Configuration or ConfigurationGigabit;
    end;
    if Link.FullDuplex then
      Configuration := Configuration or ConfigurationFullDuplex;
    WriteGem(Card, GemNetworkConfiguration, Configuration);
    FillRings(Card);
    PointQueues(Card);
    ChangeGem(Card, GemNetworkControl, 0, ControlReceiveEnable or ControlTransmitEnable);
    TellNetworkLayer := Card^.WaitingForRoom;
    Card^.WaitingForRoom := False;
  end;
  Card^.MacLink := Link;
  ReleaseSpinLock(Card^.TransmitLock, TransmitLevel);
  ReleaseSpinLock(Card^.ReceiveLock, ReceiveLevel);
  if TellNetworkLayer and (Card^.Card.Adapter <> nil) then
    NetworkTransmitReady(Card^.Card.Adapter);
end;

{ --- Receiving and transmitting ------------------------------------------------------ }

procedure ReceiveFrames(Card: PGemCard);
var
  PreviousLevel: TPriorityLevel;
  Descriptor: PGemDescriptor;
  AddressWord: LongWord;
  Status: LongWord;
  Length: LongWord;
  Buffer: PByte;
  Frames: Integer;
begin
  PreviousLevel := AcquireSpinLock(Card^.ReceiveLock);
  Frames := 0;
  while Frames < ReceiveBudget do
  begin
    Descriptor := @Card^.ReceiveRing[Card^.ReceiveIndex];
    AddressWord := Descriptor^.AddressLow;
    if not ReceiveIsFilled(AddressWord) then
      Break;
    FullMemoryBarrier;
    Status := Descriptor^.Control;
    Length := ReceivedFrameLength(Status);
    Buffer := SlotBuffer(Card^.ReceivePages, Card^.ReceiveIndex);
    FinishDmaFromDevice(Card^.Dma, Buffer, BufferBytes);
    if not ReceivedWholeFrame(Status) or (Length < 14) or (Length > MaximumFrameBytes + 4) or
       (Length + ReceivePadBytes > BufferBytes) then
      Inc(Card^.Card.Statistics.ReceiveErrors)
    else
    begin
      if Length > MaximumFrameBytes then
        Length := MaximumFrameBytes;
      Inc(Card^.Card.Statistics.FramesReceived);
      Inc(Card^.Card.Statistics.BytesReceived, Length);
      NetworkFrameReceived(Card^.Card.Adapter, Buffer + ReceivePadBytes, Length);
    end;
    PrepareDmaFromDevice(Card^.Dma, Buffer, BufferBytes);
    Descriptor^.Control := 0;
    FullMemoryBarrier;
    Descriptor^.AddressLow := ReceiveReturnedWord(AddressWord);
    Card^.ReceiveIndex := (Card^.ReceiveIndex + 1) mod RingSize;
    Inc(Frames);
  end;
  ReleaseSpinLock(Card^.ReceiveLock, PreviousLevel);
  if Frames = ReceiveBudget then
    QueueDeferredCall(Card^.ServiceCall);
end;

function TransmitsInFlight(Card: PGemCard): LongWord;
begin
  Result := (Card^.TransmitProducer + RingSize - Card^.TransmitConsumer) mod RingSize;
end;

{ Transmit lock held. }
procedure ReclaimFinished(Card: PGemCard);
var
  Control: LongWord;
begin
  while Card^.TransmitConsumer <> Card^.TransmitProducer do
  begin
    Control := Card^.TransmitRing[Card^.TransmitConsumer].Control;
    if not TransmitIsDone(Control) then
      Break;
    if TransmitFailed(Control) then
      Inc(Card^.Card.Statistics.TransmitErrors);
    Card^.TransmitConsumer := (Card^.TransmitConsumer + 1) mod RingSize;
  end;
end;

procedure ReclaimTransmits(Card: PGemCard);
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
  Card: PGemCard;
  PreviousLevel: TPriorityLevel;
  Slot: LongWord;
  Buffer: PByte;
  SentLength: LongWord;
begin
  Card := PGemCard(Context);
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
      Slot := Card^.TransmitProducer;
      Buffer := SlotBuffer(Card^.TransmitPages, Slot);
      CopyMemory(Buffer, Frame, Length);
      SentLength := Length;
      if SentLength < MinimumFrameBytes then
      begin
        ZeroMemory(Buffer + SentLength, MinimumFrameBytes - SentLength);
        SentLength := MinimumFrameBytes;
      end;
      PrepareDmaToDevice(Card^.Dma, Buffer, SentLength);
      FullMemoryBarrier;
      Card^.TransmitRing[Slot].Control := TransmitControlWord(SentLength, Slot = RingSize - 1);
      Card^.TransmitProducer := (Slot + 1) mod RingSize;
      ChangeGem(Card, GemNetworkControl, 0, ControlTransmitStart);
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
  Result := PGemCard(Context)^.Card.Link.IsUp;
end;

{ --- Interrupts and the deferred routines ------------------------------------------- }

procedure HandleGemInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Card: PGemCard;
  Status: LongWord;
begin
  Card := PGemCard(Context);
  Status := ReadGem(Card, GemInterruptStatus);
  if Status = 0 then
    Exit;
  if Card^.ClearOnWrite then
    WriteGem(Card, GemInterruptStatus, Status);
  if (Status and InterruptBusError) <> 0 then
    Inc(Card^.BusErrors);
  AtomicOr(Card^.PendingStatus, Status);
  QueueDeferredCall(Card^.ServiceCall);
end;

procedure ServiceCard(Context: Pointer);
var
  Card: PGemCard;
  Status: PtrUInt;
begin
  Card := PGemCard(Context);
  Status := AtomicExchange(Card^.PendingStatus, 0);
  if not Card^.UsesInterrupts then
  begin
    Status := ReadGem(Card, GemInterruptStatus);
    if Card^.ClearOnWrite and (Status <> 0) then
      WriteGem(Card, GemInterruptStatus, Status);
    if (Status and InterruptBusError) <> 0 then
      Inc(Card^.BusErrors);
  end;
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
  Card: PGemCard;
  Link: TNetworkLinkState;
begin
  Card := PGemCard(Context);
  ReadPhyLink(Card^.Mdio, Card^.PhyAddress, Link);
  if LinksDiffer(Link, Card^.MacLink) then
    ConfigureMacForLink(Card, Link);
  UpdateNetworkCardLink(@Card^.Card, Link);
  if Link.IsUp then
    Inc(Card^.SecondsWithLink)
  else
    Card^.SecondsWithLink := 0;
  if (Card^.SecondsWithLink = SilenceReportSeconds) and not Card^.SilenceReported and
     (Card^.Card.Statistics.FramesReceived = 0) then
  begin
    Card^.SilenceReported := True;
    ReportCounters(Card, 'link up 10 s, nothing received');
  end
  else if KernelOptionIsSet(OptionGemDebug) and (Card^.SecondsWithLink mod SilenceReportSeconds = 1) then
    ReportCounters(Card, 'counters');
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
end;

{ --- Starting -------------------------------------------------------------------------- }

{ The PHY address "phy-handle" names (its reg), else the default. }
function PreferredPhyAddress(Device: PPlatformDevice): LongWord;
var
  Tree: PDeviceTree;
  Phandle: LongWord;
  Node: LongInt;
begin
  Result := DefaultPhyAddress;
  Tree := SystemDeviceTree;
  if (Device^.DeviceTreeNode = NoDeviceTreeNode) or
     not ReadCellProperty(Tree^, Device^.DeviceTreeNode, 'phy-handle', Phandle) then
    Exit;
  Node := FindNodeByPhandle(Tree^, Phandle);
  if (Node <> NoNode) and ReadCellProperty(Tree^, Node, 'reg', Phandle) and (Phandle < 32) then
    Result := Phandle;
end;

function PhyModeOf(Device: PPlatformDevice): TRgmiiDelays;
var
  Mode: array[0..23] of Char;
begin
  if PlatformPropertyText(Device, 'phy-mode', @Mode[0], SizeOf(Mode)) then
    Result := RgmiiDelaysOfPhyMode(@Mode[0])
  else
    Result := RgmiiBothDelays;
end;

function StartPhyOfCard(Card: PGemCard): Boolean;
var
  Step: PChar;
begin
  Result := False;
  Card^.Mdio := GemMdioBus(Card^.Registers);
  if not FindPhy(Card^.Mdio, PreferredPhyAddress(Card^.Device), Card^.PhyAddress, Card^.PhyId) then
  begin
    ReportFailure(Card, 'PHY search: no PHY answers on MDIO (held in reset by RP1 GPIO 32?), status',
      ReadGem(Card, GemNetworkStatus));
    Exit;
  end;
  Card^.Delays := PhyModeOf(Card^.Device);
  ReportPhy(Card);
  if not StartPhy(Card^.Mdio, Card^.PhyAddress, Card^.PhyId, Card^.Delays, Step) then
  begin
    ReportFailure(Card, Step, ReadPhyControlAndStatus(Card^.Mdio, Card^.PhyAddress));
    Exit;
  end;
  Result := True;
end;

function ProbeCadenceGem(Device: PPlatformDevice): Boolean;
var
  Card: PGemCard;
  Length: QWord;
  ModuleId: LongWord;
  Design1: LongWord;
  Design6: LongWord;
  Routines: TNetworkDriverRoutines;
begin
  Result := False;
  Card := PGemCard(AllocateZeroedKernelMemory(SizeOf(TGemCard)));
  if Card = nil then
    Exit;
  Card^.Device := Device;
  Card^.Name := @Device^.Path[0];
  if Device^.DeviceTreeNode <> NoDeviceTreeNode then
    Card^.Name := NodeName(SystemDeviceTree^, Device^.DeviceTreeNode);
  Card^.Dma := Device^.Dma;
  Card^.Registers := PByte(MapPlatformMemory(Device, 0, Length));
  if (Card^.Registers = nil) or (Length < GemQueueReceiveFirst + MaximumQueues * 4) then
  begin
    ReportFailure(Card, 'mapping: registers missing or short, length', Int64(Length));
    Exit;
  end;
  ModuleId := ReadGem(Card, GemModuleId);
  Design1 := ReadGem(Card, GemDesignConfiguration1);
  Design6 := ReadGem(Card, GemDesignConfiguration6);
  Card^.QueueCount := QueuesOfDesign(Design6);
  Card^.ClearOnWrite := (Design1 and Design1InterruptReadClear) = 0;
  ReportController(Card, ModuleId, Design1, Design6);
  if ((ModuleId shr ModuleIdShift) and ModuleIdMask) < ModuleIdOfGem then
  begin
    ReportFailure(Card, 'identification: not a GEM (all ones: RP1 unreachable), id', ModuleId);
    Exit;
  end;
  if (Design6 and Design6DmaAddress64) = 0 then
  begin
    ReportFailure(Card, 'design: no 64-bit DMA (RP1 needs it), dcfg6', Design6);
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
    ReportFailure(Card, 'address: no usable Ethernet address in local-mac-address or SA1', -1);
    Exit;
  end;
  if not AllocateDmaBuffer(Card^.Dma, DescriptorBufferBytes, DmaShared, Card^.Descriptors) or
     not AllocateRingPages(Card, Card^.ReceivePages) or not AllocateRingPages(Card, Card^.TransmitPages) then
  begin
    ReportFailure(Card, 'memory: not enough DMA memory', -1);
    Exit;
  end;
  Card^.ReceiveRing := PGemDescriptor(Card^.Descriptors.Address + ReceiveRingOffset);
  Card^.TransmitRing := PGemDescriptor(Card^.Descriptors.Address + TransmitRingOffset);

  ResetController(Card);
  ConfigureController(Card, Design1);
  if not StartPhyOfCard(Card) then
    Exit;
  FillRings(Card);
  PointQueues(Card);
  ReadPhyLink(Card^.Mdio, Card^.PhyAddress, Card^.Card.Link);
  ConfigureMacForLink(Card, Card^.Card.Link);

  Card^.UsesInterrupts := ConnectPlatformInterrupt(Device, 0, @HandleGemInterrupt, Card);
  if Card^.UsesInterrupts then
    Card^.Card.InterruptDescription := 'RP1 MSI-X'
  else
    Card^.Card.InterruptDescription := 'polling';
  Routines.Transmit := @TransmitFrame;
  Routines.LinkUp := @LinkIsUp;
  Routines.Kind := NetworkAdapterKindEthernet;
  { Takes all multicast; the network layer filters by group. }
  Routines.SetMulticastFilter := nil;
  if not AddNetworkCard(@Card^.Card, Routines, Card, Card^.Address, Description) then
  begin
    ChangeGem(Card, GemNetworkControl, ControlReceiveEnable or ControlTransmitEnable, 0);
    ReportFailure(Card, 'registration: the adapter could not be registered', -1);
    Exit;
  end;
  if Card^.UsesInterrupts then
    WriteGem(Card, GemInterruptEnable, InterruptsUsed)
  else
    SetTimer(Card^.PollTimer, PollIntervalMilliseconds, Card^.ServiceCall);
  SetTimer(Card^.WatchTimer, WatchIntervalMilliseconds, Card^.WatchCall);
  Result := True;
end;

const
  GemIds: array[0..2] of PChar = ('raspberrypi,rp1-gem', 'cdns,macb', nil);
  GemDriver: TPlatformDriver = (
    Name: 'gem';
    Ids: @GemIds[0];
    Probe: @ProbeCadenceGem);

function InitializeCadenceGemAdapters: Integer;
begin
  Result := BindPlatformDriver(GemDriver);
end;

end.
