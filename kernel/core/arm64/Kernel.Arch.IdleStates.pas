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
  nodes, arm,psci-suspend-param, with their latencies). Only standby
  (retention) states are used: the processor keeps its registers and
  the call returns once an interrupt is pending, as WFI does. Power-down
  states would lose the processor's state and return through an entry
  point, and states whose timer stops (local-timer-stop) would need
  another processor to keep time for it: neither is used. The firmware
  must offer CPU_SUSPEND (PSCI_FEATURES). idle=wfi keeps to WFI.
}
unit Kernel.Arch.IdleStates;

{$mode objfpc}

interface

uses
  Kernel.IdleStateDefinitions;

{ Fills States (from index 0) with this processor's idle states;
  returns how many. }
function ArchDiscoverIdleStates(var States: array of TIdleState): Integer;
{ Waits in State until an interrupt (interrupts enabled), on the
  processor numbered ProcessorIndex. }
procedure ArchEnterIdleState(constref State: TIdleState; ProcessorIndex: LongWord);

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Kernel.Arch.Cpu,
  Kernel.Options,
  Firmware.DeviceTreeMachine,
  Hal.FirmwareTables,
  Hal.Psci;

const
  NanosecondsPerMicrosecond = 1000;
  { The state type: power-down rather than standby. }
  OriginalFormatPowerDown = LongWord(1) shl 16;
  ExtendedFormatPowerDown = LongWord(1) shl 30;
  MaximumTreeStates = 8;

function OptionIs(Name, Value: PChar): Boolean;
var
  Text: array[0..15] of Char;
begin
  Result := GetKernelOptionValue(Name, @Text[0], SizeOf(Text)) and TextIsEqual(@Text[0], Value);
end;

procedure DescribeTreeState(var State: TIdleState; constref TreeState: TDeviceTreeIdleState; Number: Integer);
begin
  ZeroMemory(@State, SizeOf(State));
  CopyText(@State.Name[0], 'PSCI standby n', IdleStateNameCapacity);
  State.Name[13] := Char(Ord('0') + Number);
  State.Method := IdleMethodFirmwareSuspend;
  State.Parameter := TreeState.PowerState;
  State.ExitLatencyNanoseconds := QWord(TreeState.ExitLatencyMicroseconds) * NanosecondsPerMicrosecond;
  State.TargetResidencyNanoseconds := QWord(TreeState.MinimumResidencyMicroseconds) * NanosecondsPerMicrosecond;
  if State.TargetResidencyNanoseconds < QWord(TreeState.EntryLatencyMicroseconds +
     TreeState.ExitLatencyMicroseconds) * NanosecondsPerMicrosecond then
    State.TargetResidencyNanoseconds := QWord(TreeState.EntryLatencyMicroseconds +
      TreeState.ExitLatencyMicroseconds) * NanosecondsPerMicrosecond;
end;

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

  if OptionIs('idle', 'wfi') or not FirmwareDeviceTreeIsPresent then
    Exit;
  if not PsciOffersProcessorSuspend(Extended) then
    Exit;
  if Extended then
    PowerDownBit := ExtendedFormatPowerDown
  else
    PowerDownBit := OriginalFormatPowerDown;
  TreeCount := ListDeviceTreeIdleStates(TreeStates);
  Index := 0;
  while (Index < TreeCount) and (Result <= High(States)) do
  begin
    if ((TreeStates[Index].PowerState and PowerDownBit) = 0) and not TreeStates[Index].StopsLocalTimer then
    begin
      DescribeTreeState(States[Result], TreeStates[Index], Result);
      Inc(Result);
    end;
    Inc(Index);
  end;
end;

procedure ArchEnterIdleState(constref State: TIdleState; ProcessorIndex: LongWord);
begin
  if (State.Method <> IdleMethodFirmwareSuspend) or not PsciSuspendProcessor(State.Parameter) then
    HaltProcessor;
end;

end.
