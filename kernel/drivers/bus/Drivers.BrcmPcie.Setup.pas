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

  1. Resources: the node's reset lines (Drivers.BrcmResets): "bridge"
     (a line of the brcm,brcmstb-reset controller; without one, the
     SW_INIT bit of the root complex itself), "swinit" if named, and
     "rescal" (the brcm,bcm7216-pcie-sata-rescal calibration). The
     pcie nodes name no clock (the firmware leaves theirs running) and
     no PERST# GPIO or supply (PERST# is the root complex's own pin).
  2. The bridge out of reset, a "swinit" pulse, the SerDes calibrated.
  3. The bridge reset once more: asserted, 150 us during which nothing
     of the root complex is touched (on the 7712 generation its
     registers do not answer then: an access stalls the bus and the
     processor with it), deasserted. Only then PERST# held (PCIE_CTRL's
     PERSTB bit, 0 = asserted), the SerDes out of IDDQ; MISC_CTRL: SCB
     access, unsupported-request reads, 512-byte bursts, RCB settings.
  4. Inbound windows, one per "dma-ranges" entry (an RC BAR with its PCI
     address and size, a remap register with the memory address); the
     root complex mode checked; ASPM L1 (and L0s unless "aspm-no-l0s")
     advertised; the class code of a PCI bridge; outbound windows, one
     per memory "ranges" entry; little endian inbound.
  5. BCM2712 tuning: the SerDes told of the 54 MHz reference clock over
     its MDIO bus, the L1 substate timer, AXI error replies turned into
     reads of all ones (so a dead link does not abort the processor),
     250 ms timeouts, the QoS workarounds and "brcm,vdm-qos-map".
  6. The link: the generation of "max-link-speed", CLKREQ# ignored,
     PERST# released, 100 ms, then up to 100 ms more for the PHY link
     and the data link; the clock request mode ("brcm,clkreq-mode",
     default: L1 substates on); retry status visibility.

  Every wait has a timeout. The configuration space behind the root
  port (8000h) is not touched here at all: Drivers.BrcmPcie reaches it
  only once the link is up.

  A link the firmware left up (pciex4_reset=0, a network boot,
  enable_rp1_uart=1) is kept: only the windows and the step 5 settings
  that do not touch the SerDes are written again.

  Every failure is one "FAILED at step N (name)" line, then a line of
  registers - or, if the bridge is in reset, a line saying they were not
  read. The caller leaves the host down and the boot goes on.
}
unit Drivers.BrcmPcie.Setup;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.DeviceTreePci,
  Io.PlatformDevices,
  Drivers.BrcmResets;

const
  StepResources = 1;
  StepCalibration = 2;
  StepBridgeReset = 3;
  StepWindows = 4;
  StepTuning = 5;
  StepLink = 6;

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
    BridgeLine: TResetLine;
    SwinitLine: TResetLine;
    RescalLine: TResetLine;
    HasBridgeLine: Boolean;
    HasSwinitLine: Boolean;
    HasRescalLine: Boolean;
    { The bridge is (or may be) in reset: the root complex's registers
      must not be read or written. }
    BridgeInReset: Boolean;
  end;

function ReadHostRegister(Host: PBrcmPcieHost; Offset: LongWord): LongWord;
procedure WriteHostRegister(Host: PBrcmPcieHost; Offset: LongWord; Value: LongWord);
function ReadHostRegister16(Host: PBrcmPcieHost; Offset: LongWord): Word;
procedure WriteHostRegister16(Host: PBrcmPcieHost; Offset: LongWord; Value: Word);

function HostLinkIsUp(Host: PBrcmPcieHost): Boolean;

{ "[pcie] NAME: TEXT" with a register value if Value is not -1. }
procedure ReportHost(Host: PBrcmPcieHost; Text: PChar; Value: Int64);
{ "[pcie] NAME: FAILED at step N (STEP NAME): WHAT", then the registers
  (if the bridge is out of reset). }
procedure ReportHostFailure(Host: PBrcmPcieHost; Step: Integer; What: PChar);

{ Step 1: the reset lines. False (and the FAILED line) if one the node
  names cannot be driven. Touches no register of the root complex. }
function FindHostResources(Host: PBrcmPcieHost): Boolean;
{ The firmware left the bridge in reset (its STB line's status). }
function BridgeIsHeldInReset(Host: PBrcmPcieHost): Boolean;
{ Steps 2 to 5 from cold. False (and the FAILED lines) on failure. }
function ResetAndSetUpBridge(Host: PBrcmPcieHost): Boolean;
{ Step 6. }
function StartLink(Host: PBrcmPcieHost): Boolean;
{ For a link the firmware left up: the windows and the tuning that does
  not touch the SerDes. }
procedure RefreshKeptLink(Host: PBrcmPcieHost);
{ After a failure: PERST# held (if the registers answer), so the device
  behind stays in reset. }
procedure LeaveHostDown(Host: PBrcmPcieHost);
{ The negotiated speed (generation) and width. }
procedure ReadLinkState(Host: PBrcmPcieHost);

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Kernel.Scheduler,
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.DeviceTree,
  Drivers.BrcmPcie.Registers,
  Debug.Output;

const
  ResetSettleMicroseconds = 150;
  SerdesSettleMicroseconds = 200;
  MdioTimeoutMicroseconds = 200;
  PerstWaitMilliseconds = 100;
  LinkPollMilliseconds = 5;
  LinkPollLimitMilliseconds = 100;
  MaximumQosEntries = 8;

  StepNames: array[StepResources..StepLink] of PChar = (
    'resources', 'bridge out of reset, SerDes calibration', 'bridge reset', 'windows',
    'SerDes and bus tuning', 'link');

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

procedure WriteBridgeLineState(Host: PBrcmPcieHost);
begin
  if not Host^.HasBridgeLine then
  begin
    DebugWrite('; bridge reset by SW_INIT');
    Exit;
  end;
  DebugWrite('; bridge reset line ');
  DebugWriteDecimal(Host^.BridgeLine.Line);
  if ResetLineIsAsserted(Host^.BridgeLine) then
    DebugWrite(' asserted')
  else
    DebugWrite(' deasserted');
end;

procedure ReportHostFailure(Host: PBrcmPcieHost; Step: Integer; What: PChar);
var
  Status: LongWord;
begin
  DebugBeginMessage;
  DebugWriteTag('pcie');
  DebugWrite(Host^.Name);
  DebugWrite(': FAILED at step ');
  DebugWriteDecimal(Step);
  if (Step >= StepResources) and (Step <= StepLink) then
  begin
    DebugWrite(' (');
    DebugWrite(StepNames[Step]);
    DebugWrite(')');
  end;
  DebugWrite(': ');
  DebugWriteLine(What);

  DebugWriteTag('pcie');
  DebugWrite(Host^.Name);
  if Host^.BridgeInReset then
    DebugWrite(':   registers not read (the bridge is in reset)')
  else
  begin
    Status := ReadHostRegister(Host, PcieStatus);
    DebugWrite(':   status 0x');
    DebugWriteHex(Status, 2);
    DebugWrite(' (PHY link ');
    DebugWriteDecimal(Ord((Status and StatusPhyLinkUp) <> 0));
    DebugWrite(', data link ');
    DebugWriteDecimal(Ord((Status and StatusDataLinkActive) <> 0));
    DebugWrite(', RC mode ');
    DebugWriteDecimal(Ord((Status and StatusRootComplexMode) <> 0));
    DebugWrite('), ctrl 0x');
    DebugWriteHex(ReadHostRegister(Host, PcieControl), 1);
    DebugWrite(', debug 0x');
    DebugWriteHex(ReadHostRegister(Host, HardDebug2712), 8);
    DebugWrite(', misc 0x');
    DebugWriteHex(ReadHostRegister(Host, MiscControl), 8);
    DebugWrite(', rev 0x');
    DebugWriteHex(ReadHostRegister(Host, MiscRevision), 1);
  end;
  WriteBridgeLineState(Host);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ --- Step 1: resources --------------------------------------------------------- }

{ Looks up one line; False only if the node names it but it cannot be
  driven. }
function FindOneLine(Host: PBrcmPcieHost; Name: PChar; out Line: TResetLine; out Found: Boolean): Boolean;
var
  Problem: PChar;
begin
  Found := FindResetLine(Host^.Node, Name, Line, Problem);
  Result := Found or (Problem = nil);
  if not Result then
  begin
    DebugBeginMessage;
    DebugWriteTag('pcie');
    DebugWrite(Host^.Name);
    DebugWrite(': reset line "');
    DebugWrite(Name);
    DebugWrite('": ');
    DebugWriteLine(Problem);
    DebugEndMessage;
  end;
end;

procedure NoteUndrivenProperties(Host: PBrcmPcieHost);
const
  Names: array[0..4] of PChar = ('clocks', 'reset-gpios', 'pwr-gpios', 'vpcie3v3-supply', 'vpcie12v-supply');
var
  Index: Integer;
begin
  for Index := 0 to High(Names) do
    if NodeHasProperty(SystemDeviceTree^, Host^.Node, Names[Index]) then
    begin
      DebugBeginMessage;
      DebugWriteTag('pcie');
      DebugWrite(Host^.Name);
      DebugWrite(': "');
      DebugWrite(Names[Index]);
      DebugWriteLine('" is not driven; left as the firmware set it');
      DebugEndMessage;
    end;
end;

function FindHostResources(Host: PBrcmPcieHost): Boolean;
begin
  Result := FindOneLine(Host, 'bridge', Host^.BridgeLine, Host^.HasBridgeLine) and
    FindOneLine(Host, 'swinit', Host^.SwinitLine, Host^.HasSwinitLine) and
    FindOneLine(Host, 'rescal', Host^.RescalLine, Host^.HasRescalLine);
  if Result and Host^.HasBridgeLine and (Host^.BridgeLine.Kind <> ResetControllerStbLines) then
  begin
    ReportHost(Host, 'its "bridge" reset is not a brcm,brcmstb-reset line', -1);
    Result := False;
  end;
  if Result and Host^.HasSwinitLine and (Host^.SwinitLine.Kind <> ResetControllerStbLines) then
  begin
    ReportHost(Host, 'its "swinit" reset is not a brcm,brcmstb-reset line', -1);
    Result := False;
  end;
  if Result and Host^.HasRescalLine and (Host^.RescalLine.Kind <> ResetControllerRescal) then
  begin
    ReportHost(Host, 'its "rescal" reset is not a brcm,bcm7216-pcie-sata-rescal', -1);
    Result := False;
  end;
  if not Result then
  begin
    { Nothing known about the bridge: its registers stay untouched. }
    Host^.BridgeInReset := True;
    ReportHostFailure(Host, StepResources, 'a reset line the node names cannot be driven');
    Exit;
  end;
  NoteUndrivenProperties(Host);
end;

function BridgeIsHeldInReset(Host: PBrcmPcieHost): Boolean;
begin
  Result := Host^.HasBridgeLine and ResetLineIsAsserted(Host^.BridgeLine);
end;

{ --- The bridge reset ------------------------------------------------------------ }

{ Asserting marks the registers off limits until the deassert; nothing
  in between may touch them (the SW_INIT fallback is itself a register
  of the root complex, which still answers while it is set). }
procedure SetBridgeReset(Host: PBrcmPcieHost; Asserted: Boolean);
begin
  if Host^.HasBridgeLine then
  begin
    if Asserted then
    begin
      Host^.BridgeInReset := True;
      AssertResetLine(Host^.BridgeLine);
    end
    else
    begin
      DeassertResetLine(Host^.BridgeLine);
      Host^.BridgeInReset := False;
    end;
  end
  else
  begin
    if Asserted then
      ChangeHostRegister(Host, SoftwareInit1, 0, SoftwareInitGeneric)
    else
      ChangeHostRegister(Host, SoftwareInit1, SoftwareInitGeneric, 0);
    Host^.BridgeInReset := False;
  end;
  WaitMicroseconds(ResetSettleMicroseconds);
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

{ --- Step 5: BCM2712 tuning ----------------------------------------------------- }

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
  WaitMicroseconds(SerdesSettleMicroseconds);
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

{ Everything of step 5 but the SerDes: safe on a running link. }
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

{ --- Steps 2 to 5 --------------------------------------------------------------- }

function AspmToAdvertise(Host: PBrcmPcieHost): LongWord;
begin
  Result := AspmL1;
  if not NodeHasProperty(SystemDeviceTree^, Host^.Node, 'aspm-no-l0s') then
    Result := Result or AspmL0s;
end;

{ 2. Out of reset, a swinit pulse, SerDes calibrated. }
function ReleaseAndCalibrate(Host: PBrcmPcieHost): Boolean;
var
  Status: LongWord;
begin
  Result := False;
  SetBridgeReset(Host, False);
  if Host^.HasSwinitLine then
    PulseResetLine(Host^.SwinitLine, Status);
  if Host^.HasRescalLine and not PulseResetLine(Host^.RescalLine, Status) then
  begin
    ReportHost(Host, 'rescal status', Status);
    ReportHostFailure(Host, StepCalibration, 'the SerDes calibration did not finish within 1 ms');
    Exit;
  end;
  Result := True;
end;

{ 3. The bridge reset with no register access while it is asserted; then
  PERST# held and the SerDes powered. }
function CycleBridgeReset(Host: PBrcmPcieHost): Boolean;
var
  Revision: LongWord;
begin
  Result := False;
  SetBridgeReset(Host, True);
  SetBridgeReset(Host, False);
  if BridgeIsHeldInReset(Host) then
  begin
    Host^.BridgeInReset := True;
    ReportHostFailure(Host, StepBridgeReset, 'the bridge reset line does not deassert');
    Exit;
  end;
  Revision := ReadHostRegister(Host, MiscRevision);
  if (Revision = 0) or (Revision = $FFFFFFFF) then
  begin
    ReportHostFailure(Host, StepBridgeReset, 'the root complex does not answer after its reset');
    Exit;
  end;
  ChangeHostRegister(Host, PcieControl, PcieControlPerstDeasserted, 0);
  ChangeHostRegister(Host, HardDebug2712, HardDebugSerdesIddq, 0);
  WaitMicroseconds(SerdesSettleMicroseconds);
  ChangeHostRegister(Host, MiscControl, MiscControlMaximumBurstMask,
    MiscControlScbAccessEnable or MiscControlConfigReadUrMode or MiscControlRcbMpsMode or
    MiscControlRcb64Bytes or (MiscControlBurst512 shl MiscControlMaximumBurstShift));
  Result := True;
end;

{ 4. Windows and identity. }
function SetUpWindows(Host: PBrcmPcieHost): Boolean;
begin
  Result := False;
  if ProgramInboundWindows(Host) = 0 then
  begin
    ReportHostFailure(Host, StepWindows, 'the node has no usable dma-ranges');
    Exit;
  end;
  if (ReadHostRegister(Host, PcieStatus) and StatusRootComplexMode) = 0 then
  begin
    ReportHostFailure(Host, StepWindows, 'the controller is strapped as an endpoint (status bit 7 clear)');
    Exit;
  end;
  ChangeHostRegister(Host, PrivateLinkCapability, LinkCapabilityAspmMask,
    AspmToAdvertise(Host) shl LinkCapabilityAspmShift);
  ChangeHostRegister(Host, PrivateIdValue3, PrivateClassCodeMask, ClassCodePciBridge);
  ProgramOutboundWindows(Host);
  ChangeHostRegister(Host, VendorSpecificRegister1, VendorSpecificEndianBar2Mask, 0);
  Result := True;
end;

function ResetAndSetUpBridge(Host: PBrcmPcieHost): Boolean;
begin
  Result := False;
  if not ReleaseAndCalibrate(Host) or not CycleBridgeReset(Host) or not SetUpWindows(Host) then
    Exit;
  { 5. Tuning. }
  if not TuneSerdes(Host) then
  begin
    ReportHostFailure(Host, StepTuning, 'the SerDes MDIO bus did not take its 54 MHz clock settings within 200 us');
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

procedure LeaveHostDown(Host: PBrcmPcieHost);
begin
  if not Host^.BridgeInReset then
    ChangeHostRegister(Host, PcieControl, PcieControlPerstDeasserted, 0);
  ReportHost(Host, 'left down: no devices behind it (for pcie2: no RP1, so no USB, Ethernet or RP1 peripherals)', -1);
end;

{ --- Step 6 --------------------------------------------------------------------- }

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
    ReportHostFailure(Host, StepLink, 'no link 200 ms after PERST# was released');
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
