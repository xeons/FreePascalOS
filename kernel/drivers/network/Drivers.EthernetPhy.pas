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
  Ethernet PHYs on an MDIO bus, for MAC drivers that have one (GENET on
  the Raspberry Pi 4, the Cadence GEM in the Pi 5's RP1): both boards
  have a Broadcom BCM54213PE at address 1, wired by RGMII.

  The MAC driver gives its bus as a TMdioBus (its read and write of a
  clause 22 register). The PHY is set up as IEEE 802.3 clause 22 has it:
  reset, advertise 10, 100 and 1000 Mbit/s at either duplex (registers 4
  and 9), restart autonegotiation. The link comes from the status
  register (latching: read twice), the speed and duplex from what both
  sides advertise (registers 4 and 5, 9 and 10).

  RGMII clock delays, by the device tree's (or ACPI's) "phy-mode":
  "rgmii-id" has the PHY delay both clocks, "rgmii-rxid" only the
  receive clock (the MAC delays transmit), "rgmii-txid" only transmit,
  "rgmii" neither. Broadcom PHYs keep the receive skew in the "misc
  control" shadow of the auxiliary control register (18h, shadow 7, bit
  8; write enable bit 15) and the transmit delay in the "clock alignment
  control" shadow of register 1Ch (shadow 3, bit 9: GTXCLK delay), as
  Linux's bcm-phy-lib and broadcom.c describe. Other PHYs keep theirs.
}
unit Drivers.EthernetPhy;

{$mode objfpc}

interface

uses
  Drivers.NetworkCards;

const
  { The BCM54213PE's identifier (registers 2 and 3, revision masked). }
  Bcm54213PhyId = LongWord($600D84A0);
  PhyIdRevisionMask = LongWord($FFFFFFF0);
  DefaultPhyAddress = 1;

type
  TMdioRead = function(Context: Pointer; PhyAddress, RegisterNumber: LongWord; out Value: Word): Boolean;
  TMdioWrite = function(Context: Pointer; PhyAddress, RegisterNumber: LongWord; Value: Word): Boolean;

  TMdioBus = record
    Read: TMdioRead;
    Write: TMdioWrite;
    Context: Pointer;
  end;

  TRgmiiDelays = (RgmiiNoDelays, RgmiiReceiveDelay, RgmiiTransmitDelay, RgmiiBothDelays);

function PhyRead(constref Bus: TMdioBus; PhyAddress, RegisterNumber: LongWord; out Value: Word): Boolean;
function PhyWrite(constref Bus: TMdioBus; PhyAddress, RegisterNumber: LongWord; Value: Word): Boolean;

{ The PHY's 32-bit identifier, False if nothing answers at PhyAddress. }
function ReadPhyId(constref Bus: TMdioBus; PhyAddress: LongWord; out Id: LongWord): Boolean;
{ The PHY at Preferred if one answers there, else the first that does;
  False if none. }
function FindPhy(constref Bus: TMdioBus; Preferred: LongWord; out PhyAddress: LongWord; out Id: LongWord): Boolean;

{ The delays a "phy-mode" string asks of the PHY (nil: none). }
function RgmiiDelaysOfPhyMode(Mode: PChar): TRgmiiDelays;
function RgmiiDelaysText(Delays: TRgmiiDelays): PChar;

{ Resets the PHY, sets its RGMII delays (Broadcom PHYs only),
  advertises every speed and starts autonegotiation. Passive level (it
  sleeps). Step: the step that failed, for the driver's line. }
function StartPhy(constref Bus: TMdioBus; PhyAddress: LongWord; Id: LongWord; Delays: TRgmiiDelays;
  out Step: PChar): Boolean;

{ The link as autonegotiation settled it (callable at dispatch level). }
procedure ReadPhyLink(constref Bus: TMdioBus; PhyAddress: LongWord; out Link: TNetworkLinkState);

{ Basic control and status, for the drivers' failure lines. }
function ReadPhyControlAndStatus(constref Bus: TMdioBus; PhyAddress: LongWord): LongWord;

implementation

uses
  Kernel.Scheduler,
  DeviceTree.Blob;

const
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

function PhyRead(constref Bus: TMdioBus; PhyAddress, RegisterNumber: LongWord; out Value: Word): Boolean;
begin
  Value := $FFFF;
  Result := Assigned(Bus.Read) and Bus.Read(Bus.Context, PhyAddress, RegisterNumber, Value);
end;

function PhyWrite(constref Bus: TMdioBus; PhyAddress, RegisterNumber: LongWord; Value: Word): Boolean;
begin
  Result := Assigned(Bus.Write) and Bus.Write(Bus.Context, PhyAddress, RegisterNumber, Value);
end;

function ReadPhyId(constref Bus: TMdioBus; PhyAddress: LongWord; out Id: LongWord): Boolean;
var
  High: Word;
  Low: Word;
begin
  Id := 0;
  Result := PhyRead(Bus, PhyAddress, PhyId1, High) and PhyRead(Bus, PhyAddress, PhyId2, Low);
  if not Result then
    Exit;
  Id := (LongWord(High) shl 16) or Low;
  Result := (Id <> 0) and (Id <> $FFFFFFFF);
end;

function FindPhy(constref Bus: TMdioBus; Preferred: LongWord; out PhyAddress: LongWord; out Id: LongWord): Boolean;
var
  Candidate: LongWord;
begin
  PhyAddress := Preferred;
  if ReadPhyId(Bus, Preferred, Id) then
    Exit(True);
  for Candidate := 0 to 31 do
    if ReadPhyId(Bus, Candidate, Id) then
    begin
      PhyAddress := Candidate;
      Exit(True);
    end;
  Result := False;
end;

function RgmiiDelaysOfPhyMode(Mode: PChar): TRgmiiDelays;
begin
  if Mode = nil then
    Result := RgmiiNoDelays
  else if DeviceTreeTextIsEqual(Mode, 'rgmii-id') then
    Result := RgmiiBothDelays
  else if DeviceTreeTextIsEqual(Mode, 'rgmii-rxid') then
    Result := RgmiiReceiveDelay
  else if DeviceTreeTextIsEqual(Mode, 'rgmii-txid') then
    Result := RgmiiTransmitDelay
  else
    Result := RgmiiNoDelays;
end;

function RgmiiDelaysText(Delays: TRgmiiDelays): PChar;
begin
  case Delays of
    RgmiiReceiveDelay: Result := 'rgmii-rxid';
    RgmiiTransmitDelay: Result := 'rgmii-txid';
    RgmiiBothDelays: Result := 'rgmii-id';
  else
    Result := 'rgmii';
  end;
end;

procedure SetBroadcomRgmiiDelays(constref Bus: TMdioBus; PhyAddress: LongWord; Delays: TRgmiiDelays);
var
  Value: Word;
begin
  { Select the misc shadow for reading, then read it back. }
  if PhyWrite(Bus, PhyAddress, BroadcomAuxiliaryControl,
       AuxiliaryShadowMisc or (AuxiliaryShadowMisc shl AuxiliaryReadSelectShift)) and
     PhyRead(Bus, PhyAddress, BroadcomAuxiliaryControl, Value) then
  begin
    Value := (Value or AuxiliaryMiscWriteEnable) and not Word($0007);
    if Delays in [RgmiiReceiveDelay, RgmiiBothDelays] then
      Value := Value or AuxiliaryMiscRgmiiSkewEnable
    else
      Value := Value and not Word(AuxiliaryMiscRgmiiSkewEnable);
    PhyWrite(Bus, PhyAddress, BroadcomAuxiliaryControl, Value or AuxiliaryShadowMisc);
  end;
  if PhyWrite(Bus, PhyAddress, BroadcomShadow, ShadowClockAlignment shl ShadowSelectShift) and
     PhyRead(Bus, PhyAddress, BroadcomShadow, Value) then
  begin
    Value := Value and ShadowDataMask;
    if Delays in [RgmiiTransmitDelay, RgmiiBothDelays] then
      Value := Value or ClockAlignmentTransmitDelay
    else
      Value := Value and not Word(ClockAlignmentTransmitDelay);
    PhyWrite(Bus, PhyAddress, BroadcomShadow, ShadowWriteEnable or (ShadowClockAlignment shl ShadowSelectShift) or Value);
  end;
end;

function StartPhy(constref Bus: TMdioBus; PhyAddress: LongWord; Id: LongWord; Delays: TRgmiiDelays;
  out Step: PChar): Boolean;
var
  Control: Word;
  Waited: QWord;
begin
  Result := False;
  Step := 'reset write';
  if not PhyWrite(Bus, PhyAddress, PhyControl, ControlReset) then
    Exit;
  Step := 'reset wait';
  Waited := 0;
  repeat
    SleepMilliseconds(10);
    Inc(Waited, 10);
    if not PhyRead(Bus, PhyAddress, PhyControl, Control) then
      Exit;
  until ((Control and ControlReset) = 0) or (Waited >= PhyResetTimeoutMilliseconds);
  if (Control and ControlReset) <> 0 then
    Exit;
  if (Id and BroadcomVendorMask) = BroadcomVendorId then
    SetBroadcomRgmiiDelays(Bus, PhyAddress, Delays);
  Step := 'autonegotiation start';
  Result := PhyWrite(Bus, PhyAddress, PhyAdvertise, AdvertiseAll) and
    PhyWrite(Bus, PhyAddress, PhyGigabitControl, Gigabit1000Half or Gigabit1000Full) and
    PhyWrite(Bus, PhyAddress, PhyControl, ControlAutonegotiationEnable or ControlAutonegotiationRestart);
  if Result then
    Step := nil;
end;

procedure ReadPhyLink(constref Bus: TMdioBus; PhyAddress: LongWord; out Link: TNetworkLinkState);
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
  PhyRead(Bus, PhyAddress, PhyStatus, Status);
  if not PhyRead(Bus, PhyAddress, PhyStatus, Status) or ((Status and StatusLinkUp) = 0) then
    Exit;
  Link.IsUp := True;
  if PhyRead(Bus, PhyAddress, PhyGigabitControl, GigabitControl) and
     PhyRead(Bus, PhyAddress, PhyGigabitStatus, GigabitStatus) then
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
  if not PhyRead(Bus, PhyAddress, PhyAdvertise, Advertised) or
     not PhyRead(Bus, PhyAddress, PhyLinkPartner, Partner) then
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

function ReadPhyControlAndStatus(constref Bus: TMdioBus; PhyAddress: LongWord): LongWord;
var
  Control: Word;
  Status: Word;
begin
  PhyRead(Bus, PhyAddress, PhyControl, Control);
  PhyRead(Bus, PhyAddress, PhyStatus, Status);
  Result := (LongWord(Control) shl 16) or Status;
end;

end.
