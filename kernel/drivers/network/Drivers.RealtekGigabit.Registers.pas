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
  The registers the Realtek gigabit and multi-gigabit controllers
  (RTL8168/8111 and RTL8125/8126, the r8169 family) share, their
  descriptor format, and MMIO access to them. Where the generations
  differ (the interrupt registers, the transmit poll register, the
  set-up), the chip units have their own constants.
}
unit Drivers.RealtekGigabit.Registers;

{$mode objfpc}
{$pointermath on}

interface

const
  RealtekVendorId = $10EC;

  RegisterStationAddress0 = $00;
  RegisterStationAddress4 = $04;
  RegisterMulticast0 = $08;
  RegisterMulticast4 = $0C;
  { Where the tally counters are written to (64-bit, 64-byte aligned). }
  RegisterCounterDumpLow = $10;
  RegisterCounterDumpHigh = $14;
  RegisterTransmitDescriptorsLow = $20;
  RegisterTransmitDescriptorsHigh = $24;
  RegisterCommand = $37;
  RegisterTransmitConfiguration = $40;
  RegisterReceiveConfiguration = $44;
  RegisterConfigurationLock = $50;
  RegisterConfiguration1 = $52;
  RegisterConfiguration2 = $53;
  RegisterConfiguration3 = $54;
  RegisterConfiguration5 = $56;
  RegisterPhyStatus = $6C;
  RegisterPowerManagement = $6F;
  RegisterReceiveMaximumSize = $DA;
  RegisterReceiveDescriptorsLow = $E4;
  RegisterReceiveDescriptorsHigh = $E8;

  CommandTransmitEnable = $04;
  CommandReceiveEnable = $08;
  CommandReset = $10;

  ConfigurationUnlock = $C0;
  ConfigurationLocked = $00;

  CounterDumpStart = $08;

  { The chip's version: bits 20-31 of the transmit configuration, as
    (value shr 20) and XidMask. }
  XidShift = 20;
  XidMask = $FCF;

  ReceiveAcceptPhysicalMatch = $00000002;
  ReceiveAcceptMulticast = $00000004;
  ReceiveAcceptBroadcast = $00000008;
  ReceiveAccepted = ReceiveAcceptPhysicalMatch or ReceiveAcceptMulticast or ReceiveAcceptBroadcast;
  ReceiveDmaUnlimited = $00000700;

  TransmitDmaUnlimited = $00000700;
  TransmitStandardGap = $03000000;

  PhyStatusFullDuplex = $0001;
  PhyStatusLinkUp = $0002;
  PhyStatus10 = $0004;
  PhyStatus100 = $0008;
  PhyStatus1000Full = $0010;

  { Descriptor first word. }
  DescriptorOwnedByCard = LongWord($80000000);
  DescriptorEndOfRing = LongWord($40000000);
  DescriptorFirstSegment = LongWord($20000000);
  DescriptorLastSegment = LongWord($10000000);
  ReceiveDescriptorErrorSummary = LongWord($00200000);
  DescriptorLengthMask = LongWord($00003FFF);

  { Interrupt causes, in the low bits of the status and mask registers of
    both generations. }
  InterruptReceiveOk = $0001;
  InterruptReceiveError = $0002;
  InterruptTransmitOk = $0004;
  InterruptTransmitError = $0008;
  InterruptReceiveDescriptorsUsedUp = $0010;
  InterruptLinkChange = $0020;
  InterruptReceiveFifoOverflow = $0040;
  InterruptsUsed = InterruptReceiveOk or InterruptReceiveError or InterruptTransmitOk or
    InterruptTransmitError or InterruptReceiveDescriptorsUsedUp or InterruptLinkChange or
    InterruptReceiveFifoOverflow;

type
  { Receive and transmit descriptors have one layout (16 bytes). }
  PRealtekDescriptor = ^TRealtekDescriptor;
  TRealtekDescriptor = packed record
    Options1: LongWord;
    Options2: LongWord;
    AddressLow: LongWord;
    AddressHigh: LongWord;
  end;

  { The tally counters the chip dumps (the first 64 bytes, common to
    every generation). }
  PRealtekTallyCounters = ^TRealtekTallyCounters;
  TRealtekTallyCounters = packed record
    TransmitPackets: QWord;
    ReceivePackets: QWord;
    TransmitErrors: QWord;
    ReceiveErrors: LongWord;
    ReceiveMissed: Word;
    AlignmentErrors: Word;
    TransmitOneCollision: LongWord;
    TransmitMultipleCollisions: LongWord;
    ReceiveUnicast: QWord;
    ReceiveBroadcast: QWord;
    ReceiveMulticast: LongWord;
    TransmitAborted: Word;
    TransmitUnderrun: Word;
  end;

function Read8(Registers: PByte; Offset: LongWord): Byte;
function Read16(Registers: PByte; Offset: LongWord): Word;
function Read32(Registers: PByte; Offset: LongWord): LongWord;
procedure Write8(Registers: PByte; Offset: LongWord; Value: Byte);
procedure Write16(Registers: PByte; Offset: LongWord; Value: Word);
procedure Write32(Registers: PByte; Offset: LongWord; Value: LongWord);

implementation

uses
  Runtime.Atomic;

function Read8(Registers: PByte; Offset: LongWord): Byte;
begin
  Result := PByte(Registers + Offset)^;
  FullMemoryBarrier;
end;

function Read16(Registers: PByte; Offset: LongWord): Word;
begin
  Result := PWord(Registers + Offset)^;
  FullMemoryBarrier;
end;

function Read32(Registers: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure Write8(Registers: PByte; Offset: LongWord; Value: Byte);
begin
  FullMemoryBarrier;
  PByte(Registers + Offset)^ := Value;
end;

procedure Write16(Registers: PByte; Offset: LongWord; Value: Word);
begin
  FullMemoryBarrier;
  PWord(Registers + Offset)^ := Value;
end;

procedure Write32(Registers: PByte; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Registers + Offset)^ := Value;
end;

end.
