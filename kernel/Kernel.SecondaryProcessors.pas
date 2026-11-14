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
  within a second is given up on.

  The kernel option "processors=N" limits how many processors run (1
  keeps the system on the boot processor).
}
unit Kernel.SecondaryProcessors;

{$mode objfpc}

interface

type
  TIdleRoutine = procedure;

{ Starts the secondary processors; each ends up running IdleRoutine as
  its idle thread. Called from a thread, with the scheduler running. }
procedure StartSecondaryProcessors(IdleRoutine: TIdleRoutine);

implementation

uses
  Runtime.Text,
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
  Processes.Thread,
  Debug.Output;

const
  StartTimeoutMilliseconds = 1000;

var
  SecondaryIdleRoutine: TIdleRoutine;

procedure SecondaryProcessorEntry(Processor: PProcessor);
begin
  InitializeThisSecondaryProcessor(Processor);
  StartSchedulingOnThisProcessor(Processor^.IdleThread);
  EnableInterrupts;
  SecondaryIdleRoutine;
end;

{ The decimal number in Text, or 0 if Text is not one. }
function DecimalValue(Text: PChar): QWord;
var
  Index: Integer;
begin
  Result := 0;
  Index := 0;
  while Text[Index] in ['0'..'9'] do
  begin
    Result := Result * 10 + QWord(Ord(Text[Index]) - Ord('0'));
    Inc(Index);
  end;
  if (Index = 0) or (Text[Index] <> #0) then
    Result := 0;
end;

function ProcessorLimit: LongWord;
var
  Value: array[0..15] of Char;
  Number: QWord;
begin
  Result := MaximumProcessors;
  if GetKernelOptionValue('processors', @Value[0], SizeOf(Value)) then
  begin
    Number := DecimalValue(@Value[0]);
    if (Number >= 1) and (Number < MaximumProcessors) then
      Result := LongWord(Number);
  end;
end;

{ Creates what processor ApicId needs and wakes it. Returns True once it
  is online. }
function BringUpProcessor(ApicId: LongWord): Boolean;
var
  Processor: PProcessor;
  Stack: TKernelStack;
  IdleThread: PThread;
  Waited: LongWord;
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

  StartProcessor(Processor, Stack.Top, @SecondaryProcessorEntry);
  Waited := 0;
  while not Processor^.IsOnline and (Waited < StartTimeoutMilliseconds) do
  begin
    SleepMilliseconds(1);
    Inc(Waited);
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
    if PrepareProcessorStartup then
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

end.
