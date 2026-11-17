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
  Isochronous streams over xHCI: a steady flow of packets, one per
  service interval, as audio needs.

  The class driver supplies the packets (NextPacket: where the bytes
  are, in one or two pieces of physical memory, and a tag of its own)
  and hears when each has gone (PacketDone, with its tag). The stream
  keeps PacketsInFlight packets on the endpoint's transfer ring, each a
  transfer descriptor of an isochronous TRB (and a chained normal TRB
  for a second piece), started as soon as possible and interrupting when
  done; as each completes the next is queued. Stopping only stops
  queueing: what is in flight still completes. The packets' memory is
  the class driver's: for a controller that does not snoop the caches it
  is cleaned before it is queued, and every piece is given to the
  controller at its bus address (Io.Dma).

  Everything here runs under the controller's event lock (the caller
  takes it), at dispatch level.
}
unit Drivers.XhciIsochronous;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Dma,
  Drivers.XhciRings;

const
  PacketsInFlight = 24;
  MaximumPacketPieces = 2;

type
  TIsochronousPacket = record
    PieceCount: Integer;
    Physical: array[0..MaximumPacketPieces - 1] of QWord;
    Length: array[0..MaximumPacketPieces - 1] of LongWord;
    Tag: QWord;
  end;

  TIsochronousRoutines = record
    { Fills Packet with the next one; False if there is none now. }
    NextPacket: function(Context: Pointer; out Packet: TIsochronousPacket): Boolean;
    PacketDone: procedure(Context: Pointer; Tag: QWord);
  end;

  TIsochronousStream = record
    Ring: ^TProducerRing;
    { The controller's DMA attributes. }
    Dma: PDmaAttributes;
    Routines: TIsochronousRoutines;
    Context: Pointer;
    Streaming: Boolean;
    { The packets in flight, oldest first: the TRB that ends each, and
      its tag. }
    LastTrbs: array[0..PacketsInFlight - 1] of QWord;
    Tags: array[0..PacketsInFlight - 1] of QWord;
    Oldest: Integer;
    InFlight: Integer;
  end;

procedure InitializeIsochronousStream(out Stream: TIsochronousStream; var Ring: TProducerRing;
  Dma: PDmaAttributes; const Routines: TIsochronousRoutines; Context: Pointer);
{ Queues packets until PacketsInFlight are on the ring (if streaming);
  True if it queued any (the caller rings the doorbell). }
function FillIsochronousStream(var Stream: TIsochronousStream): Boolean;
{ A transfer event for the stream's endpoint: the packets up to the one
  it names are done. Then the ring is filled again; True if the caller
  should ring the doorbell. }
function IsochronousEventArrived(var Stream: TIsochronousStream; const Event: TTrb): Boolean;

implementation

uses
  Runtime.Memory,
  Memory.Layout;

const
  { Start the transfer descriptor as soon as possible. }
  TrbStartAsSoonAsPossible = LongWord(1) shl 31;

procedure InitializeIsochronousStream(out Stream: TIsochronousStream; var Ring: TProducerRing;
  Dma: PDmaAttributes; const Routines: TIsochronousRoutines; Context: Pointer);
begin
  ZeroMemory(@Stream, SizeOf(Stream));
  Stream.Ring := @Ring;
  Stream.Dma := Dma;
  Stream.Routines := Routines;
  Stream.Context := Context;
end;

{ The bus address of a piece, its bytes written out of the caches first
  (the physical address itself if the controller cannot be told it,
  which a controller reaching all of memory never refuses). }
function PreparePiece(var Stream: TIsochronousStream; Physical: QWord; Length: LongWord): QWord;
begin
  PrepareDmaToDevice(Stream.Dma^, PhysicalToVirtual(Physical), Length);
  if not TranslateDmaAddress(Stream.Dma^, Physical, Length, Result) then
    Result := Physical;
end;

{ Puts Packet on the ring as one transfer descriptor; returns the TRB
  that ends it. }
function QueuePacket(var Stream: TIsochronousStream; const Packet: TIsochronousPacket): QWord;
var
  Piece: Integer;
  Control: LongWord;
  Remaining: LongWord;
begin
  Result := 0;
  for Piece := 0 to Packet.PieceCount - 1 do
  begin
    { TD size: how many more max-size packets follow; 0 (one packet). }
    Remaining := 0;
    if Piece = 0 then
      Control := (TrbTypeIsochronous shl TrbTypeShift) or TrbStartAsSoonAsPossible
    else
      Control := TrbTypeNormal shl TrbTypeShift;
    if Piece < Packet.PieceCount - 1 then
      Control := Control or TrbChain
    else
      Control := Control or TrbInterruptOnCompletion;
    Result := EnqueueTrb(Stream.Ring^, PreparePiece(Stream, Packet.Physical[Piece], Packet.Length[Piece]),
      Packet.Length[Piece] or (Remaining shl 17), Control);
  end;
end;

function FillIsochronousStream(var Stream: TIsochronousStream): Boolean;
var
  Packet: TIsochronousPacket;
  Slot: Integer;
begin
  Result := False;
  while Stream.Streaming and (Stream.InFlight < PacketsInFlight) do
  begin
    if not Stream.Routines.NextPacket(Stream.Context, Packet) or (Packet.PieceCount < 1) or
       (Packet.PieceCount > MaximumPacketPieces) then
      Break;
    Slot := (Stream.Oldest + Stream.InFlight) mod PacketsInFlight;
    Stream.LastTrbs[Slot] := QueuePacket(Stream, Packet);
    Stream.Tags[Slot] := Packet.Tag;
    Inc(Stream.InFlight);
    Result := True;
  end;
end;

function IsInFlight(var Stream: TIsochronousStream; Trb: QWord): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Stream.InFlight - 1 do
    if Stream.LastTrbs[(Stream.Oldest + Index) mod PacketsInFlight] = Trb then
      Exit(True);
  Result := False;
end;

function IsochronousEventArrived(var Stream: TIsochronousStream; const Event: TTrb): Boolean;
var
  Finished: QWord;
  Tag: QWord;
begin
  { An event naming one of the packets: it and those before it are done
    (missed ones too). Others (the ring ran dry) only mean filling. }
  if IsInFlight(Stream, Event.Parameter) then
    repeat
      Finished := Stream.LastTrbs[Stream.Oldest];
      Tag := Stream.Tags[Stream.Oldest];
      Stream.Oldest := (Stream.Oldest + 1) mod PacketsInFlight;
      Dec(Stream.InFlight);
      Stream.Routines.PacketDone(Stream.Context, Tag);
    until Finished = Event.Parameter;
  Result := FillIsochronousStream(Stream);
end;

end.
