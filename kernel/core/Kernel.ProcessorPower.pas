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
  Processors across suspend to RAM.

  Suspend to RAM turns every processor off; only memory keeps its
  contents. Before, every processor but the boot one is frozen: asked
  (its FreezeState set to Requested) and made to run its dispatch
  interrupt, it notices there, where it holds no spin lock, commits to
  freezing (Requested to Freezing, by compare-and-exchange), stops
  answering requests from the other processors (Kernel.InterProcessor:
  a TLB shootdown would otherwise wait for it forever), saves its state
  (Kernel.Arch.Suspend), says it is Frozen and parks with interrupts
  off. The boot processor then saves its own state and calls the
  routine that puts the machine to sleep.

  A processor may not get to its dispatch interrupt in time (it runs
  with interrupts off, or above dispatch level, for long). The boot
  processor waits a while (FreezeTimeoutMilliseconds), then calls the
  freeze off processor by processor with the opposite exchange,
  Requested back to Running: where that works, the processor had not
  started and will not (it finds Running when it gets there, and goes
  on); where it does not, the processor already committed, and is
  waited for until Frozen (it runs a few instructions with interrupts
  off to get there). So each processor ends either frozen, and is
  started again by WakeOtherProcessors, or never frozen at all: none is
  left frozen with nobody to wake it.

  Waking, the firmware starts the boot processor at the waking vector:
  the start-up page (Kernel.Arch.ProcessorStartup), which takes it to
  64-bit mode and WakeEntry on a stack of its own. There it sets itself
  up again (descriptor tables, processor block, interrupt table, system
  call registers, interrupt controllers, the clock continued from where
  it paused, and its clock interrupt) and resumes its saved state: the
  saving call returns once more. Then each frozen processor is started
  again the same way (INIT, STARTUP; PSCI CPU_ON), answers requests
  again and resumes where it froze, inside its dispatch interrupt, with
  interrupts enabled again as they were there, and says it is Running.
  They share one wake stack until they resume, so each is waited for
  before the next is started; one that does not come back is a panic
  (it held a thread, and the next one would share its stack). The
  processors woken first run threads while the later ones are still
  frozen, which is why frozen ones must not be waited for otherwise.

  A frozen AArch64 processor turns itself off (PSCI CPU_OFF). Should the
  firmware refuse, it stays on and says so (HeldOn), and waits to be let
  go (Released) in place, with its state intact: the machine cannot
  have slept, since SYSTEM_SUSPEND needs every other processor off. A
  CPU_ON that the firmware refuses (the processor is still on its way
  off) is tried again until it is off or held on.

  The clock is paused last, with interrupts off and every other
  processor frozen, just before the machine sleeps: nothing reads it
  after the pause, so the uptime it continues from after waking is not
  behind any time already seen.

  Between freezing the others and starting them again the boot
  processor runs with interrupts off and takes no lock, since a frozen
  processor may still hold one at a level below dispatch.
}
unit Kernel.ProcessorPower;

{$mode objfpc}

interface

uses
  Kernel.Processors;

const
  { TProcessor.FreezeState. }
  FreezeStateRunning = 0;
  { Asked to freeze; it has not looked yet. }
  FreezeStateRequested = 1;
  { Committed: saving its state with interrupts off. }
  FreezeStateFreezing = 2;
  { Saved and parked (off, or halted). }
  FreezeStateFrozen = 3;
  { Frozen, but the firmware would not turn it off: waits in place. }
  FreezeStateHeldOn = 4;
  { Let go in place; it goes on and says Running. }
  FreezeStateReleased = 5;

type
  { Puts the machine to sleep with WakeVector as the firmware waking
    vector; does not return if it worked. }
  TEnterSleepRoutine = procedure(WakeVector: QWord);
  TFreezeStartHook = procedure;

{ Freezes every processor but this one (the boot processor, which the
  caller runs on). False if one did not freeze in time: the others may
  be frozen, and WakeOtherProcessors starts them again. }
function FreezeOtherProcessors: Boolean;
{ Saves this processor's state, calls EnterSleep, and returns once the
  machine woke and every processor runs again (interrupts still off);
  False if the machine did not go to sleep. }
function SleepAndWake(EnterSleep: TEnterSleepRoutine): Boolean;
{ Starts again the processors that froze (when the machine did not go
  to sleep after all). }
procedure WakeOtherProcessors;
{ For the dispatch interrupt: freezes this processor if asked to. }
procedure FreezeThisProcessorIfRequested;
{ True while Processor is frozen (or on its way there or back). }
function ProcessorIsFrozen(Processor: PProcessor): Boolean;
{ For the self test: Hook runs as FreezeOtherProcessors begins, before
  any processor is asked (nil: none). }
procedure SetFreezeStartHook(Hook: TFreezeStartHook);

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Arch.Suspend,
  Kernel.Arch.ProcessorStartup,
  Kernel.InterProcessor,
  Kernel.Clock,
  Kernel.Panic,
  Hal.Platform;

const
  FreezeTimeoutMilliseconds = 1000;
  { For one processor to come back once started, and for a committed
    one to finish freezing: far longer than either takes. }
  ResumeTimeoutMilliseconds = 10000;
  { Between tries of a start the firmware refused. }
  StartRetrySpins = 100000;
  WakeStackSize = 16384;

var
  { The stack a woken processor runs on until it resumes its own state
    (one processor at a time). }
  WakeStack: array[0..WakeStackSize - 1] of Byte;
  FreezeStartHook: TFreezeStartHook = nil;

procedure SetFreezeStartHook(Hook: TFreezeStartHook);
begin
  FreezeStartHook := Hook;
end;

function WakeStackTop: QWord;
begin
  Result := (QWord(@WakeStack[0]) + WakeStackSize) and not QWord(15);
end;

function FreezeStateOf(Processor: PProcessor): PtrUInt;
begin
  Result := AtomicLoad(Processor^.FreezeState);
end;

function ProcessorIsFrozen(Processor: PProcessor): Boolean;
begin
  Result := FreezeStateOf(Processor) >= FreezeStateFreezing;
end;

function IsOtherOnlineProcessor(Processor: PProcessor): Boolean;
begin
  Result := (Processor <> nil) and (Processor <> CurrentProcessor) and Processor^.IsOnline;
end;

{ The firmware would not turn this processor off: it waits here, still
  on, until WakeOtherProcessors lets it go. }
procedure WaitToBeReleasedInPlace(Processor: PProcessor);
begin
  AtomicStore(Processor^.FreezeState, FreezeStateHeldOn);
  while FreezeStateOf(Processor) <> FreezeStateReleased do
    CpuRelax;
  { Its interrupt controller kept its settings. }
  ResumeAnsweringRequests;
end;

procedure FreezeThisProcessorIfRequested;
var
  Processor: PProcessor;
  InterruptsWereEnabled: Boolean;
begin
  Processor := CurrentProcessor;
  if FreezeStateOf(Processor) <> FreezeStateRequested then
    Exit;
  InterruptsWereEnabled := SaveAndDisableInterrupts;
  { Called off since it looked: go on. }
  if AtomicCompareExchange(Processor^.FreezeState, FreezeStateFreezing, FreezeStateRequested) <>
     FreezeStateRequested then
  begin
    RestoreInterrupts(InterruptsWereEnabled);
    Exit;
  end;
  StopAnsweringRequests;
  if ArchSaveSuspendContext(Processor^.SuspendContext) = 0 then
  begin
    AtomicStore(Processor^.FreezeState, FreezeStateFrozen);
    { Until the machine sleeps: halted (INIT ends it), or off (AArch64,
      PSCI CPU_OFF; CPU_ON starts it again). Returns only if it could
      not be turned off. }
    ArchParkFrozenProcessor;
    WaitToBeReleasedInPlace(Processor);
  end;
  { Started again after waking (or let go in place): resumed here,
    inside the dispatch interrupt and at its level (the saved state
    holds the priority level), as the rest of it takes the dispatcher
    lock. Off the wake stack now, which the next processor may take. }
  AtomicStore(Processor^.FreezeState, FreezeStateRunning);
  { The saved state has interrupts off (they were disabled to save it);
    the rest of the dispatch interrupt runs as it would have. }
  RestoreInterrupts(InterruptsWereEnabled);
end;

{ Waits until Processor leaves the states in which it is between two
  of its own steps, or panics with Reason. }
procedure WaitWhileFreezeStateIs(Processor: PProcessor; State: PtrUInt; Reason: PChar);
var
  Deadline: QWord;
begin
  Deadline := DeadlineAfterMilliseconds(ResumeTimeoutMilliseconds);
  while FreezeStateOf(Processor) = State do
  begin
    if ClockNanoseconds >= Deadline then
      KernelPanicWithCode(PanicSchedulerFailure, Reason, Processor^.Index, State, 0, 0);
    CpuRelax;
  end;
end;

{ After the wait for freezing ran out: each processor still asked is
  told not to (if it has not committed yet) or waited for. }
procedure CallOffFreeze;
var
  Index: LongWord;
  Processor: PProcessor;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if not IsOtherOnlineProcessor(Processor) then
      Continue;
    if AtomicCompareExchange(Processor^.FreezeState, FreezeStateRunning, FreezeStateRequested) =
       FreezeStateRequested then
      Continue;
    WaitWhileFreezeStateIs(Processor, FreezeStateFreezing, 'a processor did not finish freezing');
  end;
end;

function FreezeOtherProcessors: Boolean;
var
  Index: LongWord;
  Processor: PProcessor;
  Deadline: QWord;
begin
  if Assigned(FreezeStartHook) then
    FreezeStartHook();
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if not IsOtherOnlineProcessor(Processor) then
      Continue;
    AtomicStore(Processor^.FreezeState, FreezeStateRequested);
    HalRequestDispatchOn(Processor^.ApicId);
  end;
  Result := True;
  Deadline := DeadlineAfterMilliseconds(FreezeTimeoutMilliseconds);
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if not IsOtherOnlineProcessor(Processor) then
      Continue;
    while (FreezeStateOf(Processor) <> FreezeStateFrozen) and (ClockNanoseconds < Deadline) do
      CpuRelax;
    if FreezeStateOf(Processor) <> FreezeStateFrozen then
    begin
      Result := False;
      Break;
    end;
  end;
  if not Result then
    CallOffFreeze;
end;

{ Where a woken processor arrives (in 64-bit mode, on the wake stack). }
procedure WakeEntry(Processor: PProcessor);
begin
  ReinitializeThisProcessor(Processor);
  if Processor^.Index = 0 then
  begin
    HalContinueClockAfterSleep;
    HalResumeBootProcessor;
  end
  else
  begin
    HalInitializeSecondaryProcessor;
    ResumeAnsweringRequests;
  end;
  { The clock continues where it paused (the boot processor resumes
    first), so each processor's next tick and due times still hold. }
  StartClockOnThisProcessor;
  ArchResumeSuspendContext(Processor^.SuspendContext);
end;

{ Starts one frozen processor again (or lets it go in place) and waits
  until it resumed and left the wake stack. }
procedure WakeProcessor(Processor: PProcessor);
var
  Deadline: QWord;
  Started: Boolean;
  Spins: LongWord;
begin
  Started := False;
  Deadline := DeadlineAfterMilliseconds(ResumeTimeoutMilliseconds);
  while FreezeStateOf(Processor) <> FreezeStateRunning do
  begin
    if ClockNanoseconds >= Deadline then
      KernelPanicWithCode(PanicSchedulerFailure, 'a processor did not come back after suspend to RAM',
        Processor^.Index, FreezeStateOf(Processor), 0, 0);
    case FreezeStateOf(Processor) of
      FreezeStateHeldOn:
        AtomicStore(Processor^.FreezeState, FreezeStateReleased);
      FreezeStateFrozen:
        if not Started then
        begin
          Started := StartProcessor(Processor, WakeStackTop, @WakeEntry);
          { Refused: still on its way off; try again in a moment. }
          if not Started then
            for Spins := 1 to StartRetrySpins do
              CpuRelax;
        end;
    end;
    CpuRelax;
  end;
end;

{ Starts every frozen processor again, one at a time. }
procedure WakeOtherProcessors;
var
  Index: LongWord;
  Processor: PProcessor;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if not IsOtherOnlineProcessor(Processor) then
      Continue;
    { A committed one gets to Frozen first. }
    WaitWhileFreezeStateIs(Processor, FreezeStateFreezing, 'a processor did not finish freezing');
    if FreezeStateOf(Processor) <> FreezeStateRunning then
      WakeProcessor(Processor);
  end;
end;

function SleepAndWake(EnterSleep: TEnterSleepRoutine): Boolean;
var
  Processor: PProcessor;
  WakeVector: QWord;
begin
  Processor := CurrentProcessor;
  HalPrepareForSleep;
  WakeVector := PrepareWakeEntry(Processor, WakeStackTop, @WakeEntry);
  DisableInterrupts;
  if ArchSaveSuspendContext(Processor^.SuspendContext) = 0 then
  begin
    { Last: nothing reads the clock between here and the sleep. }
    HalPauseClockForSleep;
    EnterSleep(WakeVector);
    { Still here: the machine did not sleep, and the clock ran on. }
    Result := False;
  end
  else
    Result := True;
  WakeOtherProcessors;
end;

end.
