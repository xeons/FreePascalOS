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
  What the task manager looks at, each time it looks: every process and
  the system's processor time and memory, and how busy everything was
  since the last look.

  The kernel gives processor time as totals that only grow, so the
  sampler keeps the last look beside the new one: a process's share is
  the processor time it added over the time that passed, out of all the
  processors (four processors kept busy are 100%, one of them 25%, as
  task managers show it); a processor's is the busy time it added over
  all the time it added. Each look also adds a sample to the histories
  the Performance tab draws: all the processors together, each one, and
  the memory in use.
}
unit TaskManager.Sampler;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Abi.SystemCalls,
  Sys.ProcessList,
  Sys.SystemUsage,
  TaskManager.History;

type
  TUsageSampler = class
  private
    FSnapshots: array[0..1] of TProcessSnapshot;
    FUsages: array[0..1] of TSystemUsage;
    { Which of the two is the newest look; the other is the one before. }
    FNewest: LongInt;
    FLooks: LongInt;
    FAllProcessors: TUsageHistory;
    FEachProcessor: array[0..AbiMaximumProcessors - 1] of TUsageHistory;
    FMemory: TUsageHistory;
    function GetProcess(Index: LongInt): PProcessDetails;
    function GetProcessCount: LongInt;
    function GetUsage: TSystemUsage;
    function GetProcessorHistory(Index: LongInt): PUsageHistory;
    function GetAllProcessorsHistory: PUsageHistory;
    function GetMemoryHistory: PUsageHistory;
    procedure AddSamples;
  public
    constructor Create;
    destructor Destroy; override;
    { Looks again. }
    procedure Refresh;
    { Process Index's share of all the processors since the last look,
      in tenths of a percent. }
    function ProcessorShare(Index: LongInt): LongWord;
    { How many processors run. }
    function ProcessorCount: LongInt;
    { The memory in use, in tenths of a percent of all of it. }
    function MemoryInUseTenths: LongWord;
    { How busy all the processors were since the last look. }
    function AllProcessorsBusy: LongWord;
    property ProcessCount: LongInt read GetProcessCount;
    property Processes[Index: LongInt]: PProcessDetails read GetProcess;
    property Usage: TSystemUsage read GetUsage;
    property AllProcessorsHistory: PUsageHistory read GetAllProcessorsHistory;
    property ProcessorHistory[Index: LongInt]: PUsageHistory read GetProcessorHistory;
    property MemoryHistory: PUsageHistory read GetMemoryHistory;
  end;

implementation

constructor TUsageSampler.Create;
var
  Index: LongInt;
begin
  inherited Create;
  InitializeProcessSnapshot(FSnapshots[0]);
  InitializeProcessSnapshot(FSnapshots[1]);
  FillChar(FUsages, SizeOf(FUsages), 0);
  ClearHistory(FAllProcessors);
  ClearHistory(FMemory);
  for Index := 0 to AbiMaximumProcessors - 1 do
    ClearHistory(FEachProcessor[Index]);
end;

destructor TUsageSampler.Destroy;
begin
  FreeProcessSnapshot(FSnapshots[0]);
  FreeProcessSnapshot(FSnapshots[1]);
  inherited Destroy;
end;

procedure TUsageSampler.Refresh;
begin
  FNewest := 1 - FNewest;
  TakeProcessSnapshot(FSnapshots[FNewest]);
  GetSystemUsage(FUsages[FNewest]);
  Inc(FLooks);
  { The first look has nothing to compare with. }
  if FLooks > 1 then
    AddSamples;
end;

procedure TUsageSampler.AddSamples;
var
  Index: LongInt;
begin
  AddSample(FAllProcessors, AllProcessorsBusy);
  for Index := 0 to AbiMaximumProcessors - 1 do
    AddSample(FEachProcessor[Index], ProcessorBusyTenths(FUsages[1 - FNewest], FUsages[FNewest], Index));
  AddSample(FMemory, MemoryInUseTenths);
end;

function TUsageSampler.GetProcessCount: LongInt;
begin
  Result := FSnapshots[FNewest].Count;
end;

function TUsageSampler.GetProcess(Index: LongInt): PProcessDetails;
begin
  Result := @FSnapshots[FNewest].Entries[Index];
end;

function TUsageSampler.GetUsage: TSystemUsage;
begin
  Result := FUsages[FNewest];
end;

function TUsageSampler.ProcessorShare(Index: LongInt): LongWord;
var
  Newest: PProcessDetails;
  Earlier: PProcessDetails;
  Elapsed: QWord;
begin
  Result := 0;
  if FLooks < 2 then
    Exit;
  Newest := GetProcess(Index);
  Earlier := FindProcessInSnapshot(FSnapshots[1 - FNewest], Newest^.ProcessId);
  if Earlier = nil then
    Exit;
  Elapsed := FSnapshots[FNewest].TakenAtMilliseconds - FSnapshots[1 - FNewest].TakenAtMilliseconds;
  Result := ProcessorShareTenths(Earlier^.ProcessorNanoseconds, Newest^.ProcessorNanoseconds, Elapsed,
    ProcessorCount);
end;

function TUsageSampler.ProcessorCount: LongInt;
begin
  Result := OnlineProcessors(FUsages[FNewest]);
  if Result < 1 then
    Result := 1;
end;

function TUsageSampler.MemoryInUseTenths: LongWord;
var
  Total: QWord;
begin
  Total := FUsages[FNewest].TotalMemory;
  if Total = 0 then
    Exit(0);
  Result := LongWord(UsedMemory(FUsages[FNewest]) * 1000 div Total);
end;

function TUsageSampler.AllProcessorsBusy: LongWord;
begin
  if FLooks < 2 then
    Exit(0);
  Result := AllProcessorsBusyTenths(FUsages[1 - FNewest], FUsages[FNewest]);
end;

function TUsageSampler.GetAllProcessorsHistory: PUsageHistory;
begin
  Result := @FAllProcessors;
end;

function TUsageSampler.GetProcessorHistory(Index: LongInt): PUsageHistory;
begin
  Result := @FEachProcessor[Index];
end;

function TUsageSampler.GetMemoryHistory: PUsageHistory;
begin
  Result := @FMemory;
end;

end.
