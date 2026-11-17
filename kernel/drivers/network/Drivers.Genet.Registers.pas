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
  The registers of Broadcom's GENET Ethernet controller, version 5 (the
  BCM2711 of the Raspberry Pi 4), as offsets from the start of its
  register space (the ACPI device's memory range, FD580000h on the Pi 4).

  The layout follows the register definitions published with Linux's
  bcmgenet driver (bcmgenet.h, and the v4/v5 tables in bcmgenet.c). The
  controller is made of blocks:

    0000h  SYS        version, port mode, receive buffer flush
    0080h  EXT        RGMII port control, power management
    0200h  INTRL2_0   interrupt controller: the default queue (ring 16),
                      link and MDIO events
    0240h  INTRL2_1   interrupt controller: the priority rings 0-15
    0300h  RBUF       receive buffer: status block, alignment
    0600h  TBUF       transmit buffer
    0800h  UMAC       the MAC: command, address, frame length, counters,
                      and the MDIO bus to the PHY (at 0E14h)
    2000h  RDMA       receive DMA: 256 descriptors, then 17 rings' registers,
                      then the DMA engine's own
    4000h  TDMA       transmit DMA, laid out the same way

  A v4/v5 descriptor is three words: length and status, the low and the
  high half of the buffer address (40-bit addressing). Descriptors live
  in the controller (written through the registers, not in memory).
  A ring takes a run of descriptors; its start and end are given in
  words. Ring 16 is the default queue, the only one used here.
}
unit Drivers.Genet.Registers;

{$mode objfpc}

interface

const
  { --- Blocks --- }
  GenetSystemBlock = $0000;
  GenetExtensionBlock = $0080;
  GenetInterrupt0Block = $0200;
  GenetInterrupt1Block = $0240;
  GenetReceiveBufferBlock = $0300;
  GenetTransmitBufferBlock = $0600;
  GenetMacBlock = $0800;
  GenetReceiveDmaBlock = $2000;
  GenetTransmitDmaBlock = $4000;
  GenetRegisterSpan = $10000;

  { --- SYS --- }
  SystemRevisionControl = GenetSystemBlock + $00;
  SystemPortControl = GenetSystemBlock + $04;
  SystemReceiveBufferFlushControl = GenetSystemBlock + $08;
  SystemTransmitBufferFlushControl = GenetSystemBlock + $0C;

  { The major revision field (bits 27-24) reads 6 on a GENET v5 (5 on
    v4, 0 on v1); the minor is bits 19-16. }
  RevisionMajorShift = 24;
  RevisionMajorMask = $0F;
  RevisionMinorShift = 16;
  RevisionMinorMask = $0F;
  RevisionMajorOfVersion5 = 6;

  { Port modes: an external gigabit PHY (RGMII). }
  PortModeExternalGigabitPhy = 3;

  { Receive buffer flush control: the flush bit. }
  ReceiveBufferFlush = LongWord(1) shl 1;

  { --- EXT --- }
  ExtensionPowerManagement = GenetExtensionBlock + $00;
  ExtensionRgmiiOutOfBandControl = GenetExtensionBlock + $0C;

  PowerDownBias = LongWord(1) shl 0;
  PowerDownDll = LongWord(1) shl 1;

  RgmiiLink = LongWord(1) shl 4;
  RgmiiOutOfBandDisable = LongWord(1) shl 5;
  RgmiiModeEnable = LongWord(1) shl 6;
  { Turns the MAC's own transmit clock delay off (for "rgmii", where
    the board or the PHY adds both delays). }
  RgmiiIdModeDisable = LongWord(1) shl 16;

  { --- INTRL2_0 and INTRL2_1: offsets inside each block --- }
  InterruptStatus = $00;
  InterruptSet = $04;
  InterruptClear = $08;
  InterruptMaskStatus = $0C;
  InterruptMaskSet = $10;
  InterruptMaskClear = $14;

  { INTRL2_0 sources. }
  InterruptLinkUp = LongWord(1) shl 4;
  InterruptLinkDown = LongWord(1) shl 5;
  InterruptReceiveBufferOverflow = LongWord(1) shl 9;
  { The default queue's DMA: "buffers done" past the ring's threshold. }
  InterruptReceiveDmaDone = LongWord(1) shl 13;
  InterruptTransmitDmaDone = LongWord(1) shl 16;
  InterruptMdioDone = LongWord(1) shl 23;
  InterruptMdioError = LongWord(1) shl 24;

  { --- RBUF --- }
  ReceiveBufferControl = GenetReceiveBufferBlock + $00;
  ReceiveBufferSizeControl = GenetReceiveBufferBlock + $B4;

  { A 64-byte receive status block before each frame (left off here). }
  ReceiveBuffer64ByteStatus = LongWord(1) shl 0;
  { Two bytes of padding before each frame, so the IP header that
    follows the 14-byte Ethernet header is 4-byte aligned. }
  ReceiveBufferAlign2Bytes = LongWord(1) shl 1;
  ReceiveBufferBadDiscard = LongWord(1) shl 2;

  { --- TBUF --- }
  TransmitBufferControl = GenetTransmitBufferBlock + $00;
  { A 64-byte transmit status block before each frame (left off here). }
  TransmitBuffer64ByteStatus = LongWord(1) shl 0;

  { --- UMAC --- }
  MacCommand = GenetMacBlock + $008;
  MacAddress0 = GenetMacBlock + $00C;
  MacAddress1 = GenetMacBlock + $010;
  MacMaximumFrameLength = GenetMacBlock + $014;
  MacTransmitFlush = GenetMacBlock + $334;
  MacCounterControl = GenetMacBlock + $580;
  MacMdioCommand = GenetMacBlock + $614;

  CommandTransmitEnable = LongWord(1) shl 0;
  CommandReceiveEnable = LongWord(1) shl 1;
  CommandSpeedShift = 2;
  CommandSpeedMask = LongWord(3);
  CommandSpeed10 = 0;
  CommandSpeed100 = 1;
  CommandSpeed1000 = 2;
  CommandPromiscuous = LongWord(1) shl 4;
  CommandPadEnable = LongWord(1) shl 5;
  CommandCrcForward = LongWord(1) shl 6;
  CommandReceivePauseIgnore = LongWord(1) shl 8;
  CommandHalfDuplex = LongWord(1) shl 10;
  CommandSoftwareReset = LongWord(1) shl 13;
  CommandTransmitPauseIgnore = LongWord(1) shl 28;

  CounterResetReceive = LongWord(1) shl 0;
  CounterResetRunt = LongWord(1) shl 1;
  CounterResetTransmit = LongWord(1) shl 2;

  { MDIO command: start (busy while set), read failed, operation, PHY
    address, register, data. }
  MdioStartBusy = LongWord(1) shl 29;
  MdioReadFailed = LongWord(1) shl 28;
  MdioOperationRead = LongWord(2) shl 26;
  MdioOperationWrite = LongWord(1) shl 26;
  MdioPhyShift = 21;
  MdioRegisterShift = 16;
  MdioDataMask = $FFFF;

  { --- RDMA and TDMA: offsets inside each block --- }
  DmaDescriptorCount = 256;
  DmaWordsPerDescriptor = 3;
  DmaDescriptorBytes = DmaWordsPerDescriptor * 4;
  { Inside a descriptor. }
  DescriptorLengthStatus = $00;
  DescriptorAddressLow = $04;
  DescriptorAddressHigh = $08;

  { The rings' registers follow the descriptors, 40h bytes a ring, rings
    0 to 16; the engine's own registers follow those. }
  DmaRingRegistersStart = DmaDescriptorCount * DmaDescriptorBytes;
  DmaRingRegisterBytes = $40;
  DmaRingCount = 17;
  DmaDefaultRing = 16;
  DmaEngineRegistersStart = DmaRingRegistersStart + DmaRingCount * DmaRingRegisterBytes;

  { Inside a ring's registers. The receive engine produces and the
    driver consumes; the transmit engine the other way round, so the
    two indexes swap places between RDMA and TDMA. }
  RingReceiveWritePointer = $00;
  RingTransmitReadPointer = $00;
  RingReceiveProducerIndex = $08;
  RingTransmitConsumerIndex = $08;
  RingReceiveConsumerIndex = $0C;
  RingTransmitProducerIndex = $0C;
  RingBufferSize = $10;
  RingStartAddress = $14;
  RingStartAddressHigh = $18;
  RingEndAddress = $1C;
  RingEndAddressHigh = $20;
  RingBuffersDoneThreshold = $24;
  RingReceiveFlowThresholds = $28;
  RingTransmitFlowPeriod = $28;
  RingReceiveReadPointer = $2C;
  RingTransmitWritePointer = $2C;

  { Ring buffer size: descriptors in the ring (upper half), bytes per
    buffer (lower half). }
  RingSizeShift = 16;
  { Producer and consumer indexes count in 16 bits; the receive producer
    register also counts discarded frames in its upper half. }
  RingIndexMask = $FFFF;
  { Flow control thresholds of a receive ring: XOFF (upper) and XON. }
  RingFlowOffShift = 16;
  RingFlowOff = 5;
  RingFlowOn = DmaDescriptorCount shr 4;

  { Inside the engine's registers. }
  DmaRingConfiguration = $00;
  DmaControl = $04;
  DmaStatus = $08;
  DmaBurstSize = $0C;

  DmaEnable = LongWord(1) shl 0;
  { Ring N's buffer enable in the control register is bit N + 1. }
  DmaRingBufferEnableShift = 1;
  DmaDisabled = LongWord(1) shl 0;
  { The longest bus burst, in 64-bit words (the BCM2711's limit). }
  DmaMaximumBurst = $08;

  { --- Descriptor length and status --- }
  DescriptorLengthShift = 16;
  DescriptorLengthMask = $0FFF;
  DescriptorOwn = $8000;
  DescriptorEndOfPacket = $4000;
  DescriptorStartOfPacket = $2000;
  DescriptorWrap = $1000;
  { Transmit: append the check sequence; the queue tag (all ones). }
  DescriptorTransmitAppendCrc = $0040;
  DescriptorTransmitQueueTagShift = 7;
  DescriptorTransmitQueueTagMask = $3F;
  DescriptorTransmitUnderrun = $0200;
  { Receive errors: overrun, bad check sequence, receive error, not a
    whole number of bytes, too long. }
  DescriptorReceiveOverrun = $0001;
  DescriptorReceiveCrcError = $0002;
  DescriptorReceiveError = $0004;
  DescriptorReceiveNonOctet = $0008;
  DescriptorReceiveTooLong = $0010;
  DescriptorReceiveErrors = DescriptorReceiveOverrun or DescriptorReceiveCrcError or DescriptorReceiveError or
    DescriptorReceiveNonOctet or DescriptorReceiveTooLong;

  { The frame and its padding as the MAC counts them (1500 bytes of
    payload, header, VLAN tag, check sequence, room to spare). }
  GenetMaximumFrameLength = 1536;
  { What each receive buffer holds. }
  GenetReceiveBufferBytes = 2048;
  ReceiveAlignmentPadBytes = 2;

{ Where descriptor Index of a DMA block starts, from the block. }
function DescriptorOffset(Index: LongWord): LongWord;
{ Where register Register of ring Ring starts, from the DMA block. }
function RingRegisterOffset(Ring: LongWord; Register: LongWord): LongWord;

implementation

function DescriptorOffset(Index: LongWord): LongWord;
begin
  Result := Index * DmaDescriptorBytes;
end;

function RingRegisterOffset(Ring: LongWord; Register: LongWord): LongWord;
begin
  Result := DmaRingRegistersStart + Ring * DmaRingRegisterBytes + Register;
end;

end.
