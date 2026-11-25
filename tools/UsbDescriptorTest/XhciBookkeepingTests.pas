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
  The xHCI driver's bookkeeping, in memory: which device context an
  endpoint takes (endpoint 0 refused in both directions), a producer
  ring's TRBs, link and cycle bit across wraps, the pointer a Set TR
  Dequeue Pointer gets after a transfer is given up (past every TRB
  queued, with the ring's cycle bit), the event ring taking only what
  the controller completed, and the bytes a transfer moved from its
  event (a residue larger than its TRB never wraps the count).
}
unit XhciBookkeepingTests;

{$mode objfpc}
{$pointermath on}

interface

procedure TestXhciBookkeeping;

implementation

uses
  SysUtils,
  Drivers.XhciTrbs,
  Drivers.XhciTransfers,
  UsbTestChecks;

const
  RingBusAddress = QWord($12340000);

procedure TestContextIndexes;
var
  ContextIndex: LongWord;
begin
  Check(not EndpointContextIndex($00, ContextIndex), 'endpoint 00h takes no endpoint context');
  CheckNumber(ContextIndex, 0, 'endpoint 00h''s context');
  Check(not EndpointContextIndex($80, ContextIndex), 'endpoint 80h takes no endpoint context');
  Check(not EndpointContextIndex($91, ContextIndex), 'an address with a reserved bit takes none');
  Check(EndpointContextIndex($01, ContextIndex), 'endpoint 01h has a context');
  CheckNumber(ContextIndex, 2, 'endpoint 01h''s context');
  Check(EndpointContextIndex($81, ContextIndex), 'endpoint 81h has a context');
  CheckNumber(ContextIndex, 3, 'endpoint 81h''s context');
  Check(EndpointContextIndex($8F, ContextIndex), 'endpoint 8Fh has a context');
  CheckNumber(ContextIndex, 31, 'endpoint 8Fh''s context');
end;

procedure TestProducerRing;
var
  Ring: TProducerRing;
  Memory: PTrb;
  Index: Integer;
  Trb: QWord;
begin
  Memory := GetMem(TrbsPerRing * SizeOf(TTrb));
  Ring.Trbs := Memory;
  Ring.BusAddress := RingBusAddress;
  ResetProducerRing(Ring);
  CheckNumber(RingResumePointer(Ring), RingBusAddress or TrbCycle, 'an empty ring resumes at its start, cycle 1');
  { A transfer of three TRBs, then given up: the dequeue pointer goes
    past all three. }
  EnqueueTrb(Ring, $1000, 4096, (TrbTypeNormal shl TrbTypeShift) or TrbChain);
  EnqueueTrb(Ring, $2000, 4096, (TrbTypeNormal shl TrbTypeShift) or TrbChain);
  Trb := EnqueueTrb(Ring, $3000, 100, (TrbTypeNormal shl TrbTypeShift) or TrbInterruptOnCompletion);
  CheckNumber(Trb, RingBusAddress + 2 * SizeOf(TTrb), 'the third TRB''s bus address');
  CheckNumber(RingResumePointer(Ring), (RingBusAddress + 3 * SizeOf(TTrb)) or TrbCycle,
    'a given up transfer''s ring resumes past it');
  CheckNumber(Memory[2].Control and TrbCycle, 1, 'TRBs carry the ring''s cycle bit');
  { Up to the link: the ring wraps and the cycle bit flips. }
  for Index := 3 to TrbsPerRing - 3 do
    EnqueueTrb(Ring, 0, 0, TrbTypeNormal shl TrbTypeShift);
  { The last TRB before the link is chained: the link joins the chain. }
  EnqueueTrb(Ring, 0, 0, (TrbTypeNormal shl TrbTypeShift) or TrbChain);
  CheckNumber(Ring.Enqueue, 0, 'the ring wrapped');
  CheckNumber(Ring.Cycle, 0, 'its cycle bit flipped');
  CheckNumber(TrbType(Memory[TrbsPerRing - 1]), TrbTypeLink, 'the last TRB is the link');
  CheckNumber(Memory[TrbsPerRing - 1].Control and TrbCycle, 1, 'the link carries the old cycle bit');
  Check((Memory[TrbsPerRing - 1].Control and TrbChain) <> 0, 'a link inside a chain is chained');
  CheckNumber(Memory[TrbsPerRing - 1].Parameter, RingBusAddress, 'the link points back to the start');
  CheckNumber(RingResumePointer(Ring), RingBusAddress, 'after the wrap it resumes at the start, cycle 0');
  EnqueueTrb(Ring, 0, 0, TrbTypeNormal shl TrbTypeShift);
  CheckNumber(Memory[0].Control and TrbCycle, 0, 'the next lap''s TRBs carry cycle 0');
  FreeMem(Memory);
end;

procedure WriteEvent(Memory: PTrb; Index: Integer; Parameter: QWord; Code, Cycle: LongWord);
begin
  Memory[Index].Parameter := Parameter;
  Memory[Index].Status := Code shl 24;
  Memory[Index].Control := (TrbTypeTransferEvent shl TrbTypeShift) or Cycle;
end;

procedure TestEventRing;
var
  Ring: TEventRing;
  Memory: PTrb;
  Event: TTrb;
  Index: Integer;
  Taken: Integer;
begin
  Memory := GetMem(TrbsPerRing * SizeOf(TTrb));
  FillChar(Ring, SizeOf(Ring), 0);
  Ring.Trbs := Memory;
  Ring.BusAddress := RingBusAddress;
  ResetEventRing(Ring);
  Check(not NextEvent(Ring, Event), 'an empty event ring has no event');
  WriteEvent(Memory, 0, $AAAA, CompletionSuccess, 1);
  WriteEvent(Memory, 1, $BBBB, CompletionStall, 1);
  Check(NextEvent(Ring, Event), 'the first event is taken');
  CheckNumber(Event.Parameter, $AAAA, 'the first event''s TRB');
  Check(NextEvent(Ring, Event), 'the second event is taken');
  CheckNumber(CompletionCode(Event), CompletionStall, 'the second event''s code');
  Check(IsHaltingCompletion(CompletionCode(Event)), 'a stall halts the endpoint');
  Check(not IsHaltingCompletion(CompletionShortPacket), 'a short packet does not');
  Check(not NextEvent(Ring, Event), 'nothing past what the controller wrote');
  CheckNumber(EventDequeuePointer(Ring), RingBusAddress + 2 * SizeOf(TTrb), 'the dequeue pointer');
  { A whole lap: the expected cycle bit flips, and last lap's events
    (cycle 1) are not taken again. }
  for Index := 2 to TrbsPerRing - 1 do
    WriteEvent(Memory, Index, Index, CompletionSuccess, 1);
  Taken := 0;
  while NextEvent(Ring, Event) do
    Inc(Taken);
  CheckNumber(Taken, TrbsPerRing - 2, 'the rest of the lap');
  CheckNumber(Ring.Cycle, 0, 'the expected cycle bit flipped');
  Check(not NextEvent(Ring, Event), 'last lap''s events are not taken again');
  WriteEvent(Memory, 0, $CCCC, CompletionSuccess, 0);
  Check(NextEvent(Ring, Event) and (Event.Parameter = $CCCC), 'the next lap''s event is taken');
  FreeMem(Memory);
end;

procedure TestPendingTransfers;
var
  Pending: TPendingTransfer;
  Index: Integer;
begin
  ClearPendingTransfer(Pending);
  for Index := 0 to 15 do
    Check(NotePendingTrb(Pending, RingBusAddress + QWord(Index) * 16, 4096), 'a 64 KiB transfer''s TRBs fit');
  Check(IsPendingTrb(Pending, RingBusAddress + 3 * 16), 'its fourth TRB is pending');
  Check(not IsPendingTrb(Pending, RingBusAddress + 16 * 16), 'a TRB past it is not');
  CheckNumber(CompletedBytes(Pending, RingBusAddress + 15 * 16, 0), 65536, 'a whole transfer');
  CheckNumber(CompletedBytes(Pending, RingBusAddress + 3 * 16, 100), 3 * 4096 + 3996,
    'a short packet in the fourth TRB');
  CheckNumber(CompletedBytes(Pending, RingBusAddress + 3 * 16, $FFFFFF), 3 * 4096,
    'a residue larger than its TRB does not wrap the count');
  CheckNumber(CompletedBytes(Pending, $DEAD0000, 0), 0, 'an event for another TRB moves nothing');
  ClearPendingTransfer(Pending);
  for Index := 1 to MaximumPendingTrbs do
    NotePendingTrb(Pending, Index, 1);
  Check(not NotePendingTrb(Pending, 0, 1), 'the list does not overflow');
  CheckNumber(Pending.Count, MaximumPendingTrbs, 'the full list''s count');
  ClearPendingTransfer(Pending);
  Check(not IsPendingTrb(Pending, 1), 'a cleared transfer has no TRB (late events are ignored)');
end;

procedure TestXhciBookkeeping;
begin
  TestContextIndexes;
  TestProducerRing;
  TestEventRing;
  TestPendingTransfers;
end;

end.
