{
  Local APIC driver.

  Each processor has a local APIC that receives interrupts, provides a
  per-processor timer and sends inter-processor interrupts. It is used in
  one of two modes:

    xAPIC   Registers are memory mapped (normally at 0xFEE00000).
    x2APIC  Registers are model specific registers starting at 0x800.

  The firmware may hand over in either mode, so register access goes
  through ReadApicRegister/WriteApicRegister which handle both.
}
unit Hal.LocalApic;

{$mode objfpc}

interface

procedure InitializeLocalApic(SpuriousVector: Byte);

function LocalApicId: LongWord;
function LocalApicUsesX2ApicMode: Boolean;

procedure LocalApicEndOfInterrupt;
procedure LocalApicSendSelfInterrupt(Vector: Byte);

{ Measures how many timer ticks (at the divider used by the periodic
  timer) elapse per second. }
function MeasureLocalApicTimerFrequency: QWord;

procedure StartLocalApicPeriodicTimer(Vector: Byte; TicksPerInterrupt: LongWord);
procedure StopLocalApicTimer;

implementation

uses
  Memory.Layout,
  Kernel.Arch.Cpu,
  Hal.IntervalTimer;

const
  MsrApicBase = $1B;
  ApicBaseGlobalEnable = QWord(1) shl 11;
  ApicBaseX2ApicEnable = QWord(1) shl 10;
  ApicBaseAddressMask = QWord($000FFFFFFFFFF000);

  X2ApicMsrBase = $800;

  { Register offsets in the xAPIC memory mapped layout. }
  RegisterId = $020;
  RegisterTaskPriority = $080;
  RegisterEndOfInterrupt = $0B0;
  RegisterSpuriousVector = $0F0;
  RegisterInterruptCommandLow = $300;
  RegisterInterruptCommandHigh = $310;
  RegisterLvtTimer = $320;
  RegisterLvtLint0 = $350;
  RegisterLvtLint1 = $360;
  RegisterLvtError = $370;
  RegisterTimerInitialCount = $380;
  RegisterTimerCurrentCount = $390;
  RegisterTimerDivide = $3E0;

  SpuriousVectorApicEnable = $100;
  LvtMasked = LongWord(1) shl 16;
  LvtTimerPeriodic = LongWord(1) shl 17;
  TimerDivideBy16 = $3;

  InterruptCommandDeliveryPending = LongWord(1) shl 12;
  InterruptCommandShorthandSelf = LongWord(1) shl 18;

  CalibrationMicroseconds = 10000;
  CalibrationsPerSecond = 1000000 div CalibrationMicroseconds;

var
  RegisterBase: PtrUInt;
  UsesX2ApicMode: Boolean;

function LocalApicUsesX2ApicMode: Boolean;
begin
  Result := UsesX2ApicMode;
end;

function ReadApicRegister(Offset: LongWord): LongWord;
begin
  if UsesX2ApicMode then
    Result := LongWord(ReadModelSpecificRegister(X2ApicMsrBase + (Offset shr 4)))
  else
    Result := PLongWord(RegisterBase + Offset)^;
end;

procedure WriteApicRegister(Offset: LongWord; Value: LongWord);
begin
  if UsesX2ApicMode then
    WriteModelSpecificRegister(X2ApicMsrBase + (Offset shr 4), Value)
  else
    PLongWord(RegisterBase + Offset)^ := Value;
end;

procedure InitializeLocalApic(SpuriousVector: Byte);
var
  ApicBase: QWord;
begin
  ApicBase := ReadModelSpecificRegister(MsrApicBase);
  UsesX2ApicMode := (ApicBase and ApicBaseX2ApicEnable) <> 0;
  RegisterBase := PtrUInt(PhysicalToVirtual(ApicBase and ApicBaseAddressMask));

  if (ApicBase and ApicBaseGlobalEnable) = 0 then
    WriteModelSpecificRegister(MsrApicBase, ApicBase or ApicBaseGlobalEnable);

  { Priority filtering is done through CR8, which aliases this register. }
  WriteApicRegister(RegisterTaskPriority, 0);

  WriteApicRegister(RegisterLvtTimer, LvtMasked);
  WriteApicRegister(RegisterLvtLint0, LvtMasked);
  WriteApicRegister(RegisterLvtLint1, LvtMasked);
  WriteApicRegister(RegisterLvtError, LvtMasked);

  WriteApicRegister(RegisterSpuriousVector, SpuriousVectorApicEnable or SpuriousVector);

  { Clear anything left in service by the firmware. }
  WriteApicRegister(RegisterEndOfInterrupt, 0);
end;

function LocalApicId: LongWord;
begin
  if UsesX2ApicMode then
    Result := ReadApicRegister(RegisterId)
  else
    Result := ReadApicRegister(RegisterId) shr 24;
end;

procedure LocalApicEndOfInterrupt;
begin
  WriteApicRegister(RegisterEndOfInterrupt, 0);
end;

procedure LocalApicSendSelfInterrupt(Vector: Byte);
begin
  if UsesX2ApicMode then
  begin
    { In x2APIC mode the command register is a single 64-bit MSR. }
    WriteModelSpecificRegister(X2ApicMsrBase + (RegisterInterruptCommandLow shr 4),
      InterruptCommandShorthandSelf or Vector);
    Exit;
  end;

  while (ReadApicRegister(RegisterInterruptCommandLow) and InterruptCommandDeliveryPending) <> 0 do
    CpuRelax;
  WriteApicRegister(RegisterInterruptCommandHigh, 0);
  WriteApicRegister(RegisterInterruptCommandLow, InterruptCommandShorthandSelf or Vector);
end;

function MeasureLocalApicTimerFrequency: QWord;
const
  StartingCount = High(LongWord);
var
  RemainingCount: LongWord;
begin
  WriteApicRegister(RegisterTimerDivide, TimerDivideBy16);
  WriteApicRegister(RegisterLvtTimer, LvtMasked);
  WriteApicRegister(RegisterTimerInitialCount, StartingCount);

  IntervalTimerBusyWait(CalibrationMicroseconds);

  RemainingCount := ReadApicRegister(RegisterTimerCurrentCount);
  WriteApicRegister(RegisterTimerInitialCount, 0);

  Result := QWord(StartingCount - RemainingCount) * CalibrationsPerSecond;
end;

procedure StartLocalApicPeriodicTimer(Vector: Byte; TicksPerInterrupt: LongWord);
begin
  WriteApicRegister(RegisterTimerDivide, TimerDivideBy16);
  WriteApicRegister(RegisterLvtTimer, LvtTimerPeriodic or Vector);
  WriteApicRegister(RegisterTimerInitialCount, TicksPerInterrupt);
end;

procedure StopLocalApicTimer;
begin
  WriteApicRegister(RegisterLvtTimer, LvtMasked);
  WriteApicRegister(RegisterTimerInitialCount, 0);
end;

end.
