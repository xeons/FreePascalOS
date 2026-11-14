{
  Run queues: one set per processor.

  Every processor has a run queue per priority level. A thread that
  becomes ready is placed (ChooseProcessorFor) on

    1. the processor it last ran on, if that one is idle (its data may
       still be in that processor's cache),
    2. else any idle processor it may run on, this one first,
    3. else the processor running the least important thread, if that is
       less important than this one,
    4. else again the processor it last ran on.

  A processor choosing its next thread (TakeReadyThreadFor) takes the
  most important thread of its own queues, unless another processor's
  queues hold a more important one that may run here - or, when its own
  queues are empty, any one that may run here. So no processor idles or
  runs something less important while a thread it could run waits
  elsewhere, and threads still mostly stay where they are.

  The affinity mask of a thread limits it to some processors (bit N for
  the processor with index N). A mask that allows no online processor
  allows them all.

  Everything here runs under the dispatcher lock (Kernel.Scheduler).
}
unit Kernel.ReadyQueues;

{$mode objfpc}

interface

uses
  Kernel.Threads,
  Kernel.Processors;

procedure InitializeReadyQueues;

function ThreadMayRunOn(Thread: PThreadControlBlock; Processor: PProcessor): Boolean;
{ Where a thread that becomes ready should go; see the unit comment. }
function ChooseProcessorFor(Thread: PThreadControlBlock): PProcessor;

procedure EnqueueReadyThread(Thread: PThreadControlBlock; Processor: PProcessor);
{ Takes a ready thread out of whichever queue it is in. }
procedure RemoveReadyThread(Thread: PThreadControlBlock);

{ The priority of the thread TakeReadyThreadFor would return, or -1. }
function BestReadyPriorityFor(Processor: PProcessor): Integer;
{ The next thread for Processor, taken out of its queue; nil if none. }
function TakeReadyThreadFor(Processor: PProcessor): PThreadControlBlock;

{ An idle processor (other than Exclude) that Thread may run on, or nil. }
function FindIdleProcessorFor(Thread: PThreadControlBlock; Exclude: PProcessor): PProcessor;

function ReadyThreadTotal: LongWord;

implementation

uses
  Runtime.LinkedList;

type
  TReadyQueue = record
    Queues: array[0..PriorityCount - 1] of TListEntry;
    { Bit N is set when Queues[N] is not empty. }
    PriorityMask: LongWord;
    Count: LongWord;
  end;
  PReadyQueue = ^TReadyQueue;

var
  ReadyQueues: array[0..MaximumProcessors - 1] of TReadyQueue;
  TotalReady: LongWord;

procedure InitializeReadyQueues;
var
  Index: Integer;
  Priority: Integer;
begin
  for Index := 0 to MaximumProcessors - 1 do
  begin
    for Priority := 0 to PriorityCount - 1 do
      InitializeListHead(ReadyQueues[Index].Queues[Priority]);
    ReadyQueues[Index].PriorityMask := 0;
    ReadyQueues[Index].Count := 0;
  end;
  TotalReady := 0;
end;

function OnlineProcessorMask: QWord;
var
  Index: LongWord;
begin
  Result := 0;
  for Index := 0 to ProcessorTotal - 1 do
    if ProcessorByIndex(Index)^.IsOnline then
      Result := Result or (QWord(1) shl Index);
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
    if Candidate^.RunningThread^.Priority >= Thread^.Priority then
      Continue;
    if (Result = nil) or (Candidate^.RunningThread^.Priority < Result^.RunningThread^.Priority) then
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

procedure EnqueueReadyThread(Thread: PThreadControlBlock; Processor: PProcessor);
var
  Queue: PReadyQueue;
begin
  Queue := @ReadyQueues[Processor^.Index];
  Thread^.State := ThreadStateReady;
  Thread^.QueuedProcessorIndex := Processor^.Index;
  InsertAtTail(Queue^.Queues[Thread^.Priority], @Thread^.SchedulerLink);
  Queue^.PriorityMask := Queue^.PriorityMask or (LongWord(1) shl Thread^.Priority);
  Inc(Queue^.Count);
  Inc(TotalReady);
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
  Dec(TotalReady);
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

{ The most important thread in another processor's queues that may run
  on Processor, with a priority of at least Floor; nil if none. }
function FindThreadToTake(Processor: PProcessor; Floor: Integer): PThreadControlBlock;
var
  Index: LongWord;
  Queue: PReadyQueue;
  Priority: Integer;
  Candidate: PThreadControlBlock;
begin
  Result := nil;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    if Index = Processor^.Index then
      Continue;
    Queue := @ReadyQueues[Index];
    if Queue^.Count = 0 then
      Continue;
    for Priority := HighestThreadPriority downto Floor do
    begin
      if (Result <> nil) and (Priority <= Integer(Result^.Priority)) then
        Break;
      if (Queue^.PriorityMask and (LongWord(1) shl Priority)) = 0 then
        Continue;
      Candidate := FirstRunnableAt(Queue, Priority, Processor);
      if Candidate <> nil then
      begin
        Result := Candidate;
        Break;
      end;
    end;
  end;
end;

{ The next thread for Processor without taking it out. }
function PeekReadyThreadFor(Processor: PProcessor): PThreadControlBlock;
var
  Own: PReadyQueue;
  OwnPriority: Integer;
  Other: PThreadControlBlock;
begin
  Own := @ReadyQueues[Processor^.Index];
  OwnPriority := HighestPriorityIn(Own^.PriorityMask);
  { Only a more important thread is worth taking from elsewhere. }
  if OwnPriority < 0 then
    Other := FindThreadToTake(Processor, LowestThreadPriority)
  else
    Other := FindThreadToTake(Processor, OwnPriority + 1);
  if Other <> nil then
    Exit(Other);
  if OwnPriority < 0 then
    Exit(nil);
  Result := ThreadFromSchedulerLink(Own^.Queues[OwnPriority].Next);
end;

function BestReadyPriorityFor(Processor: PProcessor): Integer;
var
  Thread: PThreadControlBlock;
begin
  Thread := PeekReadyThreadFor(Processor);
  if Thread = nil then
    Exit(-1);
  Result := Integer(Thread^.Priority);
end;

function TakeReadyThreadFor(Processor: PProcessor): PThreadControlBlock;
begin
  Result := PeekReadyThreadFor(Processor);
  if Result <> nil then
    RemoveReadyThread(Result);
end;

function ReadyThreadTotal: LongWord;
begin
  Result := TotalReady;
end;

end.
