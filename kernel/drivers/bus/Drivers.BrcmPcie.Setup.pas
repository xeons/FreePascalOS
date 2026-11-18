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
  Bringing up a BCM2712 PCIe root complex, step by step, as Linux's
  pcie-brcmstb.c does it for the 7712 generation (implemented from its
  description, not copied):

  1. The bridge out of reset (its "bridge" line of the STB reset
     controller, else the SW_INIT bit), the SerDes calibrated (the
     "rescal" reset controller: start, wait for done, stop).
  2. The bridge reset once more, PERST# held, the SerDes out of IDDQ;
     MISC_CTRL: SCB access, unsupported-request reads, 512-byte bursts,
     RCB settings.
  3. Inbound windows, one per "dma-ranges" entry (the 7712 generation
     maps each by itself: an RC BAR with its PCI address and size, a
     remap register with the memory address); the root complex mode
     checked; ASPM L1 (and L0s unless "aspm-no-l0s") advertised; the
     class code of a PCI bridge; outbound windows, one per memory
     "ranges" entry (PCI address, then base and limit in megabytes);
     little endian inbound.
  4. BCM2712 tuning: the SerDes told of the 54 MHz reference clock over
     its MDIO bus, the L1 substate timers, AXI error replies turned into
     reads of all ones (so a dead link does not abort the processor),
     250 ms timeouts, the QoS workarounds and "brcm,vdm-qos-map".
  5. The link: the generation of "max-link-speed", CLKREQ# ignored,
     PERST# released, 100 ms, then up to 100 ms more for the PHY link
     and the data link to come up; the clock request mode
     ("brcm,clkreq-mode", default: L1 substates on); retry status
     visibility for configuration requests.

  A link the firmware left up (a network boot, enable_rp1_uart=1) is
  kept: only the windows and the step 4 settings that do not touch the
  SerDes are written again (Drivers.BrcmPcie chooses).

  Every failure says which step and the registers that tell why.
}
unit Drivers.BrcmPcie.Setup;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.DeviceTreePci,
  Io.PlatformDevices;

type
  PBrcmPcieHost = ^TBrcmPcieHost;
  TBrcmPcieHost = record
    Device: PPlatformDevice;
    Node: LongInt;
    { The node's name, for the log lines. }
    Name: PChar;
    Registers: PByte;
    PciHost: TDeviceTreePciHost;
    { "max-link-speed" (0: no limit). }
    Generation: LongWord;
    KeptFirmwareLink: Boolean;
    LinkSpeed: LongWord;
    LinkWidth: LongWord;
  end;

function ReadHostRegister(Host: PBrcmPcieHost; Offset: LongWord): LongWord;
procedure WriteHostRegister(Host: PBrcmPcieHost; Offset: LongWord; Value: LongWord);
function ReadHostRegister16(Host: PBrcmPcieHost; Offset: LongWord): Word;
procedure WriteHostRegister16(Host: PBrcmPcieHost; Offset: LongWord; Value: Word);

function HostLinkIsUp(Host: PBrcmPcieHost): Boolean;

{ "[pcie] NAME: TEXT" with a register value if Value is not -1. }
procedure ReportHost(Host: PBrcmPcieHost; Text: PChar; Value: Int64);
{ "[pcie] NAME: FAILED at STEP: what, status S (PHY link P, data link D)". }
procedure ReportHostFailure(Host: PBrcmPcieHost; Step: PChar; What: PChar);

{ Steps 1 to 4 from cold. False (and a line saying where) on failure. }
function ResetAndSetUpBridge(Host: PBrcmPcieHost): Boolean;
{ Step 5. }
function StartLink(Host: PBrcmPcieHost): Boolean;
{ For a link the firmware left up: the windows and the tuning that does
  not touch the SerDes. }
procedure RefreshKeptLink(Host: PBrcmPcieHost);
{ The negotiated speed (generation) and width. }
procedure ReadLinkState(Host: PBrcmPcieHost);

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Kernel.Scheduler,
  Memory.DeviceMapping,
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.DeviceTree,
  Drivers.BrcmPcie.Registers,
  Debug.Output;

const
  ResetSettleMicroseconds = 150;
  RescalTimeoutMicroseconds = 2000;
  MdioTimeoutMicroseconds = 200;
  PerstWaitMilliseconds = 100;
  LinkPollMilliseconds = 5;
  LinkPollLimitMilliseconds = 100;
  MaximumResetEntries = 8;
  ResetControllerBytes = $30;
  RescalBytes = $10;
  MaximumQosEntries = 8;

{ --- Register access ------------------------------------------------------- }

function ReadHostRegister(Host: PBrcmPcieHost; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Host^.Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteHostRegister(Host: PBrcmPcieHost; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Host^.Registers + Offset)^ := Value;
end;

function ReadHostRegister16(Host: PBrcmPcieHost; Offset: LongWord): Word;
begin
  Result := PWord(Host^.Registers + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteHostRegister16(Host: PBrcmPcieHost; Offset: LongWord; Value: Word);
begin
  FullMemoryBarrier;
  PWord(Host^.Registers + Offset)^ := Value;
end;

procedure ChangeHostRegister(Host: PBrcmPcieHost; Offset: LongWord; Clear, SetBits: LongWord);
begin
  WriteHostRegister(Host, Offset, (ReadHostRegister(Host, Offset) and not Clear) or SetBits);
end;

procedure WaitMicroseconds(Microseconds: QWord);
var
  Deadline: QWord;
begin
  Deadline := ClockNanoseconds + Microseconds * 1000;
  while ClockNanoseconds < Deadline do
    CpuRelax;
end;

function HostLinkIsUp(Host: PBrcmPcieHost): Boolean;
var
  Status: LongWord;
begin
  Status := ReadHostRegister(Host, PcieStatus);
  Result := ((Status and StatusPhyLinkUp) <> 0) and ((Status and StatusDataLinkActive) <> 0);
end;

{ --- Reporting --------------------------------------------------------------- }

procedure ReportHost(Host: PBrcmPcieHost; Text: PChar; Value: Int64);
begin
  DebugBeginMessage;
  DebugWriteTag('pcie');
  DebugWrite(Host^.Name);
  DebugWrite(': ');
  DebugWrite(Text);
  if Value >= 0 then
  begin
    DebugWrite(' 0x');
    DebugWriteHex(QWord(Value), 1);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure ReportHostFailure(Host: PBrcmPcieHost; Step: PChar; What: PChar);
var
  Status: LongWord;
begin
  Status := ReadHostRegister(Host, PcieStatus);
  DebugBeginMessage;
  DebugWriteTag('pcie');
  DebugWrite(Host^.Name);
  DebugWrite(': FAILED at ');
  DebugWrite(Step);
  DebugWrite(': ');
  DebugWrite(What);
  DebugWrite(', status 0x');
  DebugWriteHex(Status, 2);
  DebugWrite(' (PHY link ');
  DebugWriteDecimal(Ord((Status and StatusPhyLinkUp) <> 0));
  DebugWrite(', data link ');
  DebugWriteDecimal(Ord((Status and StatusDataLinkActive) <> 0));
  DebugWrite(', RC mode ');
  DebugWriteDecimal(Ord((Status and StatusRootComplexMode) <> 0));
  DebugWrite('), debug 0x');
  DebugWriteHex(ReadHostRegister(Host, HardDebug2712), 8);
  DebugWrite(', ctrl 0x');
  DebugWriteHex(ReadHostRegister(Host, PcieControl), 1);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ --- Reset controllers ------------------------------------------------------- }

{ The controller node and line of the "resets" entry named Name. }
function FindResetLine(Host: PBrcmPcieHost; Name: PChar; out Controller: LongInt; out Line: LongWord): Boolean;
var
  Tree: PDeviceTree;
  Names: TDeviceTreeProperty;
  Resets: TDeviceTreeProperty;
  Entry: LongWord;
  Cell: LongWord;
  Cells: LongWord;
  Candidate: LongInt;
begin
  Controller := NoNode;
  Line := 0;
  Result := False;
  Tree := SystemDeviceTree;
  if not FindProperty(Tree^, Host^.Node, 'reset-names', Names) or
     not FindProperty(Tree^, Host^.Node, 'resets', Resets) then
    Exit;
  Entry := 0;
  Cell := 0;
  while (Entry < MaximumResetEntries) and (Cell < PropertyCellCount(Resets)) do
  begin
    Candidate := FindNodeByPhandle(Tree^, PropertyCell(Resets, Cell));
    if (Candidate = NoNode) or not ReadCellProperty(Tree^, Candidate, '#reset-cells', Cells) then
      Exit;
    if DeviceTreeTextIsEqual(PropertyString(Names, Entry), Name) then
    begin
      Controller := Candidate;
      if (Cells > 0) and (Cell + 1 < PropertyCellCount(Resets)) then
        Line := PropertyCell(Resets, Cell + 1);
      Exit(True);
    end;
    Cell := Cell + 1 + Cells;
    Inc(Entry);
  end;
end;

function MapNode(Node: LongInt; Bytes: QWord; out Physical: QWord): PByte;
var
  Size: QWord;
begin
  Result := nil;
  if not NodeRegisterPhysical(SystemDeviceTree^, Node, 0, Physical, Size) then
    Exit;
  Result := PByte(MapDeviceMemory(Physical, Bytes));
end;

{ The bridge reset: its line of the STB reset controller, else the
  SW_INIT bit of the bridge itself. }
procedure SetBridgeReset(Host: PBrcmPcieHost; Asserted: Boolean);
var
  Controller: LongInt;
  Line: LongWord;
  Base: PByte;
  Physical: QWord;
  Offset: LongWord;
begin
  if FindResetLine(Host, 'bridge', Controller, Line) then
  begin
    Base := MapNode(Controller, ResetControllerBytes + (Line shr 5) * ResetBankBytes, Physical);
    if Base <> nil then
    begin
      Offset := (Line shr 5) * ResetBankBytes;
      FullMemoryBarrier;
      if Asserted then
        PLongWord(Base + Offset + ResetSet)^ := LongWord(1) shl (Line and 31)
      else
        PLongWord(Base + Offset + ResetClear)^ := LongWord(1) shl (Line and 31);
      FullMemoryBarrier;
      UnmapDeviceMemory(Base, ResetControllerBytes + (Line shr 5) * ResetBankBytes);
      WaitMicroseconds(ResetSettleMicroseconds);
      Exit;
    end;
  end;
  if Asserted then
    ChangeHostRegister(Host, SoftwareInit1, 0, SoftwareInitGeneric)
  else
    ChangeHostRegister(Host, SoftwareInit1, SoftwareInitGeneric, 0);
  WaitMicroseconds(ResetSettleMicroseconds);
end;

{ The SerDes resistor calibration: started, waited for, stopped. False
  if it never reports done (no rescal controller named is fine). }
function CalibrateSerdes(Host: PBrcmPcieHost): Boolean;
var
  Controller: LongInt;
  Line: LongWord;
  Base: PByte;
  Physical: QWord;
  Deadline: QWord;
  Status: LongWord;
begin
  Result := True;
  if not FindResetLine(Host, 'rescal', Controller, Line) then
    Exit;
  Base := MapNode(Controller, RescalBytes, Physical);
  if Base = nil then
    Exit;
  FullMemoryBarrier;
  PLongWord(Base + RescalStart)^ := PLongWord(Base + RescalStart)^ or RescalStartBit;
  FullMemoryBarrier;
  Deadline := ClockNanoseconds + RescalTimeoutMicroseconds * 1000;
  repeat
    Status := PLongWord(Base + RescalStatus)^;
    if (Status and RescalStatusBit) <> 0 then
      Break;
    CpuRelax;
  until ClockNanoseconds > Deadline;
  PLongWord(Base + RescalStart)^ := PLongWord(Base + RescalStart)^ and not RescalStartBit;
  FullMemoryBarrier;
  UnmapDeviceMemory(Base, RescalBytes);
  if (Status and RescalStatusBit) = 0 then
  begin
    ReportHost(Host, 'rescal never finished, status', Status);
    Result := False;
  end;
end;

{ --- The SerDes's MDIO bus ---------------------------------------------------- }

function MdioWrite(Host: PBrcmPcieHost; Port, RegisterNumber: LongWord; Value: Word): Boolean;
var
  Deadline: QWord;
begin
  WriteHostRegister(Host, MdioAddress, ((Port shl MdioPortShift) and MdioPortMask) or
    (RegisterNumber and MdioRegisterMask) or (MdioCommandWrite shl MdioCommandShift));
  ReadHostRegister(Host, MdioAddress);
  WriteHostRegister(Host, MdioWriteData, MdioDataDone or Value);
  Deadline := ClockNanoseconds + MdioTimeoutMicroseconds * 1000;
  repeat
    if (ReadHostRegister(Host, MdioWriteData) and MdioDataDone) = 0 then
      Exit(True);
    CpuRelax;
  until ClockNanoseconds > Deadline;
  Result := False;
end;

{ --- Windows ------------------------------------------------------------------ }

procedure SetOutboundWindow(Host: PBrcmPcieHost; Window: LongWord; ProcessorAddress, PciAddress, Size: QWord);
var
  BaseMegabytes: QWord;
  LimitMegabytes: QWord;
  Value: LongWord;
begin
  WriteHostRegister(Host, OutboundWindowLow + Window * OutboundWindowStride, LongWord(PciAddress));
  WriteHostRegister(Host, OutboundWindowHigh + Window * OutboundWindowStride, LongWord(PciAddress shr 32));
  BaseMegabytes := ProcessorAddress shr 20;
  LimitMegabytes := (ProcessorAddress + Size - 1) shr 20;
  Value := ReadHostRegister(Host, OutboundBaseLimit + Window * OutboundBaseLimitStride);
  Value := (Value and not (OutboundBaseMask or OutboundLimitMask)) or
    ((LongWord(BaseMegabytes and $FFF) shl OutboundBaseShift) and OutboundBaseMask) or
    ((LongWord(LimitMegabytes and $FFF) shl OutboundLimitShift) and OutboundLimitMask);
  WriteHostRegister(Host, OutboundBaseLimit + Window * OutboundBaseLimitStride, Value);
  ChangeHostRegister(Host, OutboundBaseHigh + Window * OutboundHighStride, OutboundHighMask,
    LongWord(BaseMegabytes shr OutboundMegabyteBitsLow) and OutboundHighMask);
  ChangeHostRegister(Host, OutboundLimitHigh + Window * OutboundHighStride, OutboundHighMask,
    LongWord(LimitMegabytes shr OutboundMegabyteBitsLow) and OutboundHighMask);
end;

procedure ProgramOutboundWindows(Host: PBrcmPcieHost);
var
  Index: Integer;
  Used: LongWord;
begin
  Used := 0;
  for Index := 0 to Host^.PciHost.WindowCount - 1 do
    if (Host^.PciHost.Windows[Index].Space >= PciSpaceMemory32) and (Used < OutboundWindowCount) then
    begin
      SetOutboundWindow(Host, Used, Host^.PciHost.Windows[Index].PhysicalAddress,
        Host^.PciHost.Windows[Index].BusAddress, Host^.PciHost.Windows[Index].Size);
      Inc(Used);
    end;
end;

procedure SetInboundWindow(Host: PBrcmPcieHost; Window: LongWord; PciAddress, MemoryAddress, Size: QWord);
var
  Value: LongWord;
begin
  Value := (LongWord(PciAddress) and not LongWord(InboundSizeMask)) or EncodeInboundSize(Size);
  WriteHostRegister(Host, InboundConfigOffset(Window), Value);
  WriteHostRegister(Host, InboundConfigOffset(Window) + 4, LongWord(PciAddress shr 32));
  WriteHostRegister(Host, InboundRemapOffset(Window),
    (LongWord(MemoryAddress) and not LongWord($FFF)) or InboundRemapAccessEnable);
  WriteHostRegister(Host, InboundRemapOffset(Window) + 4, LongWord(MemoryAddress shr 32));
end;

{ One inbound window per "dma-ranges" entry; how many. }
function ProgramInboundWindows(Host: PBrcmPcieHost): LongWord;
var
  Index: LongWord;
  BusStart: QWord;
  Physical: QWord;
  Size: QWord;
begin
  Result := 0;
  Index := 0;
  while (Result < InboundWindowCount2712) and
        ReadDmaRange(SystemDeviceTree^, Host^.Node, Index, BusStart, Physical, Size) do
  begin
    if Size > 0 then
    begin
      Inc(Result);
      SetInboundWindow(Host, Result, BusStart, Physical, Size);
    end;
    Inc(Index);
  end;
end;

{ --- Step 4: BCM2712 tuning ----------------------------------------------------- }

function TuneSerdes(Host: PBrcmPcieHost): Boolean;
const
  RegisterNumbers: array[0..6] of Byte = ($16, $17, $18, $19, $1B, $1C, $1E);
  Values: array[0..6] of Word = ($50B9, $BDA1, $0094, $97B4, $5030, $5030, $0007);
var
  Index: Integer;
begin
  { The 54 MHz crystal as the reference clock. }
  Result := MdioWrite(Host, 0, MdioSetAddress, $1600);
  Index := 0;
  while Result and (Index <= High(RegisterNumbers)) do
  begin
    Result := MdioWrite(Host, 0, RegisterNumbers[Index], Values[Index]);
    Inc(Index);
  end;
  WaitMicroseconds(200);
end;

{ The QoS map: "brcm,fifo-qos-map" (4 bytes) or "brcm,vdm-qos-map" (8). }
procedure ApplyQosMaps(Host: PBrcmPcieHost);
var
  Tree: PDeviceTree;
  Prop: TDeviceTreeProperty;
  Value: LongWord;
  Index: Integer;
begin
  Tree := SystemDeviceTree;
  ChangeHostRegister(Host, MiscControl1, MiscControl1VdmQosControl, 0);
  if FindProperty(Tree^, Host^.Node, 'brcm,fifo-qos-map', Prop) and (Prop.Length >= 4) then
  begin
    Value := 0;
    for Index := 0 to 3 do
      Value := Value or (LongWord(Prop.Value[Index] and $F) shl (Index * 4));
    for Index := 0 to MaximumQosEntries - 1 do
      WriteHostRegister(Host, TrafficClassQueueToQosFirst - LongWord(Index) * 4, Value);
  end
  else if FindProperty(Tree^, Host^.Node, 'brcm,vdm-qos-map', Prop) and (Prop.Length >= 8) then
  begin
    ChangeHostRegister(Host, MiscControl1, 0, MiscControl1VdmQosControl);
    Value := 0;
    for Index := 0 to 7 do
      Value := Value or (LongWord(Prop.Value[Index] and $F) shl (Index * 4));
    WriteHostRegister(Host, VdmPriorityToQosLow, Value);
    WriteHostRegister(Host, VdmPriorityToQosHigh, Value);
    WriteHostRegister(Host, TransactionVdmControl1, 0);
    ChangeHostRegister(Host, TransactionVdmControl0, 0, VdmEnabled or VdmIgnoreTag or VdmIgnoreVendorId);
  end;
end;

{ Everything of step 4 but the SerDes: safe on a running link. }
procedure TuneBus(Host: PBrcmPcieHost);
var
  Value: LongWord;
begin
  ChangeHostRegister(Host, PhyControl15, PhyControl15ClockPeriodMask, PhyControl15ClockPeriod2712);
  { A failed access reads as all ones instead of aborting. }
  ChangeHostRegister(Host, UbusControl, 0, UbusReplyErrorDisable or UbusReplyDecodeErrorDisable);
  WriteHostRegister(Host, AxiReadErrorData, $FFFFFFFF);
  WriteHostRegister(Host, UbusTimeout, UbusTimeout250Milliseconds);
  WriteHostRegister(Host, RcConfigRetryTimeout, RcConfigRetry240Milliseconds);
  ChangeHostRegister(Host, AxiInterfaceControl, AxiRequestFifoQosPropagation,
    AxiRclkQosArrayFix or AxiQosUpdateTimingFix or AxiDisableQosGatingInMaster);
  { Without the timing fix (C1 stepping, or one lane): fewer requests
    in flight. }
  Value := ReadHostRegister(Host, AxiInterfaceControl);
  if (Value and AxiQosUpdateTimingFix) = 0 then
    WriteHostRegister(Host, AxiInterfaceControl, (Value and not LongWord(AxiMaximumOutstandingMask)) or 15);
  ApplyQosMaps(Host);
end;

{ --- Steps 1 to 3 --------------------------------------------------------------- }

function AspmToAdvertise(Host: PBrcmPcieHost): LongWord;
begin
  Result := AspmL1;
  if not NodeHasProperty(SystemDeviceTree^, Host^.Node, 'aspm-no-l0s') then
    Result := Result or AspmL0s;
end;

function ResetAndSetUpBridge(Host: PBrcmPcieHost): Boolean;
var
  InboundCount: LongWord;
begin
  Result := False;
  { 1. Out of reset, SerDes calibrated. }
  SetBridgeReset(Host, False);
  if not CalibrateSerdes(Host) then
  begin
    ReportHostFailure(Host, 'step 1 (rescal)', 'SerDes calibration timed out');
    Exit;
  end;
  { 2. Reset again with PERST# held; SerDes powered. }
  SetBridgeReset(Host, True);
  ChangeHostRegister(Host, PcieControl, PcieControlPerstDeasserted, 0);
  WaitMicroseconds(ResetSettleMicroseconds);
  SetBridgeReset(Host, False);
  ChangeHostRegister(Host, HardDebug2712, HardDebugSerdesIddq, 0);
  WaitMicroseconds(ResetSettleMicroseconds);
  ChangeHostRegister(Host, MiscControl, MiscControlMaximumBurstMask,
    MiscControlScbAccessEnable or MiscControlConfigReadUrMode or MiscControlRcbMpsMode or
    MiscControlRcb64Bytes or (MiscControlBurst512 shl MiscControlMaximumBurstShift));
  { 3. Windows and identity. }
  InboundCount := ProgramInboundWindows(Host);
  if InboundCount = 0 then
  begin
    ReportHostFailure(Host, 'step 3 (inbound windows)', 'the node has no usable dma-ranges');
    Exit;
  end;
  if (ReadHostRegister(Host, PcieStatus) and StatusRootComplexMode) = 0 then
  begin
    ReportHostFailure(Host, 'step 3 (mode)', 'the controller is strapped as an endpoint');
    Exit;
  end;
  ChangeHostRegister(Host, PrivateLinkCapability, LinkCapabilityAspmMask,
    AspmToAdvertise(Host) shl LinkCapabilityAspmShift);
  ChangeHostRegister(Host, PrivateIdValue3, PrivateClassCodeMask, ClassCodePciBridge);
  ProgramOutboundWindows(Host);
  ChangeHostRegister(Host, VendorSpecificRegister1, VendorSpecificEndianBar2Mask, 0);
  { 4. Tuning. }
  if not TuneSerdes(Host) then
  begin
    ReportHostFailure(Host, 'step 4 (SerDes MDIO)', 'the SerDes did not take its clock settings');
    Exit;
  end;
  TuneBus(Host);
  Result := True;
end;

procedure RefreshKeptLink(Host: PBrcmPcieHost);
begin
  TuneBus(Host);
  ProgramInboundWindows(Host);
  ProgramOutboundWindows(Host);
  ChangeHostRegister(Host, PrivateIdValue3, PrivateClassCodeMask, ClassCodePciBridge);
end;

{ --- Step 5 --------------------------------------------------------------------- }

procedure LimitGeneration(Host: PBrcmPcieHost);
var
  Control2: Word;
begin
  if Host^.Generation = 0 then
    Exit;
  ChangeHostRegister(Host, PrivateLinkCapability, LinkCapabilitySpeedMask, Host^.Generation and LinkCapabilitySpeedMask);
  Control2 := ReadHostRegister16(Host, ExpressLinkControl2);
  Control2 := (Control2 and not Word(LinkControl2TargetSpeedMask)) or Word(Host^.Generation and LinkControl2TargetSpeedMask);
  WriteHostRegister16(Host, ExpressLinkControl2, Control2);
end;

procedure ConfigureClockRequest(Host: PBrcmPcieHost);
var
  Mode: PChar;
  Bits: LongWord;
begin
  Mode := ReadTextProperty(SystemDeviceTree^, Host^.Node, 'brcm,clkreq-mode');
  if (Mode = nil) or DeviceTreeTextIsEqual(Mode, 'default') then
    Bits := HardDebugL1SubstatesEnable
  else
  begin
    if DeviceTreeTextIsEqual(Mode, 'no-l1ss') then
      Bits := HardDebugClockRequestDebugEnable
    else
      Bits := HardDebugRefclockOverrideOut or HardDebugRefclockOverrideEnable;
    { No L1 substates advertised. }
    ChangeHostRegister(Host, PrivateRootCapability, RootCapabilityL1SubstatesMask,
      2 shl RootCapabilityL1SubstatesShift);
  end;
  ChangeHostRegister(Host, HardDebug2712, HardDebugClockRequestMask, Bits);
end;

procedure EnableRetryVisibility(Host: PBrcmPcieHost);
begin
  if (ReadHostRegister16(Host, ExpressRootCapabilities) and RootCapabilityRetryVisibility) <> 0 then
    WriteHostRegister16(Host, ExpressRootControl,
      ReadHostRegister16(Host, ExpressRootControl) or RootControlRetryVisibilityEnable);
end;

function StartLink(Host: PBrcmPcieHost): Boolean;
var
  Waited: LongWord;
begin
  LimitGeneration(Host);
  ChangeHostRegister(Host, HardDebug2712, HardDebugClockRequestMask, 0);
  ChangeHostRegister(Host, PcieControl, 0, PcieControlPerstDeasserted);
  SleepMilliseconds(PerstWaitMilliseconds);
  Waited := 0;
  while not HostLinkIsUp(Host) and (Waited < LinkPollLimitMilliseconds) do
  begin
    SleepMilliseconds(LinkPollMilliseconds);
    Inc(Waited, LinkPollMilliseconds);
  end;
  if not HostLinkIsUp(Host) then
  begin
    ReportHostFailure(Host, 'step 5 (link)', 'no link 200 ms after PERST# was released');
    Exit(False);
  end;
  ConfigureClockRequest(Host);
  EnableRetryVisibility(Host);
  Result := True;
end;

procedure ReadLinkState(Host: PBrcmPcieHost);
var
  Status: Word;
begin
  Status := ReadHostRegister16(Host, ExpressLinkStatus);
  Host^.LinkSpeed := Status and LinkStatusSpeedMask;
  Host^.LinkWidth := (Status shr LinkStatusWidthShift) and LinkStatusWidthMask;
end;

end.
