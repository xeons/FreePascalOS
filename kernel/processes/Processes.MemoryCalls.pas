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
  System calls about memory pressure and storage (168-170):
  CallTrimVolume (fstrim, FileSystem.Trim), CallGetBlockCacheStatistics
  (Io.BlockCache, FileSystem.Discards) and CallGetMemoryPressure
  (Memory.PhysicalPages, Memory.Pressure, Processes.OutOfMemory).
}
unit Processes.MemoryCalls;

{$mode objfpc}

interface

function PerformTrimVolume(PathAddress: QWord): Int64;
function PerformGetBlockCacheStatistics(StatisticsAddress: QWord): Int64;
function PerformGetMemoryPressure(PressureAddress: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Memory.PhysicalPages,
  Memory.Pressure,
  Memory.CommitCharge,
  Io.BlockCache,
  FileSystem.Types,
  FileSystem.Discards,
  FileSystem.Trim,
  Processes.Process,
  Processes.Thread,
  Processes.Security,
  Processes.FileCalls,
  Processes.MemoryCharges,
  Processes.OutOfMemory,
  Processes.MappedFileEviction,
  Processes.UserAccess;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function PerformTrimVolume(PathAddress: QWord): Int64;
var
  KernelPath: PPathBuffer;
  Error: LongInt;
  Status: TFileSystemStatus;
  Discarded: QWord;
begin
  if CurrentProcess^.Credentials.EffectiveUserId <> RootUserId then
    Exit(Failure(ErrorNotPermitted));
  Error := FetchKernelPath(PathAddress, KernelPath);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Status := TrimVolumeAtPath(@KernelPath^[0], Discarded);
  FreeKernelMemory(KernelPath);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  Result := Int64(Discarded);
end;

function PerformGetBlockCacheStatistics(StatisticsAddress: QWord): Int64;
var
  Cache: TBlockCacheStatistics;
  Discards: TVolumeDiscardStatistics;
  Statistics: TAbiBlockCacheStatistics;
begin
  GetBlockCacheStatistics(Cache);
  GetVolumeDiscardStatistics(Discards);
  FillMemory(@Statistics, SizeOf(Statistics), 0);
  Statistics.LineBytes := CacheLineSize;
  Statistics.LineCount := Cache.LineCount;
  Statistics.MinimumLines := Cache.MinimumLines;
  Statistics.MaximumLines := Cache.MaximumLines;
  Statistics.DirtyLines := Cache.DirtyLines;
  Statistics.Hits := Cache.Hits;
  Statistics.Misses := Cache.Misses;
  Statistics.ReadAhead := Cache.ReadAhead;
  Statistics.WrittenBack := Cache.WrittenBack;
  Statistics.LinesGrown := Cache.LinesGrown;
  Statistics.LinesShrunk := Cache.LinesShrunk;
  Statistics.LinesDiscarded := Cache.LinesDiscarded;
  Statistics.BytesQueuedForDiscard := Discards.BytesQueued;
  Statistics.BytesDiscarded := Discards.BytesDiscarded;
  Result := -Int64(CopyToUser(StatisticsAddress, @Statistics, SizeOf(Statistics)));
end;

function PerformGetMemoryPressure(PressureAddress: QWord): Int64;
var
  Physical: TPhysicalMemoryStatistics;
  Reclaim: TMemoryPressureStatistics;
  Ended: TOutOfMemoryStatistics;
  Pressure: TAbiMemoryPressure;
begin
  GetPhysicalMemoryStatistics(Physical);
  GetMemoryPressureStatistics(Reclaim);
  GetOutOfMemoryStatistics(Ended);
  FillMemory(@Pressure, SizeOf(Pressure), 0);
  Pressure.TotalPages := Physical.TotalUsablePages;
  Pressure.FreePages := Physical.FreePages;
  GetMemoryWatermarks(Pressure.LowWatermarkPages, Pressure.CriticalWatermarkPages);
  Pressure.Level := LongWord(Ord(CurrentMemoryPressure));
  Pressure.PressureEvents := Reclaim.PressureEvents;
  Pressure.ReclaimCalls := Reclaim.ReclaimCalls;
  Pressure.ReclaimedPages := Reclaim.ReclaimedPages;
  Pressure.FailedAllocations := Reclaim.FailedAllocations;
  Pressure.CommittedPages := SystemCommittedPages;
  Pressure.ProcessesEnded := Ended.ProcessesEnded;
  Pressure.LastEndedProcessId := Ended.LastEndedProcessId;
  CopyText(@Pressure.LastEndedName[0], @Ended.LastEndedName[0], SizeOf(Pressure.LastEndedName));
  Pressure.CommitLimitPages := SystemCommitLimitPages;
  Pressure.CommitFailures := SystemCommitFailures;
  Pressure.ReserveRefusals := ReserveRefusalCount;
  Pressure.ThrashGuardRefusals := ThrashGuardRefusedPages;
  Result := -Int64(CopyToUser(PressureAddress, @Pressure, SizeOf(Pressure)));
end;

end.
