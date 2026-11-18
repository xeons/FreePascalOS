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
  The registers of the Broadcom STB PCIe root complex as the BCM2712 has
  it (brcm,bcm2712-pcie, "7712" generation), offsets into its register
  block (reg 0, 9310h bytes), as Linux's pcie-brcmstb.c names them.

  0000h-0FFFh is the root port's own configuration space (its PCI
  Express capability at ACh); the endpoint behind it is reached through
  a 4 KiB window at 8000h selected by the index register at 9000h.
  The "BAR" registers are inbound windows (PCI bus addresses to memory):
  the core was an endpoint once.
}
unit Drivers.BrcmPcie.Registers;

{$mode objfpc}

interface

const
  BrcmPcieRegisterBytes = $9310;

  { The root port's PCI Express capability. }
  ExpressCapability = $00AC;
  ExpressLinkStatus = ExpressCapability + $12;
  ExpressRootControl = ExpressCapability + $1C;
  ExpressRootCapabilities = ExpressCapability + $1E;
  ExpressLinkControl2 = ExpressCapability + $30;
  LinkStatusSpeedMask = $000F;
  LinkStatusWidthShift = 4;
  LinkStatusWidthMask = $003F;
  RootCapabilityRetryVisibility = $0001;
  RootControlRetryVisibilityEnable = $0010;
  LinkControl2TargetSpeedMask = $000F;

  VendorSpecificRegister1 = $0188;
  VendorSpecificEndianBar2Mask = $000C;

  PrivateIdValue3 = $043C;
  PrivateClassCodeMask = $00FFFFFF;
  ClassCodePciBridge = $060400;

  PrivateLinkCapability = $04DC;
  LinkCapabilityAspmMask = $0C00;
  LinkCapabilityAspmShift = 10;
  AspmL0s = 1;
  AspmL1 = 2;
  LinkCapabilitySpeedMask = $000F;

  PrivateRootCapability = $04F8;
  RootCapabilityL1SubstatesMask = $00F8;
  RootCapabilityL1SubstatesShift = 3;

  { MDIO to the SerDes. }
  MdioAddress = $1100;
  MdioWriteData = $1104;
  MdioReadData = $1108;
  MdioPortMask = $000F0000;
  MdioPortShift = 16;
  MdioRegisterMask = $0000FFFF;
  MdioCommandShift = 20;
  MdioCommandWrite = 0;
  MdioDataDone = LongWord($80000000);
  MdioSetAddress = $1F;

  PhyControl15 = $184C;
  PhyControl15ClockPeriodMask = $00FF;
  { 1/54 MHz, rounded down: 18.52 ns. }
  PhyControl15ClockPeriod2712 = $12;

  TransactionVdmControl1 = $0A0C;
  TransactionVdmControl0 = $0A20;
  VdmEnabled = $00010000;
  VdmIgnoreTag = $00020000;
  VdmIgnoreVendorId = $00040000;

  MiscControl = $4008;
  MiscControlRcb64Bytes = $00000080;
  MiscControlRcbMpsMode = $00000400;
  MiscControlScbAccessEnable = $00001000;
  MiscControlConfigReadUrMode = $00002000;
  MiscControlMaximumBurstMask = $00300000;
  MiscControlMaximumBurstShift = 20;
  { 512 bytes. }
  MiscControlBurst512 = 2;

  { Outbound windows (processor to PCI), four of them. }
  OutboundWindowCount = 4;
  OutboundWindowLow = $400C;
  OutboundWindowHigh = $4010;
  OutboundWindowStride = 8;
  OutboundBaseLimit = $4070;
  OutboundBaseLimitStride = 4;
  OutboundBaseMask = $0000FFF0;
  OutboundBaseShift = 4;
  OutboundLimitMask = LongWord($FFF00000);
  OutboundLimitShift = 20;
  { The megabyte number bits above the twelve the base/limit word holds. }
  OutboundBaseHigh = $4080;
  OutboundLimitHigh = $4084;
  OutboundHighStride = 8;
  OutboundHighMask = $FF;
  OutboundMegabyteBitsLow = 12;

  { Inbound windows ("RC BARs" 1-10) and where each lands in memory. }
  InboundWindowFirstConfig = $402C;
  InboundWindowFourthConfig = $40D4;
  InboundSizeMask = $1F;
  InboundRemapFirst = $40AC;
  InboundRemapFourth = $410C;
  InboundRemapAccessEnable = $1;
  InboundWindowCount2712 = 10;

  RcConfigRetryTimeout = $405C;

  PcieControl = $4064;
  PcieControlPerstDeasserted = $00000004;

  PcieStatus = $4068;
  StatusPhyLinkUp = $10;
  StatusDataLinkActive = $20;
  StatusLinkInL23 = $40;
  StatusRootComplexMode = $80;

  MiscRevision = $406C;

  MiscControl1 = $40A0;
  MiscControl1VdmQosControl = $00000020;
  UbusControl = $40A4;
  UbusReplyErrorDisable = $00002000;
  UbusReplyDecodeErrorDisable = $00080000;
  UbusTimeout = $40A8;
  UbusTimeout250Milliseconds = $0B2D0000;
  RcConfigRetry240Milliseconds = $0ABA0000;

  VdmPriorityToQosHigh = $4164;
  VdmPriorityToQosLow = $4168;
  TrafficClassQueueToQosFirst = $4160;

  AxiInterfaceControl = $416C;
  AxiRequestFifoQosPropagation = $00000080;
  AxiDisableQosGatingInMaster = $00000800;
  AxiQosUpdateTimingFix = $00001000;
  AxiRclkQosArrayFix = $00002000;
  AxiMaximumOutstandingMask = $3F;
  AxiReadErrorData = $4170;

  HardDebug2712 = $4304;
  HardDebugClockRequestDebugEnable = $00000002;
  HardDebugPerstAssert = $00000008;
  HardDebugRefclockOverrideEnable = $00010000;
  HardDebugRefclockOverrideOut = $00100000;
  HardDebugL1SubstatesEnable = $00200000;
  HardDebugSerdesIddq = $08000000;
  HardDebugClockRequestMask = HardDebugClockRequestDebugEnable or HardDebugRefclockOverrideEnable or
    HardDebugRefclockOverrideOut or HardDebugL1SubstatesEnable;

  { The endpoint's configuration space: the index selects bus, device
    and function as ECAM would place them, the data window shows it. }
  ConfigurationData = $8000;
  ConfigurationIndex = $9000;

  { Bridge reset when no reset controller is named. }
  SoftwareInit1 = $9210;
  SoftwareInitGeneric = $2;

  { The rescal block (brcm,bcm7216-pcie-sata-rescal). }
  RescalStart = $0;
  RescalStartBit = $1;
  RescalStatus = $8;
  RescalStatusBit = $1;

  { The STB reset controller (brcm,brcmstb-reset): banks of 32 lines. }
  ResetBankBytes = $18;
  ResetSet = $00;
  ResetClear = $04;

{ The RC BAR register offsets of inbound window Window (1-based). }
function InboundConfigOffset(Window: LongWord): LongWord;
function InboundRemapOffset(Window: LongWord): LongWord;
{ The size field for an inbound window of Size bytes (0: disabled). }
function EncodeInboundSize(Size: QWord): LongWord;

implementation

function InboundConfigOffset(Window: LongWord): LongWord;
begin
  if Window <= 3 then
    Result := InboundWindowFirstConfig + 8 * (Window - 1)
  else
    Result := InboundWindowFourthConfig + 8 * (Window - 4);
end;

function InboundRemapOffset(Window: LongWord): LongWord;
begin
  if Window <= 3 then
    Result := InboundRemapFirst + 8 * (Window - 1)
  else
    Result := InboundRemapFourth + 8 * (Window - 4);
end;

function FloorLog2(Value: QWord): LongWord;
begin
  Result := 0;
  while Value > 1 do
  begin
    Value := Value shr 1;
    Inc(Result);
  end;
end;

function EncodeInboundSize(Size: QWord): LongWord;
var
  Log2: LongWord;
begin
  Result := 0;
  if Size = 0 then
    Exit;
  Log2 := FloorLog2(Size);
  if (Log2 >= 12) and (Log2 <= 15) then
    Result := (Log2 - 12) + $1C
  else if (Log2 >= 16) and (Log2 <= 36) then
    Result := Log2 - 15;
end;

end.
