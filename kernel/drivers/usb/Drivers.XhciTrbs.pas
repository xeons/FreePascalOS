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
  xHCI transfer request blocks (TRBs) and the bookkeeping of the rings
  they live in, without the memory (Drivers.XhciRings allocates it).

  Every TRB is 16 bytes: a 64-bit parameter, a status word and a control
  word holding the TRB type and the cycle bit. A producer ring (the
  command ring, and each endpoint's transfer ring) is a page of TRBs
  whose last one links back to the first and flips the producer's cycle
  bit; the controller takes TRBs whose cycle bit matches its own. The
  event ring goes the other way: the controller writes events, the
  driver takes those whose cycle bit matches its expectation (flipping
  it after each wrap), and tells the controller how far it got.

  An event's control word (with its cycle bit) is read first and the
  rest only after a barrier: the controller writes the control word
  last, and on a weakly ordered processor reading the whole TRB at once
  could pair a new cycle bit with an old parameter.

  Plain Pascal with no kernel dependencies past the runtime (the host
  test tools/UsbDescriptorTest drives the rings in memory).
}
unit Drivers.XhciTrbs;

{$mode objfpc}
{$pointermath on}

interface

const
  TrbsPerRing = 256;

  TrbTypeNormal = 1;
  TrbTypeSetupStage = 2;
  TrbTypeDataStage = 3;
  TrbTypeStatusStage = 4;
  TrbTypeIsochronous = 5;
  TrbTypeLink = 6;
  TrbTypeEnableSlot = 9;
  TrbTypeDisableSlot = 10;
  TrbTypeAddressDevice = 11;
  TrbTypeConfigureEndpoint = 12;
  TrbTypeEvaluateContext = 13;
  TrbTypeResetEndpoint = 14;
  TrbTypeStopEndpoint = 15;
  TrbTypeSetDequeuePointer = 16;
  TrbTypeTransferEvent = 32;
  TrbTypeCommandCompletionEvent = 33;
  TrbTypePortStatusChangeEvent = 34;

  TrbCycle = LongWord(1) shl 0;
  TrbToggleCycle = LongWord(1) shl 1;
  TrbInterruptOnShortPacket = LongWord(1) shl 2;
  TrbChain = LongWord(1) shl 4;
  TrbInterruptOnCompletion = LongWord(1) shl 5;
  TrbImmediateData = LongWord(1) shl 6;
  TrbTypeShift = 10;

  CompletionSuccess = 1;
  { These halt the endpoint: it needs a Reset Endpoint command. }
  CompletionBabble = 3;
  CompletionTransactionError = 4;
  CompletionStall = 6;
  CompletionShortPacket = 13;
  { A command on an endpoint or slot in the wrong state (Stop Endpoint
    on a halted endpoint, say). }
  CompletionContextStateError = 19;
  { The command ring was stopped or a command aborted (Command Abort). }
  CompletionCommandRingStopped = 24;
  CompletionCommandAborted = 25;
  { What a transfer stopped by Stop Endpoint ends with. }
  CompletionStopped = 26;
  CompletionStoppedLengthInvalid = 27;

type
  TTrb = packed record
    Parameter: QWord;
    Status: LongWord;
    Control: LongWord;
  end;
  PTrb = ^TTrb;

  { A ring the driver produces TRBs on. }
  TProducerRing = record
    Trbs: PTrb;
    { Where the controller finds the ring (Io.Dma), and its page as
      allocated (for giving it back). }
    BusAddress: QWord;
    Physical: QWord;
    IsUncachedMapping: Boolean;
    Enqueue: LongWord;
    Cycle: LongWord;
  end;

  TEventRing = record
    Trbs: PTrb;
    BusAddress: QWord;
    { The segment table (one segment). }
    SegmentTable: PQWord;
    SegmentTableBusAddress: QWord;
    Dequeue: LongWord;
    Cycle: LongWord;
  end;

{ Empties a ring in its page (as a controller that was reset expects it). }
procedure ResetProducerRing(var Ring: TProducerRing);
{ Puts a TRB on Ring (its cycle bit set for the ring) and returns its
  bus address. }
function EnqueueTrb(var Ring: TProducerRing; Parameter: QWord; Status: LongWord;
  Control: LongWord): QWord;
{ Where the next TRB goes, with the ring's cycle bit in bit 0: what a
  Set TR Dequeue Pointer command takes to make the controller skip
  everything queued so far. }
function RingResumePointer(const Ring: TProducerRing): QWord;

procedure ResetEventRing(var Ring: TEventRing);
{ The next event, if the controller has written one. }
function NextEvent(var Ring: TEventRing; out Event: TTrb): Boolean;
{ The bus address of the event ring's dequeue position. }
function EventDequeuePointer(const Ring: TEventRing): QWord;

function TrbType(const Trb: TTrb): LongWord;
function CompletionCode(const Trb: TTrb): LongWord;
{ True for a completion that halts the endpoint (stall, babble,
  transaction error). }
function IsHaltingCompletion(Code: LongWord): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic;

procedure ResetProducerRing(var Ring: TProducerRing);
begin
  FillMemory(Ring.Trbs, TrbsPerRing * SizeOf(TTrb), 0);
  Ring.Enqueue := 0;
  Ring.Cycle := TrbCycle;
  { The last TRB links back to the first and flips the cycle bit. }
  Ring.Trbs[TrbsPerRing - 1].Parameter := Ring.BusAddress;
  Ring.Trbs[TrbsPerRing - 1].Control := (TrbTypeLink shl TrbTypeShift) or TrbToggleCycle;
end;

function EnqueueTrb(var Ring: TProducerRing; Parameter: QWord; Status: LongWord;
  Control: LongWord): QWord;
var
  Trb: PTrb;
  LinkControl: LongWord;
begin
  Trb := @Ring.Trbs[Ring.Enqueue];
  Result := Ring.BusAddress + Ring.Enqueue * SizeOf(TTrb);
  Trb^.Parameter := Parameter;
  Trb^.Status := Status;
  { The cycle bit last, so the controller never sees half a TRB. }
  FullMemoryBarrier;
  Trb^.Control := (Control and not TrbCycle) or Ring.Cycle;
  Inc(Ring.Enqueue);
  if Ring.Enqueue = TrbsPerRing - 1 then
  begin
    LinkControl := Ring.Trbs[TrbsPerRing - 1].Control;
    LinkControl := (LinkControl and not (TrbCycle or TrbChain)) or Ring.Cycle;
    { A link inside a chain is part of it. }
    if (Control and TrbChain) <> 0 then
      LinkControl := LinkControl or TrbChain;
    FullMemoryBarrier;
    Ring.Trbs[TrbsPerRing - 1].Control := LinkControl;
    Ring.Enqueue := 0;
    Ring.Cycle := Ring.Cycle xor TrbCycle;
  end;
end;

function RingResumePointer(const Ring: TProducerRing): QWord;
begin
  Result := (Ring.BusAddress + QWord(Ring.Enqueue) * SizeOf(TTrb)) or Ring.Cycle;
end;

procedure ResetEventRing(var Ring: TEventRing);
begin
  FillMemory(Ring.Trbs, TrbsPerRing * SizeOf(TTrb), 0);
  Ring.Dequeue := 0;
  Ring.Cycle := TrbCycle;
end;

function NextEvent(var Ring: TEventRing; out Event: TTrb): Boolean;
var
  Slot: PTrb;
begin
  Slot := @Ring.Trbs[Ring.Dequeue];
  Event.Control := PLongWord(@Slot^.Control)^;
  Result := (Event.Control and TrbCycle) = Ring.Cycle;
  if not Result then
    Exit;
  { The rest only once the cycle bit says the event is complete. }
  FullMemoryBarrier;
  Event.Parameter := Slot^.Parameter;
  Event.Status := Slot^.Status;
  Inc(Ring.Dequeue);
  if Ring.Dequeue = TrbsPerRing then
  begin
    Ring.Dequeue := 0;
    Ring.Cycle := Ring.Cycle xor TrbCycle;
  end;
end;

function EventDequeuePointer(const Ring: TEventRing): QWord;
begin
  Result := Ring.BusAddress + Ring.Dequeue * SizeOf(TTrb);
end;

function TrbType(const Trb: TTrb): LongWord;
begin
  Result := (Trb.Control shr TrbTypeShift) and $3F;
end;

function CompletionCode(const Trb: TTrb): LongWord;
begin
  Result := Trb.Status shr 24;
end;

function IsHaltingCompletion(Code: LongWord): Boolean;
begin
  Result := (Code = CompletionStall) or (Code = CompletionBabble) or (Code = CompletionTransactionError);
end;

end.
