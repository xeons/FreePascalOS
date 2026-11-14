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

{ Starts the periodic clock interrupt on the clock vector. }
procedure HalStartClock(InterruptsPerSecond: LongWord);

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
{ Prepares the executing secondary processor's interrupt controller and
  starts its clock (at the rate HalStartClock was given). }
procedure HalInitializeSecondaryProcessor;
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
  Hal.IntervalTimer,
  Hal.InterruptVectors,
  Hal.LegacyPic,
  Hal.LocalApic,
  Kernel.Panic,
  Debug.Output;

var
  TimerTicksPerSecond: QWord;
  ClockInterruptsPerSecond: LongWord;

procedure InitializeHal;
begin
  RemapAndMaskLegacyPic(LegacyPicMasterVectorBase, LegacyPicSlaveVectorBase);
  InitializeLocalApic(ApicSpuriousVector);
  TimerTicksPerSecond := MeasureLocalApicTimerFrequency;
  if TimerTicksPerSecond = 0 then
    KernelPanicWithCode(PanicHardwareMissing, 'local APIC timer does not count', 0, 0, 0, 0);
end;

procedure HalStartClock(InterruptsPerSecond: LongWord);
begin
  ClockInterruptsPerSecond := InterruptsPerSecond;
  StartLocalApicPeriodicTimer(ClockInterruptVector,
    LongWord(TimerTicksPerSecond div InterruptsPerSecond));
end;

procedure HalEndOfInterrupt;
begin
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

procedure HalInitializeSecondaryProcessor;
begin
  InitializeLocalApic(ApicSpuriousVector);
  if ClockInterruptsPerSecond <> 0 then
    StartLocalApicPeriodicTimer(ClockInterruptVector,
      LongWord(TimerTicksPerSecond div ClockInterruptsPerSecond));
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
  DebugWriteLine(' kHz');
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
