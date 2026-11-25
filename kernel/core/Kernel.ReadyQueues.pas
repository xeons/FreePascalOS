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
  Run queues: one set per processor, each with its own lock.

  Every processor has a run queue per priority level and a lock (the
  processor's scheduling lock) that protects them, which thread it runs
  and at what priority, its time slice and its processor time. The lock
  is taken at DispatchLevel. Kernel.Scheduler holds it across a thread
  switch on that processor; the thread that runs next releases it.

  Lock order (see Kernel.Scheduler): the dispatcher lock (wait queues)
  comes before any processor's scheduling lock; a processor holding one
  scheduling lock only ever TRIES to take another (TryLockProcessor), so
  no two processors can wait for each other.

  A thread that becomes ready is placed (ChooseProcessorFor) on

    1. the processor it last ran on, if that one is idle (its data may
       still be in that processor's cache),
    2. else any idle processor it may run on, this one first,
    3. else the processor running the least important thread, if that is
       less important than this one,
    4. else again the processor it last ran on.

  This reads the other processors' running priorities without their
  locks (RunningPriority, kept by the scheduler for this): a hint that
  may be a moment old, never a pointer to follow.

  A processor choosing its next thread (TakeReadyThreadFor) takes the
  most important thread of its own queues, unless another processor's
  queues hold a more important one that may run here - or, when its own
  queues are empty, any one that may run here (work stealing). Those
  queues are taken only if their lock is free at that moment; if one was
  busy and might have held something, StealWasRefused is set, so an idle
  processor tries again (PullThreadForIdleProcessor) instead of halting.

  A thread taken out of a queue (to run, or to move) is in no queue for
  a while: its QueuedProcessorIndex is NotQueued then.

  The affinity mask of a thread limits it to some processors (bit N for
  the processor with index N). A mask that allows no online processor
  allows them all.
}
unit Kernel.ReadyQueues;

{$mode objfpc}

interface

uses
  Kernel.PriorityLevel,
  Kernel.Threads,
  Kernel.Processors;

const
  { QueuedProcessorIndex of a ready thread that is in no queue. }
  NotQueued = High(LongWord);

procedure InitializeReadyQueues;

{ The processor's scheduling lock, at DispatchLevel or above. }
procedure LockProcessor(Processor: PProcessor);
procedure UnlockProcessor(Processor: PProcessor);
function TryLockProcessor(Processor: PProcessor): Boolean;
{ The same from any level up to DispatchLevel (raises to it). }
function LockProcessorAtDispatchLevel(Processor: PProcessor): TPriorityLevel;
procedure UnlockProcessorAndLower(Processor: PProcessor; PreviousLevel: TPriorityLevel);

{ The priority of the thread Processor runs, kept under its lock
  (SetRunningPriority) and read by anyone without it. }
procedure SetRunningPriority(Processor: PProcessor; Priority: LongWord);
function RunningPriorityOf(Processor: PProcessor): LongWord;

function ThreadMayRunOn(Thread: PThreadControlBlock; Processor: PProcessor): Boolean;
{ Where a thread that becomes ready should go; see the unit comment.
  No lock needed. }
function ChooseProcessorFor(Thread: PThreadControlBlock): PProcessor;
{ An idle processor (other than Exclude) that Thread may run on, or nil.
  No lock needed. }
function FindIdleProcessorFor(Thread: PThreadControlBlock; Exclude: PProcessor): PProcessor;

{ Processor's lock held. }
procedure EnqueueReadyThread(Thread: PThreadControlBlock; Processor: PProcessor);
{ Takes a ready thread out of its queue; the lock of the processor
  whose queue it is in (QueuedProcessorIndex) held. }
procedure RemoveReadyThread(Thread: PThreadControlBlock);

{ The next thread for Processor of at least MinimumPriority, taken out
  of its queue, or nil; Processor's lock held. }
function TakeReadyThreadFor(Processor: PProcessor; MinimumPriority: Integer): PThreadControlBlock;

{ For an idle processor that holds no scheduling lock: moves the most
  important thread it may run from another processor's queue into its
  own (waiting for that queue's lock), if a steal was refused since the
  last time. True if it moved one (the caller asks for a dispatch). }
function PullThreadForIdleProcessor(Processor: PProcessor): Boolean;
function StealWasRefused(Processor: PProcessor): Boolean;

{ Threads in all queues (read without locks: a moment's figure). }
function ReadyThreadTotal: LongWord;

{ A ready thread that has waited long enough for the starvation boost
  by Now (Kernel.PriorityBoosts), taken out of its queue, or nil. Takes
  each processor's lock in turn, so the caller holds none. }
function TakeStarvedReadyThread(Now: QWord): PThreadControlBlock;

implementation

uses
  Runtime.LinkedList,
  Runtime.Atomic,
  Kernel.SpinLock,
  Kernel.Clock,
  Kernel.PriorityBoosts;

type
  TReadyQueue = record
    Lock: TSpinLock;
    Queues: array[0..PriorityCount - 1] of TListEntry;
    { Bit N is set when Queues[N] is not empty. Changed under the lock,
      read by other processors without it to see where to look. }
    PriorityMask: LongWord;
    Count: LongWord;
    { The priority of the thread the processor runs (0 when idle). }
    RunningPriority: LongWord;
    { A steal from another queue found its lock taken (see the unit
      comment); 1 or 0. }
    StealRefused: PtrUInt;
  end;
  PReadyQueue = ^TReadyQueue;

var
  ReadyQueues: array[0..MaximumProcessors - 1] of TReadyQueue;

procedure InitializeReadyQueues;
var
  Index: Integer;
  Priority: Integer;
begin
  for Index := 0 to MaximumProcessors - 1 do
  begin
    InitializeSpinLock(ReadyQueues[Index].Lock);
    for Priority := 0 to PriorityCount - 1 do
      InitializeListHead(ReadyQueues[Index].Queues[Priority]);
    ReadyQueues[Index].PriorityMask := 0;
    ReadyQueues[Index].Count := 0;
    ReadyQueues[Index].RunningPriority := IdlePriority;
    ReadyQueues[Index].StealRefused := 0;
  end;
end;

function QueueOf(Processor: PProcessor): PReadyQueue;
begin
  Result := @ReadyQueues[Processor^.Index];
end;

{ --- Locks ----------------------------------------------------------------- }

procedure LockProcessor(Processor: PProcessor);
begin
  AcquireSpinLockAtCurrentLevel(QueueOf(Processor)^.Lock);
end;

procedure UnlockProcessor(Processor: PProcessor);
begin
  ReleaseSpinLockAtCurrentLevel(QueueOf(Processor)^.Lock);
end;

function TryLockProcessor(Processor: PProcessor): Boolean;
begin
  Result := TryAcquireSpinLockAtCurrentLevel(QueueOf(Processor)^.Lock);
end;

function LockProcessorAtDispatchLevel(Processor: PProcessor): TPriorityLevel;
begin
  Result := AcquireSpinLock(QueueOf(Processor)^.Lock);
end;

procedure UnlockProcessorAndLower(Processor: PProcessor; PreviousLevel: TPriorityLevel);
begin
  ReleaseSpinLock(QueueOf(Processor)^.Lock, PreviousLevel);
end;

procedure SetRunningPriority(Processor: PProcessor; Priority: LongWord);
begin
  QueueOf(Processor)^.RunningPriority := Priority;
end;

function RunningPriorityOf(Processor: PProcessor): LongWord;
begin
  Result := QueueOf(Processor)^.RunningPriority;
end;

{ --- Placement --------------------------------------------------------------- }

function OnlineProcessorMask: QWord;
var
  Index: LongWord;
  Processor: PProcessor;
begin
  Result := 0;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Processor := ProcessorByIndex(Index);
    if (Processor <> nil) and Processor^.IsOnline then
      Result := Result or (QWord(1) shl Index);
  end;
end;

function ThreadMayRunOn(Thread: PThreadControlBlock; Processor: PProcessor): Boolean;
begin
  if (Thread^.AffinityMask and (QWord(1) shl Processor^.Index)) <> 0 then
    Exit(True);
  Result := (Thread^.AffinityMask and OnlineProcessorMask) = 0;
end;

function IsIdle(Processor: PProcessor): Boolean;
begin
  Result := Processor^.RunningThread = Processor^.IdleThread;
end;

function UsableProcessor(Thread: PThreadControlBlock; Processor: PProcessor): Boolean;
begin
  Result := (Processor <> nil) and Processor^.IsOnline and ThreadMayRunOn(Thread, Processor);
end;

function FindIdleProcessorFor(Thread: PThreadControlBlock; Exclude: PProcessor): PProcessor;
var
  Index: LongWord;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Result := ProcessorByIndex(Index);
    if (Result <> Exclude) and UsableProcessor(Thread, Result) and IsIdle(Result) then
      Exit;
  end;
  Result := nil;
end;

{ The usable processor running the least important thread, if that is
  less important than Thread; else nil. }
function FindLessImportantProcessor(Thread: PThreadControlBlock): PProcessor;
var
  Index: LongWord;
  Candidate: PProcessor;
begin
  Result := nil;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Candidate := ProcessorByIndex(Index);
    if not UsableProcessor(Thread, Candidate) then
      Continue;
    if RunningPriorityOf(Candidate) >= Thread^.Priority then
      Continue;
    if (Result = nil) or (RunningPriorityOf(Candidate) < RunningPriorityOf(Result)) then
      Result := Candidate;
  end;
end;

function ChooseProcessorFor(Thread: PThreadControlBlock): PProcessor;
var
  Last: PProcessor;
  Index: LongWord;
begin
  Last := ProcessorByIndex(Thread^.LastProcessorIndex);
  if UsableProcessor(Thread, Last) and IsIdle(Last) then
    Exit(Last);
  if UsableProcessor(Thread, CurrentProcessor) and IsIdle(CurrentProcessor) then
    Exit(CurrentProcessor);
  Result := FindIdleProcessorFor(Thread, nil);
  if Result <> nil then
    Exit;
  Result := FindLessImportantProcessor(Thread);
  if Result <> nil then
    Exit;
  if UsableProcessor(Thread, Last) then
    Exit(Last);
  if UsableProcessor(Thread, CurrentProcessor) then
    Exit(CurrentProcessor);
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Result := ProcessorByIndex(Index);
    if UsableProcessor(Thread, Result) then
      Exit;
  end;
  Result := CurrentProcessor;
end;

{ --- The queues ------------------------------------------------------------- }

procedure EnqueueReadyThread(Thread: PThreadControlBlock; Processor: PProcessor);
var
  Queue: PReadyQueue;
begin
  Queue := QueueOf(Processor);
  Thread^.State := ThreadStateReady;
  Thread^.ReadySince := ClockNanoseconds;
  Thread^.QueuedProcessorIndex := Processor^.Index;
  InsertAtTail(Queue^.Queues[Thread^.Priority], @Thread^.SchedulerLink);
  Queue^.PriorityMask := Queue^.PriorityMask or (LongWord(1) shl Thread^.Priority);
  Inc(Queue^.Count);
end;

procedure RemoveReadyThread(Thread: PThreadControlBlock);
var
  Queue: PReadyQueue;
begin
  Queue := @ReadyQueues[Thread^.QueuedProcessorIndex];
  RemoveListEntry(@Thread^.SchedulerLink);
  if ListIsEmpty(Queue^.Queues[Thread^.Priority]) then
    Queue^.PriorityMask := Queue^.PriorityMask and not (LongWord(1) shl Thread^.Priority);
  Dec(Queue^.Count);
  Thread^.QueuedProcessorIndex := NotQueued;
end;

function HighestPriorityIn(Mask: LongWord): Integer;
var
  Priority: Integer;
begin
  for Priority := HighestThreadPriority downto LowestThreadPriority do
    if (Mask and (LongWord(1) shl Priority)) <> 0 then
      Exit(Priority);
  Result := -1;
end;

{ The first thread of priority Priority in Queue that may run on
  Processor, or nil. }
function FirstRunnableAt(Queue: PReadyQueue; Priority: Integer; Processor: PProcessor): PThreadControlBlock;
var
  Entry: PListEntry;
begin
  Entry := Queue^.Queues[Priority].Next;
  while Entry <> @Queue^.Queues[Priority] do
  begin
    Result := ThreadFromSchedulerLink(Entry);
    if ThreadMayRunOn(Result, Processor) then
      Exit;
    Entry := Entry^.Next;
  end;
  Result := nil;
end;

{ The most important thread in Queue of at least Floor that may run on
  Processor (Queue's lock held), or nil. }
function BestRunnableIn(Queue: PReadyQueue; Processor: PProcessor; Floor: Integer): PThreadControlBlock;
var
  Priority: Integer;
begin
  for Priority := HighestThreadPriority downto Floor do
  begin
    if (Queue^.PriorityMask and (LongWord(1) shl Priority)) = 0 then
      Continue;
    Result := FirstRunnableAt(Queue, Priority, Processor);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

{ The other processor whose queues look (without their locks) to hold
  the most important thread of at least Floor, skipping those in
  Tried; nil if none. }
function MostPromisingVictim(Processor: PProcessor; Floor: Integer; Tried: QWord): PProcessor;
var
  Index: LongWord;
  Highest: Integer;
  BestPriority: Integer;
  Mask: LongWord;
begin
  Result := nil;
  BestPriority := Floor - 1;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    if (Index = Processor^.Index) or ((Tried and (QWord(1) shl Index)) <> 0) then
      Continue;
    Mask := ReadyQueues[Index].PriorityMask;
    if Mask = 0 then
      Continue;
    Highest := HighestPriorityIn(Mask);
    if Highest > BestPriority then
    begin
      BestPriority := Highest;
      Result := ProcessorByIndex(Index);
    end;
  end;
end;

{ Takes from another processor's queues the most important thread of at
  least Floor that may run on Processor (Processor's lock held, the
  others only tried); nil if none could be had. }
function StealThreadFor(Processor: PProcessor; Floor: Integer): PThreadControlBlock;
var
  Tried: QWord;
  Victim: PProcessor;
  VictimQueue: PReadyQueue;
begin
  Result := nil;
  Tried := 0;
  if Floor < LowestThreadPriority then
    Floor := LowestThreadPriority;
  repeat
    Victim := MostPromisingVictim(Processor, Floor, Tried);
    if Victim = nil then
      Exit;
    Tried := Tried or (QWord(1) shl Victim^.Index);
    if not TryLockProcessor(Victim) then
    begin
      AtomicStore(QueueOf(Processor)^.StealRefused, 1);
      Continue;
    end;
    VictimQueue := QueueOf(Victim);
    Result := BestRunnableIn(VictimQueue, Processor, Floor);
    if Result <> nil then
      RemoveReadyThread(Result);
    UnlockProcessor(Victim);
  until Result <> nil;
end;

function TakeReadyThreadFor(Processor: PProcessor; MinimumPriority: Integer): PThreadControlBlock;
var
  Own: PThreadControlBlock;
  Floor: Integer;
begin
  if MinimumPriority > HighestThreadPriority then
    Exit(nil);
  if MinimumPriority < LowestThreadPriority then
    MinimumPriority := LowestThreadPriority;
  Own := BestRunnableIn(QueueOf(Processor), Processor, MinimumPriority);
  { Only a more important thread is worth taking from elsewhere. }
  if Own = nil then
    Floor := MinimumPriority
  else
    Floor := Integer(Own^.Priority) + 1;
  Result := nil;
  if Floor <= HighestThreadPriority then
    Result := StealThreadFor(Processor, Floor);
  if Result <> nil then
    Exit;
  if Own <> nil then
    RemoveReadyThread(Own);
  Result := Own;
end;

function PullThreadForIdleProcessor(Processor: PProcessor): Boolean;
var
  Tried: QWord;
  Victim: PProcessor;
  Thread: PThreadControlBlock;
begin
  Result := False;
  if AtomicExchange(QueueOf(Processor)^.StealRefused, 0) = 0 then
    Exit;
  Tried := 0;
  repeat
    Victim := MostPromisingVictim(Processor, LowestThreadPriority, Tried);
    if Victim = nil then
      Exit;
    Tried := Tried or (QWord(1) shl Victim^.Index);
    { No other scheduling lock is held here, so this one may be waited
      for. }
    LockProcessor(Victim);
    Thread := BestRunnableIn(QueueOf(Victim), Processor, LowestThreadPriority);
    if Thread <> nil then
      RemoveReadyThread(Thread);
    UnlockProcessor(Victim);
  until Thread <> nil;
  LockProcessor(Processor);
  EnqueueReadyThread(Thread, Processor);
  UnlockProcessor(Processor);
  Result := True;
end;

function StealWasRefused(Processor: PProcessor): Boolean;
begin
  Result := AtomicLoad(QueueOf(Processor)^.StealRefused) <> 0;
end;

function ReadyThreadTotal: LongWord;
var
  Index: LongWord;
begin
  Result := 0;
  for Index := 0 to ProcessorTotal - 1 do
    Result := Result + ReadyQueues[Index].Count;
end;

{ Only the queues below the top of the variable class can hold one. }
function StarvedThreadIn(Queue: PReadyQueue; Now: QWord): PThreadControlBlock;
var
  Priority: Integer;
  Entry: PListEntry;
begin
  for Priority := LowestThreadPriority to HighestVariablePriority - 1 do
  begin
    if (Queue^.PriorityMask and (LongWord(1) shl Priority)) = 0 then
      Continue;
    Entry := Queue^.Queues[Priority].Next;
    while Entry <> @Queue^.Queues[Priority] do
    begin
      Result := ThreadFromSchedulerLink(Entry);
      if HasStarved(Result^.BasePriority, Result^.Priority, Result^.ReadySince, Now) then
        Exit;
      Entry := Entry^.Next;
    end;
  end;
  Result := nil;
end;

function TakeStarvedReadyThread(Now: QWord): PThreadControlBlock;
var
  Index: LongWord;
  Processor: PProcessor;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    if ReadyQueues[Index].Count = 0 then
      Continue;
    Processor := ProcessorByIndex(Index);
    LockProcessor(Processor);
    Result := StarvedThreadIn(@ReadyQueues[Index], Now);
    if Result <> nil then
      RemoveReadyThread(Result);
    UnlockProcessor(Processor);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

end.
