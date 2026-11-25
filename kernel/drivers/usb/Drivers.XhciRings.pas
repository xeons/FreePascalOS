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
  xHCI rings' memory: each ring is a page of DMA memory of the
  controller (Io.Dma), shared with it: uncached for a controller that
  does not snoop. The TRBs and the rings' bookkeeping are in
  Drivers.XhciTrbs.
}
unit Drivers.XhciRings;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Dma,
  Drivers.XhciTrbs;

{ Rings are DMA memory of the controller (Dma: its attributes). }
function AllocateProducerRing(constref Dma: TDmaAttributes; out Ring: TProducerRing): Boolean;
function AllocateEventRing(constref Dma: TDmaAttributes; out Ring: TEventRing): Boolean;
{ Gives a ring's page back (once the controller can no longer use it). }
procedure FreeProducerRing(constref Dma: TDmaAttributes; var Ring: TProducerRing);

implementation

uses
  Runtime.Memory;

function AllocateRingPage(constref Dma: TDmaAttributes; out Buffer: TDmaBuffer): PTrb;
begin
  if not AllocateDmaBuffer(Dma, SizeOf(TTrb) * TrbsPerRing, DmaShared, Buffer) then
    Exit(nil);
  Result := PTrb(Buffer.Address);
end;

function AllocateProducerRing(constref Dma: TDmaAttributes; out Ring: TProducerRing): Boolean;
var
  Buffer: TDmaBuffer;
begin
  ZeroMemory(@Ring, SizeOf(Ring));
  Ring.Trbs := AllocateRingPage(Dma, Buffer);
  Result := Ring.Trbs <> nil;
  if not Result then
    Exit;
  Ring.BusAddress := Buffer.DeviceAddress;
  Ring.Physical := Buffer.Physical;
  Ring.IsUncachedMapping := Buffer.IsUncachedMapping;
  ResetProducerRing(Ring);
end;

procedure FreeProducerRing(constref Dma: TDmaAttributes; var Ring: TProducerRing);
var
  Buffer: TDmaBuffer;
begin
  if Ring.Trbs = nil then
    Exit;
  ZeroMemory(@Buffer, SizeOf(Buffer));
  Buffer.Address := PByte(Ring.Trbs);
  Buffer.Physical := Ring.Physical;
  Buffer.DeviceAddress := Ring.BusAddress;
  Buffer.SizeInBytes := SizeOf(TTrb) * TrbsPerRing;
  Buffer.IsUncachedMapping := Ring.IsUncachedMapping;
  FreeDmaBuffer(Buffer);
  ZeroMemory(@Ring, SizeOf(Ring));
end;

function AllocateEventRing(constref Dma: TDmaAttributes; out Ring: TEventRing): Boolean;
var
  Buffer: TDmaBuffer;
begin
  ZeroMemory(@Ring, SizeOf(Ring));
  Ring.Trbs := AllocateRingPage(Dma, Buffer);
  Ring.BusAddress := Buffer.DeviceAddress;
  Ring.SegmentTable := PQWord(AllocateRingPage(Dma, Buffer));
  Ring.SegmentTableBusAddress := Buffer.DeviceAddress;
  Result := (Ring.Trbs <> nil) and (Ring.SegmentTable <> nil);
  if not Result then
    Exit;
  Ring.SegmentTable[0] := Ring.BusAddress;
  Ring.SegmentTable[1] := TrbsPerRing;
  Ring.Dequeue := 0;
  Ring.Cycle := TrbCycle;
end;

end.
