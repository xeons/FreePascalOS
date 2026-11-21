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
  The machine's core devices from a device tree, where ACPI's MADT,
  GTDT and FADT would say them (the HAL asks here when there are no ACPI
  tables):

  - the GIC: GICv2 ("arm,gic-400", "arm,cortex-a15-gic": distributor and
    CPU interface, the first two "reg" entries; a GICv2m frame below it,
    "arm,gic-v2m-frame", with its SPIs in "arm,msi-base-spi" and
    "arm,msi-num-spis" or else in the frame's own type register) and
    GICv3 ("arm,gic-v3": distributor and the first redistributor
    region, and an ITS below it, "arm,gic-v3-its");
  - the processors: /cpus/cpu@N with device_type "cpu", their "reg"
    being the MPIDR affinity, started by PSCI ("enable-method");
  - the generic timer ("arm,armv8-timer"): its interrupts are the
    secure and non-secure physical, the virtual (the kernel's) and the
    hypervisor timers, and "clock-frequency" if the firmware left
    CNTFRQ_EL0 unset;
  - PSCI ("arm,psci-1.0", "arm,psci-0.2", "arm,psci"): "method" "hvc"
    (QEMU at EL1) or "smc" (QEMU with EL2, a Raspberry Pi's TF-A); PSCI
    0.1 names its own CPU_ON function id.

  Plain Pascal, built by the host test.
}
unit Firmware.DeviceTreeMachine;

{$mode objfpc}

interface

const
  MaximumDeviceTreeProcessors = 64;

type
  TDeviceTreeGic = record
    { 2 or 3; 0 if there is none. }
    Version: Byte;
    DistributorAddress: QWord;
    CpuInterfaceAddress: QWord;
    RedistributorAddress: QWord;
    { The first redistributor region's size, and the first ITS
      ("arm,gic-v3-its" below the GIC), 0 if none. }
    RedistributorSize: QWord;
    ItsAddress: QWord;
    MessageFrameAddress: QWord;
    { 0 if the tree does not say: read the frame's type register. }
    MessageFrameFirstSpi: LongWord;
    MessageFrameSpiCount: LongWord;
  end;

  TDeviceTreeTimer = record
    { The virtual timer's INTID. }
    Intid: LongWord;
    LevelTriggered: Boolean;
    { "clock-frequency", 0 if not given. }
    Frequency: LongWord;
  end;

  TDeviceTreePsci = record
    UseHypervisorCall: Boolean;
    CpuOnFunction: LongWord;
  end;

  { A processor idle state ("arm,idle-state" under /cpus/idle-states). }
  TDeviceTreeIdleState = record
    { arm,psci-suspend-param: the PSCI CPU_SUSPEND power state. }
    PowerState: LongWord;
    EntryLatencyMicroseconds: LongWord;
    ExitLatencyMicroseconds: LongWord;
    MinimumResidencyMicroseconds: LongWord;
    { local-timer-stop: the processor's timer stops in it. }
    StopsLocalTimer: Boolean;
  end;

function DescribeDeviceTreeGic(out Gic: TDeviceTreeGic): Boolean;
function DescribeDeviceTreeTimer(out Timer: TDeviceTreeTimer): Boolean;
function DescribeDeviceTreePsci(out Psci: TDeviceTreePsci): Boolean;
{ The processors that can be started: their MPIDR affinities
  (Aff2.Aff1.Aff0), the boot processor among them. Returns the count. }
function ListDeviceTreeProcessors(var Affinities: array of LongWord): Integer;
{ The idle states the tree describes (those with a PSCI power state).
  Returns the count. }
function ListDeviceTreeIdleStates(var States: array of TDeviceTreeIdleState): Integer;

implementation

uses
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.DeviceTree,
  Firmware.DeviceTreeInterrupts;

const
  PsciStandardCpuOn = $C4000003;
  VirtualTimerIndex = 2;
  AffinityMask = $FFFFFF;

function FindFirstCompatible(Compatible: PChar): LongInt;
begin
  Result := FindCompatibleNode(SystemDeviceTree^, NoNode, Compatible);
end;

function FindGicNode(out Version: Byte): LongInt;
begin
  Version := 2;
  Result := FindFirstCompatible('arm,gic-400');
  if Result = NoNode then
    Result := FindFirstCompatible('arm,cortex-a15-gic');
  if Result = NoNode then
    Result := FindFirstCompatible('arm,gic-v2');
  if Result = NoNode then
    Result := FindFirstCompatible('arm,cortex-a9-gic');
  if Result = NoNode then
  begin
    Version := 3;
    Result := FindFirstCompatible('arm,gic-v3');
  end;
  if Result = NoNode then
    Version := 0;
end;

procedure DescribeMessageFrame(var Gic: TDeviceTreeGic);
var
  Tree: PDeviceTree;
  Frame: LongInt;
  Size: QWord;
begin
  Tree := SystemDeviceTree;
  Frame := FindFirstCompatible('arm,gic-v2m-frame');
  if (Frame = NoNode) or not NodeRegisterPhysical(Tree^, Frame, 0, Gic.MessageFrameAddress, Size) then
  begin
    Gic.MessageFrameAddress := 0;
    Exit;
  end;
  if not ReadCellProperty(Tree^, Frame, 'arm,msi-base-spi', Gic.MessageFrameFirstSpi) or
     not ReadCellProperty(Tree^, Frame, 'arm,msi-num-spis', Gic.MessageFrameSpiCount) then
  begin
    Gic.MessageFrameFirstSpi := 0;
    Gic.MessageFrameSpiCount := 0;
  end;
end;

procedure DescribeTranslationService(var Gic: TDeviceTreeGic);
var
  Its: LongInt;
  Size: QWord;
begin
  Its := FindFirstCompatible('arm,gic-v3-its');
  if (Its = NoNode) or not NodeRegisterPhysical(SystemDeviceTree^, Its, 0, Gic.ItsAddress, Size) then
    Gic.ItsAddress := 0;
end;

function DescribeDeviceTreeGic(out Gic: TDeviceTreeGic): Boolean;
var
  Tree: PDeviceTree;
  Node: LongInt;
  Size: QWord;
  SecondAddress: QWord;
begin
  Tree := SystemDeviceTree;
  Gic.Version := 0;
  Gic.DistributorAddress := 0;
  Gic.CpuInterfaceAddress := 0;
  Gic.RedistributorAddress := 0;
  Gic.RedistributorSize := 0;
  Gic.ItsAddress := 0;
  Gic.MessageFrameAddress := 0;
  Gic.MessageFrameFirstSpi := 0;
  Gic.MessageFrameSpiCount := 0;
  Result := False;
  Node := FindGicNode(Gic.Version);
  if (Node = NoNode) or not NodeRegisterPhysical(Tree^, Node, 0, Gic.DistributorAddress, Size) or
     not NodeRegisterPhysical(Tree^, Node, 1, SecondAddress, Size) then
  begin
    Gic.Version := 0;
    Exit;
  end;
  if Gic.Version = 2 then
    Gic.CpuInterfaceAddress := SecondAddress
  else
  begin
    Gic.RedistributorAddress := SecondAddress;
    Gic.RedistributorSize := Size;
    DescribeTranslationService(Gic);
  end;
  DescribeMessageFrame(Gic);
  Result := True;
end;

function DescribeDeviceTreeTimer(out Timer: TDeviceTreeTimer): Boolean;
var
  Tree: PDeviceTree;
  Node: LongInt;
  Gic: TGicInterrupt;
begin
  Tree := SystemDeviceTree;
  Timer.Intid := 0;
  Timer.LevelTriggered := True;
  Timer.Frequency := 0;
  Node := FindFirstCompatible('arm,armv8-timer');
  if Node = NoNode then
    Node := FindFirstCompatible('arm,armv7-timer');
  Result := (Node <> NoNode) and NodeGicInterrupt(Tree^, Node, VirtualTimerIndex, Gic);
  if not Result then
    Exit;
  Timer.Intid := Gic.Intid;
  Timer.LevelTriggered := Gic.LevelTriggered;
  if not ReadCellProperty(Tree^, Node, 'clock-frequency', Timer.Frequency) then
    Timer.Frequency := 0;
end;

function DescribeDeviceTreePsci(out Psci: TDeviceTreePsci): Boolean;
var
  Tree: PDeviceTree;
  Node: LongInt;
  Method: PChar;
begin
  Tree := SystemDeviceTree;
  Psci.UseHypervisorCall := False;
  Psci.CpuOnFunction := PsciStandardCpuOn;
  Result := False;
  Node := FindFirstCompatible('arm,psci-1.0');
  if Node = NoNode then
    Node := FindFirstCompatible('arm,psci-0.2');
  if Node = NoNode then
  begin
    Node := FindFirstCompatible('arm,psci');
    if (Node <> NoNode) and not ReadCellProperty(Tree^, Node, 'cpu_on', Psci.CpuOnFunction) then
      Exit;
  end;
  if Node = NoNode then
    Exit;
  Method := ReadTextProperty(Tree^, Node, 'method');
  if DeviceTreeTextIsEqual(Method, 'hvc') then
    Psci.UseHypervisorCall := True
  else if not DeviceTreeTextIsEqual(Method, 'smc') then
    Exit;
  Result := True;
end;

function ListDeviceTreeProcessors(var Affinities: array of LongWord): Integer;
var
  Tree: PDeviceTree;
  Cpus: LongInt;
  Node: LongInt;
  AddressCells: LongWord;
  Prop: TDeviceTreeProperty;
  Affinity: LongWord;
  Method: PChar;
begin
  Result := 0;
  Tree := SystemDeviceTree;
  Cpus := FindNodeByPath(Tree^, '/cpus');
  if Cpus = NoNode then
    Exit;
  AddressCells := NodeAddressCells(Tree^, Cpus);
  Node := FirstChildNode(Tree^, Cpus);
  while (Node <> NoNode) and (Result <= High(Affinities)) do
  begin
    if NodeHasDeviceType(Tree^, Node, 'cpu') and NodeIsEnabled(Tree^, Node) and
       FindProperty(Tree^, Node, 'reg', Prop) and (AddressCells >= 1) and
       (PropertyCellCount(Prop) >= AddressCells) then
    begin
      Affinity := LongWord(ReadCells(Prop.Value, AddressCells) and AffinityMask);
      Method := ReadTextProperty(Tree^, Node, 'enable-method');
      { Only PSCI starts processors here (spin tables are not driven);
        one without a method is the one already running. }
      if (Method = nil) or DeviceTreeTextIsEqual(Method, 'psci') then
      begin
        Affinities[Result] := Affinity;
        Inc(Result);
      end;
    end;
    Node := NextSiblingNode(Tree^, Node);
  end;
end;

function ListDeviceTreeIdleStates(var States: array of TDeviceTreeIdleState): Integer;
var
  Tree: PDeviceTree;
  Node: LongInt;
  State: TDeviceTreeIdleState;
begin
  Result := 0;
  Tree := SystemDeviceTree;
  if Tree = nil then
    Exit;
  Node := FindCompatibleNode(Tree^, NoNode, 'arm,idle-state');
  while (Node <> NoNode) and (Result <= High(States)) do
  begin
    if ReadCellProperty(Tree^, Node, 'arm,psci-suspend-param', State.PowerState) then
    begin
      if not ReadCellProperty(Tree^, Node, 'entry-latency-us', State.EntryLatencyMicroseconds) then
        State.EntryLatencyMicroseconds := 0;
      if not ReadCellProperty(Tree^, Node, 'exit-latency-us', State.ExitLatencyMicroseconds) then
        State.ExitLatencyMicroseconds := 0;
      if not ReadCellProperty(Tree^, Node, 'min-residency-us', State.MinimumResidencyMicroseconds) then
        State.MinimumResidencyMicroseconds := 0;
      State.StopsLocalTimer := NodeHasProperty(Tree^, Node, 'local-timer-stop');
      States[Result] := State;
      Inc(Result);
    end;
    Node := FindCompatibleNode(Tree^, Node, 'arm,idle-state');
  end;
end;

end.
