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
  Hal.InterruptVectors,
  Hal.LegacyPic,
  Hal.LocalApic,
  Kernel.Panic,
  Debug.Output;

var
  TimerTicksPerSecond: QWord;

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
