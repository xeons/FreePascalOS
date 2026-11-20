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
  What was sent in each ack-eliciting packet, for loss recovery (RFC
  9002 appendix A.1): its number, time and size, and a record of each
  frame that has to be sent again (or whose acknowledgement means
  something) if the packet is lost. Frames are not copied: a STREAM or
  CRYPTO frame is its range, and the data stays in the send buffer;
  control frames are sent again with the values current then.

  Each packet number space keeps its packets in a ring of fixed size,
  in the order sent (so by packet number); a full ring holds back new
  ack-eliciting packets until acknowledgements free entries. Packets
  that carry nothing but ACK and PADDING are not kept.
}
unit Quic.SentPackets;

{$mode objfpc}
{$modeswitch advancedrecords}
{$packenum 1}

interface

const
  MaximumSentFrames = 10;
  { Ack-eliciting packets in flight at most: in the Application space,
    and in each of Initial and Handshake. }
  ApplicationRingSize = 384;
  HandshakeRingSize = 32;

type
  TQuicSentFrameKind = (SentStream, SentCrypto, SentAck, SentMaxData, SentMaxStreamData, SentMaxStreams,
    SentResetStream, SentStopSending, SentHandshakeDone, SentNewConnectionId, SentRetireConnectionId,
    SentDataBlocked, SentStreamDataBlocked, SentStreamsBlocked, SentPing, SentNewToken);

  TQuicSentFrame = record
    Kind: TQuicSentFrameKind;
    { FIN of a STREAM frame; bidirectional for MAX_STREAMS and
      STREAMS_BLOCKED. }
    Flag: Boolean;
    Length: LongWord;
    { A stream ID, a sequence number, or the largest acknowledged of an
      ACK. }
    Number: QWord;
    Offset: QWord;
  end;

  TQuicSentPacket = record
    InUse: Boolean;
    PacketNumber: QWord;
    TimeSent: Int64;
    Size: Integer;
    AckEliciting: Boolean;
    InFlight: Boolean;
    IsPathMtuProbe: Boolean;
    FrameCount: Integer;
    Frames: array[0..MaximumSentFrames - 1] of TQuicSentFrame;
  end;
  PQuicSentPacket = ^TQuicSentPacket;

  TQuicSentPacketRing = record
    Packets: array of TQuicSentPacket;
    { The oldest entry and how many entries from it are used or
      holes. }
    Head: Integer;
    Span: Integer;
    procedure Initialize(Size: Integer);
    procedure Release;
    function IsFull: Boolean;
    { A new entry at the end, zeroed and in use; nil when full. }
    function Add: PQuicSentPacket;
    { The Index-th entry from the oldest (0 <= Index < Span), which may
      be a hole (InUse False). }
    function At(Index: Integer): PQuicSentPacket;
    { Marks an entry free and drops holes from the front. }
    procedure Remove(Packet: PQuicSentPacket);
    { Marks an entry free only (entries keep their places while a loop
      goes over them); Compact drops the holes from the front after. }
    procedure MarkFree(Packet: PQuicSentPacket);
    procedure Compact;
    procedure Clear;
    function IsEmpty: Boolean;
  end;

implementation

procedure TQuicSentPacketRing.Initialize(Size: Integer);
begin
  Packets := nil;
  SetLength(Packets, Size);
  Head := 0;
  Span := 0;
end;

procedure TQuicSentPacketRing.Release;
begin
  Packets := nil;
  Head := 0;
  Span := 0;
end;

function TQuicSentPacketRing.IsFull: Boolean;
begin
  Result := Span >= Length(Packets);
end;

function TQuicSentPacketRing.Add: PQuicSentPacket;
begin
  if IsFull then
    Exit(nil);
  Result := @Packets[(Head + Span) mod Length(Packets)];
  Result^.InUse := True;
  Result^.FrameCount := 0;
  Result^.IsPathMtuProbe := False;
  Result^.AckEliciting := False;
  Result^.InFlight := False;
  Inc(Span);
end;

function TQuicSentPacketRing.At(Index: Integer): PQuicSentPacket;
begin
  Result := @Packets[(Head + Index) mod Length(Packets)];
end;

procedure TQuicSentPacketRing.MarkFree(Packet: PQuicSentPacket);
begin
  Packet^.InUse := False;
end;

procedure TQuicSentPacketRing.Remove(Packet: PQuicSentPacket);
begin
  Packet^.InUse := False;
  Compact;
end;

procedure TQuicSentPacketRing.Compact;
begin
  while (Span > 0) and not Packets[Head].InUse do
  begin
    Head := (Head + 1) mod Length(Packets);
    Dec(Span);
  end;
end;

procedure TQuicSentPacketRing.Clear;
var
  Index: Integer;
begin
  for Index := 0 to Length(Packets) - 1 do
    Packets[Index].InUse := False;
  Head := 0;
  Span := 0;
end;

function TQuicSentPacketRing.IsEmpty: Boolean;
begin
  Result := Span = 0;
end;

end.
