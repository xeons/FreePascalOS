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
  Bringing an RTL8125/RTL8126 from any state to running, in the order
  and with the values of the Linux r8169 driver (rtl_hw_init_8125,
  rtl_hw_start_8125 and rtl_hw_start_8125_common, and the generic
  rtl_hw_start around them):

  1. The MAC's own start-up: receive gated off, the firmware's
     out-of-band mode left, the link list FIFO ready, then a reset.
  2. The PLL and the PHY powered up; the PHY waited for until it says
     "LAN on".
  3. With the configuration registers unlocked: ASPM and clock requests
     off (the chip, and its PCI Express link, never go to L0s/L1, which
     costs a little power and avoids the link drops and stalls those
     states cause on these chips), interrupt coalescing off, receive
     side scaling and the extra queues off, the legacy transmit
     descriptor format, the MAC's FIFO and timing values, energy
     efficient Ethernet off, receive ungated.
  4. The largest frame, the station address, the rings; receive and
     transmit on.
  5. The PHY: the firmware patch if one was loaded (Drivers.Rtl8125
     loads it once the system volume is mounted, and runs this step
     again then), advanced link-down power saving and EEE off,
     10/100/1000 and 2.5G (and 5G on the RTL8126) advertised, and
     autonegotiation restarted.

  Not done: the per-version PHY tuning tables and the PCI Express PHY
  (EPHY) values Linux writes; the chip negotiates with the PHY's own
  defaults.
}
unit Drivers.Rtl8125.Setup;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drivers.RealtekGigabit,
  Drivers.RealtekFirmware,
  Drivers.Rtl8125.Versions;

const
  Rtl8125InterruptMask = $38;
  Rtl8125InterruptStatus = $3C;
  Rtl8125TransmitPoll = $90;

type
  PRtl8125State = ^TRtl8125State;
  TRtl8125State = record
    Version: PRtl8125Version;
    Firmware: TRealtekFirmware;
    HasFirmware: Boolean;
  end;

{ The chip's BringUp (Drivers.RealtekGigabit). }
function BringUpRtl8125(Card: PRealtekCard): Boolean;
{ Step 5 alone (configuration lock held): after a firmware patch
  arrived. }
procedure ConfigureRtl8125Phy(Card: PRealtekCard);

implementation

uses
  Kernel.Scheduler,
  Io.Pci,
  Drivers.NetworkBuffers,
  Drivers.RealtekGigabit.Registers,
  Drivers.RealtekGigabit.Rings,
  Drivers.RealtekOcp,
  Debug.Output;

const
  RegisterInterruptConfiguration0 = $34;
  RegisterInterruptConfiguration1 = $7A;
  RegisterMcu = $D3;
  RegisterMiscellaneous = $F0;
  RegisterInterruptMitigation = $E2;
  RegisterReceiveSideScaling = $4500;
  RegisterQueueCount = $4800;
  RegisterUnnamed382 = $382;
  RegisterUnnamed1880 = $1880;
  RegisterCoalescingFirst = $0A00;
  RegisterCoalescingEndShort = $0A80;
  RegisterCoalescingEndLong = $0B00;

  McuNowOutOfBand = $80;
  McuLinkListReady = $02;
  MiscellaneousReceiveGated = LongWord(1) shl 19;
  TransmitConfigurationEmpty = LongWord(1) shl 11;
  TransmitAutoFifo = LongWord(1) shl 7;
  ReceiveFetchDefault = LongWord(8) shl 27;
  ReceivePauseSlotOn = LongWord(1) shl 11;
  Configuration1Bit4 = $10;
  Configuration2ClockRequest = $80;
  Configuration3ReadyToL23 = $02;
  Configuration5Aspm = $01;
  PowerManagementPllOn = $C0;

  PhyOcpPhyState = $A420;
  PhyStateMask = $0007;
  PhyStateLanOn = 3;
  PhyOcpAldps = $A430;
  AldpsEnable = $0004;
  PhyOcpEeeAdvertisement = $A5D0;
  EeeAdvertise100And1000 = $0006;
  PhyOcpEeeAdvertisement2 = $A6D4;
  EeeAdvertise2500And5000 = $0003;
  PhyOcpMultiGigabitControl = $A5D4;
  Advertise2500Full = $0080;
  Advertise5000Full = $0100;
  Advertise10And100 = $01E0;
  Advertise1000Full = $0200;

  ShortWaitMilliseconds = 10;
  PhyStateWaitMilliseconds = 500;
  PhyResetWaitMilliseconds = 100;

procedure Report(Card: PRealtekCard; Text: PChar);
begin
  ReportRealtek(Card, Text);
end;

function WaitForRegister32(Card: PRealtekCard; Offset, Mask, Expected: LongWord; Milliseconds: LongWord): Boolean;
var
  Waited: LongWord;
begin
  Waited := 0;
  while (Read32(Card^.Registers, Offset) and Mask) <> Expected do
  begin
    if Waited >= Milliseconds then
      Exit(False);
    SleepMilliseconds(1);
    Inc(Waited);
  end;
  Result := True;
end;

function WaitForPhyState(Card: PRealtekCard; State: Word; Milliseconds: LongWord; out LastValue: Word): Boolean;
var
  Waited: LongWord;
begin
  Waited := 0;
  repeat
    if ReadPhyOcp(Card, PhyOcpPhyState, LastValue) and ((LastValue and PhyStateMask) = State) then
      Exit(True);
    SleepMilliseconds(1);
    Inc(Waited);
  until Waited >= Milliseconds;
  Result := False;
end;

{ --- 1. The MAC's own start-up ---------------------------------------------------- }

procedure GateReceive(Card: PRealtekCard; Gated: Boolean);
var
  Value: LongWord;
begin
  Value := Read32(Card^.Registers, RegisterMiscellaneous);
  if Gated then
    Value := Value or MiscellaneousReceiveGated
  else
    Value := Value and not MiscellaneousReceiveGated;
  Write32(Card^.Registers, RegisterMiscellaneous, Value);
end;

procedure WaitForLinkListReady(Card: PRealtekCard);
begin
  if not WaitForRealtekRegister8(Card, RegisterMcu, McuLinkListReady, McuLinkListReady, ShortWaitMilliseconds) then
    Report(Card, 'the link list FIFO did not become ready; going on');
end;

procedure InitializeMac(Card: PRealtekCard);
var
  Waited: LongWord;
begin
  GateReceive(Card, True);
  SleepMilliseconds(2);
  { What is in the FIFOs drains first. }
  WaitForRegister32(Card, RegisterTransmitConfiguration, TransmitConfigurationEmpty, TransmitConfigurationEmpty,
    ShortWaitMilliseconds);
  Waited := 0;
  while ((Read16(Card^.Registers, RegisterInterruptMitigation) and $0103) <> $0103) and (Waited < ShortWaitMilliseconds) do
  begin
    SleepMilliseconds(1);
    Inc(Waited);
  end;
  Write8(Card^.Registers, RegisterCommand,
    Read8(Card^.Registers, RegisterCommand) and not (CommandTransmitEnable or CommandReceiveEnable));
  SleepMilliseconds(1);
  Write8(Card^.Registers, RegisterMcu, Read8(Card^.Registers, RegisterMcu) and not McuNowOutOfBand);
  ModifyMacOcp(Card, $E8DE, $4000, 0);
  WaitForLinkListReady(Card);
  WriteMacOcp(Card, $C0AA, $07D0);
  WriteMacOcp(Card, $C0A6, $0150);
  WriteMacOcp(Card, $C01E, $5555);
  WaitForLinkListReady(Card);
end;

{ --- 2. Power ----------------------------------------------------------------------- }

procedure PowerUpPhy(Card: PRealtekCard);
var
  State: Word;
begin
  Write8(Card^.Registers, RegisterPowerManagement,
    Read8(Card^.Registers, RegisterPowerManagement) or PowerManagementPllOn);
  if not ModifyPhyOcp(Card, PhyOcpBasicControl, BasicControlPowerDown, 0) then
    Report(Card, 'the PHY does not answer');
  if not WaitForPhyState(Card, PhyStateLanOn, PhyStateWaitMilliseconds, State) then
  begin
    DebugBeginMessage;
    DebugWriteTag('realtek');
    DebugWrite('the PHY did not say "LAN on" (state register ');
    DebugWriteHex(State, 4);
    DebugWriteLine('); going on');
    DebugEndMessage;
  end;
end;

{ --- 3. The MAC's set-up ------------------------------------------------------------ }

procedure DisableActiveStatePowerManagement(Card: PRealtekCard);
var
  Capability: Word;
  Control: Word;
begin
  Write8(Card^.Registers, RegisterConfiguration5,
    Read8(Card^.Registers, RegisterConfiguration5) and not Configuration5Aspm);
  Write8(Card^.Registers, RegisterConfiguration2,
    Read8(Card^.Registers, RegisterConfiguration2) and not Configuration2ClockRequest);
  Capability := FindPciCapability(Card^.Pci, PciCapabilityExpress);
  if Capability = 0 then
    Exit;
  Control := PciRead16(Card^.Pci, Capability + PciExpressLinkControl);
  PciWrite16(Card^.Pci, Capability + PciExpressLinkControl, Control and not PciExpressLinkControlAspmMask);
end;

procedure DisableCoalescing(Card: PRealtekCard; Generation: TRtl8125Generation);
var
  Offset: LongWord;
  EndOffset: LongWord;
begin
  Write8(Card^.Registers, RegisterInterruptConfiguration0, 0);
  if Generation in [Generation8125B, Generation8126A] then
    EndOffset := RegisterCoalescingEndShort
  else
    EndOffset := RegisterCoalescingEndLong;
  Offset := RegisterCoalescingFirst;
  while Offset < EndOffset do
  begin
    Write32(Card^.Registers, Offset, 0);
    Inc(Offset, 4);
  end;
  if Generation in [Generation8125B, Generation8126A] then
    Write16(Card^.Registers, RegisterInterruptConfiguration1, 0);
end;

{ The MAC clears bit 13 of E00Eh when the values written are in effect. }
function WaitMacOcpBitClear(Card: PRealtekCard): Boolean;
var
  Waited: LongWord;
begin
  Waited := 0;
  while (ReadMacOcp(Card, $E00E) and $2000) <> 0 do
  begin
    if Waited >= ShortWaitMilliseconds then
      Exit(False);
    SleepMilliseconds(1);
    Inc(Waited);
  end;
  Result := True;
end;

{ rtl_hw_start_8125_common. }
procedure ConfigureMac(Card: PRealtekCard; Generation: TRtl8125Generation);
begin
  Write8(Card^.Registers, RegisterConfiguration3,
    Read8(Card^.Registers, RegisterConfiguration3) and not Configuration3ReadyToL23);
  Write16(Card^.Registers, RegisterUnnamed382, $221B);
  Write32(Card^.Registers, RegisterReceiveSideScaling, 0);
  Write16(Card^.Registers, RegisterQueueCount, 0);
  { No UPS power saving. }
  ModifyMacOcp(Card, $D40A, $0010, 0);
  Write8(Card^.Registers, RegisterConfiguration1,
    Read8(Card^.Registers, RegisterConfiguration1) and not Configuration1Bit4);
  WriteMacOcp(Card, $C140, $FFFF);
  WriteMacOcp(Card, $C142, $FFFF);
  ModifyMacOcp(Card, $D3E2, $0FFF, $03A9);
  ModifyMacOcp(Card, $D3E4, $00FF, $0000);
  ModifyMacOcp(Card, $E860, $0000, $0080);
  { The legacy transmit descriptors, which the rings use. }
  ModifyMacOcp(Card, $EB58, $0001, $0000);
  case Generation of
    Generation8126A: ModifyMacOcp(Card, $E614, $0700, $0400);
    Generation8125B: ModifyMacOcp(Card, $E614, $0700, $0200);
  else
    ModifyMacOcp(Card, $E614, $0700, $0300);
  end;
  if Generation = Generation8125B then
    ModifyMacOcp(Card, $E63E, $0C30, $0000)
  else
    ModifyMacOcp(Card, $E63E, $0C30, $0020);
  ModifyMacOcp(Card, $C0B4, $0000, $000C);
  ModifyMacOcp(Card, $EB6A, $00FF, $0033);
  ModifyMacOcp(Card, $EB50, $03E0, $0040);
  ModifyMacOcp(Card, $E056, $00F0, $0030);
  ModifyMacOcp(Card, $E040, $1000, $0000);
  ModifyMacOcp(Card, $EA1C, $0003, $0001);
  ModifyMacOcp(Card, $E0C0, $4F0F, $4403);
  ModifyMacOcp(Card, $E052, $0080, $0068);
  ModifyMacOcp(Card, $D430, $0FFF, $047F);
  ModifyMacOcp(Card, $EA1C, $0004, $0000);
  ModifyMacOcp(Card, $EB54, $0000, $0001);
  SleepMilliseconds(1);
  ModifyMacOcp(Card, $EB54, $0001, $0000);
  Write16(Card^.Registers, RegisterUnnamed1880, Read16(Card^.Registers, RegisterUnnamed1880) and not $0030);
  WriteMacOcp(Card, $E098, $C302);
  if not WaitMacOcpBitClear(Card) then
    Report(Card, 'the MAC did not finish its set-up (E00Eh); going on');
  { Energy efficient Ethernet off in the MAC. }
  ModifyMacOcp(Card, $E040, $0003, $0000);
  if Generation = Generation8125A then
    ModifyMacOcp(Card, $EB62, $0006, $0000);
  GateReceive(Card, False);
  { Leaving L1 on any activity. }
  ModifyMacOcp(Card, $C0AC, $0000, $1F80);
end;

{ --- 5. The PHY ---------------------------------------------------------------------- }

type
  { The firmware's view of the registers: MDIO-style numbers in pages
    (register 1Fh picks the page), as Linux's r8168g_mdio_read/write and
    mac_mcu_read/write. }
  TFirmwareTarget = record
    Card: PRealtekCard;
    OcpBase: Word;
  end;
  PFirmwareTarget = ^TFirmwareTarget;

function FirmwarePhyRead(Context: Pointer; RegisterNumber: LongWord): Word;
var
  Target: PFirmwareTarget;
  Value: Word;
begin
  Target := PFirmwareTarget(Context);
  if RegisterNumber = $1F then
  begin
    if Target^.OcpBase = PhyOcpStandardBase then
      Exit(0);
    Exit(Target^.OcpBase shr 4);
  end;
  if Target^.OcpBase <> PhyOcpStandardBase then
    RegisterNumber := RegisterNumber - $10;
  ReadPhyOcp(Target^.Card, Word(Target^.OcpBase + RegisterNumber * 2), Value);
  Result := Value;
end;

procedure FirmwarePhyWrite(Context: Pointer; RegisterNumber: LongWord; Value: Word);
var
  Target: PFirmwareTarget;
begin
  Target := PFirmwareTarget(Context);
  if RegisterNumber = $1F then
  begin
    if Value = 0 then
      Target^.OcpBase := PhyOcpStandardBase
    else
      Target^.OcpBase := Word(Value shl 4);
    Exit;
  end;
  if Target^.OcpBase <> PhyOcpStandardBase then
    RegisterNumber := RegisterNumber - $10;
  WritePhyOcp(Target^.Card, Word(Target^.OcpBase + RegisterNumber * 2), Value);
end;

function FirmwareMacRead(Context: Pointer; RegisterNumber: LongWord): Word;
var
  Target: PFirmwareTarget;
begin
  Target := PFirmwareTarget(Context);
  Result := ReadMacOcp(Target^.Card, Word(Target^.OcpBase + RegisterNumber));
end;

procedure FirmwareMacWrite(Context: Pointer; RegisterNumber: LongWord; Value: Word);
var
  Target: PFirmwareTarget;
begin
  Target := PFirmwareTarget(Context);
  if RegisterNumber = $1F then
  begin
    Target^.OcpBase := Word(Value shl 4);
    Exit;
  end;
  WriteMacOcp(Target^.Card, Word(Target^.OcpBase + RegisterNumber), Value);
end;

procedure ApplyFirmware(Card: PRealtekCard; State: PRtl8125State);
var
  Target: TFirmwareTarget;
  Access: TRealtekFirmwareAccess;
  Waited: LongWord;
  Control: Word;
begin
  Target.Card := Card;
  Target.OcpBase := PhyOcpStandardBase;
  Access.Context := @Target;
  Access.PhyRead := @FirmwarePhyRead;
  Access.PhyWrite := @FirmwarePhyWrite;
  Access.MacRead := @FirmwareMacRead;
  Access.MacWrite := @FirmwareMacWrite;
  if not RunRealtekFirmware(State^.Firmware, Access) then
    Report(Card, 'the PHY firmware patch did not finish (step limit)');
  { The patch may leave the PHY resetting itself. }
  Waited := 0;
  while ReadPhyOcp(Card, PhyOcpBasicControl, Control) and ((Control and BasicControlReset) <> 0) and
        (Waited < PhyResetWaitMilliseconds) do
  begin
    SleepMilliseconds(5);
    Inc(Waited, 5);
  end;
end;

procedure ConfigureRtl8125Phy(Card: PRealtekCard);
var
  State: PRtl8125State;
  MultiGigabit: Word;
begin
  State := PRtl8125State(Card^.ChipData);
  if State^.HasFirmware then
    ApplyFirmware(Card, State);
  ModifyPhyOcp(Card, PhyOcpAldps, AldpsEnable, 0);
  ModifyPhyOcp(Card, PhyOcpEeeAdvertisement, EeeAdvertise100And1000, 0);
  ModifyPhyOcp(Card, PhyOcpEeeAdvertisement2, EeeAdvertise2500And5000, 0);
  ModifyPhyOcp(Card, PhyOcpAdvertisement, 0, Advertise10And100);
  ModifyPhyOcp(Card, PhyOcpGigabitControl, 0, Advertise1000Full);
  MultiGigabit := Advertise2500Full;
  if State^.Version^.Generation = Generation8126A then
    MultiGigabit := MultiGigabit or Advertise5000Full;
  ModifyPhyOcp(Card, PhyOcpMultiGigabitControl, 0, MultiGigabit);
  if not WritePhyOcp(Card, PhyOcpBasicControl,
    BasicControlAutoNegotiationEnable or BasicControlRestartAutoNegotiation) then
    Report(Card, 'autonegotiation could not be restarted (the PHY does not answer)');
end;

{ --- All of it ------------------------------------------------------------------------- }

function BringUpRtl8125(Card: PRealtekCard): Boolean;
var
  State: PRtl8125State;
  Generation: TRtl8125Generation;
  ReceiveConfiguration: LongWord;
begin
  State := PRtl8125State(Card^.ChipData);
  Generation := State^.Version^.Generation;
  Write32(Card^.Registers, Rtl8125InterruptMask, 0);
  Write32(Card^.Registers, Rtl8125InterruptStatus, $FFFFFFFF);

  InitializeMac(Card);
  Result := ResetRealtekChip(Card);
  if not Result then
    Exit;
  PowerUpPhy(Card);

  UnlockRealtekConfiguration(Card);
  DisableActiveStatePowerManagement(Card);
  DisableCoalescing(Card, Generation);
  ConfigureMac(Card, Generation);
  Write16(Card^.Registers, RegisterReceiveMaximumSize, NetworkBufferBytes);
  WriteRealtekStationAddress(Card);
  ProgramRealtekRings(Card^.Rings);
  LockRealtekConfiguration(Card);

  Write8(Card^.Registers, RegisterCommand, CommandTransmitEnable or CommandReceiveEnable);
  ReceiveConfiguration := ReceiveFetchDefault or ReceiveDmaUnlimited or ReceiveAccepted;
  if Generation = Generation8126A then
    ReceiveConfiguration := ReceiveConfiguration or ReceivePauseSlotOn;
  Write32(Card^.Registers, RegisterReceiveConfiguration, ReceiveConfiguration);
  Write32(Card^.Registers, RegisterTransmitConfiguration,
    TransmitStandardGap or TransmitDmaUnlimited or TransmitAutoFifo);
  AcceptAllMulticast(Card);
  Write32(Card^.Registers, Rtl8125InterruptStatus, $FFFFFFFF);

  ConfigureRtl8125Phy(Card);
end;

end.
