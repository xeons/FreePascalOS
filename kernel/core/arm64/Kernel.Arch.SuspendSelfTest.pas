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
  Self test of suspend to RAM on AArch64 (the kernel option
  suspendtest): the whole way down and back (Processes.Suspend) - the
  drivers' power handlers, every other processor frozen and turned off
  (PSCI CPU_OFF), PSCI SYSTEM_SUSPEND, then each processor started again
  through the start-up entry (CPU_ON), set up again (vectors,
  translation, PAN, its GIC interface, its clock) and resumed where it
  froze. QEMU's PSCI has no SYSTEM_SUSPEND: with psci-suspend=force the
  firmware refuses it, which takes the same way back for every
  processor but the boot one. Afterwards every processor must run a
  thread again.

  Two more things are checked on the way:
  - A processor that does not freeze in time: a thread holds the last
    processor at dispatch level from just before the freeze until the
    boot processor gave up waiting for it, which calls the suspend off
    (the others, frozen meanwhile, are started again). Once let go, that
    processor must not freeze late (its request was called off) and
    must run threads as before.
  - The floating point and SIMD registers of the thread a processor
    froze in the middle of: a thread on processor 1 holds distinctive
    values in all of them (and in FPCR and FPSR) across the suspend
    (SuspendSelfTestFpu.s), and finds them all unchanged after.
}
unit Kernel.Arch.SuspendSelfTest;

{$mode objfpc}

interface

{ Runs the test if the option asks for it. }
procedure RunSuspendSelfTestIfAsked;

implementation

uses
  Abi.SystemCalls,
  Runtime.Atomic,
  Kernel.Options,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.Processors,
  Kernel.ProcessorPower,
  Kernel.Clock,
  Kernel.Scheduler,
  Kernel.Threads,
  Kernel.Events,
  Kernel.SelfTest,
  Processes.Thread,
  Processes.Suspend,
  Debug.Output;

const
  WaitMilliseconds = 5000;
  { Longer than the freeze waits for a processor (Kernel.ProcessorPower). }
  HoldLimitMilliseconds = 30000;
  TestThreadPriority = 20;
  FpuSeed = QWord($5A17C0DE00000000);

type
  { Read and written by ArchSuspendTestHoldFpuValues. }
  TFpuHoldFlags = record
    LetGo: PtrUInt;
    Holding: PtrUInt;
  end;

var
  Arrived: array[0..MaximumProcessors - 1] of TEvent;
  { The late processor test. }
  HeldProcessorIndex: LongWord;
  HoldStarted: PtrUInt;
  HoldRaised: PtrUInt;
  HoldSawRequest: Boolean;
  HoldSawCallOff: Boolean;
  HoldDone: TEvent;
  { The floating point test. }
  FpuFlags: TFpuHoldFlags;
  FpuChanged: QWord;
  FpuDone: TEvent;

function ArchSuspendTestHoldFpuValues(var Flags: TFpuHoldFlags; Seed: QWord): QWord;
  external name 'ArchSuspendTestHoldFpuValues';

{ Moves to the processor whose index is Context and says so. }
procedure VisitProcessor(Context: Pointer);
var
  Index: LongWord;
begin
  Index := LongWord(PtrUInt(Context));
  SetThreadAffinity(CurrentThread, QWord(1) shl Index);
  if CurrentProcessorIndex = Index then
    SignalEvent(Arrived[Index]);
end;

function EveryProcessorRuns: Boolean;
var
  Index: LongWord;
begin
  Result := True;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    if not ProcessorByIndex(Index)^.IsOnline then
      Continue;
    InitializeEvent(Arrived[Index], EventKindNotification, False);
    if CreateSystemThread(@VisitProcessor, Pointer(PtrUInt(Index)), TestThreadPriority, 'SuspendTest',
      False) = nil then
      Exit(False);
    if WaitForEventWithOptions(Arrived[Index], WaitMilliseconds, False) <> WaitSignaled then
      Exit(False);
  end;
end;

function NoProcessorIsFrozen: Boolean;
var
  Index: LongWord;
begin
  Result := True;
  for Index := 0 to ProcessorTotal - 1 do
    if ProcessorByIndex(Index)^.IsOnline and ProcessorIsFrozen(ProcessorByIndex(Index)) then
      Result := False;
end;

function LastOnlineProcessorIndex: LongWord;
var
  Index: LongWord;
begin
  Result := 0;
  for Index := 0 to ProcessorTotal - 1 do
    if ProcessorByIndex(Index)^.IsOnline then
      Result := Index;
end;

{ On the held processor: at dispatch level from the start of the freeze
  until it was called off (or the limit). }
procedure HoldProcessor(Context: Pointer);
var
  Processor: PProcessor;
  PreviousLevel: TPriorityLevel;
  Deadline: QWord;
begin
  SetThreadAffinity(CurrentThread, QWord(1) shl HeldProcessorIndex);
  { Wait at thread level for the freeze to begin. }
  Deadline := DeadlineAfterMilliseconds(HoldLimitMilliseconds);
  while (AtomicLoad(HoldStarted) = 0) and (ClockNanoseconds < Deadline) do
    YieldExecution;
  PreviousLevel := RaisePriorityLevel(DispatchLevel);
  Processor := CurrentProcessor;
  AtomicStore(HoldRaised, 1);
  while (AtomicLoad(Processor^.FreezeState) <> FreezeStateRequested) and (ClockNanoseconds < Deadline) do
    CpuRelax;
  HoldSawRequest := AtomicLoad(Processor^.FreezeState) = FreezeStateRequested;
  while (AtomicLoad(Processor^.FreezeState) = FreezeStateRequested) and (ClockNanoseconds < Deadline) do
    CpuRelax;
  HoldSawCallOff := AtomicLoad(Processor^.FreezeState) = FreezeStateRunning;
  { The dispatch interrupt asked for by the freeze comes now: it must
    find nothing to do. }
  LowerPriorityLevel(PreviousLevel);
  SignalEvent(HoldDone);
end;

{ From FreezeOtherProcessors: lets the holder raise its level first. }
procedure StartHolding;
var
  Deadline: QWord;
begin
  AtomicStore(HoldStarted, 1);
  Deadline := DeadlineAfterMilliseconds(WaitMilliseconds);
  while (AtomicLoad(HoldRaised) = 0) and (ClockNanoseconds < Deadline) do
    CpuRelax;
end;

procedure TestLateProcessor;
var
  Status: LongInt;
  StillHeld: Boolean;
begin
  HeldProcessorIndex := LastOnlineProcessorIndex;
  if HeldProcessorIndex = 0 then
    Exit;
  HoldStarted := 0;
  HoldRaised := 0;
  HoldSawRequest := False;
  HoldSawCallOff := False;
  InitializeEvent(HoldDone, EventKindNotification, False);
  if CreateSystemThread(@HoldProcessor, nil, TestThreadPriority, 'SuspendHold', False) = nil then
  begin
    Check(False, 'the processor holding thread was created');
    Exit;
  end;
  SetFreezeStartHook(@StartHolding);
  Status := SuspendToRam;
  SetFreezeStartHook(nil);
  StillHeld := WaitForEventWithOptions(HoldDone, HoldLimitMilliseconds + WaitMilliseconds, False) = WaitSignaled;
  Check(AtomicLoad(HoldRaised) <> 0, 'a processor was held at dispatch level as the freeze began');
  Check(Status <> ErrorNone, 'suspend to RAM was called off when a processor did not freeze in time');
  Check(StillHeld and HoldSawRequest and HoldSawCallOff,
    'the late processor''s freeze request was called off while it was held');
  Check(NoProcessorIsFrozen, 'no processor stayed frozen after the call off');
  Check(EveryProcessorRuns, 'the late processor and the others run threads after the call off');
  ReportPassed('suspend to RAM: a processor that did not freeze in time keeps running');
end;

procedure HoldFpuValues(Context: Pointer);
begin
  SetThreadAffinity(CurrentThread, QWord(1) shl 1);
  FpuChanged := ArchSuspendTestHoldFpuValues(FpuFlags, FpuSeed);
  SignalEvent(FpuDone);
end;

{ Starts a thread on processor 1 holding the floating point values. }
function StartFpuHolder: Boolean;
var
  Deadline: QWord;
begin
  FpuFlags.LetGo := 0;
  FpuFlags.Holding := 0;
  FpuChanged := High(QWord);
  InitializeEvent(FpuDone, EventKindNotification, False);
  if CreateSystemThread(@HoldFpuValues, nil, TestThreadPriority, 'SuspendFpu', False) = nil then
    Exit(False);
  Deadline := DeadlineAfterMilliseconds(WaitMilliseconds);
  while (AtomicLoad(FpuFlags.Holding) = 0) and (ClockNanoseconds < Deadline) do
    SleepMilliseconds(1);
  Result := AtomicLoad(FpuFlags.Holding) <> 0;
end;

procedure CheckFpuHolder;
begin
  AtomicStore(FpuFlags.LetGo, 1);
  Check(WaitForEventWithOptions(FpuDone, WaitMilliseconds, False) = WaitSignaled,
    'the floating point thread finished after suspend to RAM');
  if FpuChanged <> 0 then
  begin
    DebugBeginMessage;
    DebugWriteTag('selftest');
    DebugWrite('floating point / SIMD registers changed across suspend: ');
    DebugWriteDecimal(FpuChanged);
    DebugWriteLine('');
    DebugEndMessage;
  end;
  Check(FpuChanged = 0, 'a frozen thread''s floating point and SIMD registers survived suspend to RAM');
end;

procedure RunSuspendSelfTestIfAsked;
var
  Status: LongInt;
  HoldsFpu: Boolean;
begin
  if not KernelOptionIsSet('suspendtest') then
    Exit;
  TestLateProcessor;
  HoldsFpu := (ProcessorTotal > 1) and ProcessorByIndex(1)^.IsOnline;
  if HoldsFpu then
    Check(StartFpuHolder, 'a thread on processor 1 holds floating point values');
  Status := SuspendToRam;
  if HoldsFpu then
    CheckFpuHolder;
  Check(NoProcessorIsFrozen, 'every processor resumed after suspend to RAM');
  Check(EveryProcessorRuns, 'every processor runs threads after suspend to RAM');
  if Status = ErrorNone then
    ReportPassed('suspend to RAM (PSCI SYSTEM_SUSPEND): slept, woke, every processor back')
  else
    ReportPassed('suspend to RAM (PSCI SYSTEM_SUSPEND): the firmware refused, every processor back');
end;

end.
