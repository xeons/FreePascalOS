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
  Setting an Intel gigabit controller up: the reset, the station
  address, the link, the receive and transmit units, and reading its
  link and statistics.

  The reset (CTRL.RST) returns the MAC to its power-on state and makes
  the hardware load its EEPROM or NVM again, the station address with
  it, into receive address register 0. Copper parts negotiate the link
  by themselves once told "set link up" with automatic speed detection.
  Every wait has a bound.
}
unit Drivers.E1000.Hardware;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.NetworkAdapters,
  Drivers.E1000.Models,
  Drivers.NetworkCards;

{ Quiets and resets the controller. False if the reset did not finish. }
function ResetE1000(Registers: PByte; Family: TE1000Family): Boolean;
{ The station address: receive address register 0 if valid, else the
  EEPROM (FunctionNumber picks the port of a dual-port 82546). }
function ReadE1000Address(Registers: PByte; Family: TE1000Family; FunctionNumber: Byte;
  out Address: TEthernetAddress): Boolean;
{ Receive address 0 is Address; the multicast table is cleared. }
procedure WriteE1000Address(Registers: PByte; const Address: TEthernetAddress);
procedure ConfigureE1000Link(Registers: PByte);
procedure ConfigureE1000Transmit(Registers: PByte; Family: TE1000Family);
{ Receives frames for the station address, broadcasts and every
  multicast (the network layer filters those; adapters keep no list). }
procedure EnableE1000Receive(Registers: PByte);
procedure DisableE1000ReceiveAndTransmit(Registers: PByte);
procedure ReadE1000Link(Registers: PByte; out Link: TNetworkLinkState);
{ The counters read since last time, added to the receive or transmit
  ones (each read clears them in the card). }
procedure ReadE1000ReceiveCounters(Registers: PByte; var Statistics: TNetworkCardStatistics);
procedure ReadE1000TransmitCounters(Registers: PByte; var Statistics: TNetworkCardStatistics);

implementation

uses
  Kernel.Clock,
  Kernel.Scheduler,
  Kernel.Arch.Cpu,
  Drivers.E1000.Registers,
  Debug.Output;

const
  ResetTimeoutMilliseconds = 100;
  LanInitTimeoutMilliseconds = 150;
  SoftwareFlagTimeoutMilliseconds = 1000;
  EepromReadTimeoutMilliseconds = 10;
  { 8000 interrupts a second at most, in units of 256 ns. }
  InterruptThrottleValue = 488;
  BitsTransmitArbitrationHub = (LongWord(1) shl 23) or (LongWord(1) shl 24) or (LongWord(1) shl 26) or
    (LongWord(1) shl 27);

{ Waits until (register and Mask) = Expected or Milliseconds passed. }
function WaitForRegister(Registers: PByte; Offset, Mask, Expected: LongWord; Milliseconds: QWord): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(Milliseconds) + 1;
  repeat
    if (ReadRegister(Registers, Offset) and Mask) = Expected then
      Exit(True);
    CpuRelax;
  until ClockTickCount > Deadline;
  Result := (ReadRegister(Registers, Offset) and Mask) = Expected;
end;

procedure Report(Text: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('e1000');
  DebugWriteLine(Text);
  DebugEndMessage;
end;

{ The hub parts' software flag, which keeps the firmware (the management
  engine) away from the MAC and PHY while it is held; the reset clears
  it. }
procedure AcquireSoftwareFlag(Registers: PByte);
var
  Control: LongWord;
begin
  if not WaitForRegister(Registers, RegisterExtendedConfigurationControl, ExtendedConfigurationSoftwareFlag, 0,
    SoftwareFlagTimeoutMilliseconds) then
    Report('the firmware holds the software flag; resetting anyway');
  Control := ReadRegister(Registers, RegisterExtendedConfigurationControl);
  WriteRegister(Registers, RegisterExtendedConfigurationControl, Control or ExtendedConfigurationSoftwareFlag);
  if not WaitForRegister(Registers, RegisterExtendedConfigurationControl, ExtendedConfigurationSoftwareFlag,
    ExtendedConfigurationSoftwareFlag, SoftwareFlagTimeoutMilliseconds) then
    Report('the software flag could not be taken; resetting anyway');
end;

function ResetE1000(Registers: PByte; Family: TE1000Family): Boolean;
var
  Status: LongWord;
begin
  WriteRegister(Registers, RegisterInterruptMaskClear, InterruptsAll);
  WriteRegister(Registers, RegisterReceiveControl, 0);
  WriteRegister(Registers, RegisterTransmitControl, TransmitPadShortPackets);
  FlushRegisterWrites(Registers);
  { Lets DMA in progress finish. }
  SleepMilliseconds(10);

  if Family = FamilyHub then
    AcquireSoftwareFlag(Registers);
  WriteRegister(Registers, RegisterControl, ReadRegister(Registers, RegisterControl) or ControlReset);
  SleepMilliseconds(10);
  Result := WaitForRegister(Registers, RegisterControl, ControlReset, 0, ResetTimeoutMilliseconds);
  if Family = FamilyHub then
  begin
    if not WaitForRegister(Registers, RegisterStatus, StatusLanInitDone, StatusLanInitDone,
      LanInitTimeoutMilliseconds) then
      Report('the hardware did not say its configuration was loaded');
    Status := ReadRegister(Registers, RegisterStatus);
    WriteRegister(Registers, RegisterStatus, Status and not StatusLanInitDone);
  end
  else
    { The EEPROM is read again after the reset. }
    SleepMilliseconds(10);
  WriteRegister(Registers, RegisterInterruptMaskClear, InterruptsAll);
  ReadRegister(Registers, RegisterInterruptCause);
end;

function ReadEepromWord(Registers: PByte; Family: TE1000Family; WordAddress: LongWord; out Value: Word): Boolean;
var
  DoneBit: LongWord;
  AddressShift: LongWord;
begin
  if Family = FamilyClassic then
  begin
    DoneBit := EepromReadDoneOld;
    AddressShift := EepromReadAddressShiftOld;
  end
  else
  begin
    DoneBit := EepromReadDoneNew;
    AddressShift := EepromReadAddressShiftNew;
  end;
  WriteRegister(Registers, RegisterEepromRead, (WordAddress shl AddressShift) or EepromReadStart);
  Result := WaitForRegister(Registers, RegisterEepromRead, DoneBit, DoneBit, EepromReadTimeoutMilliseconds);
  Value := Word(ReadRegister(Registers, RegisterEepromRead) shr EepromReadDataShift);
end;

function ReadE1000Address(Registers: PByte; Family: TE1000Family; FunctionNumber: Byte;
  out Address: TEthernetAddress): Boolean;
var
  Low: LongWord;
  High: LongWord;
  Index: Integer;
  Value: Word;
begin
  Low := ReadRegister(Registers, RegisterReceiveAddressLow0);
  High := ReadRegister(Registers, RegisterReceiveAddressHigh0);
  for Index := 0 to 3 do
    Address[Index] := Byte(Low shr (Index * 8));
  Address[4] := Byte(High);
  Address[5] := Byte(High shr 8);
  if ((High and ReceiveAddressValid) <> 0) and EthernetAddressIsUsable(Address) then
    Exit(True);

  { The hub parts keep the address in the platform's flash, which only
    the hardware's own load reads here. }
  if Family = FamilyHub then
    Exit(False);
  for Index := 0 to 2 do
  begin
    if not ReadEepromWord(Registers, Family, LongWord(Index), Value) then
      Exit(False);
    Address[Index * 2] := Byte(Value);
    Address[Index * 2 + 1] := Byte(Value shr 8);
  end;
  { The second port of a dual-port part answers to the next address. }
  if (Family = FamilyClassic) and (FunctionNumber = 1) then
    Address[5] := Address[5] xor 1;
  Result := EthernetAddressIsUsable(Address);
end;

procedure WriteE1000Address(Registers: PByte; const Address: TEthernetAddress);
var
  Index: Integer;
begin
  WriteRegister(Registers, RegisterReceiveAddressLow0,
    LongWord(Address[0]) or (LongWord(Address[1]) shl 8) or (LongWord(Address[2]) shl 16) or
    (LongWord(Address[3]) shl 24));
  WriteRegister(Registers, RegisterReceiveAddressHigh0,
    LongWord(Address[4]) or (LongWord(Address[5]) shl 8) or ReceiveAddressValid);
  for Index := 0 to MulticastTableEntries - 1 do
    WriteRegister(Registers, RegisterMulticastTable + LongWord(Index) * 4, 0);
end;

procedure ConfigureE1000Link(Registers: PByte);
var
  Control: LongWord;
begin
  Control := ReadRegister(Registers, RegisterControl);
  Control := Control or ControlSetLinkUp or ControlAutoSpeedDetection;
  Control := Control and not (ControlLinkReset or ControlPhyReset or ControlInvertLossOfSignal or
    ControlForceSpeed or ControlForceDuplex or ControlVlanMode);
  WriteRegister(Registers, RegisterControl, Control);
  WriteRegister(Registers, RegisterInterruptThrottle, InterruptThrottleValue);
end;

procedure ConfigureE1000Transmit(Registers: PByte; Family: TE1000Family);
var
  Value: LongWord;
begin
  if Family in [FamilyExpress, FamilyHub] then
  begin
    Value := ReadRegister(Registers, RegisterTransmitDescriptorControl);
    WriteRegister(Registers, RegisterTransmitDescriptorControl,
      Value or TransmitDescriptorRequiredBit or TransmitDescriptorGranularity);
  end;
  if Family = FamilyHub then
  begin
    { As the hub parts' initialisation sets them. }
    Value := ReadRegister(Registers, RegisterTransmitArbitration0);
    WriteRegister(Registers, RegisterTransmitArbitration0, Value or BitsTransmitArbitrationHub);
    Value := ReadRegister(Registers, RegisterReceiveFilterControl);
    WriteRegister(Registers, RegisterReceiveFilterControl,
      Value or ReceiveFilterNfsWriteDisable or ReceiveFilterNfsReadDisable);
  end;
  WriteRegister(Registers, RegisterTransmitGap, TransmitGapCopper);
  WriteRegister(Registers, RegisterTransmitControl,
    TransmitEnable or TransmitPadShortPackets or
    (TransmitCollisionThreshold shl TransmitCollisionThresholdShift) or
    (TransmitCollisionDistance shl TransmitCollisionDistanceShift) or
    TransmitRetransmitLateCollision);
end;

procedure EnableE1000Receive(Registers: PByte);
begin
  WriteRegister(Registers, RegisterReceiveDelay, 0);
  WriteRegister(Registers, RegisterReceiveControl,
    ReceiveEnable or ReceiveBroadcastAccept or ReceiveMulticastPromiscuous or ReceiveStripCrc or
    ReceiveBufferSize2048 or ReceiveThresholdHalf);
end;

procedure DisableE1000ReceiveAndTransmit(Registers: PByte);
begin
  WriteRegister(Registers, RegisterInterruptMaskClear, InterruptsAll);
  WriteRegister(Registers, RegisterReceiveControl, 0);
  WriteRegister(Registers, RegisterTransmitControl, TransmitPadShortPackets);
  FlushRegisterWrites(Registers);
end;

procedure ReadE1000Link(Registers: PByte; out Link: TNetworkLinkState);
var
  Status: LongWord;
begin
  Status := ReadRegister(Registers, RegisterStatus);
  Link.IsUp := (Status and StatusLinkUp) <> 0;
  Link.FullDuplex := (Status and StatusFullDuplex) <> 0;
  case (Status and StatusSpeedMask) shr StatusSpeedShift of
    0: Link.SpeedMegabits := 10;
    1: Link.SpeedMegabits := 100;
  else
    Link.SpeedMegabits := 1000;
  end;
  if not Link.IsUp then
  begin
    Link.SpeedMegabits := 0;
    Link.FullDuplex := False;
  end;
end;

procedure ReadE1000ReceiveCounters(Registers: PByte; var Statistics: TNetworkCardStatistics);
begin
  Inc(Statistics.ReceiveErrors, ReadRegister(Registers, StatisticCrcErrors));
  Inc(Statistics.ReceiveErrors, ReadRegister(Registers, StatisticAlignmentErrors));
  Inc(Statistics.ReceiveErrors, ReadRegister(Registers, StatisticReceiveErrors));
  Inc(Statistics.ReceiveErrors, ReadRegister(Registers, StatisticReceiveLengthErrors));
  Inc(Statistics.ReceiveMissed, ReadRegister(Registers, StatisticMissedPackets));
  { Frames that waited for a buffer but were not lost: only cleared. }
  ReadRegister(Registers, StatisticReceiveNoBuffers);
end;

procedure ReadE1000TransmitCounters(Registers: PByte; var Statistics: TNetworkCardStatistics);
begin
  Inc(Statistics.Collisions, ReadRegister(Registers, StatisticCollisions));
  Inc(Statistics.TransmitErrors, ReadRegister(Registers, StatisticExcessiveCollisions));
  Inc(Statistics.TransmitErrors, ReadRegister(Registers, StatisticLateCollisions));
end;

end.
