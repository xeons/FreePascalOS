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
  The idle states of an AArch64 processor.

  State 0 is WFI. Deeper ones are the firmware's: PSCI CPU_SUSPEND with
  a power state the device tree's idle states give ("arm,idle-state"
  nodes, arm,psci-suspend-param, with their latencies). The firmware
  must offer CPU_SUSPEND (PSCI_FEATURES). idle=wfi keeps to WFI.
  - Standby (retention) states: the processor keeps its registers and
    the call returns once an interrupt is pending, as WFI does.
  - Power-down states: the processor loses its registers, its timer and
    its interrupt controller interface. Its state is saved first
    (Kernel.Arch.Suspend, as for suspend to RAM) and CPU_SUSPEND is
    given the start-up entry and a start-up record of its own
    (PrepareIdleWakeEntry); an interrupt brings it back there, where it
    sets itself up again (translation, vectors, block, the GIC) and
    resumes the saved state: the saving call returns a second time. The
    firmware may take a shallower state instead and simply return,
    registers kept. These states, and standby states whose timer stops
    (local-timer-stop), are marked as stopping the timer: the boot
    processor wakes them when due (Kernel.BroadcastTimer).
  - idle=powerdown-test: QEMU powers nothing down (its CPU_SUSPEND is a
    WFI), so a WFI power-down state is made up and entered by turning
    the processor off (CPU_OFF); whatever would wake it starts it again
    with CPU_ON through the same entry (Kernel.BroadcastTimer), so the
    way back from a lost state is tested.
}
unit Kernel.Arch.IdleStates;

{$mode objfpc}

interface

uses
  Kernel.IdleStateDefinitions;

{ Fills States (from index 0) with this processor's idle states;
  returns how many. }
function ArchDiscoverIdleStates(var States: array of TIdleState): Integer;
{ Waits in State until an interrupt, on the processor numbered
  ProcessorIndex. Called with interrupts disabled; they are enabled by
  the wait itself, so one that came since the caller disabled them
  ends it at once (and is taken on return). }
procedure ArchEnterIdleState(constref State: TIdleState; ProcessorIndex: LongWord);
{ ACPI's _CST states are x86-64's: none is taken here. }
function ArchIdleStateFromFirmware(CStateType, Entry, Parameter, LatencyMicroseconds: LongWord;
  out State: TIdleState): Boolean;
{ _PDC/_OSC are x86-64's: no capabilities. }
function ArchProcessorCapabilities: LongWord;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Kernel.Arch.Cpu,
  Kernel.Arch.Suspend,
  Kernel.Arch.ProcessorStartup,
  Kernel.Processors,
  Kernel.BroadcastTimer,
  Kernel.InterProcessor,
  Kernel.Options,
  Kernel.PriorityLevel,
  Firmware.DeviceTreeMachine,
  Hal.FirmwareTables,
  Hal.Platform,
  Hal.GenericTimer,
  Hal.Psci;

const
  NanosecondsPerMicrosecond = 1000;
  { The state type: power-down rather than standby. }
  OriginalFormatPowerDown = LongWord(1) shl 16;
  ExtendedFormatPowerDown = LongWord(1) shl 30;
  MaximumTreeStates = 8;
  { TIdleState.Parameter of the made-up state of idle=powerdown-test. }
  TestPowerDownState = High(LongWord);

var
  PowerDownTest: Boolean = False;

function OptionIs(Name, Value: PChar): Boolean;
var
  Text: array[0..15] of Char;
begin
  Result := GetKernelOptionValue(Name, @Text[0], SizeOf(Text)) and TextIsEqual(@Text[0], Value);
end;

procedure DescribeTreeState(var State: TIdleState; constref TreeState: TDeviceTreeIdleState; Number: Integer;
  PowerDown: Boolean);
begin
  ZeroMemory(@State, SizeOf(State));
  if PowerDown then
  begin
    CopyText(@State.Name[0], 'PSCI off n', IdleStateNameCapacity);
    State.Name[9] := Char(Ord('0') + Number);
    State.Flags := IdleStateStopsTimer or IdleStateLosesContext;
  end
  else
  begin
    CopyText(@State.Name[0], 'PSCI standby n', IdleStateNameCapacity);
    State.Name[13] := Char(Ord('0') + Number);
    if TreeState.StopsLocalTimer then
      State.Flags := IdleStateStopsTimer;
  end;
  State.Method := IdleMethodFirmwareSuspend;
  State.Parameter := TreeState.PowerState;
  State.ExitLatencyNanoseconds := QWord(TreeState.ExitLatencyMicroseconds) * NanosecondsPerMicrosecond;
  State.TargetResidencyNanoseconds := QWord(TreeState.MinimumResidencyMicroseconds) * NanosecondsPerMicrosecond;
  if State.TargetResidencyNanoseconds < QWord(TreeState.EntryLatencyMicroseconds +
     TreeState.ExitLatencyMicroseconds) * NanosecondsPerMicrosecond then
    State.TargetResidencyNanoseconds := QWord(TreeState.EntryLatencyMicroseconds +
      TreeState.ExitLatencyMicroseconds) * NanosecondsPerMicrosecond;
end;

function PowerUpProcessor(Processor: PProcessor): Boolean; forward;

function ArchDiscoverIdleStates(var States: array of TIdleState): Integer;
var
  TreeStates: array[0..MaximumTreeStates - 1] of TDeviceTreeIdleState;
  TreeCount: Integer;
  Index: Integer;
  Extended: Boolean;
  PowerDownBit: LongWord;
begin
  ZeroMemory(@States[0], SizeOf(TIdleState));
  CopyText(@States[0].Name[0], 'WFI', IdleStateNameCapacity);
  States[0].Method := IdleMethodHalt;
  States[0].ExitLatencyNanoseconds := NanosecondsPerMicrosecond;
  Result := 1;

  if OptionIs('idle', 'wfi') then
    Exit;
  if OptionIs('idle', 'powerdown-test') and PsciIsAvailable then
  begin
    PowerDownTest := True;
    SetPowerUpRoutine(@PowerUpProcessor);
    ZeroMemory(@States[1], SizeOf(TIdleState));
    CopyText(@States[1].Name[0], 'off (test)', IdleStateNameCapacity);
    States[1].Method := IdleMethodFirmwareSuspend;
    States[1].Parameter := TestPowerDownState;
    States[1].Flags := IdleStateStopsTimer or IdleStateLosesContext;
    States[1].ExitLatencyNanoseconds := 100 * NanosecondsPerMicrosecond;
    States[1].TargetResidencyNanoseconds := 10000 * NanosecondsPerMicrosecond;
    Exit(2);
  end;
  if not FirmwareDeviceTreeIsPresent or not PsciOffersProcessorSuspend(Extended) then
    Exit;
  if Extended then
    PowerDownBit := ExtendedFormatPowerDown
  else
    PowerDownBit := OriginalFormatPowerDown;
  TreeCount := ListDeviceTreeIdleStates(TreeStates);
  Index := 0;
  while (Index < TreeCount) and (Result <= High(States)) do
  begin
    DescribeTreeState(States[Result], TreeStates[Index], Result,
      (TreeStates[Index].PowerState and PowerDownBit) <> 0);
    Inc(Result);
    Inc(Index);
  end;
end;

procedure IdleWakeEntry(Processor: PProcessor); forward;

{ idle=powerdown-test's way back up: CPU_ON through the entry. }
function PowerUpProcessor(Processor: PProcessor): Boolean;
var
  Entry: QWord;
  Context: QWord;
begin
  Entry := PrepareIdleWakeEntry(Processor, @IdleWakeEntry, Context);
  Result := (Entry <> 0) and HalStartProcessorAt(Processor^.ApicId, Entry, Context);
end;

{ Where a processor that powered down comes back (on its own small
  stack, translation on): set up again, then the saved state resumed
  inside ArchEnterIdleState. Its timer is set again by the idle loop. }
procedure IdleWakeEntry(Processor: PProcessor);
begin
  ReinitializeThisProcessor(Processor);
  HalInitializeSecondaryProcessor;
  { Lost with the power: programs read the virtual counter for the
    clock page (the timer itself is set again by the idle loop). }
  AllowUserCounterReads;
  if PowerDownTest then
  begin
    NotePoweredUp(Processor);
    { Its translations went with the power. }
    ResumeAnsweringRequests;
  end;
  ArchResumeSuspendContext(Processor^.SuspendContext);
end;

{ The made-up state: the processor turns itself off. }
function ArchReadPendingInterrupts: QWord; external name 'ArchReadPendingInterrupts';

procedure TurnOffForTest(Processor: PProcessor);
const
  PendingIrq = $80;
begin
  { Shootdowns skip it while off; it flushes its TLB when back. }
  StopAnsweringRequests;
  NotePoweredDown(Processor);
  if not PowerDownMayProceed(Processor, (ArchReadPendingInterrupts and PendingIrq) <> 0) then
  begin
    ResumeAnsweringRequests;
    Exit;
  end;
  DataSynchronizationBarrier;
  PsciTurnOffThisProcessor;
  { Refused: still on, state kept. }
  NotePoweredUp(Processor);
  ResumeAnsweringRequests;
end;

{ A power-down state: True if the processor came back with its state
  (resumed, or the firmware took a shallower state). }
procedure EnterPowerDownState(constref State: TIdleState);
var
  Processor: PProcessor;
  Entry: QWord;
  Context: QWord;
begin
  Processor := CurrentProcessor;
  if ArchSaveSuspendContext(Processor^.SuspendContext) <> 0 then
  begin
    { Back through the entry: resumed. Whatever woke it may have been
      a thread made ready for it (the test's CPU_ON sends no dispatch
      interrupt): the scheduler looks once interrupts are on. }
    HalRequestSoftwareInterrupt(DispatchLevel);
    Exit;
  end;
  if State.Parameter = TestPowerDownState then
  begin
    TurnOffForTest(Processor);
    Exit;
  end;
  Entry := PrepareIdleWakeEntry(Processor, @IdleWakeEntry, Context);
  if (Entry = 0) or not PsciSuspendProcessorAt(State.Parameter, Entry, Context) then
    { Refused: a plain wait instead (interrupts are enabled after). }
    EnableInterruptsAndHalt;
end;

{ A standby state, like WFI, returns for a pending interrupt even while
  PSTATE.I masks it; it is taken once they are enabled again. }
procedure ArchEnterIdleState(constref State: TIdleState; ProcessorIndex: LongWord);
begin
  if (State.Flags and IdleStateLosesContext) <> 0 then
  begin
    EnterPowerDownState(State);
    EnableInterrupts;
  end
  else if (State.Method = IdleMethodFirmwareSuspend) and PsciSuspendProcessor(State.Parameter) then
    EnableInterrupts
  else
    EnableInterruptsAndHalt;
end;

function ArchIdleStateFromFirmware(CStateType, Entry, Parameter, LatencyMicroseconds: LongWord;
  out State: TIdleState): Boolean;
begin
  ZeroMemory(@State, SizeOf(State));
  Result := False;
end;

function ArchProcessorCapabilities: LongWord;
begin
  Result := 0;
end;

end.
