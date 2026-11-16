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
  The registers and descriptors of Intel's gigabit Ethernet controllers
  (the 8254x PCI family, the 8257x PCI Express family and the I217, I218
  and I219 built into the platform controller hub), and MMIO access to
  them. All of them keep this register model for one receive and one
  transmit queue with legacy descriptors.
}
unit Drivers.E1000.Registers;

{$mode objfpc}
{$pointermath on}

interface

const
  RegisterControl = $0000;
  RegisterStatus = $0008;
  RegisterEepromRead = $0014;
  RegisterExtendedControl = $0018;
  RegisterInterruptCause = $00C0;
  RegisterInterruptThrottle = $00C4;
  RegisterInterruptMaskSet = $00D0;
  RegisterInterruptMaskClear = $00D8;
  RegisterReceiveControl = $0100;
  RegisterTransmitControl = $0400;
  RegisterTransmitGap = $0410;
  { Software/firmware semaphore of the platform controller hub parts. }
  RegisterExtendedConfigurationControl = $0F00;
  RegisterReceiveDescriptorBaseLow = $2800;
  RegisterReceiveDescriptorBaseHigh = $2804;
  RegisterReceiveDescriptorLength = $2808;
  RegisterReceiveDescriptorHead = $2810;
  RegisterReceiveDescriptorTail = $2818;
  RegisterReceiveDelay = $2820;
  RegisterTransmitDescriptorBaseLow = $3800;
  RegisterTransmitDescriptorBaseHigh = $3804;
  RegisterTransmitDescriptorLength = $3808;
  RegisterTransmitDescriptorHead = $3810;
  RegisterTransmitDescriptorTail = $3818;
  RegisterTransmitDescriptorControl = $3828;
  RegisterTransmitArbitration0 = $3840;
  RegisterMulticastTable = $5200;
  MulticastTableEntries = 128;
  RegisterReceiveFilterControl = $5008;
  RegisterReceiveAddressLow0 = $5400;
  RegisterReceiveAddressHigh0 = $5404;

  { Statistics: each read returns what was counted since the last read. }
  StatisticCrcErrors = $4000;
  StatisticAlignmentErrors = $4004;
  StatisticReceiveErrors = $400C;
  StatisticMissedPackets = $4010;
  StatisticExcessiveCollisions = $4018;
  StatisticLateCollisions = $4020;
  StatisticCollisions = $4028;
  StatisticReceiveLengthErrors = $4040;
  StatisticReceiveNoBuffers = $40A0;

  ControlFullDuplex = LongWord(1) shl 0;
  ControlLinkReset = LongWord(1) shl 3;
  ControlAutoSpeedDetection = LongWord(1) shl 5;
  ControlSetLinkUp = LongWord(1) shl 6;
  ControlInvertLossOfSignal = LongWord(1) shl 7;
  ControlForceSpeed = LongWord(1) shl 11;
  ControlForceDuplex = LongWord(1) shl 12;
  ControlReset = LongWord(1) shl 26;
  ControlVlanMode = LongWord(1) shl 30;
  ControlPhyReset = LongWord(1) shl 31;

  StatusFullDuplex = LongWord(1) shl 0;
  StatusLinkUp = LongWord(1) shl 1;
  StatusSpeedShift = 6;
  StatusSpeedMask = LongWord(3) shl StatusSpeedShift;
  { Platform controller hub parts: set when the hardware finished
    loading its configuration after a reset. }
  StatusLanInitDone = LongWord(1) shl 9;

  { The EEPROM read register comes in two layouts: the first 8254x parts
    (82540, 82545, 82546) and the later ones (82541, 82547, 8257x). }
  EepromReadStart = LongWord(1) shl 0;
  EepromReadDoneOld = LongWord(1) shl 4;
  EepromReadAddressShiftOld = 8;
  EepromReadDoneNew = LongWord(1) shl 1;
  EepromReadAddressShiftNew = 2;
  EepromReadDataShift = 16;

  ExtendedConfigurationSoftwareFlag = LongWord(1) shl 5;

  InterruptTransmitWrittenBack = LongWord(1) shl 0;
  InterruptTransmitQueueEmpty = LongWord(1) shl 1;
  InterruptLinkStatusChange = LongWord(1) shl 2;
  InterruptReceiveSequenceError = LongWord(1) shl 3;
  InterruptReceiveMinimumThreshold = LongWord(1) shl 4;
  InterruptReceiveOverrun = LongWord(1) shl 6;
  InterruptReceiveTimer = LongWord(1) shl 7;
  InterruptsUsed = InterruptTransmitWrittenBack or InterruptLinkStatusChange or
    InterruptReceiveSequenceError or InterruptReceiveMinimumThreshold or InterruptReceiveOverrun or
    InterruptReceiveTimer;
  InterruptsAll = $FFFFFFFF;

  ReceiveEnable = LongWord(1) shl 1;
  ReceiveStoreBadPackets = LongWord(1) shl 2;
  ReceiveUnicastPromiscuous = LongWord(1) shl 3;
  ReceiveMulticastPromiscuous = LongWord(1) shl 4;
  ReceiveLongPackets = LongWord(1) shl 5;
  { Descriptor minimum threshold: an interrupt when half the ring is
    left. }
  ReceiveThresholdHalf = LongWord(0) shl 8;
  ReceiveBroadcastAccept = LongWord(1) shl 15;
  { Buffer size field: 0 is 2048 bytes. }
  ReceiveBufferSize2048 = LongWord(0) shl 16;
  ReceiveStripCrc = LongWord(1) shl 26;

  TransmitEnable = LongWord(1) shl 1;
  TransmitPadShortPackets = LongWord(1) shl 3;
  TransmitCollisionThresholdShift = 4;
  TransmitCollisionThreshold = $0F;
  TransmitCollisionDistanceShift = 12;
  TransmitCollisionDistance = $3F;
  TransmitRetransmitLateCollision = LongWord(1) shl 24;
  { Inter-packet gap for copper: IPGT 8, IPGR1 8, IPGR2 6. }
  TransmitGapCopper = $00602008;

  { Transmit descriptor control: write-back granularity in descriptors,
    and bit 22, which the 8257x and hub parts' manuals say must be set. }
  TransmitDescriptorGranularity = LongWord(1) shl 24;
  TransmitDescriptorRequiredBit = LongWord(1) shl 22;

  ReceiveFilterNfsWriteDisable = LongWord(1) shl 6;
  ReceiveFilterNfsReadDisable = LongWord(1) shl 7;

  ReceiveAddressValid = LongWord(1) shl 31;

  { Receive descriptor status and errors. }
  ReceiveStatusDone = $01;
  ReceiveStatusEndOfPacket = $02;
  ReceiveErrorsFrame = $97;  { CRC, symbol, sequence, carrier extension, data }

  TransmitCommandEndOfPacket = $01;
  TransmitCommandInsertCrc = $02;
  TransmitCommandReportStatus = $08;
  TransmitStatusDone = $01;
  TransmitStatusExcessCollisions = $02;
  TransmitStatusLateCollision = $04;

type
  { Legacy receive descriptor (16 bytes). }
  PReceiveDescriptor = ^TReceiveDescriptor;
  TReceiveDescriptor = packed record
    BufferAddress: QWord;
    Length: Word;
    Checksum: Word;
    Status: Byte;
    Errors: Byte;
    Special: Word;
  end;

  { Legacy transmit descriptor (16 bytes). }
  PTransmitDescriptor = ^TTransmitDescriptor;
  TTransmitDescriptor = packed record
    BufferAddress: QWord;
    Length: Word;
    ChecksumOffset: Byte;
    Command: Byte;
    Status: Byte;
    ChecksumStart: Byte;
    Special: Word;
  end;

function ReadRegister(Registers: PByte; Offset: LongWord): LongWord;
procedure WriteRegister(Registers: PByte; Offset: LongWord; Value: LongWord);
{ Makes sure posted writes reached the card (reads the status register). }
procedure FlushRegisterWrites(Registers: PByte);

implementation

uses
  Runtime.Atomic;

function ReadRegister(Registers: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteRegister(Registers: PByte; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Registers + Offset)^ := Value;
end;

procedure FlushRegisterWrites(Registers: PByte);
begin
  ReadRegister(Registers, RegisterStatus);
end;

end.
