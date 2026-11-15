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
  (Kernel.Arch.ProcessorStartup).
}
unit Kernel.Processors;

{$mode objfpc}

interface

uses
  Kernel.Threads,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.Suspend;

const
  MaximumProcessors = 32;

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
    { Set by the clock interrupt; read and cleared under the dispatcher
      lock by the dispatch interrupt (Kernel.Scheduler). }
    QuantumHasExpired: Boolean;
    { The address space this processor has loaded (TLB shootdowns are
      only sent where it matters). }
    ActiveAddressSpace: QWord;
    { Requests from other processors (Kernel.InterProcessor). }
    PendingRequests: LongWord;
    { Where the clock interrupt last found the processor (for the hang
      dump: a processor stuck in a loop shows where). }
    InterruptedAddress: QWord;
    { The double fault, NMI and machine check stacks (a secondary
      processor's; the boot processor's are static). }
    InterruptStackArea: Pointer;
    DescriptorTables: TProcessorDescriptorTables;
    { Suspend to RAM (Kernel.ProcessorPower): asked to freeze, frozen,
      and the state it froze in. }
    FreezeRequested: Boolean;
    Frozen: Boolean;
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
  ProcessorsStarted: LongWord = 0;
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
  Result^.Index := ProcessorsStarted;
  Result^.ApicId := ApicId;
  Processors[ProcessorsStarted] := Result;
  Inc(ProcessorsStarted);
end;

procedure MarkProcessorOnline(Processor: PProcessor);
begin
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
  Result := ProcessorsStarted;
end;

function OnlineProcessorCount: LongWord;
begin
  Result := LongWord(AtomicFetchAndAdd(ProcessorsOnline, 0));
end;

function ProcessorByIndex(Index: LongWord): PProcessor;
begin
  if Index >= ProcessorsStarted then
    Exit(nil);
  Result := Processors[Index];
end;

end.
