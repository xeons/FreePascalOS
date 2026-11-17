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
  The PHY behind a GENET controller, reached over the MDIO bus in the
  controller's MAC block (Drivers.Genet.Registers): on the Raspberry Pi
  4 a Broadcom BCM54213PE at address 1, wired by RGMII.

  MDIO: a command (operation, PHY address, register, data for a write)
  is written, then the start bit set; the controller clears it when the
  transfer is done, and a read leaves the data in the low 16 bits (with
  a "read failed" bit if no PHY answered).

  The PHY is set up as IEEE 802.3 clause 22 has it: reset, advertise
  10, 100 and 1000 Mbit/s at either duplex (registers 4 and 9), and
  restart autonegotiation. The link comes from the status register
  (latching: read twice), the speed and duplex from what both sides
  advertise (registers 4 and 5, 9 and 10).

  RGMII clock delays: the Pi 4's firmware tables name the mode
  "rgmii-rxid": the PHY delays the receive clock, the MAC the transmit
  clock. Broadcom PHYs keep the receive skew in the "misc control"
  shadow of the auxiliary control register (18h, shadow 7, bit 8; write
  enable bit 15) and the transmit delay in the "clock alignment control"
  shadow of register 1Ch (shadow 3, bit 9: GTXCLK delay), as Linux's
  bcm-phy-lib and broadcom.c describe. Both are set here.
}
unit Drivers.Genet.Phy;

{$mode objfpc}

interface

uses
  Drivers.NetworkCards;

const
  { The BCM54213PE's identifier (registers 2 and 3, revision masked). }
  Bcm54213PhyId = LongWord($600D84A0);
  PhyIdRevisionMask = LongWord($FFFFFFF0);
  DefaultPhyAddress = 1;

function MdioRead(Registers: PByte; PhyAddress, RegisterNumber: LongWord; out Value: Word): Boolean;
function MdioWrite(Registers: PByte; PhyAddress, RegisterNumber: LongWord; Value: Word): Boolean;

{ The PHY's 32-bit identifier, False if nothing answers at PhyAddress. }
function ReadPhyId(Registers: PByte; PhyAddress: LongWord; out Id: LongWord): Boolean;
{ The PHY at Preferred if one answers there, else the first that does;
  False if none. }
function FindPhy(Registers: PByte; Preferred: LongWord; out PhyAddress: LongWord; out Id: LongWord): Boolean;

{ Resets the PHY, sets its RGMII delays for "rgmii-rxid" (Broadcom PHYs
  only), advertises every speed and starts autonegotiation. Passive
  level (it sleeps). }
function StartPhy(Registers: PByte; PhyAddress: LongWord; Id: LongWord): Boolean;

{ The link as autonegotiation settled it (callable at dispatch level). }
procedure ReadPhyLink(Registers: PByte; PhyAddress: LongWord; out Link: TNetworkLinkState);

implementation

uses
  Runtime.Atomic,
  Kernel.Clock,
  Kernel.Arch.Cpu,
  Kernel.Scheduler,
  Drivers.Genet.Registers;

const
  MdioTimeoutNanoseconds = 2000000;
  PhyResetTimeoutMilliseconds = 500;

  { Clause 22 registers. }
  PhyControl = 0;
  PhyStatus = 1;
  PhyId1 = 2;
  PhyId2 = 3;
  PhyAdvertise = 4;
  PhyLinkPartner = 5;
  PhyGigabitControl = 9;
  PhyGigabitStatus = 10;

  ControlReset = $8000;
  ControlAutonegotiationEnable = $1000;
  ControlAutonegotiationRestart = $0200;

  StatusLinkUp = $0004;

  AdvertiseSelectorIeee8023 = $0001;
  Advertise10Half = $0020;
  Advertise10Full = $0040;
  Advertise100Half = $0080;
  Advertise100Full = $0100;
  AdvertiseAll = AdvertiseSelectorIeee8023 or Advertise10Half or Advertise10Full or Advertise100Half or
    Advertise100Full;

  Gigabit1000Half = $0100;
  Gigabit1000Full = $0200;
  { The partner's abilities in register 10 sit two bits above ours in
    register 9. }
  PartnerGigabitShift = 2;

  { Broadcom: the auxiliary control register and its misc shadow. }
  BroadcomAuxiliaryControl = $18;
  AuxiliaryShadowMisc = $07;
  AuxiliaryReadSelectShift = 12;
  AuxiliaryMiscWriteEnable = $8000;
  AuxiliaryMiscRgmiiSkewEnable = $0100;

  { Broadcom: the shadow register 1Ch and its clock alignment shadow. }
  BroadcomShadow = $1C;
  ShadowSelectShift = 10;
  ShadowWriteEnable = $8000;
  ShadowDataMask = $03FF;
  ShadowClockAlignment = $03;
  ClockAlignmentTransmitDelay = $0200;

  BroadcomVendorMask = LongWord($FFFFFC00);
  BroadcomVendorId = LongWord($600D8400);

function ReadMdioRegister(Registers: PByte): LongWord;
begin
  Result := PLongWord(Registers + MacMdioCommand)^;
  FullMemoryBarrier;
end;

procedure WriteMdioRegister(Registers: PByte; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Registers + MacMdioCommand)^ := Value;
end;

{ Starts the command written last and waits for it; the final register
  value, or False on time out. }
function RunMdioCommand(Registers: PByte; Command: LongWord; out Final: LongWord): Boolean;
var
  Deadline: QWord;
begin
  WriteMdioRegister(Registers, Command);
  WriteMdioRegister(Registers, Command or MdioStartBusy);
  Deadline := ClockNanoseconds + MdioTimeoutNanoseconds;
  repeat
    Final := ReadMdioRegister(Registers);
    if (Final and MdioStartBusy) = 0 then
      Exit(True);
    CpuRelax;
  until ClockNanoseconds > Deadline;
  Result := False;
end;

function MdioRead(Registers: PByte; PhyAddress, RegisterNumber: LongWord; out Value: Word): Boolean;
var
  Final: LongWord;
begin
  Value := $FFFF;
  Result := RunMdioCommand(Registers, MdioOperationRead or ((PhyAddress and $1F) shl MdioPhyShift) or
    ((RegisterNumber and $1F) shl MdioRegisterShift), Final) and ((Final and MdioReadFailed) = 0);
  if Result then
    Value := Word(Final and MdioDataMask);
end;

function MdioWrite(Registers: PByte; PhyAddress, RegisterNumber: LongWord; Value: Word): Boolean;
var
  Final: LongWord;
begin
  Result := RunMdioCommand(Registers, MdioOperationWrite or ((PhyAddress and $1F) shl MdioPhyShift) or
    ((RegisterNumber and $1F) shl MdioRegisterShift) or Value, Final);
end;

function ReadPhyId(Registers: PByte; PhyAddress: LongWord; out Id: LongWord): Boolean;
var
  High: Word;
  Low: Word;
begin
  Id := 0;
  Result := MdioRead(Registers, PhyAddress, PhyId1, High) and MdioRead(Registers, PhyAddress, PhyId2, Low);
  if not Result then
    Exit;
  Id := (LongWord(High) shl 16) or Low;
  Result := (Id <> 0) and (Id <> $FFFFFFFF);
end;

function FindPhy(Registers: PByte; Preferred: LongWord; out PhyAddress: LongWord; out Id: LongWord): Boolean;
var
  Candidate: LongWord;
begin
  PhyAddress := Preferred;
  if ReadPhyId(Registers, Preferred, Id) then
    Exit(True);
  for Candidate := 0 to 31 do
    if ReadPhyId(Registers, Candidate, Id) then
    begin
      PhyAddress := Candidate;
      Exit(True);
    end;
  Result := False;
end;

{ Sets the RGMII delays for "rgmii-rxid": receive skew on in the PHY,
  its transmit clock delay off (the MAC delays the transmit clock). }
procedure SetBroadcomRgmiiDelays(Registers: PByte; PhyAddress: LongWord);
var
  Value: Word;
begin
  { Select the misc shadow for reading, then read it back. }
  if MdioWrite(Registers, PhyAddress, BroadcomAuxiliaryControl,
       AuxiliaryShadowMisc or (AuxiliaryShadowMisc shl AuxiliaryReadSelectShift)) and
     MdioRead(Registers, PhyAddress, BroadcomAuxiliaryControl, Value) then
  begin
    Value := (Value or AuxiliaryMiscWriteEnable or AuxiliaryMiscRgmiiSkewEnable) and not Word($0007);
    MdioWrite(Registers, PhyAddress, BroadcomAuxiliaryControl, Value or AuxiliaryShadowMisc);
  end;
  if MdioWrite(Registers, PhyAddress, BroadcomShadow, ShadowClockAlignment shl ShadowSelectShift) and
     MdioRead(Registers, PhyAddress, BroadcomShadow, Value) then
  begin
    Value := (Value and ShadowDataMask) and not Word(ClockAlignmentTransmitDelay);
    MdioWrite(Registers, PhyAddress, BroadcomShadow,
      ShadowWriteEnable or (ShadowClockAlignment shl ShadowSelectShift) or Value);
  end;
end;

function StartPhy(Registers: PByte; PhyAddress: LongWord; Id: LongWord): Boolean;
var
  Control: Word;
  Waited: QWord;
begin
  Result := False;
  if not MdioWrite(Registers, PhyAddress, PhyControl, ControlReset) then
    Exit;
  Waited := 0;
  repeat
    SleepMilliseconds(10);
    Inc(Waited, 10);
    if not MdioRead(Registers, PhyAddress, PhyControl, Control) then
      Exit;
  until ((Control and ControlReset) = 0) or (Waited >= PhyResetTimeoutMilliseconds);
  if (Control and ControlReset) <> 0 then
    Exit;
  if (Id and BroadcomVendorMask) = BroadcomVendorId then
    SetBroadcomRgmiiDelays(Registers, PhyAddress);
  Result := MdioWrite(Registers, PhyAddress, PhyAdvertise, AdvertiseAll) and
    MdioWrite(Registers, PhyAddress, PhyGigabitControl, Gigabit1000Half or Gigabit1000Full) and
    MdioWrite(Registers, PhyAddress, PhyControl, ControlAutonegotiationEnable or ControlAutonegotiationRestart);
end;

procedure ReadPhyLink(Registers: PByte; PhyAddress: LongWord; out Link: TNetworkLinkState);
var
  Status: Word;
  Advertised: Word;
  Partner: Word;
  GigabitControl: Word;
  GigabitStatus: Word;
  Common: Word;
begin
  Link.IsUp := False;
  Link.SpeedMegabits := 0;
  Link.FullDuplex := False;
  { The link bit latches a loss until read: the second read is now. }
  MdioRead(Registers, PhyAddress, PhyStatus, Status);
  if not MdioRead(Registers, PhyAddress, PhyStatus, Status) or ((Status and StatusLinkUp) = 0) then
    Exit;
  Link.IsUp := True;
  if MdioRead(Registers, PhyAddress, PhyGigabitControl, GigabitControl) and
     MdioRead(Registers, PhyAddress, PhyGigabitStatus, GigabitStatus) then
  begin
    Common := GigabitControl and (GigabitStatus shr PartnerGigabitShift);
    if (Common and Gigabit1000Full) <> 0 then
    begin
      Link.SpeedMegabits := 1000;
      Link.FullDuplex := True;
      Exit;
    end;
    if (Common and Gigabit1000Half) <> 0 then
    begin
      Link.SpeedMegabits := 1000;
      Exit;
    end;
  end;
  if not MdioRead(Registers, PhyAddress, PhyAdvertise, Advertised) or
     not MdioRead(Registers, PhyAddress, PhyLinkPartner, Partner) then
    Exit;
  Common := Advertised and Partner;
  if (Common and Advertise100Full) <> 0 then
  begin
    Link.SpeedMegabits := 100;
    Link.FullDuplex := True;
  end
  else if (Common and Advertise100Half) <> 0 then
    Link.SpeedMegabits := 100
  else if (Common and Advertise10Full) <> 0 then
  begin
    Link.SpeedMegabits := 10;
    Link.FullDuplex := True;
  end
  else
    Link.SpeedMegabits := 10;
end;

end.
