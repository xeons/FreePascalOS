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
  The whole system's processor time and memory (CallGetSystemUsage):
  each processor's busy and idle time, how many processes and threads
  there are, and what the RAM is used for.

  The memory figures come from the page allocator's count of pages per
  use (Memory.PhysicalPages), so they add up to the RAM there is: what
  processes have of their own, the program and library files they
  share, sections, the block cache, the kernel's heap, stacks and page
  tables, the kernel itself and drivers' buffers.
}
unit Processes.SystemUsage;

{$mode objfpc}

interface

function PerformGetSystemUsage(UsageAddress: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.PhysicalPages,
  Kernel.Clock,
  Kernel.Scheduler,
  Kernel.Processors,
  Kernel.ProcessorTime,
  Processes.Process,
  Processes.UserAccess;

procedure DescribeProcessors(var Usage: TAbiSystemUsage);
var
  Index: LongWord;
  Processor: PProcessor;
begin
  Usage.ProcessorCount := ProcessorTotal;
  if Usage.ProcessorCount > AbiMaximumProcessors then
    Usage.ProcessorCount := AbiMaximumProcessors;
  Index := 0;
  while Index < Usage.ProcessorCount do
  begin
    Processor := ProcessorByIndex(Index);
    if (Processor <> nil) and Processor^.IsOnline then
      Usage.Processors[Index].Online := 1;
    GetProcessorTimes(Index, Usage.Processors[Index].BusyNanoseconds, Usage.Processors[Index].IdleNanoseconds);
    Inc(Index);
  end;
end;

procedure CountOne(Process: PProcess; Context: Pointer);
begin
  Inc(PAbiSystemUsage(Context)^.ProcessCount);
  Inc(PAbiSystemUsage(Context)^.ThreadCount, Process^.ThreadCount);
end;

procedure CountProcesses(var Usage: TAbiSystemUsage);
begin
  LockProcessRegistry;
  VisitRunningProcessesLocked(@CountOne, @Usage);
  UnlockProcessRegistry;
  { The kernel's own threads (the idle threads among them). }
  Inc(Usage.ThreadCount, SystemProcess^.ThreadCount);
end;

procedure DescribeMemory(var Usage: TAbiSystemUsage);
var
  Statistics: TPhysicalMemoryStatistics;
  Counts: TPageUsageCounts;
begin
  GetPhysicalMemoryStatistics(Statistics);
  GetPageUsageCounts(Counts);
  Usage.TotalMemory := Statistics.TotalUsablePages * PageSize;
  Usage.FreeMemory := Statistics.FreePages * PageSize;
  Usage.UserMemory := Counts[PageUsageUserMemory] * PageSize;
  Usage.ProgramImageMemory := Counts[PageUsageProgramImage] * PageSize;
  Usage.SectionMemory := Counts[PageUsageSection] * PageSize;
  Usage.BlockCacheMemory := Counts[PageUsageBlockCache] * PageSize;
  Usage.KernelHeapMemory := Counts[PageUsageKernelHeap] * PageSize;
  Usage.KernelStackMemory := Counts[PageUsageKernelStack] * PageSize;
  Usage.PageTableMemory := Counts[PageUsagePageTable] * PageSize;
  Usage.KernelImageMemory := (Counts[PageUsageKernelImage] + Counts[PageUsageBootData] +
    Counts[PageUsageFrameDatabase]) * PageSize;
  Usage.DriverMemory := Counts[PageUsageGeneral] * PageSize;
end;

function PerformGetSystemUsage(UsageAddress: QWord): Int64;
var
  Usage: TAbiSystemUsage;
begin
  FillMemory(@Usage, SizeOf(Usage), 0);
  Usage.UptimeNanoseconds := ClockNanoseconds;
  Usage.ContextSwitches := ContextSwitchCount;
  DescribeProcessors(Usage);
  CountProcesses(Usage);
  DescribeMemory(Usage);
  Result := -Int64(CopyToUser(UsageAddress, @Usage, SizeOf(Usage)));
end;

end.
