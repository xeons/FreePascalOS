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
  Self test of the physical page quarantine (Memory.PageQuarantine),
  with "heapchecks", part of the protection self tests:

    * a write into a freed page is found (on a page the test owns, so
      nothing else can have taken it meanwhile);
    * a freed page goes into the quarantine, filled;
    * as many frees again as the quarantine holds push it out, checked,
      to the free list - while threads on the other processors free and
      take pages of their own all the while.

  Whether the page went in and came out is read from the quarantine's
  own count (its watch), not from the page's use: other processors may
  push the page out early, and it may then be handed out and freed
  again, back into the quarantine, before the test looks.
}
unit Kernel.PageQuarantineSelfTest;

{$mode objfpc}
{$pointermath on}

interface

procedure TestPhysicalPageQuarantine;

implementation

uses
  Runtime.Atomic,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.HeapChecks,
  Memory.PageQuarantine,
  Kernel.Threads,
  Processes.Thread,
  Kernel.Scheduler,
  Kernel.Processors,
  Kernel.SelfTest,
  Debug.Output;

const
  DamagedOffset = 100;
  { Threads freeing pages beside the test, at most. }
  MaximumChurners = 3;
  WaitLimitMilliseconds = 5000;

var
  StopChurning: PtrUInt;
  ChurnersRunning: Int64;
  ChurnersFinished: Int64;
  ChurnedPages: Int64;

procedure WriteSkipped(TestName: PChar; Reason: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('selftest');
  DebugWrite(TestName);
  DebugWrite(': skipped (');
  DebugWrite(Reason);
  DebugWriteLine(')');
  DebugEndMessage;
end;

{ Takes and frees pages until told to stop. }
procedure ChurnerMain(Context: Pointer);
var
  Page: TPhysicalAddress;
begin
  AtomicIncrement(ChurnersRunning);
  while AtomicLoad(StopChurning) = 0 do
  begin
    Page := AllocatePhysicalPage(PageUsageGeneral);
    if Page <> 0 then
    begin
      FreePhysicalPage(Page);
      AtomicIncrement(ChurnedPages);
    end;
  end;
  AtomicIncrement(ChurnersFinished);
end;

{ Waits until Counter reaches Wanted; False after the limit. }
function WaitForCount(var Counter: Int64; Wanted: PtrUInt): Boolean;
var
  Waited: LongInt;
begin
  Waited := 0;
  while AtomicLoad(PtrUInt(Counter)) < Wanted do
  begin
    if Waited >= WaitLimitMilliseconds then
      Exit(False);
    SleepMilliseconds(1);
    Inc(Waited);
  end;
  Result := True;
end;

function StartChurners: PtrUInt;
var
  Index: PtrUInt;
begin
  StopChurning := 0;
  ChurnersRunning := 0;
  ChurnersFinished := 0;
  ChurnedPages := 0;
  Result := 0;
  if OnlineProcessorCount > 1 then
    Result := OnlineProcessorCount - 1;
  if Result > MaximumChurners then
    Result := MaximumChurners;
  Index := 0;
  while Index < Result do
  begin
    Check(CreateSystemThread(@ChurnerMain, nil, DefaultThreadPriority, 'PageChurner', False) <> nil,
      'could not create a page quarantine test thread');
    Inc(Index);
  end;
  Check(WaitForCount(ChurnersRunning, Result), 'the page quarantine test threads did not start');
end;

procedure StopChurners(Count: PtrUInt);
begin
  AtomicStore(StopChurning, 1);
  Check(WaitForCount(ChurnersFinished, Count), 'the page quarantine test threads did not stop');
end;

procedure TestDamageIsFound;
var
  Page: TPhysicalAddress;
begin
  Page := AllocatePhysicalPage(PageUsageGeneral);
  Check(Page <> 0, 'no physical page for the quarantine test');
  FillFreedPage(PhysicalToVirtual(Page));
  Check(QuarantinedPageDamage(Page) = NoDamage, 'a filled physical page was taken for damaged');
  PByte(PhysicalToVirtual(Page))[DamagedOffset] := 0;
  Check(QuarantinedPageDamage(Page) = DamagedOffset, 'a write into a freed physical page was not found');
  FreePhysicalPage(Page);
end;

procedure TestPhysicalPageQuarantine;
var
  Page: TPhysicalAddress;
  Filler: TPhysicalAddress;
  Count: QWord;
  Churners: PtrUInt;
  Entered: Boolean;
  Departed: Boolean;
  Damage: Int64;
  Usage: TPageUsage;
begin
  if KernelHeapCheckLevel <> HeapChecksQuarantine then
  begin
    WriteSkipped('freed physical pages filled and held back', 'no "heapchecks"');
    Exit;
  end;
  TestDamageIsFound;
  Churners := StartChurners;

  Page := AllocatePhysicalPage(PageUsageGeneral);
  Check(Page <> 0, 'no physical page for the quarantine test');
  WatchPhysicalPageQuarantine(Page);
  FreePhysicalPage(Page);
  GetPhysicalPageQuarantineWatch(Entered, Departed);
  Check(Entered, 'a freed physical page was not held back');
  { Read while it is held back: if it is still there afterwards, nothing
    else had it meanwhile. }
  Usage := PageUsageOf(Page);
  Damage := QuarantinedPageDamage(Page);
  GetPhysicalPageQuarantineWatch(Entered, Departed);
  if not Departed then
  begin
    Check(Usage = PageUsageQuarantined, 'a held back physical page is not marked so');
    Check(Damage = NoDamage, 'a freed physical page was not filled');
  end;

  { As many frees again push it out of the ring, checked, to the free
    list (sooner, with the other threads' frees). }
  Count := 0;
  while Count < PageQuarantineCapacity do
  begin
    Filler := AllocatePhysicalPage(PageUsageGeneral);
    Check(Filler <> 0, 'no physical page for the quarantine test');
    FreePhysicalPage(Filler);
    Inc(Count);
  end;
  GetPhysicalPageQuarantineWatch(Entered, Departed);
  Check(Departed, 'a physical page stayed in the quarantine');
  StopChurners(Churners);
  ReportPassed('freed physical pages filled, held back and checked (with other processors freeing)');
end;

end.
