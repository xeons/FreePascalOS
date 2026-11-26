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
  The AArch64 platform: the GIC (Hal.Gic), the generic timer
  (Hal.GenericTimer) and PSCI (Hal.Psci), found through the firmware's
  ACPI tables, so the same kernel runs on QEMU's virt machine and on a
  Raspberry Pi 4 with UEFI firmware.

  The interface is the x86-64 HAL's; a processor id is its MPIDR
  affinity (Kernel.Arch.Processor), and processors are started through
  PSCI (HalStartProcessorAt) instead of start-up IPIs.
}
unit Hal.Platform;

{$mode objfpc}

interface

uses
  Kernel.PriorityLevel,
  Kernel.TimerDescription;

{ Prepares the interrupt controller and the timer. Interrupts must still
  be disabled. }
procedure InitializeHal;

{ --- The clock (see the x86-64 Hal.Platform) --- }
function HalClockNanoseconds: QWord;
procedure HalStartClockOnThisProcessor;
{ What the clock is read from ("time stamp counter", "KVM paravirtual
  clock", "generic timer"). }
function HalClockSourceName: PChar;
procedure HalSetClockInterruptIn(Nanoseconds: QWord);
{ The clock as programs may read it themselves (the clock page,
  Kernel.ClockPage): the counter value at which it read
  OriginNanoseconds and the counter's rate. False if programs cannot
  read the kernel's clock (KVM's paravirtual clock). }
function HalDescribeUserClock(out Origin, OriginNanoseconds, CountsPerSecond: QWord): Boolean;

{ --- Platform timers (see the x86-64 Hal.Platform): AArch64 has no
  timer outside the processors, so no broadcast timer of its own; the
  generic timer is the clock and needs no watchdog. --- }
type
  THalBroadcastHandler = procedure(Now: QWord);

procedure HalStartPlatformTimers;
function HalBroadcastTimerIsAvailable: Boolean;
procedure HalSetBroadcastHandler(Handler: THalBroadcastHandler);
procedure HalSetBroadcastTimerAt(Deadline: QWord);
procedure HalDescribeBroadcastTimer(Text: PChar; Capacity: LongWord);
function HalClockNeedsWatching: Boolean;
function HalWatchClock: Boolean;
function HalClockRunsInDeepIdle: Boolean;
procedure HalDescribeTimers(out Description: TTimerDescription);

procedure HalEndOfInterrupt;
procedure HalRequestSoftwareInterrupt(Level: TPriorityLevel);
function HalClockInterruptVector: Byte;
function HalDispatchInterruptVector: Byte;

{ --- Several processors --- }
function HalCurrentProcessorId: LongWord;
procedure HalInitializeSecondaryProcessor;
{ First thing on a processor that starts or wakes, before its priority
  level may change: what the level needs (a GICv3's system register
  interface). }
procedure HalOpenInterruptInterface;
procedure HalPrepareForSleep;
procedure HalResumeBootProcessor;
{ The last step before the machine sleeps (interrupts off, the other
  processors frozen): the clock remembers where it is. After waking, on
  the boot processor: it continues from there, so the uptime never
  steps back nor counts the time asleep. }
procedure HalPauseClockForSleep;
procedure HalContinueClockAfterSleep;
{ Starts processor ProcessorId at the physical address EntryPoint (MMU
  off) with Context in X0. False if the firmware refused. }
function HalStartProcessorAt(ProcessorId: LongWord; EntryPoint, Context: QWord): Boolean;
procedure HalRequestDispatchOn(ProcessorId: LongWord);
procedure HalSendRequestInterrupt(ProcessorId: LongWord);
function HalRequestInterruptVector: Byte;
{ Stops every other processor (used by the panic path). }
procedure HalHaltOtherProcessors;
{ True if the machine can suspend to RAM through the HAL (PSCI
  SYSTEM_SUSPEND; the kernel option psci-suspend=force tries it even
  where PSCI_FEATURES says no, which tests the way back when the
  firmware refuses). }
function HalOffersSuspendToRam: Boolean;
{ Suspends to RAM, waking at WakeVector (PrepareWakeEntry). Returns only
  if the firmware refused. }
procedure HalEnterSuspendToRam(WakeVector: QWord);
{ Resets the machine through PSCI. Returns if that did not work. }
procedure HalResetMachine;
{ Powers the machine off through PSCI. Returns if that did not work. }
procedure HalPowerOff;
procedure HalWriteDescription;

type
  TEmulatorExitReason = (EmulatorExitSuccess, EmulatorExitPanic, EmulatorExitTestFailure);

{ Ends the emulator session with a result code through semihosting
  (QEMU started with -semihosting-config enable=on); the exit status is
  (reason * 2) + 1, as on x86-64. Only call this when the kernel was told
  it runs under test: without semihosting the instruction faults. }
procedure HalExitEmulator(Reason: TEmulatorExitReason);

implementation

uses
  Hal.Gic,
  Hal.GenericTimer,
  Hal.Psci,
  Hal.InterruptVectors,
  Kernel.Arch.Cpu,
  Kernel.Arch.Exceptions,
  Kernel.Arch.ProcessorStartup,
  Kernel.Options,
  Kernel.Arch.TrapFrame,
  Kernel.Interrupts,
  Kernel.Processors,
  Kernel.Panic,
  Runtime.Text,
  Runtime.Memory,
  Debug.Output;

const
  NanosecondsPerSecond = 1000000000;
  { The longest wait the clock interrupt is set for at once (the kernel
    asks again when it comes): what an idle processor with nothing due
    sleeps at most. Times the timer's rate, it stays well within 64
    bits for timers up to 4 GHz. }
  LongestClockWaitNanoseconds = 4 * QWord(NanosecondsPerSecond);
  StopInterruptVector = InterProcessorInterruptVector + 1;

  SemihostingExitExtended = $20;
  ApplicationExit = $20026;

procedure ArchSemihostingCall(Operation: QWord; Parameters: Pointer); external name 'ArchSemihostingCall';

{ Another processor panicked: stop here. }
procedure HandleStopInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  while True do
  begin
    DisableInterrupts;
    HaltProcessor;
  end;
end;

procedure InitializeHal;
begin
  if not InitializeGic then
    KernelPanicWithCode(PanicHardwareMissing, 'no GICv2 or GICv3 interrupt controller (ACPI MADT or device tree)', 0, 0, 0, 0);
  SetInterruptAcknowledger(@AcknowledgeGicInterrupt);
  InitializeGenericTimer;
  if CounterFrequency = 0 then
    KernelPanicWithCode(PanicHardwareMissing, 'the generic timer has no frequency', 0, 0, 0, 0);
  ConnectGicInterrupt(TimerInterrupt, ClockInterruptVector, TimerInterruptIsLevelTriggered,
    CurrentProcessor^.ApicId);
  RegisterInterruptHandler(StopInterruptVector, @HandleStopInterrupt, nil);
  InitializePsci;
end;

function HalClockNanoseconds: QWord;
begin
  Result := GenericTimerNanoseconds;
end;

function HalDescribeUserClock(out Origin, OriginNanoseconds, CountsPerSecond: QWord): Boolean;
begin
  Result := DescribeGenericTimer(Origin, CountsPerSecond);
  OriginNanoseconds := 0;
end;

procedure HalStartClockOnThisProcessor;
begin
  { Programs read the virtual counter for the clock page (CNTKCTL_EL1
    may have been reset by a power-down). }
  AllowUserCounterReads;
  SetTimerInterruptIn(0);
end;

procedure HalSetClockInterruptIn(Nanoseconds: QWord);
var
  Ticks: QWord;
begin
  if Nanoseconds > LongestClockWaitNanoseconds then
    Nanoseconds := LongestClockWaitNanoseconds;
  { Rounded up: the timer counts the same counter the clock reads, so
    an interrupt never comes early by it. }
  Ticks := (Nanoseconds * CounterFrequency + NanosecondsPerSecond - 1) div NanosecondsPerSecond;
  SetTimerInterruptIn(Ticks);
end;

function HalClockSourceName: PChar;
begin
  Result := 'generic timer';
end;

procedure HalStartPlatformTimers;
begin
end;

function HalBroadcastTimerIsAvailable: Boolean;
begin
  Result := False;
end;

procedure HalSetBroadcastHandler(Handler: THalBroadcastHandler);
begin
end;

procedure HalSetBroadcastTimerAt(Deadline: QWord);
begin
end;

procedure HalDescribeBroadcastTimer(Text: PChar; Capacity: LongWord);
begin
  CopyText(Text, 'none', Capacity);
end;

function HalClockNeedsWatching: Boolean;
begin
  Result := False;
end;

function HalWatchClock: Boolean;
begin
  Result := False;
end;

function HalClockRunsInDeepIdle: Boolean;
begin
  Result := True;
end;

procedure HalDescribeTimers(out Description: TTimerDescription);
begin
  ZeroMemory(@Description, SizeOf(Description));
  Description.Flags := TimerCounterInvariant;
  Description.CounterHertz := CounterFrequency;
  Description.LocalTimerHertz := CounterFrequency;
  Description.HpetEventComparator := -1;
  CopyText(@Description.ClockSource[0], 'generic timer', TimerNameCapacity);
  CopyText(@Description.CounterCalibration[0], 'CNTFRQ_EL0', TimerNameCapacity);
  CopyText(@Description.LocalTimerCalibration[0], 'CNTFRQ_EL0', TimerNameCapacity);
  CopyText(@Description.HpetRoute[0], 'none', TimerNameCapacity);
end;

procedure HalEndOfInterrupt;
begin
  EndGicInterrupt;
end;

procedure HalRequestSoftwareInterrupt(Level: TPriorityLevel);
begin
  if Level <> DispatchLevel then
    KernelPanicWithCode(PanicInvalidPriorityLevel,
      'software interrupts are only supported at dispatch level', Level, 0, 0, 0);
  SendSoftwareInterruptToSelf(SoftwareInterruptDispatch);
end;

function HalClockInterruptVector: Byte;
begin
  Result := ClockInterruptVector;
end;

function HalDispatchInterruptVector: Byte;
begin
  Result := DispatchInterruptVector;
end;

function HalCurrentProcessorId: LongWord;
begin
  Result := LongWord(ReadProcessorAffinity and $FFFFFF);
end;

procedure HalInitializeSecondaryProcessor;
begin
  InitializeGicOnThisProcessor;
end;

procedure HalOpenInterruptInterface;
begin
  OpenGicSystemRegistersOnThisProcessor;
end;

procedure HalPrepareForSleep;
begin
end;

procedure HalResumeBootProcessor;
begin
  { The distributor lost its settings if the machine slept. }
  RestoreGicAfterSleep;
end;

procedure HalPauseClockForSleep;
begin
  PauseGenericTimer;
end;

procedure HalContinueClockAfterSleep;
begin
  ContinueGenericTimer;
end;

function HalStartProcessorAt(ProcessorId: LongWord; EntryPoint, Context: QWord): Boolean;
begin
  Result := PsciStartProcessor(ProcessorId, EntryPoint, Context);
end;

procedure HalRequestDispatchOn(ProcessorId: LongWord);
begin
  SendSoftwareInterrupt(SoftwareInterruptDispatch, ProcessorId);
end;

procedure HalSendRequestInterrupt(ProcessorId: LongWord);
begin
  SendSoftwareInterrupt(SoftwareInterruptRequest, ProcessorId);
end;

function HalRequestInterruptVector: Byte;
begin
  Result := InterProcessorInterruptVector;
end;

procedure HalHaltOtherProcessors;
begin
  SendSoftwareInterruptToOthers(SoftwareInterruptStop);
end;

function HalOffersSuspendToRam: Boolean;
var
  Value: array[0..15] of Char;
begin
  Result := PsciOffersSystemSuspend;
  if not Result and GetKernelOptionValue('psci-suspend', @Value[0], SizeOf(Value)) then
    Result := (Value[0] = 'f') and (Value[1] = 'o') and (Value[2] = 'r') and (Value[3] = 'c') and (Value[4] = 'e');
end;

procedure HalEnterSuspendToRam(WakeVector: QWord);
begin
  if WakeVector = 0 then
    Exit;
  PsciSuspendSystem(WakeVector, WakeEntryContext);
end;

procedure HalResetMachine;
begin
  PsciReset;
end;

procedure HalPowerOff;
begin
  PsciPowerOff;
end;

procedure HalWriteDescription;
begin
  DebugBeginMessage;
  DebugWriteTag('hal');
  DebugWrite('GICv');
  DebugWriteDecimal(GicVersion);
  DebugWrite(', ');
  DebugWriteDecimal(GicInterruptCount);
  DebugWrite(' interrupts; generic timer ');
  DebugWriteDecimal(CounterFrequency div 1000);
  DebugWrite(' kHz on INTID ');
  DebugWriteDecimal(TimerInterrupt);
  if PsciIsAvailable then
  begin
    DebugWrite('; PSCI ');
    DebugWriteDecimal(PsciVersion shr 16);
    DebugWrite('.');
    DebugWriteDecimal(PsciVersion and $FFFF);
    if PsciUsesHypervisorCall then
      DebugWrite(' (HVC)')
    else
      DebugWrite(' (SMC)');
    if PsciOffersSystemSuspend then
      DebugWrite(', suspend to RAM');
  end
  else
    DebugWrite('; no PSCI');
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure HalExitEmulator(Reason: TEmulatorExitReason);
var
  Parameters: array[0..1] of QWord;
begin
  Parameters[0] := ApplicationExit;
  Parameters[1] := QWord(Ord(Reason)) * 2 + 1;
  ArchSemihostingCall(SemihostingExitExtended, @Parameters[0]);
end;

end.
