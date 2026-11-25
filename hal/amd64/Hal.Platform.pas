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
  Hardware abstraction layer interface.

  The kernel talks to interrupt controllers and timers only through this
  unit. Every supported architecture provides a unit with this name and
  these routines; the build picks the right one through its unit search
  path. This is the x86-64 PC implementation.
}
unit Hal.Platform;

{$mode objfpc}

interface

uses
  Kernel.PriorityLevel;

{ Prepares the interrupt controllers. Interrupts must still be disabled. }
procedure InitializeHal;

{ --- The clock ---

  Every processor has a one-shot clock interrupt (on the clock vector):
  the kernel asks for each one when it wants it (Kernel.Clock), and a
  counter tells the time in nanoseconds in between. }

{ Nanoseconds since InitializeHal, not counting time spent in suspend to
  RAM. Any processor, any level. }
function HalClockNanoseconds: QWord;
{ Starts the executing processor's clock interrupt, its first one right
  away (at start and after waking). }
procedure HalStartClockOnThisProcessor;
{ Sets the executing processor's next clock interrupt to come in
  Nanoseconds (0: right away), replacing the one set before. It comes
  no earlier; a very long time is cut to what the timer can count. Call
  with interrupts disabled. }
{ What the clock is read from ("time stamp counter", "KVM paravirtual
  clock", "generic timer"). }
function HalClockSourceName: PChar;
procedure HalSetClockInterruptIn(Nanoseconds: QWord);

{ Signals the end of the interrupt currently being serviced. }
procedure HalEndOfInterrupt;

{ Requests a software interrupt at Level on the current processor. It is
  delivered as soon as the processor's priority level drops below Level.
  Only DispatchLevel is supported. }
procedure HalRequestSoftwareInterrupt(Level: TPriorityLevel);

function HalClockInterruptVector: Byte;
function HalDispatchInterruptVector: Byte;

{ --- Several processors --- }

{ The interrupt controller id of the executing processor. }
function HalCurrentProcessorId: LongWord;
{ Prepares the executing secondary processor's interrupt controller (its
  clock is started with HalStartClockOnThisProcessor). }
procedure HalInitializeSecondaryProcessor;
{ Before suspend to RAM: keeps the interrupt routing. }
procedure HalPrepareForSleep;
{ The last step before the machine sleeps (interrupts off, the other
  processors frozen): the clock remembers where it is. After waking, on
  the boot processor and first: it continues from there, so the uptime
  never steps back nor counts the time asleep. }
procedure HalPauseClockForSleep;
procedure HalContinueClockAfterSleep;
{ False: x86-64 machines suspend through ACPI S3 (Io.AcpiSleep), not
  the HAL. }
function HalOffersSuspendToRam: Boolean;
procedure HalEnterSuspendToRam(WakeVector: QWord);
{ After waking, on the boot processor: the legacy PICs masked again, its
  local APIC as before and the interrupt routing put back. }
procedure HalResumeBootProcessor;
{ Wakes the processor with interrupt controller id ProcessorId so that it
  starts in real mode at physical page StartupPage (below 1 MiB). }
procedure HalStartProcessor(ProcessorId: LongWord; StartupPage: Byte);
{ Asks processor ProcessorId to run its dispatch interrupt (reschedule). }
procedure HalRequestDispatchOn(ProcessorId: LongWord);
{ Sends the inter-processor request interrupt to processor ProcessorId. }
procedure HalSendRequestInterrupt(ProcessorId: LongWord);
function HalRequestInterruptVector: Byte;
{ Stops every other processor (used by the panic path). }
procedure HalHaltOtherProcessors;
{ Resets the machine the legacy ways: the keyboard controller's reset
  line, then the chipset's reset control register (port 0CF9h). Returns
  if neither worked. }
procedure HalResetMachine;

{ Powers the machine off without ACPI: there is no such way on a PC, so
  this returns at once (it powers off through ACPI's S5, Io.AcpiSleep). }
procedure HalPowerOff;

procedure HalWriteDescription;

type
  TEmulatorExitReason = (EmulatorExitSuccess, EmulatorExitPanic, EmulatorExitTestFailure);

{ Ends the emulator session with a result code, using QEMU's debug exit
  device. Only call this when the kernel was told it runs under test:
  on real hardware the port may belong to something else. }
procedure HalExitEmulator(Reason: TEmulatorExitReason);

implementation

uses
  Hal.PortIo,
  Hal.IoApic,
  Hal.InterruptRemapping,
  Hal.InterruptController,
  Hal.IntervalTimer,
  Hal.InterruptVectors,
  Hal.LegacyPic,
  Hal.LocalApic,
  Hal.TimeStampClock,
  Hal.ParavirtualClock,
  Runtime.Text,
  Kernel.Arch.Cpu,
  Kernel.Options,
  Kernel.Panic,
  Debug.Output;

const
  { The interval timer can count at most about 54 ms; the longer the
    measurement, the closer the clock keeps to real time. }
  CalibrationMicroseconds = 50000;
  MicrosecondsPerSecond = 1000000;
  NanosecondsPerSecond = 1000000000;
  { The longest wait the clock interrupt is set for at once (the kernel
    asks again when it comes): what an idle processor with nothing due
    sleeps at most. Times the timer's rate, it stays well within 64
    bits for timers up to 4 GHz. }
  LongestClockWaitNanoseconds = 4 * QWord(NanosecondsPerSecond);

var
  TimerTicksPerSecond: QWord;
  CyclesPerSecond: QWord;
  CounterIsInvariant: Boolean;
  { The kernel's clock is KVM's paravirtual clock rather than the
    counter (see ChooseClockSource). }
  UsesParavirtualClock: Boolean = False;

{ Measures the local APIC timer and the time stamp counter over the same
  stretch of the interval timer, so that the ratio between the two (which
  decides whether a clock interrupt comes early by the counter) is close
  even if the stretch itself is a little off. }
procedure MeasureTimerFrequencies;
var
  StartCycles: QWord;
  Cycles: QWord;
  TimerTicks: QWord;
begin
  StartLocalApicTimerCountdown;
  StartCycles := ReadTimeStampCounter;
  IntervalTimerBusyWait(CalibrationMicroseconds);
  TimerTicks := StopLocalApicTimerCountdown;
  Cycles := ReadTimeStampCounter - StartCycles;
  TimerTicksPerSecond := TimerTicks * MicrosecondsPerSecond div CalibrationMicroseconds;
  CyclesPerSecond := Cycles * MicrosecondsPerSecond div CalibrationMicroseconds;
  if TimerTicksPerSecond = 0 then
    KernelPanicWithCode(PanicHardwareMissing, 'local APIC timer does not count', 0, 0, 0, 0);
  if CyclesPerSecond = 0 then
    KernelPanicWithCode(PanicHardwareMissing, 'time stamp counter does not count', 0, 0, 0, 0);
  StartTimeStampClock(CyclesPerSecond);
end;

{ The time stamp counter, unless it is not invariant and KVM offers its
  paravirtual clock (clock=tsc keeps the counter, clock=kvmclock takes
  the paravirtual clock whenever there is one). }
procedure ChooseClockSource;
var
  Value: array[0..15] of Char;
  Wanted: Boolean;
begin
  CounterIsInvariant := TimeStampCounterIsInvariant;
  Wanted := not CounterIsInvariant;
  if GetKernelOptionValue('clock', @Value[0], SizeOf(Value)) then
    Wanted := TextIsEqual(@Value[0], 'kvmclock');
  if Wanted then
    UsesParavirtualClock := StartParavirtualClock;
end;

procedure InitializeHal;
begin
  RemapAndMaskLegacyPic(LegacyPicMasterVectorBase, LegacyPicSlaveVectorBase);
  InitializeLocalApic(ApicSpuriousVector);
  MeasureTimerFrequencies;
  ChooseClockSource;
end;

function HalClockNanoseconds: QWord;
begin
  if UsesParavirtualClock then
    Result := ParavirtualClockNanoseconds
  else
    Result := TimeStampClockNanoseconds;
end;

procedure HalStartClockOnThisProcessor;
begin
  StartLocalApicOneShotTimer(ClockInterruptVector);
end;

procedure HalSetClockInterruptIn(Nanoseconds: QWord);
var
  Count: QWord;
begin
  if Nanoseconds > LongestClockWaitNanoseconds then
    Nanoseconds := LongestClockWaitNanoseconds;
  { Rounded up, and a little more: the timer and the counter were
    measured against each other only so closely, and an interrupt that
    comes early by the counter has to be set again. }
  Count := (Nanoseconds * TimerTicksPerSecond + NanosecondsPerSecond - 1) div NanosecondsPerSecond;
  Count := Count + Count shr 10 + 1;
  if Count > High(LongWord) then
    Count := High(LongWord);
  SetLocalApicTimerCount(LongWord(Count));
end;

function HalClockSourceName: PChar;
begin
  if UsesParavirtualClock then
    Result := 'KVM paravirtual clock'
  else
    Result := 'time stamp counter';
end;

procedure HalEndOfInterrupt;
begin
  { Before the local APIC forgets which vector is in service. }
  EndRemappedLevelInterrupt;
  LocalApicEndOfInterrupt;
end;

procedure HalRequestSoftwareInterrupt(Level: TPriorityLevel);
begin
  if Level <> DispatchLevel then
    KernelPanicWithCode(PanicInvalidPriorityLevel,
      'software interrupts are only supported at dispatch level', Level, 0, 0, 0);
  LocalApicSendSelfInterrupt(DispatchInterruptVector);
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
  Result := LocalApicId;
end;

procedure HalPrepareForSleep;
begin
  SaveIoApicEntries;
end;

procedure HalPauseClockForSleep;
begin
  PauseTimeStampClock;
  if UsesParavirtualClock then
    PauseParavirtualClock;
end;

procedure HalContinueClockAfterSleep;
begin
  ContinueTimeStampClock;
  if UsesParavirtualClock then
    ContinueParavirtualClock;
end;

function HalOffersSuspendToRam: Boolean;
begin
  Result := False;
end;

procedure HalEnterSuspendToRam(WakeVector: QWord);
begin
end;

procedure HalResumeBootProcessor;
begin
  RemapAndMaskLegacyPic(LegacyPicMasterVectorBase, LegacyPicSlaveVectorBase);
  InitializeLocalApic(ApicSpuriousVector);
  { The IOMMU forgot its tables: before the entries that name them. }
  ResumeInterruptRemapping;
  RestoreIoApicEntries;
end;

procedure HalInitializeSecondaryProcessor;
begin
  InitializeLocalApic(ApicSpuriousVector);
end;

procedure HalStartProcessor(ProcessorId: LongWord; StartupPage: Byte);
const
  { The waits of the usual INIT, STARTUP, STARTUP sequence. }
  AfterInitMicroseconds = 10000;
  AfterStartupMicroseconds = 200;
begin
  LocalApicSendInit(ProcessorId);
  IntervalTimerBusyWait(AfterInitMicroseconds);
  LocalApicSendStartup(ProcessorId, StartupPage);
  IntervalTimerBusyWait(AfterStartupMicroseconds);
  LocalApicSendStartup(ProcessorId, StartupPage);
  IntervalTimerBusyWait(AfterStartupMicroseconds);
end;

procedure HalRequestDispatchOn(ProcessorId: LongWord);
begin
  LocalApicSendInterrupt(ProcessorId, DispatchInterruptVector);
end;

procedure HalSendRequestInterrupt(ProcessorId: LongWord);
begin
  LocalApicSendInterrupt(ProcessorId, InterProcessorInterruptVector);
end;

function HalRequestInterruptVector: Byte;
begin
  Result := InterProcessorInterruptVector;
end;

procedure HalResetMachine;
const
  KeyboardStatusPort = $64;
  KeyboardInputFull = $02;
  KeyboardPulseReset = $FE;
  ResetControlPort = $CF9;
  ResetControlHardReset = $06;
var
  Tries: Integer;
begin
  for Tries := 1 to 100000 do
    if (ReadPortByte(KeyboardStatusPort) and KeyboardInputFull) = 0 then
      Break;
  WritePortByte(KeyboardStatusPort, KeyboardPulseReset);
  for Tries := 1 to 1000000 do
    CpuRelax;
  WritePortByte(ResetControlPort, ResetControlHardReset);
  for Tries := 1 to 1000000 do
    CpuRelax;
end;

procedure HalPowerOff;
begin
end;

procedure HalHaltOtherProcessors;
begin
  LocalApicSendNmiToOthers;
end;

procedure HalWriteDescription;
begin
  DebugBeginMessage;
  DebugWriteTag('hal');
  DebugWrite('Local APIC ');
  DebugWriteDecimal(LocalApicId);
  if LocalApicUsesX2ApicMode then
    DebugWrite(' (x2APIC mode)')
  else
    DebugWrite(' (xAPIC mode)');
  DebugWrite(', timer ');
  DebugWriteDecimal(TimerTicksPerSecond div 1000);
  DebugWrite(' kHz, time stamp counter ');
  DebugWriteDecimal(CyclesPerSecond div 1000000);
  if CounterIsInvariant then
    DebugWrite(' MHz (invariant)')
  else
    DebugWrite(' MHz (not invariant)');
  if UsesParavirtualClock then
    DebugWrite('; clock: KVM paravirtual clock')
  else
    DebugWrite('; clock: time stamp counter');
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure HalExitEmulator(Reason: TEmulatorExitReason);
const
  { Matches "-device isa-debug-exit,iobase=0xf4,iosize=0x04". QEMU exits
    with status (value * 2) + 1: success 1, panic 3, test failure 5. }
  DebugExitPort = $F4;
begin
  WritePortLongWord(DebugExitPort, Ord(Reason));
end;

end.
