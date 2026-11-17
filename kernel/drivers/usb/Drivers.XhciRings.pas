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
  xHCI rings: transfer request blocks (TRBs) and the rings they live in.

  Every TRB is 16 bytes: a 64-bit parameter, a status word and a control
  word holding the TRB type and the cycle bit. A producer ring (the
  command ring, and each endpoint's transfer ring) is a page of TRBs
  whose last one links back to the first and flips the producer's cycle
  bit; the controller takes TRBs whose cycle bit matches its own. The
  event ring goes the other way: the controller writes events, the
  driver takes those whose cycle bit matches its expectation (flipping
  it after each wrap), and tells the controller how far it got.
}
unit Drivers.XhciRings;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Dma;

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
  CompletionShortPacket = 13;

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
    { Where the controller finds the ring (Io.Dma). }
    BusAddress: QWord;
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

{ Rings are DMA memory of the controller (Dma: its attributes), shared
  with it: uncached for a controller that does not snoop. }
function AllocateProducerRing(constref Dma: TDmaAttributes; out Ring: TProducerRing): Boolean;
{ Empties a ring in its page (as a controller that was reset expects it). }
procedure ResetProducerRing(var Ring: TProducerRing);
{ Puts a TRB on Ring (its cycle bit set for the ring) and returns its
  bus address. }
function EnqueueTrb(var Ring: TProducerRing; Parameter: QWord; Status: LongWord;
  Control: LongWord): QWord;

function AllocateEventRing(constref Dma: TDmaAttributes; out Ring: TEventRing): Boolean;
procedure ResetEventRing(var Ring: TEventRing);
{ The next event, if the controller has written one. }
function NextEvent(var Ring: TEventRing; out Event: TTrb): Boolean;
{ The bus address of the event ring's dequeue position. }
function EventDequeuePointer(const Ring: TEventRing): QWord;

function TrbType(const Trb: TTrb): LongWord;
function CompletionCode(const Trb: TTrb): LongWord;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic;

function AllocateRingPage(constref Dma: TDmaAttributes; out BusAddress: QWord): PTrb;
var
  Buffer: TDmaBuffer;
begin
  BusAddress := 0;
  if not AllocateDmaBuffer(Dma, SizeOf(TTrb) * TrbsPerRing, DmaShared, Buffer) then
    Exit(nil);
  BusAddress := Buffer.DeviceAddress;
  Result := PTrb(Buffer.Address);
end;

procedure ResetProducerRing(var Ring: TProducerRing);
begin
  FillMemory(Ring.Trbs, TrbsPerRing * SizeOf(TTrb), 0);
  Ring.Enqueue := 0;
  Ring.Cycle := TrbCycle;
  { The last TRB links back to the first and flips the cycle bit. }
  Ring.Trbs[TrbsPerRing - 1].Parameter := Ring.BusAddress;
  Ring.Trbs[TrbsPerRing - 1].Control := (TrbTypeLink shl TrbTypeShift) or TrbToggleCycle;
end;

function AllocateProducerRing(constref Dma: TDmaAttributes; out Ring: TProducerRing): Boolean;
begin
  Ring.Trbs := AllocateRingPage(Dma, Ring.BusAddress);
  Result := Ring.Trbs <> nil;
  if Result then
    ResetProducerRing(Ring);
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

function AllocateEventRing(constref Dma: TDmaAttributes; out Ring: TEventRing): Boolean;
begin
  Ring.Trbs := AllocateRingPage(Dma, Ring.BusAddress);
  Ring.SegmentTable := PQWord(AllocateRingPage(Dma, Ring.SegmentTableBusAddress));
  Result := (Ring.Trbs <> nil) and (Ring.SegmentTable <> nil);
  if not Result then
    Exit;
  Ring.SegmentTable[0] := Ring.BusAddress;
  Ring.SegmentTable[1] := TrbsPerRing;
  Ring.Dequeue := 0;
  Ring.Cycle := TrbCycle;
end;

procedure ResetEventRing(var Ring: TEventRing);
begin
  FillMemory(Ring.Trbs, TrbsPerRing * SizeOf(TTrb), 0);
  Ring.Dequeue := 0;
  Ring.Cycle := TrbCycle;
end;

function NextEvent(var Ring: TEventRing; out Event: TTrb): Boolean;
begin
  FullMemoryBarrier;
  Event := Ring.Trbs[Ring.Dequeue];
  Result := (Event.Control and TrbCycle) = Ring.Cycle;
  if not Result then
    Exit;
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

end.
