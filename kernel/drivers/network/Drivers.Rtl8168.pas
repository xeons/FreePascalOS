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
  Realtek RTL8168/8111 gigabit Ethernet (PCI Express), the chip on very
  many PC mainboards. QEMU has no model of it: this is written from the
  register layout the family documents and is untested.

  What sets this generation apart from the RTL8125 (Drivers.Rtl8125):
  16-bit interrupt mask and status registers at 3Ch and 3Eh, the
  transmit poll register at 38h (bit 6 polls the normal queue), and the
  link in the PHY status register. The set-up is the generic one the
  family shares: reset, unlock the configuration registers, the
  station address, the largest frame, the descriptor rings, then
  receive and transmit on with their configuration. The per-version
  PHY tuning and PHY firmware patches Linux applies to some RTL8168
  versions are not applied; the PHY negotiates with its defaults.
}
unit Drivers.Rtl8168;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every RTL8168/8111 card; returns how many. }
function InitializeRtl8168Adapters: Integer;

implementation

uses
  Io.Pci,
  Io.NetworkAdapters,
  Drivers.NetworkCards,
  Drivers.NetworkBuffers,
  Drivers.RealtekGigabit.Registers,
  Drivers.RealtekGigabit.Rings,
  Drivers.RealtekGigabit,
  Debug.Output;

const
  RegisterTransmitPoll = $38;
  RegisterInterruptMask = $3C;
  RegisterInterruptStatus = $3E;
  RegisterInterruptMitigation = $E2;
  RegisterMaximumTransmitPacket = $EC;
  RegisterStationAddressBackup = $19E0;
  TransmitPollNormalQueue = $40;
  { In units of 128 bytes. }
  MaximumTransmitPacketValue = $3F;
  ReceiveNoFifoThreshold = $0000E000;
  { The RTL8168B versions (XID 300h and 380h under this mask) are the
    ones Linux keeps to 32-bit DMA; the RTL8168C and later take 64-bit
    addresses. }
  Rtl8168bXidMask = $7C8;
  Rtl8168bFirstXid = $300;
  Rtl8168bSecondXid = $380;

procedure PollTransmit(Registers: PByte);
begin
  Write8(Registers, RegisterTransmitPoll, TransmitPollNormalQueue);
end;

function Uses32BitDma(Card: PRealtekCard): Boolean;
var
  Xid: LongWord;
begin
  Xid := (Read32(Card^.Registers, RegisterTransmitConfiguration) shr XidShift) and Rtl8168bXidMask;
  Result := (Xid = Rtl8168bFirstXid) or (Xid = Rtl8168bSecondXid);
end;

function BringUp(Card: PRealtekCard): Boolean;
begin
  Write16(Card^.Registers, RegisterInterruptMask, 0);
  Result := ResetRealtekChip(Card);
  if not Result then
    Exit;
  UnlockRealtekConfiguration(Card);
  WriteRealtekStationAddress(Card);
  Write16(Card^.Registers, RegisterReceiveMaximumSize, NetworkBufferBytes);
  Write8(Card^.Registers, RegisterMaximumTransmitPacket, MaximumTransmitPacketValue);
  Write16(Card^.Registers, RegisterInterruptMitigation, 0);
  ProgramRealtekRings(Card^.Rings);
  LockRealtekConfiguration(Card);
  Write8(Card^.Registers, RegisterCommand, CommandTransmitEnable or CommandReceiveEnable);
  Write32(Card^.Registers, RegisterTransmitConfiguration, TransmitStandardGap or TransmitDmaUnlimited);
  Write32(Card^.Registers, RegisterReceiveConfiguration,
    ReceiveNoFifoThreshold or ReceiveDmaUnlimited or ReceiveAccepted);
  AcceptAllMulticast(Card);
  Write16(Card^.Registers, RegisterInterruptStatus, $FFFF);
end;

procedure ReadLink(Card: PRealtekCard; out Link: TNetworkLinkState);
var
  Status: Byte;
begin
  Status := Read8(Card^.Registers, RegisterPhyStatus);
  Link.IsUp := (Status and PhyStatusLinkUp) <> 0;
  Link.FullDuplex := Link.IsUp and ((Status and PhyStatusFullDuplex) <> 0);
  Link.SpeedMegabits := 0;
  if not Link.IsUp then
    Exit;
  if (Status and PhyStatus1000Full) <> 0 then
    Link.SpeedMegabits := 1000
  else if (Status and PhyStatus100) <> 0 then
    Link.SpeedMegabits := 100
  else if (Status and PhyStatus10) <> 0 then
    Link.SpeedMegabits := 10;
end;

function IsRtl8168(Pci: PPciDevice): Boolean;
begin
  Result := (Pci^.VendorId = RealtekVendorId) and ((Pci^.DeviceId = $8168) or (Pci^.DeviceId = $8161));
end;

function StartCard(Pci: PPciDevice): Boolean;
var
  Chip: TRealtekChip;
  Card: PRealtekCard;
begin
  Result := False;
  Chip.InterruptMaskRegister := RegisterInterruptMask;
  Chip.InterruptStatusRegister := RegisterInterruptStatus;
  Chip.WideInterruptRegisters := False;
  Chip.TransmitPoll := @PollTransmit;
  Chip.BringUp := @BringUp;
  Chip.ReadLink := @ReadLink;
  Chip.LinkStillDown := nil;
  Chip.Uses32BitDma := @Uses32BitDma;
  Card := CreateRealtekCard(Pci, Chip, nil);
  if Card = nil then
    Exit;
  { Later versions keep a copy of the address loaded at power-on. }
  if not ReadRealtekStationAddress(Card, RegisterStationAddress0, Card^.Address) and
     not ReadRealtekStationAddress(Card, RegisterStationAddressBackup, Card^.Address) then
  begin
    ReportRealtek(Card, 'no valid station address');
    Exit;
  end;
  Result := StartRealtekCard(Card, 'Realtek RTL8168/8111');
end;

function InitializeRtl8168Adapters: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
    if IsRtl8168(PciDeviceAt(Index)) and StartCard(PciDeviceAt(Index)) then
      Inc(Result);
end;

end.
