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
  InvalidateRemoteTranslations panics when called with interrupts
  disabled or above DispatchLevel. Every request must also arrive: the
  HAL sends inter-processor interrupts with interrupts disabled, since
  an interrupt in the middle of an xAPIC send could redirect it
  (Hal.LocalApic).

  Each target has a flag of its own (ShootdownPending): the sender sets
  it and sends the interrupt, the target clears it once it invalidated,
  and the sender waits until every flag it set is clear (a stuck one
  names its processor in the panic).

  Suspend to RAM: a processor frozen for it (Kernel.ProcessorPower)
  halts with interrupts off and is later started again with INIT, which
  throws away any interrupt still waiting at its interrupt controller.
  A request sent to it would never be answered, and processors woken
  first run (and shoot down) while the others are still frozen. So a
  freezing processor stops answering requests (StopAnsweringRequests):
  it clears the flag of a request already sent to it, and senders skip
  it from then on. That is safe, as it starts again with empty
  translation caches. Woken, once its interrupt controller works again,
  it answers requests again (ResumeAnsweringRequests) and only then
  throws away what it cached meanwhile. Flag and AnswersRequests are
  each written before the other is read, with full barriers, on both
  sides, so either the sender sees that the target stopped answering
  or the target sees the request and clears it.

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

{ Suspend to RAM. A processor about to freeze, with interrupts
  disabled, stops answering requests (and any waiting for it ends); a
  woken processor, once its interrupt controller is set up again,
  answers them again and empties its translation caches. }
procedure StopAnsweringRequests;
procedure ResumeAnsweringRequests;

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

procedure HandleRequestInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Processor: PProcessor;
  PageIndex: LongWord;
begin
  Processor := CurrentProcessor;
  if (ShootdownRoot = 0) or (Processor^.ActiveAddressSpace = ShootdownRoot) then
    for PageIndex := 1 to ShootdownPageCount do
      InvalidateTlbEntry(ShootdownAddress + QWord(PageIndex - 1) * PageSize);
  AtomicStore(Processor^.ShootdownPending, 0);
end;

procedure StopAnsweringRequests;
var
  Processor: PProcessor;
begin
  Processor := CurrentProcessor;
  AtomicExchange(Processor^.AnswersRequests, 0);
  { Its translation caches go with the power: what was asked of it is
    done. }
  AtomicExchange(Processor^.ShootdownPending, 0);
end;

procedure ResumeAnsweringRequests;
begin
  AtomicExchange(CurrentProcessor^.AnswersRequests, 1);
  { Translations cached between starting and now may have been changed
    by a sender that skipped this processor. }
  FlushEntireTlb;
end;

{ Asks Target to invalidate the translations of the current request.
  The flag is set before AnswersRequests is read (the exchange is a full
  barrier): a target that stopped answering in between clears it, one
  that stopped before is seen here. }
procedure SendShootdownRequest(Target: PProcessor);
begin
  AtomicExchange(Target^.ShootdownPending, 1);
  if AtomicLoad(Target^.AnswersRequests) <> 0 then
    HalSendRequestInterrupt(Target^.ApicId)
  else
    AtomicStore(Target^.ShootdownPending, 0);
end;

{ Waits until every processor answered; panics naming the first one that
  did not. }
procedure WaitForShootdownAnswers(Root: QWord; StartAddress: QWord; PageCount: LongWord);
var
  Index: LongWord;
  Spins: QWord;
  Target: PProcessor;
begin
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Target := ProcessorByIndex(Index);
    if Target = nil then
      Continue;
    Spins := 0;
    while AtomicLoad(Target^.ShootdownPending) <> 0 do
    begin
      CpuRelax;
      Inc(Spins);
      if Spins = AcknowledgementSpinLimit then
        KernelPanicWithCode(PanicSchedulerFailure, 'a processor did not answer a TLB shootdown',
          StartAddress, Root, PageCount, Index);
    end;
  end;
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
begin
  if OnlineProcessorCount <= 1 then
    Exit;
  { A sender that cannot take interrupts never answers the request of a
    processor that started its shootdown first: both would wait forever.
    Catch such a caller here, not as a hang. }
  if not InterruptsAreEnabled then
    KernelPanicWithCode(PanicSchedulerFailure, 'TLB shootdown with interrupts disabled',
      StartAddress, Root, PageCount, 0);
  if CurrentPriorityLevel > DispatchLevel then
    KernelPanicWithCode(PanicInvalidPriorityLevel, 'TLB shootdown above dispatch level',
      StartAddress, Root, CurrentPriorityLevel, 0);
  PreviousLevel := AcquireSpinLock(ShootdownLock);
  Self := CurrentProcessor;
  ShootdownRoot := Root;
  ShootdownAddress := StartAddress;
  ShootdownPageCount := PageCount;
  { The page table change must be visible before the other processors'
    loaded address spaces are read: one switching to Root either shows
    up here or already sees the changed table. }
  FullMemoryBarrier;
  for Index := 0 to ProcessorTotal - 1 do
  begin
    Other := ProcessorByIndex(Index);
    if (Other = Self) or not Other^.IsOnline then
      Continue;
    if (Root <> 0) and (Other^.ActiveAddressSpace <> Root) then
      Continue;
    SendShootdownRequest(Other);
  end;
  WaitForShootdownAnswers(Root, StartAddress, PageCount);
  ReleaseSpinLock(ShootdownLock, PreviousLevel);
end;

procedure RequestDispatchOnProcessor(Processor: PProcessor);
begin
  HalRequestDispatchOn(Processor^.ApicId);
end;

end.
