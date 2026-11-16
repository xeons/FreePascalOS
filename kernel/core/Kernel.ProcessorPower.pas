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
  (FreezeRequested) and made to run its dispatch interrupt, it notices
  there, where it holds no spin lock, saves its state
  (Kernel.Arch.Suspend) and halts with interrupts off. The boot
  processor then saves its own state and calls the routine that puts
  the machine to sleep.

  Waking, the firmware starts the boot processor at the waking vector:
  the start-up page (Kernel.Arch.ProcessorStartup), which takes it to
  64-bit mode and WakeEntry on a stack of its own. There it sets itself
  up again (descriptor tables, processor block, interrupt table, system
  call registers, interrupt controllers, the clock continued from where
  it paused, and its clock interrupt) and resumes its
  saved state: the saving call returns once more. Then each frozen
  processor is started again the same way (INIT, STARTUP) and resumes
  where it froze, inside its dispatch interrupt.

  Between freezing the others and starting them again the boot
  processor runs with interrupts off and takes no lock, since a frozen
  processor may still hold one at a level below dispatch.
}
unit Kernel.ProcessorPower;

{$mode objfpc}

interface

type
  { Puts the machine to sleep with WakeVector as the firmware waking
    vector; does not return if it worked. }
  TEnterSleepRoutine = procedure(WakeVector: QWord);

{ Freezes every processor but this one (the boot processor, which the
  caller runs on). False if one did not freeze in time. }
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

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Arch.Suspend,
  Kernel.Arch.ProcessorStartup,
  Kernel.Processors,
  Kernel.Clock,
  Hal.Platform,
  Debug.Output;

const
  FreezeWaitSpins = 200000000;
  WakeStackSize = 16384;

var
  { The stack a woken processor runs on until it resumes its own state
    (one processor at a time). }
  WakeStack: array[0..WakeStackSize - 1] of Byte;

function WakeStackTop: QWord;
begin
  Result := (QWord(@WakeStack[0]) + WakeStackSize) and not QWord(15);
end;

procedure FreezeThisProcessorIfRequested;
var
  Processor: PProcessor;
begin
  Processor := CurrentProcessor;
  if not Processor^.FreezeRequested then
    Exit;
  DisableInterrupts;
  if ArchSaveSuspendContext(Processor^.SuspendContext) = 0 then
  begin
    FullMemoryBarrier;
    Processor^.Frozen := True;
    { Until the machine sleeps; INIT ends this. }
    while True do
      HaltProcessor;
  end;
  { Started again after waking: resumed here, inside the dispatch
    interrupt and at its level (the saved state holds the priority
    level), as the rest of it takes the dispatcher lock. }
  Processor^.FreezeRequested := False;
  Processor^.Frozen := False;
end;

function FreezeOtherProcessors: Boolean;
var
  Index: LongWord;
  Processor: PProcessor;
  Spins: QWord;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if (Processor = CurrentProcessor) or not Processor^.IsOnline then
      Continue;
    Processor^.Frozen := False;
    FullMemoryBarrier;
    Processor^.FreezeRequested := True;
    HalRequestDispatchOn(Processor^.ApicId);
  end;
  Result := True;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if (Processor = CurrentProcessor) or not Processor^.IsOnline then
      Continue;
    Spins := 0;
    while not Processor^.Frozen and (Spins < FreezeWaitSpins) do
    begin
      CpuRelax;
      Inc(Spins);
    end;
    if not Processor^.Frozen then
      Result := False;
  end;
end;

{ Where a woken processor arrives (in 64-bit mode, on the wake stack). }
procedure WakeEntry(Processor: PProcessor);
begin
  ReinitializeThisProcessor(Processor);
  if Processor^.Index = 0 then
    HalResumeBootProcessor
  else
    HalInitializeSecondaryProcessor;
  { The clock continues where it paused (the boot processor resumes
    first), so each processor's next tick and due times still hold. }
  StartClockOnThisProcessor;
  ArchResumeSuspendContext(Processor^.SuspendContext);
end;

{ Starts every frozen processor again and waits until each resumed. }
procedure WakeOtherProcessors;
var
  Index: LongWord;
  Processor: PProcessor;
  Spins: QWord;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if (Processor = CurrentProcessor) or not Processor^.IsOnline or not Processor^.Frozen then
      Continue;
    StartProcessor(Processor, WakeStackTop, @WakeEntry);
    { One at a time: they share the wake stack until they resume. }
    Spins := 0;
    while Processor^.Frozen and (Spins < FreezeWaitSpins) do
    begin
      CpuRelax;
      Inc(Spins);
    end;
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
    EnterSleep(WakeVector);
    { Still here: the machine did not sleep. }
    Result := False;
  end
  else
    Result := True;
  WakeOtherProcessors;
end;

end.
