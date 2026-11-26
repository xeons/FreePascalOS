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
  Memory pressure: caches that give memory back when it runs short.

  Caches that keep memory only to be faster (the block cache, the
  image sections of programs nobody runs, the heap check quarantine)
  register a shrinker: a routine asked to free some pages, gently (only
  what costs nothing: clean data) or hard (writing dirty data back
  first). ReclaimMemory asks them in turn until enough pages are free.

  The page allocator (Memory.PhysicalPages) calls back when free pages
  fall below its low watermark or an allocation fails. That callback
  only queues a deferred call, which wakes the pressure thread
  (RunMemoryPressureWatcher, the "MemoryPressure" system thread): it
  reclaims until free memory is half the low watermark above it again,
  hard below the critical watermark. The thread also looks once a
  second.

  Callers that need a page at once and may wait - a user page fault, a
  kernel allocation at passive level - call ReclaimMemory themselves
  and try again. When even that finds nothing and memory is critical,
  the out-of-memory handler (set by Processes.OutOfMemory: it ends a
  process) is the last resort; the pressure thread calls it too when
  allocations keep failing with nothing left to reclaim. The pressure
  thread runs in the real-time class (Kernel.Startup), so no busy
  program, boosted or not, keeps it from relieving the pressure.

  ReclaimMemory runs one at a time (a second caller waits, then finds
  the memory the first freed). A shrinker that itself allocates and
  fails must not reclaim again: CanReclaimMemoryHere is False on the
  thread that runs the shrinkers.
}
unit Memory.Pressure;

{$mode objfpc}

interface

type
  TShrinkUrgency = (
    { Only what costs nothing to drop (clean cached data). }
    ShrinkGently,
    { Dirty data too, written back first. }
    ShrinkHard);

  { Frees up to PagesWanted pages; returns how many it freed. Called at
    passive level, with no lock of the caller's held. }
  TShrinkRoutine = function(PagesWanted: QWord; Urgency: TShrinkUrgency): QWord;

  { The last resort when memory is critical and nothing could be
    reclaimed: frees memory somehow (ends a process). True if it did
    something worth waiting for. }
  TOutOfMemoryHandler = function: Boolean;

  TMemoryPressureStatistics = record
    { Times the allocator found memory short. }
    PressureEvents: QWord;
    { Calls of ReclaimMemory, and the pages the shrinkers freed. }
    ReclaimCalls: QWord;
    ReclaimedPages: QWord;
    { Allocations of physical pages that failed. }
    FailedAllocations: QWord;
  end;

procedure InitializeMemoryPressure;

{ Adds a shrinker; they are asked in the order registered. }
procedure RegisterShrinker(Name: PChar; Routine: TShrinkRoutine);
procedure SetOutOfMemoryHandler(Handler: TOutOfMemoryHandler);

{ Asks the shrinkers for PagesWanted pages; returns how many they freed.
  Does nothing (0) where CanReclaimMemoryHere is False. }
function ReclaimMemory(PagesWanted: QWord; Urgency: TShrinkUrgency): QWord;
{ True where ReclaimMemory may run: passive level, interrupts on, and
  not on the thread running the shrinkers. }
function CanReclaimMemoryHere: Boolean;

{ Free pages that would end the pressure (the low watermark and half
  again) less what is free now; 0 when that much is free. }
function PagesShortOfComfort: QWord;

{ The pressure thread: a system thread runs this; it never returns. }
procedure RunMemoryPressureWatcher(Context: Pointer);

procedure GetMemoryPressureStatistics(out Statistics: TMemoryPressureStatistics);
procedure WriteMemoryPressureSummary;

implementation

uses
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Memory.HeapChecks,
  Memory.CommitCharge,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.Mutex,
  Kernel.Events,
  Kernel.DeferredCalls,
  Debug.Output;

const
  MaximumShrinkers = 8;
  WatcherIntervalMilliseconds = 1000;

type
  TShrinker = record
    Name: PChar;
    Routine: TShrinkRoutine;
  end;

var
  Shrinkers: array[0..MaximumShrinkers - 1] of TShrinker;
  ShrinkerCount: Integer;
  OutOfMemoryHandler: TOutOfMemoryHandler;
  ReclaimLock: TMutex;
  PressureEvent: TEvent;
  WakeWatcherCall: TDeferredCall;
  IsInitialized: Boolean;
  Counters: TMemoryPressureStatistics;

procedure WakeWatcher(Context: Pointer);
begin
  SignalEvent(PressureEvent);
end;

{ The allocator's callback: any level, perhaps with spin locks held. }
procedure NoteMemoryPressure;
begin
  Inc(Counters.PressureEvents);
  QueueDeferredCall(WakeWatcherCall);
end;

function FreePagesNow: QWord; forward;

{ The kernel heap's reclaimer: a failed allocation that may wait. }
function ReclaimForKernelHeap(PageCount: QWord): Boolean;
begin
  Result := ReclaimMemory(PageCount + PagesShortOfComfort, ShrinkHard) > 0;
end;

{ A shrinker: the heap check quarantine (heapchecks) holds freed blocks
  and pages back; letting them go costs only the checks' reach. }
function ShrinkHeapQuarantine(PagesWanted: QWord; Urgency: TShrinkUrgency): QWord;
var
  FreeBefore: QWord;
  FreeAfter: QWord;
begin
  Result := 0;
  if KernelHeapCheckLevel <> HeapChecksQuarantine then
    Exit;
  FreeBefore := FreePagesNow;
  FlushKernelHeapQuarantine;
  FreeAfter := FreePagesNow;
  if FreeAfter > FreeBefore then
    Result := FreeAfter - FreeBefore;
end;

procedure InitializeMemoryPressure;
begin
  InitializeMutex(ReclaimLock);
  InitializeEvent(PressureEvent, EventKindSynchronization, False);
  InitializeDeferredCall(WakeWatcherCall, @WakeWatcher, nil);
  IsInitialized := True;
  SetMemoryPressureCallback(@NoteMemoryPressure);
  SetKernelHeapReclaimer(@ReclaimForKernelHeap);
  RegisterShrinker('heap check quarantine', @ShrinkHeapQuarantine);
end;

procedure RegisterShrinker(Name: PChar; Routine: TShrinkRoutine);
begin
  if ShrinkerCount >= MaximumShrinkers then
    Exit;
  Shrinkers[ShrinkerCount].Name := Name;
  Shrinkers[ShrinkerCount].Routine := Routine;
  Inc(ShrinkerCount);
end;

procedure SetOutOfMemoryHandler(Handler: TOutOfMemoryHandler);
begin
  OutOfMemoryHandler := Handler;
end;

function CanReclaimMemoryHere: Boolean;
begin
  Result := IsInitialized and (CurrentPriorityLevel = PassiveLevel) and InterruptsAreEnabled and
    not MutexIsOwnedByCurrentThread(ReclaimLock);
end;

function FreePagesNow: QWord;
var
  Physical: TPhysicalMemoryStatistics;
begin
  GetPhysicalMemoryStatistics(Physical);
  Result := Physical.FreePages;
end;

function PagesShortOfComfort: QWord;
var
  Low: QWord;
  Critical: QWord;
  Comfort: QWord;
  FreeNow: QWord;
begin
  GetMemoryWatermarks(Low, Critical);
  Comfort := Low + Low div 2;
  FreeNow := FreePagesNow;
  if FreeNow >= Comfort then
    Result := 0
  else
    Result := Comfort - FreeNow;
end;

{ Asks every shrinker in turn until Wanted pages came back. }
function AskShrinkers(Wanted: QWord; Urgency: TShrinkUrgency): QWord;
var
  Index: Integer;
begin
  Result := 0;
  Index := 0;
  while (Index < ShrinkerCount) and (Result < Wanted) do
  begin
    Result := Result + Shrinkers[Index].Routine(Wanted - Result, Urgency);
    Inc(Index);
  end;
end;

function ReclaimMemory(PagesWanted: QWord; Urgency: TShrinkUrgency): QWord;
var
  FreeBefore: QWord;
begin
  Result := 0;
  if (PagesWanted = 0) or not CanReclaimMemoryHere then
    Exit;
  FreeBefore := FreePagesNow;
  AcquireMutex(ReclaimLock);
  { Another thread reclaimed while this one waited. }
  if FreePagesNow >= FreeBefore + PagesWanted then
  begin
    ReleaseMutex(ReclaimLock);
    Exit(PagesWanted);
  end;
  Inc(Counters.ReclaimCalls);
  Result := AskShrinkers(PagesWanted, Urgency);
  { Gently was not enough and memory is critical: dirty data goes too. }
  if (Result < PagesWanted) and (Urgency = ShrinkGently) and
     (CurrentMemoryPressure = MemoryPressureCritical) then
    Result := Result + AskShrinkers(PagesWanted - Result, ShrinkHard);
  Counters.ReclaimedPages := Counters.ReclaimedPages + Result;
  ReleaseMutex(ReclaimLock);
end;

{ One look: reclaims while memory is short; the last resort if it stays
  critical while allocations keep failing. }
procedure RelievePressure(var FailuresSeen: QWord);
var
  Wanted: QWord;
  Freed: QWord;
  Urgency: TShrinkUrgency;
  Failures: QWord;
begin
  repeat
    Wanted := PagesShortOfComfort;
    if Wanted = 0 then
      Break;
    if CurrentMemoryPressure = MemoryPressureCritical then
      Urgency := ShrinkHard
    else
      Urgency := ShrinkGently;
    Freed := ReclaimMemory(Wanted, Urgency);
  until Freed = 0;
  Failures := FailedPageAllocationCount;
  if (CurrentMemoryPressure = MemoryPressureCritical) and (Failures <> FailuresSeen) and
     Assigned(OutOfMemoryHandler) then
    OutOfMemoryHandler();
  FailuresSeen := Failures;
  AcknowledgeMemoryPressure;
end;

procedure RunMemoryPressureWatcher(Context: Pointer);
var
  FailuresSeen: QWord;
begin
  FailuresSeen := FailedPageAllocationCount;
  while True do
  begin
    WaitForEventWithOptions(PressureEvent, WatcherIntervalMilliseconds, False);
    RelievePressure(FailuresSeen);
    { The kernel's own share of memory changed: so does what processes
      may commit (Memory.CommitCharge). }
    RefreshSystemCommitLimit;
  end;
end;

procedure GetMemoryPressureStatistics(out Statistics: TMemoryPressureStatistics);
begin
  Statistics := Counters;
  Statistics.FailedAllocations := FailedPageAllocationCount;
end;

procedure WriteMemoryPressureSummary;
var
  Low: QWord;
  Critical: QWord;
begin
  GetMemoryWatermarks(Low, Critical);
  DebugBeginMessage;
  DebugWriteTag('memory');
  DebugWrite('watermarks ');
  DebugWriteSize(Low * PageSize);
  DebugWrite(' low, ');
  DebugWriteSize(Critical * PageSize);
  DebugWrite(' critical; short ');
  DebugWriteDecimal(Counters.PressureEvents);
  DebugWrite(' times, ');
  DebugWriteDecimal(Counters.ReclaimedPages);
  DebugWrite(' pages reclaimed in ');
  DebugWriteDecimal(Counters.ReclaimCalls);
  DebugWrite(' calls, ');
  DebugWriteDecimal(FailedPageAllocationCount);
  DebugWriteLine(' failed allocations');
  DebugEndMessage;
end;

end.
