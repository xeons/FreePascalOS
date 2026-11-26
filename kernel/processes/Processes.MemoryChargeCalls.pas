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
  The block of memory and loader calls (208-213).

  CallGetImageCacheStatistics (208): the loader's image sections and the
  relocated copies kept with them (Processes.ImageSections,
  Processes.RelocatedCopies).

  CallGetProcessMemoryCharge (209): what the out-of-memory policy
  (Processes.OutOfMemory) charges a process with - its resident pages,
  the sections it made and its commitments not resident yet
  (Processes.MemoryCharges, fed by the virtual memory calls) - and the
  score it would have if memory ran out now (Processes.OutOfMemoryScores).
}
unit Processes.MemoryChargeCalls;

{$mode objfpc}

interface

function PerformGetProcessMemoryCharge(ProcessId: QWord; ChargeAddress: QWord): Int64;
function PerformGetImageCacheStatistics(StatisticsAddress: QWord): Int64;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.PhysicalPages,
  Objects.Manager,
  Processes.Process,
  Processes.AddressSpace,
  Processes.MemoryCharges,
  Processes.OutOfMemoryScores,
  Processes.SecurityCalls,
  Processes.ImageSections,
  Processes.RelocatedCopies,
  Processes.UserAccess;

procedure DescribeCharge(Process: PProcess; out Charge: TAbiProcessMemoryCharge);
var
  Usage: TAddressSpaceUsage;
  Candidate: TOomCandidate;
  Physical: TPhysicalMemoryStatistics;
  Score: Int64;
begin
  FillMemory(@Charge, SizeOf(Charge), 0);
  LockProcessRegistry;
  if ReadPublishedSpaceUsage(Process^.AddressSpace, Usage) then
  begin
    Charge.ResidentPages := Usage.ResidentPages;
    Charge.SharedPages := Usage.SharedPages;
    Charge.CommitChargePages := Usage.CommitChargePages;
  end;
  if Process^.SectionChargePages > 0 then
    Charge.SectionPages := QWord(Process^.SectionChargePages);
  Charge.FootprintPages := ProcessFootprintPages(Process);
  if Charge.FootprintPages > Charge.ResidentPages + Charge.SectionPages then
    Charge.CommittedNotResidentPages := Charge.FootprintPages - Charge.ResidentPages - Charge.SectionPages;
  DescribeOomCandidate(Process, Candidate);
  Charge.OomScoreAdjust := Process^.OomScoreAdjust;
  if Candidate.IsProtected then
    Charge.Flags := ProcessMemoryProtected;
  UnlockProcessRegistry;
  GetPhysicalMemoryStatistics(Physical);
  Score := OomScore(Candidate, Physical.TotalUsablePages);
  if Score = OomNotEligible then
    Charge.OomScore := ProcessMemoryNotEligible
  else
    Charge.OomScore := Score;
end;

function PerformGetProcessMemoryCharge(ProcessId: QWord; ChargeAddress: QWord): Int64;
var
  Target: PProcess;
  Charge: TAbiProcessMemoryCharge;
begin
  Target := ReferenceProcess(ProcessId);
  if Target = nil then
    Exit(-Int64(ErrorNotFound));
  DescribeCharge(Target, Charge);
  DereferenceObject(Target);
  Result := -Int64(CopyToUser(ChargeAddress, @Charge, SizeOf(Charge)));
end;

function CounterValue(Value: Int64): QWord;
begin
  if Value < 0 then
    Exit(0);
  Result := QWord(Value);
end;

function PerformGetImageCacheStatistics(StatisticsAddress: QWord): Int64;
var
  Statistics: TAbiImageCacheStatistics;
begin
  FillMemory(@Statistics, SizeOf(Statistics), 0);
  Statistics.CachedSections := CachedImageSectionCount;
  Statistics.RelocatedCopies := CounterValue(RelocatedCopyCounters.Copies);
  Statistics.RelocatedPages := CounterValue(RelocatedCopyCounters.Pages);
  Statistics.RelocationsReused := CounterValue(RelocatedCopyCounters.Reused);
  Statistics.RelocationsKept := CounterValue(RelocatedCopyCounters.Kept);
  Statistics.RelocationsNotKept := CounterValue(RelocatedCopyCounters.NotKept);
  Statistics.SharedPlacements := CounterValue(RelocatedCopyCounters.SharedPlacements);
  Statistics.CopiesDropped := CounterValue(RelocatedCopyCounters.Dropped);
  Result := -Int64(CopyToUser(StatisticsAddress, @Statistics, SizeOf(Statistics)));
end;

end.
