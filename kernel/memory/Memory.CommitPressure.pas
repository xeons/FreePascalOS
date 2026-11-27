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
  Commit pressure: how close what processes were promised is to what
  the system can back (Memory.Reserves has the rules).

  When the headroom under the system's commit limit falls below the low
  watermark, memory is short as surely as when free pages are: the
  memory pressure thread (Memory.Pressure) counts it as a pressure
  event, and CallGetMemoryPressure reports the higher of the two levels,
  so a program watching it stops asking (and gives memory back) before
  its commitments are refused. Under strict accounting the limit counts
  the caches as available, so the promises not touched yet may need the
  caches' pages: the thread also shrinks the caches gently until the
  outstanding promises and the low watermark are free. Overcommitted
  promises are not expected to be touched all, so they shrink nothing
  ahead of time.

  It also writes a kernel log line when commitments were refused since
  the last look, with the figures that refused them.
}
unit Memory.CommitPressure;

{$mode objfpc}

interface

uses
  Memory.Reserves;

{ The commit pressure now (none without a limit). }
function CurrentCommitPressure: TCommitPressure;
{ The promised pages not resident yet. }
function OutstandingCommitments: QWord;
{ The pages the caches should give back now for the promises (0 when
  there is no commit pressure, or free memory covers them). }
function CommitReclaimPagesWanted: QWord;
{ Logs the commitments refused since the last call (the memory pressure
  thread, once a second). Passive level. }
procedure ReportCommitRefusals;

implementation

uses
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.CommitCharge,
  Debug.Output;

var
  FailuresReported: QWord = 0;

function CurrentCommitPressure: TCommitPressure;
var
  Low: QWord;
  Critical: QWord;
begin
  GetMemoryWatermarks(Low, Critical);
  Result := CommitPressureLevel(SystemCommittedPages, SystemCommitLimitPages, Low, Critical);
end;

function OutstandingCommitments: QWord;
var
  Counts: TPageUsageCounts;
begin
  GetPageUsageCounts(Counts);
  Result := OutstandingCommitPages(SystemCommittedPages, Counts[PageUsageUserMemory] + Counts[PageUsageSection]);
end;

function CommitReclaimPagesWanted: QWord;
var
  Physical: TPhysicalMemoryStatistics;
  Low: QWord;
  Critical: QWord;
begin
  if not SystemCommitmentsBacked or (CurrentCommitPressure = CommitPressureNone) then
    Exit(0);
  GetPhysicalMemoryStatistics(Physical);
  GetMemoryWatermarks(Low, Critical);
  Result := CommitReclaimTarget(OutstandingCommitments, Physical.FreePages, Low);
end;

procedure ReportCommitRefusals;
var
  Failures: QWord;
  Physical: TPhysicalMemoryStatistics;
  Committed, Untouched, Limit, KernelHeld, Kept, Largest, Refused: QWord;
begin
  Failures := SystemCommitFailures;
  if Failures = FailuresReported then
    Exit;
  { Every figure is read before the message begins: the debug output
    holds its lock at the highest level, where the page lock that these
    figures take may not be acquired. }
  GetPhysicalMemoryStatistics(Physical);
  Committed := SystemCommittedPages;
  Untouched := OutstandingCommitments;
  Limit := SystemCommitLimitPages;
  KernelHeld := KernelHeldPages;
  Kept := KeptCachePages;
  Largest := LargestSystemCommitPages;
  Refused := LastRefusedCommitPages;
  DebugBeginMessage;
  DebugWriteTag('memory');
  DebugWrite('commit limit refused ');
  DebugWriteDecimal(Failures - FailuresReported);
  DebugWrite(' commitments (the last of ');
  DebugWriteSize(Refused * PageSize);
  if Largest <> 0 then
  begin
    DebugWrite(', one may be up to ');
    DebugWriteSize(Largest * PageSize);
  end;
  DebugWrite('): ');
  DebugWriteSize(Committed * PageSize);
  DebugWrite(' committed (');
  DebugWriteSize(Untouched * PageSize);
  DebugWrite(' not touched) of ');
  DebugWriteSize(Limit * PageSize);
  DebugWrite('; ');
  DebugWriteSize(Physical.FreePages * PageSize);
  DebugWrite(' free, ');
  DebugWriteSize(KernelHeld * PageSize);
  DebugWrite(' kernel, ');
  DebugWriteSize(Kept * PageSize);
  DebugWriteLine(' kept by caches');
  DebugEndMessage;
  FailuresReported := Failures;
end;

end.
