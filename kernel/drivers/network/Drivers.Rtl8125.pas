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
  Realtek RTL8125 (2.5 Gbit/s, also sold as the Killer E3000) and
  RTL8126 (5 Gbit/s, also the Killer E5000) Ethernet. QEMU has no model
  of them: this is written from the Linux r8169 driver's sequences and
  is untested until it runs on such a machine.

  What sets this generation apart from the RTL8168: 32-bit interrupt
  mask and status registers at 38h and 3Ch, the transmit poll register
  at 90h (bit 0 for the first queue), several queues of which only the
  first is used, the MAC and PHY reached through OCP windows
  (Drivers.RealtekOcp), and a set-up that depends on the version
  (Drivers.Rtl8125.Versions, read from the XID bits; the set-up in
  Drivers.Rtl8125.Setup). The station address comes from the backup
  copy the chip loads at power-on (19E0h), else the address registers.

  The PHY firmware patch Linux loads for each version (rtl_nic/...fw)
  is asked for from /lib/firmware (Io.Firmware) and applied once the
  system volume is mounted, and again on every set-up after that (on
  waking). Linux treats the patches as optional, and so does this
  driver: without the file the chip runs with its PHY's own code.

  The link (up, 10 to 5000 Mbit/s, duplex) is read from the MAC's PHY
  status register; while it stays down, what the PHY says is logged
  after 10 and 60 seconds.
}
unit Drivers.Rtl8125;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every RTL8125/RTL8126 card; returns how many. }
function InitializeRtl8125Adapters: Integer;

implementation

uses
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.Mutex,
  Io.Pci,
  Io.Firmware,
  Io.NetworkAdapters,
  Drivers.NetworkCards,
  Drivers.RealtekGigabit.Registers,
  Drivers.RealtekGigabit,
  Drivers.RealtekOcp,
  Drivers.RealtekFirmware,
  Drivers.Rtl8125.Versions,
  Drivers.Rtl8125.Setup,
  Debug.Output;

const
  RegisterStationAddressBackup = $19E0;
  TransmitPollFirstQueue = $01;
  PhyStatus2500Full = $0400;
  PhyStatus5000Full = $1000;
  PhyOcpSpecificStatus = $A434;
  PhyOcpPhyState = $A420;
  FirstDiagnosisSeconds = 10;
  SecondDiagnosisSeconds = 60;

procedure PollTransmit(Registers: PByte);
begin
  Write8(Registers, Rtl8125TransmitPoll, TransmitPollFirstQueue);
end;

procedure ReadLink(Card: PRealtekCard; out Link: TNetworkLinkState);
var
  Status: Word;
begin
  Status := Read16(Card^.Registers, RegisterPhyStatus);
  Link.IsUp := (Status and PhyStatusLinkUp) <> 0;
  Link.FullDuplex := Link.IsUp and ((Status and PhyStatusFullDuplex) <> 0);
  Link.SpeedMegabits := 0;
  if not Link.IsUp then
    Exit;
  if (Status and PhyStatus5000Full) <> 0 then
    Link.SpeedMegabits := 5000
  else if (Status and PhyStatus2500Full) <> 0 then
    Link.SpeedMegabits := 2500
  else if (Status and PhyStatus1000Full) <> 0 then
    Link.SpeedMegabits := 1000
  else if (Status and PhyStatus100) <> 0 then
    Link.SpeedMegabits := 100
  else if (Status and PhyStatus10) <> 0 then
    Link.SpeedMegabits := 10;
end;

procedure WritePhyRegister(Card: PRealtekCard; Name: PChar; Address: Word);
var
  Value: Word;
begin
  DebugWrite(Name);
  if ReadPhyOcp(Card, Address, Value) then
    DebugWriteHex(Value, 4)
  else
    DebugWrite('(no answer)');
end;

{ The link stayed down: what the MAC and PHY say, for whoever reads the
  log. }
procedure LinkStillDown(Card: PRealtekCard; Seconds: LongWord);
begin
  if (Seconds <> FirstDiagnosisSeconds) and (Seconds <> SecondDiagnosisSeconds) then
    Exit;
  DebugBeginMessage;
  DebugWriteTag('realtek');
  DebugWrite(@Card^.Description[0]);
  DebugWrite(': no link after ');
  DebugWriteDecimal(Seconds);
  DebugWrite(' s; PHY status ');
  DebugWriteHex(Read16(Card^.Registers, RegisterPhyStatus), 4);
  WritePhyRegister(Card, ', BMCR ', PhyOcpBasicControl);
  WritePhyRegister(Card, ', BMSR ', PhyOcpBasicStatus);
  WritePhyRegister(Card, ', PHYSR ', PhyOcpSpecificStatus);
  WritePhyRegister(Card, ', PHY state ', PhyOcpPhyState);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ --- The firmware patch ------------------------------------------------------------ }

procedure FirmwareArrived(Context: Pointer; Data: PByte; Size: QWord);
var
  Card: PRealtekCard;
  State: PRtl8125State;
  Firmware: TRealtekFirmware;
begin
  Card := PRealtekCard(Context);
  State := PRtl8125State(Card^.ChipData);
  if Data = nil then
  begin
    ReportRealtek(Card, 'running without the PHY firmware patch');
    Exit;
  end;
  if not ParseRealtekFirmware(Data, Size, Firmware) then
  begin
    ReportRealtek(Card, 'the PHY firmware patch is malformed; running without it');
    FreeKernelMemory(Data);
    Exit;
  end;
  DebugBeginMessage;
  DebugWriteTag('realtek');
  DebugWrite(@Card^.Description[0]);
  DebugWrite(': applying PHY firmware ');
  DebugWrite(State^.Version^.FirmwareName);
  if Firmware.Version[0] <> #0 then
  begin
    DebugWrite(' (');
    DebugWrite(@Firmware.Version[0]);
    DebugWrite(')');
  end;
  DebugWrite(', ');
  DebugWriteDecimal(Firmware.OperationCount);
  DebugWriteLine(' operations');
  DebugEndMessage;
  AcquireMutex(Card^.ConfigurationLock);
  State^.Firmware := Firmware;
  State^.HasFirmware := True;
  if not Card^.IsSuspended then
    ConfigureRtl8125Phy(Card);
  ReleaseMutex(Card^.ConfigurationLock);
end;

{ --- Finding cards ------------------------------------------------------------------ }

procedure ReportVersion(Pci: PPciDevice; Xid: Word; Known: Boolean; Version: PRtl8125Version);
begin
  DebugBeginMessage;
  DebugWriteTag('realtek');
  DebugWriteHex(Pci^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(Pci^.DeviceId, 4);
  DebugWrite(' revision ');
  DebugWriteHex(Pci^.Revision, 2);
  DebugWrite(', XID ');
  DebugWriteHex(Xid, 3);
  if Known then
    DebugWrite(': ')
  else
    DebugWrite(': not a known version, set up as ');
  DebugWriteLine(Version^.Name);
  DebugEndMessage;
end;

procedure DescribeCard(State: PRtl8125State; Xid: Word; Description: PChar; Capacity: PtrUInt);
const
  HexDigits: array[0..15] of Char = '0123456789ABCDEF';
var
  XidText: array[0..15] of Char;
begin
  XidText[0] := ' ';
  XidText[1] := '(';
  XidText[2] := 'X';
  XidText[3] := 'I';
  XidText[4] := 'D';
  XidText[5] := ' ';
  XidText[6] := HexDigits[(Xid shr 8) and $F];
  XidText[7] := HexDigits[(Xid shr 4) and $F];
  XidText[8] := HexDigits[Xid and $F];
  XidText[9] := ')';
  XidText[10] := #0;
  CopyText(Description, State^.Version^.Name, Capacity);
  CopyText(Description + TextLength(Description), @XidText[0], Capacity - TextLength(Description));
end;

function StartCard(Pci: PPciDevice): Boolean;
var
  Chip: TRealtekChip;
  Card: PRealtekCard;
  State: PRtl8125State;
  Xid: Word;
  Description: array[0..47] of Char;
begin
  Result := False;
  State := PRtl8125State(AllocateZeroedKernelMemory(SizeOf(TRtl8125State)));
  if State = nil then
    Exit;
  Chip.InterruptMaskRegister := Rtl8125InterruptMask;
  Chip.InterruptStatusRegister := Rtl8125InterruptStatus;
  Chip.WideInterruptRegisters := True;
  Chip.TransmitPoll := @PollTransmit;
  Chip.BringUp := @BringUpRtl8125;
  Chip.ReadLink := @ReadLink;
  Chip.LinkStillDown := @LinkStillDown;
  Chip.Uses32BitDma := nil;
  Card := CreateRealtekCard(Pci, Chip, State);
  if Card = nil then
    Exit;

  Xid := Word((Read32(Card^.Registers, RegisterTransmitConfiguration) shr XidShift) and Rtl8125XidMask);
  State^.Version := FindRtl8125Version(Xid);
  if State^.Version <> nil then
    ReportVersion(Pci, Xid, True, State^.Version)
  else
  begin
    State^.Version := FallbackRtl8125Version(Pci^.DeviceId);
    ReportVersion(Pci, Xid, False, State^.Version);
  end;

  if not ReadRealtekStationAddress(Card, RegisterStationAddressBackup, Card^.Address) and
     not ReadRealtekStationAddress(Card, RegisterStationAddress0, Card^.Address) then
  begin
    ReportRealtek(Card, 'no valid station address');
    Exit;
  end;
  DescribeCard(State, Xid, @Description[0], SizeOf(Description));
  if not StartRealtekCard(Card, @Description[0]) then
    Exit;
  RequestFirmware(State^.Version^.FirmwareName, @FirmwareArrived, Card);
  Result := True;
end;

function InitializeRtl8125Adapters: Integer;
var
  Index: Integer;
  Pci: PPciDevice;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Pci := PciDeviceAt(Index);
    if IsRtl8125Family(Pci^.VendorId, Pci^.DeviceId) and StartCard(Pci) then
      Inc(Result);
  end;
end;

end.
