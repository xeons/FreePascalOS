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
  Bringing up the other processors.

  The firmware's MADT lists every processor by its interrupt controller
  id. Each one other than the boot processor gets a block, an idle thread
  (with a kernel stack, on which it starts) and stacks for the double
  fault, NMI and machine check exceptions, and is woken; once it reports
  itself online the next one follows. A processor that does not come up
  within StartTimeoutMilliseconds is given up on, and no more are started
  (they would share its start-up record while it might still read it).
  Giving up and arriving are settled by one compare-and-exchange on the
  block (StartClaim): a processor that arrives after it was given up on
  halts at once instead of joining, and one that claimed its block just
  before is waited for. The block and stacks of a processor given up on
  stay allocated, since it might still be running on them.

  The kernel option "processors=N" limits how many processors run (1
  keeps the system on the boot processor).

  A processor plugged in later (ACPI processor hotplug, Io.AcpiPower:
  a Notify on its processor object, its _STA and _MAT) is brought up
  the same way by BringUpPluggedProcessor, the start-up code prepared
  first if no other processor needed it at start. One at a time (the
  start-up record is shared).
}
unit Kernel.SecondaryProcessors;

{$mode objfpc}

interface

type
  TIdleRoutine = procedure;

{ Starts the secondary processors; each ends up running IdleRoutine as
  its idle thread. Called from a thread, with the scheduler running. }
procedure StartSecondaryProcessors(IdleRoutine: TIdleRoutine);
{ Brings up the processor with interrupt controller id ApicId, plugged
  in since start. False if it is running already, would pass the
  processor limit, or did not start. Passive level, from a thread. }
function BringUpPluggedProcessor(ApicId: LongWord): Boolean;

implementation

uses
  Runtime.Text,
  Runtime.Atomic,
  Memory.KernelHeap,
  Memory.KernelStacks,
  Memory.Arch.PageTables,
  Firmware.Madt,
  Kernel.Arch.Cpu,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.ProcessorStartup,
  Kernel.Options,
  Kernel.Processors,
  Kernel.InterProcessor,
  Kernel.Scheduler,
  Kernel.Clock,
  Kernel.Timers,
  Processes.Thread,
  Debug.Output;

const
  { Generous: starting a processor is slow in an emulator. }
  StartTimeoutMilliseconds = 10000;

var
  SecondaryIdleRoutine: TIdleRoutine;
  StartupPrepared: Boolean = False;
  RequestsInitialized: Boolean = False;

procedure SecondaryProcessorEntry(Processor: PProcessor);
begin
  if AtomicCompareExchange(Processor^.StartClaim, ProcessorStartJoined, ProcessorStartPending) <>
     ProcessorStartPending then
    { Given up on: too late to join. }
    while True do
    begin
      DisableInterrupts;
      HaltProcessor;
    end;
  InitializeThisSecondaryProcessor(Processor);
  InitializeProcessorTimers(Processor);
  StartSchedulingOnThisProcessor(Processor^.IdleThread);
  StartClockOnThisProcessor;
  EnableInterrupts;
  SecondaryIdleRoutine;
end;

function ProcessorLimit: LongWord;
var
  Number: QWord;
begin
  Result := MaximumProcessors;
  if GetKernelOptionNumber('processors', Number) and (Number >= 1) and (Number < MaximumProcessors) then
    Result := LongWord(Number);
end;

{ Creates what processor ApicId needs and wakes it. Returns True once it
  is online. }
function BringUpProcessor(ApicId: LongWord): Boolean;
var
  Processor: PProcessor;
  Stack: TKernelStack;
  IdleThread: PThread;
  Deadline: QWord;
begin
  Result := False;
  Processor := AllocateProcessorBlock(ApicId);
  if Processor = nil then
    Exit;
  Processor^.InterruptStackArea := AllocateKernelMemory(InterruptStackAreaSize);
  if (Processor^.InterruptStackArea = nil) or
     not AllocateKernelStack(DefaultKernelStackSize, Stack) then
    Exit;
  IdleThread := CreateIdleThreadFromBootContext(Stack.Base, Stack.Top);
  Processor^.IdleThread := @IdleThread^.ControlBlock;

  if not StartProcessor(Processor, Stack.Top, @SecondaryProcessorEntry) then
    AtomicCompareExchange(Processor^.StartClaim, ProcessorStartAbandoned, ProcessorStartPending);
  Deadline := DeadlineAfterMilliseconds(StartTimeoutMilliseconds);
  while not Processor^.IsOnline and (ClockNanoseconds < Deadline) and
    (AtomicLoad(Processor^.StartClaim) <> ProcessorStartAbandoned) do
    SleepMilliseconds(1);
  if not Processor^.IsOnline and
     (AtomicCompareExchange(Processor^.StartClaim, ProcessorStartAbandoned, ProcessorStartPending) =
      ProcessorStartJoined) then
  begin
    { It arrived just now: it finishes starting. }
    Deadline := DeadlineAfterMilliseconds(StartTimeoutMilliseconds);
    while not Processor^.IsOnline and (ClockNanoseconds < Deadline) do
      SleepMilliseconds(1);
  end;
  Result := Processor^.IsOnline;
end;

procedure StartSecondaryProcessors(IdleRoutine: TIdleRoutine);
var
  Index: Integer;
  ApicId: LongWord;
  BootApicId: LongWord;
  Limit: LongWord;
begin
  SecondaryIdleRoutine := IdleRoutine;
  Limit := ProcessorLimit;
  BootApicId := CurrentProcessor^.ApicId;
  if (ListedProcessorCount > 1) and (Limit > 1) then
  begin
    InitializeInterProcessorRequests;
    SetRemoteInvalidation(@InvalidateRemoteTranslations);
    RequestsInitialized := True;
    StartupPrepared := PrepareProcessorStartup;
    if StartupPrepared then
    begin
      for Index := 0 to ListedProcessorCount - 1 do
      begin
        ApicId := ListedProcessorApicId(Index);
        if ApicId = BootApicId then
          Continue;
        if ProcessorTotal >= Limit then
          Break;
        if not BringUpProcessor(ApicId) then
        begin
          DebugBeginMessage;
          DebugWriteTag('smp');
          DebugWrite('processor with APIC id ');
          DebugWriteDecimal(ApicId);
          DebugWriteLine(' did not start');
          DebugEndMessage;
          Break;
        end;
      end;
    end
    else
    begin
      DebugBeginMessage;
      DebugWriteTag('smp');
      DebugWriteLine('no free memory below 1 MiB to start the other processors in');
      DebugEndMessage;
    end;
  end;

  DebugBeginMessage;
  DebugWriteTag('smp');
  DebugWriteDecimal(OnlineProcessorCount);
  if OnlineProcessorCount = 1 then
    DebugWriteLine(' processor running')
  else
    DebugWriteLine(' processors running');
  DebugEndMessage;
end;

function ProcessorIsKnown(ApicId: LongWord): Boolean;
var
  Index: LongWord;
  Processor: PProcessor;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if (Processor <> nil) and (Processor^.ApicId = ApicId) then
      Exit(True);
  end;
  Result := False;
end;

function BringUpPluggedProcessor(ApicId: LongWord): Boolean;
begin
  Result := False;
  if ProcessorIsKnown(ApicId) or (ProcessorTotal >= ProcessorLimit) or (SecondaryIdleRoutine = nil) then
    Exit;
  if not RequestsInitialized then
  begin
    InitializeInterProcessorRequests;
    SetRemoteInvalidation(@InvalidateRemoteTranslations);
    RequestsInitialized := True;
  end;
  if not StartupPrepared then
    StartupPrepared := PrepareProcessorStartup;
  if not StartupPrepared then
    Exit;
  Result := BringUpProcessor(ApicId);
  DebugBeginMessage;
  DebugWriteTag('smp');
  DebugWrite('processor with APIC id ');
  DebugWriteDecimal(ApicId);
  if Result then
  begin
    DebugWrite(' plugged in and running; ');
    DebugWriteDecimal(OnlineProcessorCount);
    DebugWriteLine(' processors running');
  end
  else
    DebugWriteLine(' plugged in, but did not start');
  DebugEndMessage;
end;

end.
