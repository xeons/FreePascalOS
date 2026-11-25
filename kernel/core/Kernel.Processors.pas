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
  Processors and their data blocks.

  Each processor has a TProcessor block with what is private to it: the
  thread it runs, its idle thread, the scheduler's per-processor state,
  its descriptor tables and the stacks the system call entry uses. A
  processor reaches its own block through CurrentProcessor (on x86-64
  through the GS base, see Kernel.Arch.ProcessorBlock).

  Code running at PassiveLevel may be moved to another processor at any
  moment, so a block may only be used at DispatchLevel or above (or with
  interrupts off); CurrentThread is the exception, being read in one step.

  The boot processor's block is static, so it exists before the kernel
  heap. The blocks of the other processors are allocated as they start
  (Kernel.Arch.ProcessorStartup). A new block is filled in and put in
  the table before the count of started processors is raised, with a
  release store, and ProcessorTotal reads the count with an acquire
  load: whoever sees the count sees the block (AArch64 orders neither
  by itself). IsOnline likewise is set only after everything the block
  needs to run threads is in place.
}
unit Kernel.Processors;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Kernel.SpinLock,
  Kernel.Threads,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.Suspend;

const
  MaximumProcessors = 32;
  { Idle states a processor may know (Kernel.IdleStates). }
  MaximumIdleStates = 8;

type
  PProcessor = ^TProcessor;
  TProcessor = record
    { --- Fixed layout (Kernel.Arch.ProcessorBlock offsets) --- }
    Self: PProcessor;
    RunningThread: PThreadControlBlock;
    { Kernel stack the system call entry switches to (the running
      thread's), and where it parks the user stack pointer meanwhile. }
    SystemCallStack: QWord;
    UserStackScratch: QWord;

    { --- Everything else --- }
    { 0 for the boot processor, then in the order they started. }
    Index: LongWord;
    { The interrupt controller's id, used to send it interrupts. }
    ApicId: LongWord;
    IsOnline: Boolean;
    IdleThread: PThreadControlBlock;
    { 1 once the running thread's time slice is over: set by the clock
      interrupt, read and cleared in one atomic exchange by the dispatch
      interrupt (Kernel.Scheduler). }
    QuantumHasExpired: PtrUInt;
    { Its clock (Kernel.Clock): when its next 10 ms tick is due
      (High(QWord): the tick is stopped, while it idles) and when its
      clock interrupt is set to come (High(QWord): not set), in clock
      nanoseconds. }
    NextTickTime: QWord;
    ClockInterruptTime: QWord;
    { How many clock interrupts it took (its tick stops while it idles,
      so an idle processor takes few), and how often it entered each of
      the idle states (Kernel.IdleStates). }
    ClockInterruptCount: QWord;
    { Of those, the ones that found a tick, a timer or a wake-up due
      (several may be due at once; the rest came early or for the
      longest wait). }
    TickInterruptCount: QWord;
    TimerInterruptCount: QWord;
    WakeUpInterruptCount: QWord;
    IdleStateEntries: array[0..MaximumIdleStates - 1] of QWord;
    { The timers set on it (Kernel.Timers), ordered by due time, the lock
      that protects them (taken with interrupts disabled) and the first
      due time (High(QWord): none). }
    TimerQueue: TListEntry;
    TimerQueueLock: TSpinLock;
    NextTimerDueTime: QWord;
    { The threads that began a wait with a timeout on it (Kernel.Scheduler,
      under the dispatcher lock), ordered by wake-up time, and the first
      wake-up time (High(QWord): none). }
    SleepQueue: TListEntry;
    NextWakeUpTime: QWord;
    { The address space this processor has loaded (TLB shootdowns are
      only sent where it matters). }
    ActiveAddressSpace: QWord;
    { Requests from other processors (Kernel.InterProcessor): 1 while
      it answers them (0 while frozen for suspend to RAM), and 1 while a
      TLB shootdown waits for it. }
    AnswersRequests: PtrUInt;
    ShootdownPending: PtrUInt;
    { Processor time (Kernel.ProcessorTime), in clock nanoseconds:
      since when the running thread runs, and the time spent idle (in
      the idle thread) and busy so far. Changed at every switch, under
      the processor's scheduling lock (Kernel.ReadyQueues). }
    RunningSince: QWord;
    IdleNanoseconds: QWord;
    BusyNanoseconds: QWord;
    { Where the clock interrupt last found the processor (for the hang
      dump: a processor stuck in a loop shows where). }
    InterruptedAddress: QWord;
    { The top of the kernel stack it was interrupted on (nothing if it
      was in user mode): with the address, a rough call chain. }
    InterruptedStack: array[0..31] of QWord;
    InterruptedStackWords: LongWord;
    { The double fault, NMI and machine check stacks (a secondary
      processor's; the boot processor's are static). }
    InterruptStackArea: Pointer;
    DescriptorTables: TProcessorDescriptorTables;
    { Suspend to RAM (Kernel.ProcessorPower): where it is in freezing
      (FreezeState*, changed only by compare-and-exchange or by the one
      side that owns the state it is in), and the state it froze in. }
    FreezeState: PtrUInt;
    SuspendContext: TArchSuspendContext;
  end;

{ Sets up the boot processor's block. The caller makes it current
  (ArchSetProcessorBlock) once the descriptor tables are loaded. }
function InitializeBootProcessorBlock(ApicId: LongWord): PProcessor;
{ A zeroed block for the next processor to start, or nil. }
function AllocateProcessorBlock(ApicId: LongWord): PProcessor;
{ Called by a processor once it can run threads. }
procedure MarkProcessorOnline(Processor: PProcessor);

function CurrentProcessor: PProcessor;
function CurrentProcessorIndex: LongWord;
{ Like CurrentProcessorIndex, but also usable before the boot processor's
  block is in place (then 0). }
function CurrentProcessorIndexOrZero: LongWord;
{ Called once the boot processor's block is current. }
procedure MarkProcessorBlocksReady;
{ Whether the processor blocks are in place (CurrentProcessor works). }
function ProcessorBlocksAreReady: Boolean;
{ Processors that have been started (online or about to be). }
function ProcessorTotal: LongWord;
function OnlineProcessorCount: LongWord;
{ nil past the end. }
function ProcessorByIndex(Index: LongWord): PProcessor;

implementation

uses
  Runtime.Atomic,
  Runtime.Memory,
  Memory.KernelHeap,
  Kernel.Arch.ProcessorBlock;

var
  BootProcessorBlock: TProcessor;
  Processors: array[0..MaximumProcessors - 1] of PProcessor;
  { Raised (AtomicStore) only once the new block is in the table. }
  ProcessorsStarted: PtrUInt = 0;
  ProcessorsOnline: Int64 = 0;
  BlocksAreReady: Boolean = False;

function InitializeBootProcessorBlock(ApicId: LongWord): PProcessor;
begin
  ZeroMemory(@BootProcessorBlock, SizeOf(BootProcessorBlock));
  BootProcessorBlock.Self := @BootProcessorBlock;
  BootProcessorBlock.Index := 0;
  BootProcessorBlock.ApicId := ApicId;
  Processors[0] := @BootProcessorBlock;
  ProcessorsStarted := 1;
  Result := @BootProcessorBlock;
end;

function AllocateProcessorBlock(ApicId: LongWord): PProcessor;
begin
  if ProcessorsStarted >= MaximumProcessors then
    Exit(nil);
  Result := PProcessor(AllocateZeroedKernelMemory(SizeOf(TProcessor)));
  if Result = nil then
    Exit;
  Result^.Self := Result;
  Result^.Index := LongWord(ProcessorsStarted);
  Result^.ApicId := ApicId;
  Processors[ProcessorsStarted] := Result;
  FullMemoryBarrier;
  AtomicStore(ProcessorsStarted, ProcessorsStarted + 1);
end;

procedure MarkProcessorOnline(Processor: PProcessor);
begin
  { Its interrupt controller is set up by now. }
  AtomicStore(Processor^.AnswersRequests, 1);
  { Its idle thread, scheduling state and clock are set up before it is
    seen online. }
  FullMemoryBarrier;
  Processor^.IsOnline := True;
  AtomicIncrement(ProcessorsOnline);
end;

function CurrentProcessor: PProcessor;
begin
  Result := PProcessor(ArchCurrentProcessorBlock);
end;

function CurrentProcessorIndex: LongWord;
begin
  Result := CurrentProcessor^.Index;
end;

function ProcessorBlocksAreReady: Boolean;
begin
  Result := BlocksAreReady;
end;

function CurrentProcessorIndexOrZero: LongWord;
begin
  if BlocksAreReady then
    Result := CurrentProcessor^.Index
  else
    Result := 0;
end;

procedure MarkProcessorBlocksReady;
begin
  BlocksAreReady := True;
end;

function ProcessorTotal: LongWord;
begin
  Result := LongWord(AtomicLoad(ProcessorsStarted));
end;

function OnlineProcessorCount: LongWord;
begin
  Result := LongWord(AtomicFetchAndAdd(ProcessorsOnline, 0));
end;

function ProcessorByIndex(Index: LongWord): PProcessor;
begin
  if Index >= ProcessorTotal then
    Exit(nil);
  Result := Processors[Index];
end;

end.
