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
  Kernel.PriorityLevel,
  Kernel.TimerDescription;

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
{ The clock as programs may read it themselves (the clock page,
  Kernel.ClockPage): the counter value at which it read
  OriginNanoseconds and the counter's rate. False if programs cannot
  read the kernel's clock (KVM's paravirtual clock). }
function HalDescribeUserClock(out Origin, OriginNanoseconds, CountsPerSecond: QWord): Boolean;


{ --- Platform timers ---

  A timer of the platform that runs on whatever the processors do (the
  HPET's comparator here; none on AArch64): the broadcast timer of
  deep idle states (Kernel.BroadcastTimer). }

type
  { Called at the clock's level with the clock's time. }
  THalBroadcastHandler = procedure(Now: QWord);

{ On the boot processor, once device interrupts can be routed: routes
  the platform timer's interrupt to it. }
procedure HalStartPlatformTimers;
function HalBroadcastTimerIsAvailable: Boolean;
procedure HalSetBroadcastHandler(Handler: THalBroadcastHandler);
{ The broadcast timer's next interrupt at Deadline (a clock time;
  High(QWord): none). Any processor, interrupts disabled or not. }
procedure HalSetBroadcastTimerAt(Deadline: QWord);
{ "HPET comparator 2 (I/O APIC input 2)". }
procedure HalDescribeBroadcastTimer(Text: PChar; Capacity: LongWord);

{ The clock's watchdog: whether the kernel should call HalWatchClock
  about once a second, and one check (True: the clock moved to another
  counter, so the clock page must be published again). }
function HalClockNeedsWatching: Boolean;
function HalWatchClock: Boolean;
{ Whether the clock keeps counting in idle states that stop the
  processor's clock (where it does not, those states are not used). }
function HalClockRunsInDeepIdle: Boolean;
procedure HalDescribeTimers(out Description: TTimerDescription);

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
  Hal.Hpet,
  Hal.HpetEventTimer,
  Hal.ClockCalibration,
  Hal.ClockSources,
  Hal.TimerSummary,
  Runtime.Text,
  Kernel.Arch.Cpu,
  Kernel.Options,
  Kernel.Panic,
  Debug.Output;

const
  NanosecondsPerSecond = 1000000000;
  { The longest wait the clock interrupt is set for at once (the kernel
    asks again when it comes): what an idle processor with nothing due
    sleeps at most. Times the timer's rate, it stays well within 64
    bits for timers up to 4 GHz. }
  LongestClockWaitNanoseconds = 4 * QWord(NanosecondsPerSecond);

var
  TimerTicksPerSecond: QWord;

{ The time stamp counter's and the local APIC timer's rates
  (Hal.ClockCalibration), and the counter clock started. }
procedure MeasureTimerFrequencies;
var
  Calibration: TTimerCalibration;
begin
  CalibrateTimers(Calibration);
  TimerTicksPerSecond := Calibration.LocalTimerHertz;
  StartTimeStampClock(Calibration.CounterHertz);
end;

procedure InitializeHal;
begin
  RemapAndMaskLegacyPic(LegacyPicMasterVectorBase, LegacyPicSlaveVectorBase);
  InitializeLocalApic(ApicSpuriousVector);
  { Before the rates: the best reference to measure them against. }
  InitializeHpet;
  MeasureTimerFrequencies;
  ChooseClockSource;
end;

function HalClockNanoseconds: QWord;
begin
  Result := ClockSourceNanoseconds;
end;

function HalDescribeUserClock(out Origin, OriginNanoseconds, CountsPerSecond: QWord): Boolean;
begin
  Result := DescribeUserClockSource(Origin, OriginNanoseconds, CountsPerSecond);
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
  Result := ClockSourceName;
end;

procedure HalStartPlatformTimers;
begin
  if HpetIsPresent then
    StartHpetEventTimer;
end;

function HalBroadcastTimerIsAvailable: Boolean;
begin
  Result := HpetEventTimerIsRunning;
end;

procedure HalSetBroadcastHandler(Handler: THalBroadcastHandler);
begin
  SetHpetEventHandler(THpetEventHandler(Handler));
end;

procedure HalSetBroadcastTimerAt(Deadline: QWord);
begin
  SetHpetEventAt(Deadline);
end;

procedure HalDescribeBroadcastTimer(Text: PChar; Capacity: LongWord);
begin
  DescribeBroadcastTimer(Text, Capacity);
end;

function HalClockNeedsWatching: Boolean;
begin
  Result := ClockSourceIsWatched;
end;

function HalWatchClock: Boolean;
begin
  Result := WatchClockSource;
end;

function HalClockRunsInDeepIdle: Boolean;
begin
  Result := ClockKeepsRunningInDeepIdle;
end;

procedure HalDescribeTimers(out Description: TTimerDescription);
begin
  DescribePlatformTimers(Description);
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
  SaveHpetState;
end;

procedure HalPauseClockForSleep;
begin
  PauseClockSource;
end;

procedure HalContinueClockAfterSleep;
begin
  { The chipset forgot the HPET: its counter runs again before a clock
    may read it. }
  RestoreHpetState;
  ContinueClockSource;
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
  { Firmware may have started the PIT's tick again. }
  if HpetEventTimerIsRunning then
  begin
    SilenceIntervalTimerOutput;
    ResumeHpetEventTimer;
  end;
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
  CalibrationBusyWait(AfterInitMicroseconds);
  LocalApicSendStartup(ProcessorId, StartupPage);
  CalibrationBusyWait(AfterStartupMicroseconds);
  LocalApicSendStartup(ProcessorId, StartupPage);
  CalibrationBusyWait(AfterStartupMicroseconds);
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
    DebugWriteLine(' (x2APIC mode)')
  else
    DebugWriteLine(' (xAPIC mode)');
  DebugEndMessage;
  WriteTimerSummary;
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
