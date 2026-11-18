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
  Synopsys DesignWare USB3 controllers ("snps,dwc3": the two in the
  Raspberry Pi 5's RP1) as xHCI hosts. The block is an xHCI controller
  (its registers from offset 0, which Drivers.Xhci drives) with global
  registers of its own at C100h that must be set up first, as Linux's
  dwc3 core.c does for a host:

  - GSNPSID (C120h) must say 5533h (DWC_usb3), 3331h or 3332h;
  - the PHY interfaces (GUSB3PIPECTL at C2C0h, GUSB2PHYCFG at C200h):
    suspend off while setting up, U1/U2 exit through P3 off, the
    "snps,dis_rxdet_inp3_quirk", LPM sleep allowed;
  - the core's soft reset (DCTL C704h bit 30), waited for;
  - GCTL (C110h): no scale down, the clock gating and hibernation the
    design's power options call for, the port capability direction set
    to host;
  - "snps,axi-pipe-limit" (GSBUSCFG1 C104h), the quirks of GUCTL1
    (C11Ch: "snps,enhanced-nak-fs-quirk", "snps,parkmode-disable-*"),
    the transmit threshold ("snps,tx-thr-num-pkt", "snps,tx-max-burst":
    GTXTHRCFG C108h).

  Logged with the tag "dwc3": the identity and mode, and the step that
  failed.
}
unit Drivers.Dwc3;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.PlatformDevices;

{ Sets up the global registers of the DWC3 at Registers (Device's
  first memory range, mapped) for host mode; False if it is not a DWC3
  or does not come out of reset. }
function PrepareDwc3Host(Device: PPlatformDevice; Registers: PByte): Boolean;

implementation

uses
  Runtime.Atomic,
  Kernel.Clock,
  Kernel.Arch.Cpu,
  DeviceTree.Blob,
  Firmware.DeviceTree,
  Io.PlatformProperties,
  Debug.Output;

const
  GlobalSbusConfig1 = $C104;
  GlobalTransmitThreshold = $C108;
  GlobalControl = $C110;
  GlobalUserControl1 = $C11C;
  GlobalId = $C120;
  GlobalUserControl2 = $C19C;
  GlobalHardware0 = $C140;
  GlobalHardware1 = $C144;
  GlobalUsb2PhyConfig = $C200;
  GlobalUsb3PipeControl = $C2C0;
  DeviceControl = $C704;

  IdDwc3 = $5533;
  IdDwc31 = $3331;
  IdDwc32 = $3332;
  { 0x4 in the IP field also means DWC_usb32. }
  IdDwc4 = $3334;

  ControlDisableClockGating = LongWord(1) shl 0;
  ControlHibernation = LongWord(1) shl 1;
  ControlDisableScramble = LongWord(1) shl 3;
  ControlScaleDownMask = LongWord(3) shl 4;
  ControlSofItpSync = LongWord(1) shl 10;
  ControlPortCapabilityMask = LongWord(3) shl 12;
  ControlPortCapabilityHost = LongWord(1) shl 12;
  ControlU2ResetEcn = LongWord(1) shl 16;

  PowerOptionClock = 1;
  PowerOptionHibernation = 2;

  Usb2SuspendPhy = LongWord(1) shl 6;
  Usb2EnableSleep = LongWord(1) shl 8;
  Usb3SuspendPhy = LongWord(1) shl 17;
  Usb3U1U2ExitInP3 = LongWord(1) shl 27;
  Usb3DisableReceiveDetectInP3 = LongWord(1) shl 28;

  DeviceControlSoftReset = LongWord(1) shl 30;
  DeviceControlRun = LongWord(1) shl 31;
  SoftResetTimeoutNanoseconds = 100000000;

  User1ParkModeDisableFullLowSpeed = LongWord(1) shl 15;
  User1ParkModeDisableHighSpeed = LongWord(1) shl 16;
  User1ParkModeDisableSuperSpeed = LongWord(1) shl 17;
  User1EnhancedNakFullSpeed = LongWord(1) shl 19;
  User1EnhancedNakHighSpeed = LongWord(1) shl 20;
  User2ResetActiveBitLater = LongWord(1) shl 14;

  PipeTransactionLimitShift = 8;
  PipeTransactionLimitMask = LongWord($F) shl 8;

  ThresholdPacketCountSelect = LongWord(1) shl 29;
  ThresholdPacketCountShift = 24;
  ThresholdPacketCountMask = LongWord($F) shl 24;
  ThresholdBurstShift = 16;
  ThresholdBurstMask = LongWord($FF) shl 16;

  Revision190a = LongWord($5533190A);
  Revision210a = LongWord($5533210A);
  Revision250a = LongWord($5533250A);
  Revision310a = LongWord($5533310A);

function ReadGlobal(Registers: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteGlobal(Registers: PByte; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Registers + Offset)^ := Value;
end;

function DeviceName(Device: PPlatformDevice): PChar;
begin
  if Device^.DeviceTreeNode <> NoDeviceTreeNode then
    Result := NodeName(SystemDeviceTree^, Device^.DeviceTreeNode)
  else
    Result := @Device^.Path[0];
end;

procedure ReportFailure(Device: PPlatformDevice; Step: PChar; Value: LongWord);
begin
  DebugBeginMessage;
  DebugWriteTag('dwc3');
  DebugWrite(DeviceName(Device));
  DebugWrite(': FAILED at ');
  DebugWrite(Step);
  DebugWrite(' 0x');
  DebugWriteHex(Value, 8);
  DebugWriteLine('');
  DebugEndMessage;
end;

function PropertyByte(Device: PPlatformDevice; Name: PChar; out Value: Byte): Boolean;
var
  Length: LongWord;
begin
  Value := 0;
  Result := PlatformPropertyBytes(Device, Name, @Value, 1, Length) and (Length >= 1);
end;

procedure SetUpPhyInterfaces(Device: PPlatformDevice; Registers: PByte);
var
  Value: LongWord;
begin
  Value := ReadGlobal(Registers, GlobalUsb3PipeControl) and not (Usb3U1U2ExitInP3 or Usb3SuspendPhy);
  if PlatformHasProperty(Device, 'snps,dis_rxdet_inp3_quirk') then
    Value := Value or Usb3DisableReceiveDetectInP3;
  WriteGlobal(Registers, GlobalUsb3PipeControl, Value);
  Value := ReadGlobal(Registers, GlobalUsb2PhyConfig) and not Usb2SuspendPhy;
  if PlatformHasProperty(Device, 'snps,dis_enblslpm_quirk') then
    Value := Value and not Usb2EnableSleep
  else
    Value := Value or Usb2EnableSleep;
  WriteGlobal(Registers, GlobalUsb2PhyConfig, Value);
end;

function SoftReset(Registers: PByte): Boolean;
var
  Deadline: QWord;
begin
  WriteGlobal(Registers, DeviceControl,
    (ReadGlobal(Registers, DeviceControl) or DeviceControlSoftReset) and not DeviceControlRun);
  Deadline := ClockNanoseconds + SoftResetTimeoutNanoseconds;
  repeat
    if (ReadGlobal(Registers, DeviceControl) and DeviceControlSoftReset) = 0 then
      Exit(True);
    CpuRelax;
  until ClockNanoseconds > Deadline;
  Result := False;
end;

procedure SetUpGlobalControl(Registers: PByte; Revision: LongWord; IsDwc3: Boolean);
var
  Value: LongWord;
  PowerOption: LongWord;
begin
  Value := ReadGlobal(Registers, GlobalControl) and not (ControlScaleDownMask or ControlDisableScramble);
  PowerOption := (ReadGlobal(Registers, GlobalHardware1) shr 24) and 3;
  if PowerOption = PowerOptionClock then
  begin
    if IsDwc3 and (Revision >= Revision210a) and (Revision <= Revision250a) then
      Value := Value or ControlDisableClockGating or ControlSofItpSync
    else
      Value := Value and not ControlDisableClockGating;
  end
  else if PowerOption = PowerOptionHibernation then
    Value := Value or ControlHibernation;
  if IsDwc3 and (Revision < Revision190a) then
    Value := Value or ControlU2ResetEcn;
  Value := (Value and not ControlPortCapabilityMask) or ControlPortCapabilityHost;
  WriteGlobal(Registers, GlobalControl, Value);
end;

procedure ApplyQuirks(Device: PPlatformDevice; Registers: PByte; Revision: LongWord; IsDwc3: Boolean);
var
  Value: LongWord;
  Limit: Byte;
  Packets: Byte;
  Burst: Byte;
begin
  if PropertyByte(Device, 'snps,axi-pipe-limit', Limit) and (Limit >= 1) and (Limit <= 16) then
    WriteGlobal(Registers, GlobalSbusConfig1, (ReadGlobal(Registers, GlobalSbusConfig1) and
      not PipeTransactionLimitMask) or ((LongWord(Limit) - 1) shl PipeTransactionLimitShift));
  if not IsDwc3 or (Revision >= Revision250a) then
  begin
    Value := ReadGlobal(Registers, GlobalUserControl1);
    if PlatformHasProperty(Device, 'snps,enhanced-nak-fs-quirk') then
      Value := Value or User1EnhancedNakFullSpeed;
    if PlatformHasProperty(Device, 'snps,enhanced-nak-hs-quirk') then
      Value := Value or User1EnhancedNakHighSpeed;
    if PlatformHasProperty(Device, 'snps,parkmode-disable-ss-quirk') then
      Value := Value or User1ParkModeDisableSuperSpeed;
    if PlatformHasProperty(Device, 'snps,parkmode-disable-hs-quirk') then
      Value := Value or User1ParkModeDisableHighSpeed;
    if PlatformHasProperty(Device, 'snps,parkmode-disable-fsls-quirk') then
      Value := Value or User1ParkModeDisableFullLowSpeed;
    WriteGlobal(Registers, GlobalUserControl1, Value);
  end;
  if IsDwc3 and (Revision >= Revision310a) then
    WriteGlobal(Registers, GlobalUserControl2, ReadGlobal(Registers, GlobalUserControl2) or User2ResetActiveBitLater);
  if IsDwc3 and PropertyByte(Device, 'snps,tx-thr-num-pkt', Packets) and
     PropertyByte(Device, 'snps,tx-max-burst', Burst) and (Packets <> 0) and (Burst <> 0) then
  begin
    Value := ReadGlobal(Registers, GlobalTransmitThreshold) and not (ThresholdPacketCountMask or ThresholdBurstMask);
    Value := Value or ThresholdPacketCountSelect or ((LongWord(Packets) and $F) shl ThresholdPacketCountShift) or
      (LongWord(Burst) shl ThresholdBurstShift);
    WriteGlobal(Registers, GlobalTransmitThreshold, Value);
  end;
end;

function PrepareDwc3Host(Device: PPlatformDevice; Registers: PByte): Boolean;
var
  Id: LongWord;
  Kind: LongWord;
  Mode: LongWord;
  IsDwc3: Boolean;
begin
  Result := False;
  Id := ReadGlobal(Registers, GlobalId);
  Kind := Id shr 16;
  if (Kind <> IdDwc3) and (Kind <> IdDwc31) and (Kind <> IdDwc32) and (Kind <> IdDwc4) then
  begin
    ReportFailure(Device, 'identification (GSNPSID; all ones: RP1 unreachable)', Id);
    Exit;
  end;
  IsDwc3 := Kind = IdDwc3;
  Mode := ReadGlobal(Registers, GlobalHardware0) and 3;
  DebugBeginMessage;
  DebugWriteTag('dwc3');
  DebugWrite(DeviceName(Device));
  DebugWrite(': GSNPSID 0x');
  DebugWriteHex(Id, 8);
  DebugWrite(', design mode ');
  DebugWriteDecimal(Mode);
  DebugWrite(' (0 device, 1 host, 2 dual), GCTL 0x');
  DebugWriteHex(ReadGlobal(Registers, GlobalControl), 8);
  DebugWriteLine('');
  DebugEndMessage;
  if Mode = 0 then
  begin
    ReportFailure(Device, 'mode: the design is device only, GHWPARAMS0', ReadGlobal(Registers, GlobalHardware0));
    Exit;
  end;
  SetUpPhyInterfaces(Device, Registers);
  if not SoftReset(Registers) then
  begin
    ReportFailure(Device, 'core soft reset (DCTL still resetting after 100 ms)', ReadGlobal(Registers, DeviceControl));
    Exit;
  end;
  SetUpGlobalControl(Registers, Id, IsDwc3);
  ApplyQuirks(Device, Registers, Id, IsDwc3);
  Result := True;
end;

end.
