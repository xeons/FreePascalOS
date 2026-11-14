{
  Requests between processors.

  TLB shootdown: a processor caches page translations, and changing a page
  table on one processor does not reach the caches of the others. After
  removing mappings, the processor that removed them invalidates its own
  cache entries and calls InvalidateRemoteTranslations, which interrupts
  every other processor that may hold stale entries (all of them for a
  kernel address; for a user address only those that have that address
  space loaded) and waits until each has invalidated them. One request
  covers a run of consecutive pages (Memory.Arch.PageTables unmaps up to
  32 at a time), so freeing a large region costs one interrupt per run,
  not per page.

  One shootdown runs at a time (ShootdownLock). The sender waits at
  DispatchLevel with interrupts enabled; the request interrupt arrives at
  InterProcessorLevel, above any spin lock holder, so a processor
  spinning on a lock still answers. Processors must therefore not spin
  with interrupts disabled on a lock whose holder may shoot down, which is
  why page faults are handled with interrupts on (Kernel.Arch.Exceptions).

  Rescheduling: RequestDispatchOnProcessor makes another processor run its
  dispatch interrupt, for example to pick up a thread that just became
  ready while it was idle.
}
unit Kernel.InterProcessor;

{$mode objfpc}

interface

uses
  Kernel.Processors;

procedure InitializeInterProcessorRequests;

{ Invalidates the translations of PageCount pages from StartAddress on
  the other processors: all of them when Root is 0 (a kernel address),
  else those with address space Root loaded. Waits until they did. Call
  at or below DispatchLevel with interrupts enabled, holding no lock
  another processor might spin on with interrupts disabled. }
procedure InvalidateRemoteTranslations(Root: QWord; StartAddress: QWord; PageCount: LongWord);

procedure RequestDispatchOnProcessor(Processor: PProcessor);

implementation

uses
  Runtime.Atomic,
  Memory.Layout,
  Hal.Platform,
  Kernel.Arch.Cpu,
  Kernel.Arch.TrapFrame,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Interrupts,
  Kernel.Panic;

const
  { Spins of waiting for acknowledgements before giving up: far longer
    than any processor takes to answer an interrupt. }
  AcknowledgementSpinLimit = QWord(4000000000);

var
  ShootdownLock: TSpinLock;
  ShootdownRoot: QWord;
  ShootdownAddress: QWord;
  ShootdownPageCount: LongWord;
  PendingAcknowledgements: Int64;

procedure HandleRequestInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Processor: PProcessor;
  PageIndex: LongWord;
begin
  Processor := CurrentProcessor;
  if (ShootdownRoot = 0) or (Processor^.ActiveAddressSpace = ShootdownRoot) then
    for PageIndex := 1 to ShootdownPageCount do
      InvalidateTlbEntry(ShootdownAddress + QWord(PageIndex - 1) * PageSize);
  AtomicDecrement(PendingAcknowledgements);
end;

procedure InitializeInterProcessorRequests;
begin
  InitializeSpinLock(ShootdownLock);
  if not RegisterInterruptHandler(HalRequestInterruptVector, @HandleRequestInterrupt, nil) then
    KernelPanic('inter-processor request vector is already in use');
end;

procedure InvalidateRemoteTranslations(Root: QWord; StartAddress: QWord; PageCount: LongWord);
var
  PreviousLevel: TPriorityLevel;
  Self: PProcessor;
  Other: PProcessor;
  Index: LongWord;
  Spins: QWord;
begin
  if OnlineProcessorCount <= 1 then
    Exit;
  PreviousLevel := AcquireSpinLock(ShootdownLock);
  Self := CurrentProcessor;
  ShootdownRoot := Root;
  ShootdownAddress := StartAddress;
  ShootdownPageCount := PageCount;
  { The page table change must be visible before the other processors'
    loaded address spaces are read: one switching to Root either shows
    up here or already sees the changed table. }
  FullMemoryBarrier;
  PendingAcknowledgements := 0;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Other := ProcessorByIndex(Index);
    if (Other = Self) or not Other^.IsOnline then
      Continue;
    if (Root <> 0) and (Other^.ActiveAddressSpace <> Root) then
      Continue;
    AtomicIncrement(PendingAcknowledgements);
    HalSendRequestInterrupt(Other^.ApicId);
  end;
  Spins := 0;
  while AtomicFetchAndAdd(PendingAcknowledgements, 0) > 0 do
  begin
    CpuRelax;
    Inc(Spins);
    if Spins = AcknowledgementSpinLimit then
      KernelPanicWithCode(PanicSchedulerFailure, 'a processor did not answer a TLB shootdown',
        StartAddress, Root, PageCount, 0);
  end;
  ReleaseSpinLock(ShootdownLock, PreviousLevel);
end;

procedure RequestDispatchOnProcessor(Processor: PProcessor);
begin
  HalRequestDispatchOn(Processor^.ApicId);
end;

end.
