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
  The idle states of an x86-64 processor.

  State 0 is HLT. Deeper ones are entered with MONITOR/MWAIT and a
  C-state hint: CPUID leaf 5 says how many sub-states each MWAIT C-state
  has (EDX, four bits per state from C0), and the hint for C(n) is
  (n - 1) shl 4 with sub-state 0. Their exit latencies are not told by
  the processor; typical figures stand in, until ACPI's _CST (read once
  the namespace is loaded, Io.AcpiProcessorIdle) gives the firmware's
  own hints and latencies.

  ACPI's _CST may also list states entered by reading an I/O port (the
  chipset's P_LVLx registers, older machines): read with interrupts
  disabled, the chipset ends the state at the next interrupt, which is
  taken once they are enabled again.

  Deeper states are only used where it is safe:
  - not under a hypervisor (it decides itself what a halt is; QEMU's
    emulation reports MONITOR but its MWAIT does not sleep with several
    processors, and a port read there only exits to it), unless
    idle=mwait (or idle=port for port states) asks for them;
  - the time stamp counter is invariant (it is the kernel's clock, and
    stops in deep states otherwise);
  - CPUID 5 states its monitor line size and that interrupts end MWAIT.
  Where the local APIC timer does not keep running in deep states (no
  ARAT, CPUID 6 EAX bit 2) every state deeper than C1 is marked as
  stopping it (IdleStateStopsTimer): the boot processor's clock then
  wakes the processors in them (Kernel.BroadcastTimer).
  idle=halt keeps to HLT; maxcstate=N stops at C(N).
}
unit Kernel.Arch.IdleStates;

{$mode objfpc}
{$asmmode intel}

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
{ A state the firmware lists (ACPI _CST: its C-state type, how it is
  entered - AcpiIdleEntry* - with its MWAIT hint or port, and its exit
  latency) as one of ours; False if it may not be used. }
function ArchIdleStateFromFirmware(CStateType, Entry, Parameter, LatencyMicroseconds: LongWord;
  out State: TIdleState): Boolean;
{ The capabilities to tell the firmware in _PDC/_OSC (Intel's processor
  driver capability bits). }
function ArchProcessorCapabilities: LongWord;

implementation

uses
  Runtime.Text,
  Runtime.Memory,
  Kernel.Arch.Cpu,
  Kernel.Options,
  Hal.PortIo,
  Hal.TimeStampClock;

const
  CpuidFeatures = 1;
  CpuidMonitorWait = 5;
  CpuidThermalPower = 6;
  FeatureMonitorBit = LongWord(1) shl 3;
  FeatureHypervisorBit = LongWord(1) shl 31;
  MonitorWaitExtensionsBit = 1;
  MonitorWaitInterruptBreakBit = 2;
  AlwaysRunningApicTimerBit = 4;
  { MWAIT C-states C1 to C7 (leaf 5 counts sub-states up to C7). }
  DeepestMonitorWaitState = 7;
  NanosecondsPerMicrosecond = 1000;
  { Typical exit latencies of MWAIT C2 to C7, in microseconds (C1E,
    C3, C6, C7, C8/C9, C10 on recent Intel processors). }
  TypicalExitLatency: array[2..DeepestMonitorWaitState] of LongWord = (10, 80, 150, 250, 500, 1000);
  { Staying less than this many times the exit latency is not worth the
    trip. }
  ResidencyFactor = 3;

type
  { One cache line per processor to monitor: nothing writes it, the
    interrupts that end the idle wait (IPIs among them) wake it. }
  TMonitorLine = record
    Words: array[0..7] of QWord;
  end;

var
  MonitorLines: array[0..63] of TMonitorLine;
  MonitorWaitUsable: Boolean = False;
  DeepestAllowed: LongWord = 7;
  TimerKeepsRunning: Boolean = False;
  PortStatesUsable: Boolean = False;

{ Called with interrupts disabled: STI takes effect only after the next
  instruction, so MWAIT starts before any interrupt can be taken, and a
  pending one ends it. }
procedure EnableInterruptsMonitorAndWait(Address: Pointer; Hint: LongWord); assembler; nostackframe;
asm
  mov rax, rdi
  xor ecx, ecx
  xor edx, edx
  { monitor rax, ecx, edx }
  db $0F, $01, $C8
  mov eax, esi
  xor ecx, ecx
  sti
  { mwait eax, ecx }
  db $0F, $01, $C9
end;

function OptionIs(Name, Value: PChar): Boolean;
var
  Text: array[0..15] of Char;
begin
  Result := GetKernelOptionValue(Name, @Text[0], SizeOf(Text)) and TextIsEqual(@Text[0], Value);
end;

procedure NameState(var State: TIdleState; Number: LongWord);
begin
  CopyText(@State.Name[0], 'Cn (MWAIT)', IdleStateNameCapacity);
  State.Name[1] := Char(Ord('0') + Number);
end;

function DecideMonitorWait: Boolean;
var
  Registers: TCpuidResult;
  Hypervisor: Boolean;
begin
  Result := False;
  if OptionIs('idle', 'halt') then
    Exit;
  ExecuteCpuid(0, 0, Registers);
  if Registers.Eax < CpuidThermalPower then
    Exit;
  ExecuteCpuid(CpuidFeatures, 0, Registers);
  if (Registers.Ecx and FeatureMonitorBit) = 0 then
    Exit;
  Hypervisor := (Registers.Ecx and FeatureHypervisorBit) <> 0;
  if Hypervisor and not OptionIs('idle', 'mwait') then
    Exit;
  ExecuteCpuid(CpuidMonitorWait, 0, Registers);
  if (Registers.Eax and $FFFF) = 0 then
    Exit;
  if (Registers.Ecx and (MonitorWaitExtensionsBit or MonitorWaitInterruptBreakBit)) <>
     (MonitorWaitExtensionsBit or MonitorWaitInterruptBreakBit) then
    Exit;
  if not TimeStampCounterIsInvariant then
    Exit;
  Result := True;
end;

{ Things the deeper states need to know, whichever way they come. }
procedure ExamineProcessor;
var
  Registers: TCpuidResult;
  Hypervisor: Boolean;
begin
  ExecuteCpuid(0, 0, Registers);
  if Registers.Eax >= CpuidThermalPower then
  begin
    ExecuteCpuid(CpuidThermalPower, 0, Registers);
    TimerKeepsRunning := (Registers.Eax and AlwaysRunningApicTimerBit) <> 0;
  end;
  ExecuteCpuid(CpuidFeatures, 0, Registers);
  Hypervisor := (Registers.Ecx and FeatureHypervisorBit) <> 0;
  PortStatesUsable := not OptionIs('idle', 'halt') and TimeStampCounterIsInvariant and
    (not Hypervisor or OptionIs('idle', 'port'));
end;

function TimerFlags: LongWord;
begin
  if TimerKeepsRunning then
    Result := 0
  else
    Result := IdleStateStopsTimer;
end;

function ArchProcessorCapabilities: LongWord;
const
  CapabilityPerformanceFixedHardware = $0001;
  CapabilityHaltC1 = $0002;
  CapabilityMultiprocessorC1 = $0008;
  CapabilityMultiprocessorC2C3 = $0010;
  CapabilitySoftwareCoordinatedP = $0020;
  CapabilitySoftwareCoordinatedC = $0040;
  CapabilityC1FixedHardware = $0100;
  CapabilityC2C3FixedHardware = $0200;
begin
  Result := CapabilityPerformanceFixedHardware or CapabilityHaltC1 or CapabilityMultiprocessorC1 or
    CapabilityMultiprocessorC2C3 or CapabilitySoftwareCoordinatedP or CapabilitySoftwareCoordinatedC;
  if MonitorWaitUsable then
    Result := Result or CapabilityC1FixedHardware or CapabilityC2C3FixedHardware;
end;

function ArchDiscoverIdleStates(var States: array of TIdleState): Integer;
var
  Registers: TCpuidResult;
  Number: LongWord;
  SubStates: LongWord;
  Limit: QWord;
begin
  ZeroMemory(@States[0], SizeOf(TIdleState));
  CopyText(@States[0].Name[0], 'C1 (HLT)', IdleStateNameCapacity);
  States[0].Method := IdleMethodHalt;
  States[0].ExitLatencyNanoseconds := NanosecondsPerMicrosecond;
  Result := 1;

  ExamineProcessor;
  DeepestAllowed := DeepestMonitorWaitState;
  if GetKernelOptionNumber('maxcstate', Limit) and (Limit < DeepestAllowed) then
    DeepestAllowed := LongWord(Limit);
  MonitorWaitUsable := DecideMonitorWait;
  if not MonitorWaitUsable then
    Exit;

  ExecuteCpuid(CpuidMonitorWait, 0, Registers);
  Number := 2;
  while (Number <= DeepestAllowed) and (Result <= High(States)) do
  begin
    SubStates := (Registers.Edx shr (Number * 4)) and $F;
    if SubStates > 0 then
    begin
      ZeroMemory(@States[Result], SizeOf(TIdleState));
      NameState(States[Result], Number);
      States[Result].Method := IdleMethodMonitorWait;
      States[Result].Parameter := (Number - 1) shl 4;
      States[Result].Flags := TimerFlags;
      States[Result].ExitLatencyNanoseconds := QWord(TypicalExitLatency[Number]) * NanosecondsPerMicrosecond;
      States[Result].TargetResidencyNanoseconds := States[Result].ExitLatencyNanoseconds * ResidencyFactor;
      Inc(Result);
    end;
    Inc(Number);
  end;
end;

procedure ArchEnterIdleState(constref State: TIdleState; ProcessorIndex: LongWord);
begin
  case State.Method of
    IdleMethodMonitorWait:
      EnableInterruptsMonitorAndWait(@MonitorLines[ProcessorIndex and High(MonitorLines)], State.Parameter);
    IdleMethodPortRead:
      begin
        { The read enters the state; an interrupt (still pending, as
          they are disabled) ends it. }
        ReadPortByte(Word(State.Parameter));
        EnableInterrupts;
      end;
  else
    EnableInterruptsAndHalt;
  end;
end;

function PortStateFromFirmware(CStateType, Port, LatencyMicroseconds: LongWord; out State: TIdleState): Boolean;
begin
  Result := PortStatesUsable and (CStateType >= 2) and (CStateType <= DeepestAllowed) and (Port <= $FFFF);
  if not Result then
    Exit;
  CopyText(@State.Name[0], 'Cn (port)', IdleStateNameCapacity);
  State.Name[1] := Char(Ord('0') + CStateType);
  State.Method := IdleMethodPortRead;
  State.Parameter := Port;
  State.Flags := TimerFlags;
  State.ExitLatencyNanoseconds := QWord(LatencyMicroseconds) * NanosecondsPerMicrosecond;
  State.TargetResidencyNanoseconds := State.ExitLatencyNanoseconds * ResidencyFactor;
end;

function ArchIdleStateFromFirmware(CStateType, Entry, Parameter, LatencyMicroseconds: LongWord;
  out State: TIdleState): Boolean;
const
  EntryPortRead = 1;
var
  Number: LongWord;
  Hint: LongWord;
begin
  ZeroMemory(@State, SizeOf(State));
  if Entry = EntryPortRead then
    Exit(PortStateFromFirmware(CStateType, Parameter, LatencyMicroseconds, State));
  Hint := Parameter;
  Number := ((Hint shr 4) and $F) + 1;
  Result := MonitorWaitUsable and (CStateType >= 2) and (Number >= 2) and (Number <= DeepestAllowed);
  if not Result then
    Exit;
  NameState(State, Number);
  State.Name[4] := 'A';
  State.Name[5] := 'C';
  State.Name[6] := 'P';
  State.Name[7] := 'I';
  State.Name[8] := ')';
  State.Name[9] := #0;
  State.Method := IdleMethodMonitorWait;
  State.Parameter := Hint;
  State.Flags := TimerFlags;
  State.ExitLatencyNanoseconds := QWord(LatencyMicroseconds) * NanosecondsPerMicrosecond;
  State.TargetResidencyNanoseconds := State.ExitLatencyNanoseconds * ResidencyFactor;
end;

end.
