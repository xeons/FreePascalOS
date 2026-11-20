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
  Building and sending datagrams. Each datagram carries a packet for
  each packet number space with something to send, Initial first and
  the short header (1-RTT) packet last (RFC 9000 section 12.2); one
  with an Initial packet from the client, or an ack-eliciting one from
  the server, is padded to 1200 bytes (section 14.1). A packet holds, in
  this order:

    ACK                when something new was received (Initial and
                       Handshake at once, 1-RTT after two ack-eliciting
                       packets or max_ack_delay)
    CONNECTION_CLOSE   when closing (and nothing else)
    CRYPTO             lost ranges first, then new handshake bytes
    1-RTT only:        HANDSHAKE_DONE, PATH_RESPONSE, MAX_DATA,
                       MAX_STREAMS, DATA_BLOCKED, STREAMS_BLOCKED,
                       RETIRE_CONNECTION_ID, per stream RESET_STREAM,
                       STOP_SENDING, MAX_STREAM_DATA and
                       STREAM_DATA_BLOCKED, then STREAM data from the
                       streams in turn (lost ranges first)
    PING               when a probe is due and nothing else elicits an
                       acknowledgement

  Ack-eliciting packets go out only within the congestion window and
  the pacing budget (probes excepted); a server sends at most three
  times what it received until the client's address is validated.
  Everything is built in the connection's one datagram buffer and
  sealed in place: nothing is allocated per packet.
}
unit Quic.PacketSending;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Quic.ConnectionState;

{ Sends what is due now (as many datagrams as the window allows);
  NextSendTime is when pacing lets the rest go (0: nothing waits on it). }
procedure SendPendingPackets(State: PQuicConnectionState; out NextSendTime: Int64);
{ Starts a key update (the next 1-RTT packet uses new keys). }
procedure StartKeyUpdate(State: PQuicConnectionState);

implementation

uses
  SysUtils,
  Quic.Buffers,
  Quic.Congestion,
  Quic.ConnectionIds,
  Quic.Constants,
  Quic.DatagramTransports,
  Quic.Errors,
  Quic.FrameWriter,
  Quic.LossRecovery,
  Quic.PacketHeaders,
  Quic.PacketProtection,
  Quic.SendBuffers,
  Quic.SentPackets,
  Quic.Streams,
  Quic.StreamTable,
  Quic.VariableIntegers;

type
  { What one packet being built may carry. }
  TPacketPermissions = record
    { Ack-eliciting frames (window, ring and amplification allow). }
    AllowEliciting: Boolean;
    { New stream data (the pacer allows too). }
    AllowStreamData: Boolean;
    Pad: Boolean;
    Now: Int64;
  end;

procedure RecordFrame(var Packet: TQuicSentPacket; Kind: TQuicSentFrameKind; Number, Offset, Length: QWord;
  Flag: Boolean);
begin
  if Packet.FrameCount >= MaximumSentFrames then
    Exit;
  Packet.Frames[Packet.FrameCount].Kind := Kind;
  Packet.Frames[Packet.FrameCount].Number := Number;
  Packet.Frames[Packet.FrameCount].Offset := Offset;
  Packet.Frames[Packet.FrameCount].Length := LongWord(Length);
  Packet.Frames[Packet.FrameCount].Flag := Flag;
  Inc(Packet.FrameCount);
end;

function FramesFull(constref Packet: TQuicSentPacket): Boolean;
begin
  Result := Packet.FrameCount >= MaximumSentFrames;
end;

procedure StartKeyUpdate(State: PQuicConnectionState);
var
  Next: TQuicPacketKeys;
begin
  DeriveNextPhaseKeys(State^.Spaces[SpaceApplication].SendKeys, Next);
  State^.Spaces[SpaceApplication].SendKeys := Next;
  WipePacketKeys(Next);
  State^.KeyPhase := State^.KeyPhase xor 1;
  State^.KeyUpdateUnconfirmed := True;
  State^.FirstPacketOfPhase := State^.Spaces[SpaceApplication].NextPacketNumber;
  State^.PacketsInPhase := 0;
  Inc(State^.Statistics.KeyUpdates);
end;

function AckIsDue(State: PQuicConnectionState; Space: Integer; Now: Int64): Boolean;
var
  SpaceState: ^TQuicPacketSpace;
begin
  SpaceState := @State^.Spaces[Space];
  if not SpaceState^.AckPending then
    Exit(False);
  if Space <> SpaceApplication then
    Exit(True);
  Result := (SpaceState^.AckElicitingSinceAck >= 2) or ((SpaceState^.AckDeadline <> 0) and (Now >= SpaceState^.AckDeadline));
end;

function StreamFlowLimit(State: PQuicConnectionState; Stream: PQuicStream): QWord;
begin
  Result := Stream^.SendLimit;
  if Stream^.Send.SentOffset + ConnectionSendCredit(State) < Result then
    Result := Stream^.Send.SentOffset + ConnectionSendCredit(State);
end;

function StreamWantsToSend(State: PQuicConnectionState; Stream: PQuicStream): Boolean;
begin
  if not Stream^.CanSend or Stream^.ResetRequested then
    Exit(False);
  Result := Stream^.Send.HasPending(StreamFlowLimit(State, Stream));
end;

function StreamHasControlFrames(Stream: PQuicStream): Boolean;
begin
  Result := Stream^.ResetPending or Stream^.StopSendingPending or Stream^.MaxStreamDataPending or
    Stream^.StreamDataBlockedPending;
end;

{ Ack-eliciting things waiting in the Application space. }
function ApplicationHasFrames(State: PQuicConnectionState; AllowStreamData: Boolean): Boolean;
var
  Index: Integer;
begin
  if State^.HandshakeDonePending or State^.PathResponsePending or State^.MaxDataPending or
     State^.MaxStreamsBidirectionalPending or State^.MaxStreamsUnidirectionalPending or State^.DataBlockedPending or
     State^.StreamsBlockedBidirectionalPending or State^.StreamsBlockedUnidirectionalPending or
     (Length(State^.RetireQueue) > 0) then
    Exit(True);
  for Index := 0 to State^.StreamCount - 1 do
  begin
    if StreamHasControlFrames(State^.Streams[Index]) then
      Exit(True);
    if AllowStreamData and StreamWantsToSend(State, State^.Streams[Index]) then
      Exit(True);
  end;
  Result := False;
end;

function SpaceCanSend(State: PQuicConnectionState; Space: Integer): Boolean;
begin
  Result := State^.Spaces[Space].SendKeys.Ready and not State^.Spaces[Space].Discarded;
end;

{ Ack-eliciting things waiting in a space. }
function SpaceHasElicitingFrames(State: PQuicConnectionState; Space: Integer; AllowStreamData: Boolean): Boolean;
begin
  if State^.Spaces[Space].ProbesWanted > 0 then
    Exit(True);
  if State^.Spaces[Space].CryptoSend.HasPending(High(QWord)) then
    Exit(True);
  if Space = SpaceApplication then
    Exit(ApplicationHasFrames(State, AllowStreamData));
  Result := False;
end;

procedure WriteStreamControlFrames(State: PQuicConnectionState; Stream: PQuicStream; var Writer: TQuicWriter;
  var Packet: TQuicSentPacket);
var
  Saved: TQuicWriter;
begin
  if Stream^.ResetPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteResetStreamFrame(Writer, Stream^.Id, Stream^.ResetCode, StreamFinalSize(Stream));
    if Writer.Failed then
      Writer := Saved
    else
    begin
      Stream^.ResetPending := False;
      RecordFrame(Packet, SentResetStream, Stream^.Id, 0, 0, False);
    end;
  end;
  if Stream^.StopSendingPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteStopSendingFrame(Writer, Stream^.Id, Stream^.StopSendingCode);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      Stream^.StopSendingPending := False;
      RecordFrame(Packet, SentStopSending, Stream^.Id, 0, 0, False);
    end;
  end;
  if Stream^.MaxStreamDataPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteMaxStreamDataFrame(Writer, Stream^.Id, Stream^.ReceiveLimit);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      Stream^.MaxStreamDataPending := False;
      RecordFrame(Packet, SentMaxStreamData, Stream^.Id, 0, 0, False);
    end;
  end;
  if Stream^.StreamDataBlockedPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteStreamDataBlockedFrame(Writer, Stream^.Id, Stream^.SendLimit);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      Stream^.StreamDataBlockedPending := False;
      RecordFrame(Packet, SentStreamDataBlocked, Stream^.Id, 0, 0, False);
    end;
  end;
end;

procedure WriteConnectionControlFrames(State: PQuicConnectionState; var Writer: TQuicWriter;
  var Packet: TQuicSentPacket);
var
  Saved: TQuicWriter;
begin
  if State^.HandshakeDonePending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteHandshakeDoneFrame(Writer);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      State^.HandshakeDonePending := False;
      RecordFrame(Packet, SentHandshakeDone, 0, 0, 0, False);
    end;
  end;
  if State^.PathResponsePending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WritePathFrame(Writer, FramePathResponse, @State^.PathResponseData[0]);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      State^.PathResponsePending := False;
      RecordFrame(Packet, SentPing, 0, 0, 0, False);
    end;
  end;
  if State^.MaxDataPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteMaxDataFrame(Writer, State^.LocalMaxData);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      State^.MaxDataPending := False;
      RecordFrame(Packet, SentMaxData, 0, 0, 0, False);
    end;
  end;
  if State^.MaxStreamsBidirectionalPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteMaxStreamsFrame(Writer, True, State^.LocalMaxStreamsBidirectional);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      State^.MaxStreamsBidirectionalPending := False;
      RecordFrame(Packet, SentMaxStreams, 0, 0, 0, True);
    end;
  end;
  if State^.MaxStreamsUnidirectionalPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteMaxStreamsFrame(Writer, False, State^.LocalMaxStreamsUnidirectional);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      State^.MaxStreamsUnidirectionalPending := False;
      RecordFrame(Packet, SentMaxStreams, 0, 0, 0, False);
    end;
  end;
  if State^.DataBlockedPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteDataBlockedFrame(Writer, State^.PeerMaxData);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      State^.DataBlockedPending := False;
      RecordFrame(Packet, SentDataBlocked, 0, 0, 0, False);
    end;
  end;
  if State^.StreamsBlockedBidirectionalPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteStreamsBlockedFrame(Writer, True, State^.PeerMaxStreamsBidirectional);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      State^.StreamsBlockedBidirectionalPending := False;
      RecordFrame(Packet, SentStreamsBlocked, 0, 0, 0, True);
    end;
  end;
  if State^.StreamsBlockedUnidirectionalPending and not FramesFull(Packet) then
  begin
    Saved := Writer;
    WriteStreamsBlockedFrame(Writer, False, State^.PeerMaxStreamsUnidirectional);
    if Writer.Failed then
      Writer := Saved
    else
    begin
      State^.StreamsBlockedUnidirectionalPending := False;
      RecordFrame(Packet, SentStreamsBlocked, 0, 0, 0, False);
    end;
  end;
  while (Length(State^.RetireQueue) > 0) and not FramesFull(Packet) do
  begin
    Saved := Writer;
    WriteRetireConnectionIdFrame(Writer, State^.RetireQueue[0]);
    if Writer.Failed then
    begin
      Writer := Saved;
      Break;
    end;
    RecordFrame(Packet, SentRetireConnectionId, State^.RetireQueue[0], 0, 0, False);
    Delete(State^.RetireQueue, 0, 1);
  end;
end;

{ CRYPTO frames of a space while they fit. }
procedure WriteCryptoFrames(State: PQuicConnectionState; Space: Integer; var Writer: TQuicWriter;
  var Packet: TQuicSentPacket);
var
  Send: ^TQuicSendBuffer;
  Room: PtrUInt;
  Offset, Count: QWord;
  Fin: Boolean;
begin
  Send := @State^.Spaces[Space].CryptoSend;
  while Send^.HasPending(High(QWord)) and not FramesFull(Packet) do
  begin
    Room := Writer.Room;
    { Type, an offset and a length of up to four bytes each. }
    if Room <= 1 + 4 + 4 + 1 then
      Break;
    if not Send^.Next(Room - (1 + 4 + 4), High(QWord), Offset, Count, Fin) then
      Break;
    WriteCryptoFrameHeader(Writer, Offset, Count);
    Send^.Copy(Offset, Count, Writer.Position);
    Writer.Position := Writer.Position + Count;
    RecordFrame(Packet, SentCrypto, 0, Offset, Count, False);
  end;
end;

{ Data waiting on the peer's limits: STREAM_DATA_BLOCKED or
  DATA_BLOCKED, once for each limit. }
procedure NoteBlocked(State: PQuicConnectionState; Stream: PQuicStream);
begin
  if Stream^.Send.SentOffset >= Stream^.Send.WriteOffset then
    Exit;
  if (Stream^.Send.SentOffset >= Stream^.SendLimit) and (Stream^.BlockedReportedAt <> Stream^.SendLimit + 1) then
  begin
    Stream^.BlockedReportedAt := Stream^.SendLimit + 1;
    Stream^.StreamDataBlockedPending := True;
  end;
  if (ConnectionSendCredit(State) = 0) and (State^.DataBlockedReportedAt <> State^.PeerMaxData + 1) then
  begin
    State^.DataBlockedReportedAt := State^.PeerMaxData + 1;
    State^.DataBlockedPending := True;
  end;
end;

{ One STREAM frame from Stream if it has something and it fits; True
  when one was written. }
function WriteOneStreamFrame(State: PQuicConnectionState; Stream: PQuicStream; var Writer: TQuicWriter;
  var Packet: TQuicSentPacket): Boolean;
var
  Room, Overhead: PtrUInt;
  Limit, OldSent, Offset, Count: QWord;
  Fin: Boolean;
begin
  Result := False;
  if FramesFull(Packet) then
    Exit;
  Limit := StreamFlowLimit(State, Stream);
  if not Stream^.Send.HasPending(Limit) then
  begin
    NoteBlocked(State, Stream);
    Exit;
  end;
  Room := Writer.Room;
  Overhead := 1 + VariableIntegerLength(Stream^.Id) + 8 + 2;
  if Room <= Overhead then
    Exit;
  OldSent := Stream^.Send.SentOffset;
  if not Stream^.Send.Next(Room - Overhead, Limit, Offset, Count, Fin) then
    Exit;
  WriteStreamFrameHeader(Writer, Stream^.Id, Offset, Count, Fin);
  Stream^.Send.Copy(Offset, Count, Writer.Position);
  Writer.Position := Writer.Position + Count;
  State^.DataSent := State^.DataSent + (Stream^.Send.SentOffset - OldSent);
  RecordFrame(Packet, SentStream, Stream^.Id, Offset, Count, Fin);
  Result := True;
end;

procedure WriteStreamFrames(State: PQuicConnectionState; var Writer: TQuicWriter; var Packet: TQuicSentPacket);
var
  Visited, Index: Integer;
  Stream: PQuicStream;
begin
  if State^.StreamCount = 0 then
    Exit;
  Visited := 0;
  Index := State^.NextStreamToSend mod State^.StreamCount;
  while (Visited < State^.StreamCount) and (Writer.Room > 16) and not FramesFull(Packet) do
  begin
    Stream := State^.Streams[Index];
    if Stream^.CanSend and not Stream^.ResetRequested then
      { A stream may fill the packet; the next packet starts with the
        next stream. }
      while WriteOneStreamFrame(State, Stream, Writer, Packet) do
        ;
    Index := (Index + 1) mod State^.StreamCount;
    Inc(Visited);
  end;
  State^.NextStreamToSend := Index;
end;

function AckDelayField(State: PQuicConnectionState; Space: Integer; Now: Int64): QWord;
var
  Delay: Int64;
begin
  if Space <> SpaceApplication then
    Exit(0);
  Delay := Now - State^.Spaces[Space].LargestReceivedTime;
  if Delay < 0 then
    Delay := 0;
  Result := QWord(Delay * 1000) shr State^.LocalParameters.AckDelayExponent;
end;

{ The packet header; returns its length and where the packet number
  and (long headers) the length field are. }
function WriteHeader(State: PQuicConnectionState; Space: Integer; Buffer: PByte; PacketNumber: QWord;
  PacketNumberLength: Integer; out LengthOffset: Integer): Integer;
var
  Writer: TQuicWriter;
  Destination: TQuicConnectionId;
  FirstByte: Byte;
  Index: Integer;
begin
  Writer.Initialize(Buffer, 256);
  Destination := CurrentDestinationId(State);
  LengthOffset := -1;
  if Space = SpaceApplication then
  begin
    FirstByte := $40 or (State^.KeyPhase shl 2) or Byte(PacketNumberLength - 1);
    Writer.WriteByte(FirstByte);
    Writer.WriteBytes(@Destination.Bytes[0], Destination.Length);
  end
  else
  begin
    if Space = SpaceInitial then
      FirstByte := $C0 or LongHeaderTypeBits(PacketInitial)
    else
      FirstByte := $C0 or LongHeaderTypeBits(PacketHandshake);
    FirstByte := FirstByte or Byte(PacketNumberLength - 1);
    Writer.WriteByte(FirstByte);
    Writer.WriteUInt32(QuicVersion1);
    Writer.WriteByte(Destination.Length);
    Writer.WriteBytes(@Destination.Bytes[0], Destination.Length);
    Writer.WriteByte(State^.LocalId.Length);
    Writer.WriteBytes(@State^.LocalId.Bytes[0], State^.LocalId.Length);
    if Space = SpaceInitial then
    begin
      if State^.Role = RoleClient then
      begin
        Writer.WriteVariable(Length(State^.Token));
        if Length(State^.Token) > 0 then
          Writer.WriteBytes(@State^.Token[0], Length(State^.Token));
      end
      else
        Writer.WriteVariable(0);
    end;
    { The length always takes two bytes; it is filled in once known. }
    LengthOffset := Writer.Length;
    Writer.WriteUInt16(0);
  end;
  for Index := PacketNumberLength - 1 downto 0 do
    Writer.WriteByte(Byte(PacketNumber shr (8 * Index)));
  Result := Writer.Length;
end;

{ Builds one packet of Space at Buffer within Room bytes. Returns its
  length, 0 when there was nothing to put in it. }
function BuildPacket(State: PQuicConnectionState; Space: Integer; Buffer: PByte; Room: Integer;
  constref Permissions: TPacketPermissions): Integer;
var
  SpaceState: ^TQuicPacketSpace;
  PacketNumber: QWord;
  NumberLength, HeaderLength, LengthOffset, PayloadLength, Index: Integer;
  Writer: TQuicWriter;
  Packet: TQuicSentPacket;
  Stored: PQuicSentPacket;
  Mask: TQuicHeaderMask;
  AckEliciting, Wrote: Boolean;
  Saved: TQuicWriter;
begin
  Result := 0;
  SpaceState := @State^.Spaces[Space];
  PacketNumber := SpaceState^.NextPacketNumber;
  NumberLength := PacketNumberLength(PacketNumber, SpaceState^.LargestAcknowledged);
  HeaderLength := WriteHeader(State, Space, Buffer, PacketNumber, NumberLength, LengthOffset);
  if Room - HeaderLength - PacketTagLength < 8 then
    Exit;
  Writer.Initialize(Buffer + HeaderLength, Room - HeaderLength - PacketTagLength);
  Packet.FrameCount := 0;
  Wrote := False;

  if SpaceState^.AckPending and (SpaceState^.Received.Count > 0) then
  begin
    Saved := Writer;
    WriteAckFrame(Writer, SpaceState^.Received, AckDelayField(State, Space, Permissions.Now));
    if Writer.Failed then
      Writer := Saved
    else
    begin
      SpaceState^.AckPending := False;
      SpaceState^.AckElicitingSinceAck := 0;
      SpaceState^.AckDeadline := 0;
      RecordFrame(Packet, SentAck, QWord(SpaceState^.LargestReceived), 0, 0, False);
      Wrote := True;
    end;
  end;

  if State^.ClosePending then
  begin
    { An application's close is a transport APPLICATION_ERROR before
      1-RTT keys (RFC 9000 section 10.2.3), without the reason. }
    if State^.CloseIsApplication and (Space <> SpaceApplication) then
      WriteConnectionCloseFrame(Writer, False, TransportApplicationError, 0, '')
    else
      WriteConnectionCloseFrame(Writer, State^.CloseIsApplication, State^.CloseCode, State^.CloseFrameType,
        State^.CloseReason);
    Wrote := Wrote or not Writer.Failed;
  end
  else if Permissions.AllowEliciting and (State^.Phase in [PhaseHandshaking, PhaseEstablished]) then
  begin
    WriteCryptoFrames(State, Space, Writer, Packet);
    if Space = SpaceApplication then
    begin
      WriteConnectionControlFrames(State, Writer, Packet);
      for Index := 0 to State^.StreamCount - 1 do
        if StreamHasControlFrames(State^.Streams[Index]) then
          WriteStreamControlFrames(State, State^.Streams[Index], Writer, Packet);
      if Permissions.AllowStreamData then
        WriteStreamFrames(State, Writer, Packet);
    end;
  end;

  AckEliciting := False;
  for Index := 0 to Packet.FrameCount - 1 do
    if Packet.Frames[Index].Kind <> SentAck then
      AckEliciting := True;
  if not AckEliciting and Permissions.AllowEliciting and (SpaceState^.ProbesWanted > 0) and
     not State^.ClosePending then
  begin
    WritePingFrame(Writer);
    RecordFrame(Packet, SentPing, 0, 0, 0, False);
    AckEliciting := True;
  end;
  if AckEliciting and (SpaceState^.ProbesWanted > 0) then
    Dec(SpaceState^.ProbesWanted);
  Wrote := Wrote or AckEliciting;
  if not Wrote and not Permissions.Pad then
    Exit;

  { Room for the header protection sample, and the padding asked for. }
  PayloadLength := Writer.Length;
  if PayloadLength < 4 - NumberLength then
    Writer.WriteZeros(4 - NumberLength - PayloadLength);
  if Permissions.Pad then
    Writer.WriteZeros(Writer.Room);
  PayloadLength := Writer.Length;
  if LengthOffset >= 0 then
    EncodeVariableIntegerAs(NumberLength + PayloadLength + PacketTagLength, 2, Buffer + LengthOffset);

  SealPayload(SpaceState^.SendKeys, PacketNumber, Buffer, HeaderLength, Buffer + HeaderLength, PayloadLength);
  ComputeHeaderMask(SpaceState^.SendKeys, Buffer + HeaderLength - NumberLength + 4, Mask);
  ApplyHeaderMask(Buffer, HeaderLength - NumberLength, NumberLength, Mask);
  Result := HeaderLength + PayloadLength + PacketTagLength;

  Inc(SpaceState^.NextPacketNumber);
  Inc(State^.Statistics.PacketsSent);
  if Space = SpaceApplication then
    Inc(State^.PacketsInPhase);
  if AckEliciting then
  begin
    Stored := SpaceState^.Sent.Add;
    if Stored <> nil then
    begin
      Packet.InUse := True;
      Packet.PacketNumber := PacketNumber;
      Packet.TimeSent := Permissions.Now;
      Packet.Size := Result;
      Packet.AckEliciting := True;
      Packet.InFlight := True;
      Packet.IsPathMtuProbe := False;
      Stored^ := Packet;
      OnPacketSent(State, Space, Stored);
    end;
    if not State^.AckElicitingSentSinceReceive then
    begin
      State^.AckElicitingSentSinceReceive := True;
      State^.LastActivityTime := Permissions.Now;
    end;
  end;
end;

{ A 1-RTT packet of PING and PADDING as big as the largest datagram
  tried (RFC 9000 section 14.3): if it is acknowledged, the path takes
  it. }
function BuildPathMtuProbe(State: PQuicConnectionState; Buffer: PByte; Size: Integer; Now: Int64): Integer;
var
  SpaceState: ^TQuicPacketSpace;
  PacketNumber: QWord;
  NumberLength, HeaderLength, LengthOffset, PayloadLength: Integer;
  Mask: TQuicHeaderMask;
  Stored: PQuicSentPacket;
begin
  Result := 0;
  SpaceState := @State^.Spaces[SpaceApplication];
  if SpaceState^.Sent.IsFull then
    Exit;
  PacketNumber := SpaceState^.NextPacketNumber;
  NumberLength := PacketNumberLength(PacketNumber, SpaceState^.LargestAcknowledged);
  HeaderLength := WriteHeader(State, SpaceApplication, Buffer, PacketNumber, NumberLength, LengthOffset);
  PayloadLength := Size - HeaderLength - PacketTagLength;
  Buffer[HeaderLength] := FramePing;
  FillChar(Buffer[HeaderLength + 1], PayloadLength - 1, 0);
  SealPayload(SpaceState^.SendKeys, PacketNumber, Buffer, HeaderLength, Buffer + HeaderLength, PayloadLength);
  ComputeHeaderMask(SpaceState^.SendKeys, Buffer + HeaderLength - NumberLength + 4, Mask);
  ApplyHeaderMask(Buffer, HeaderLength - NumberLength, NumberLength, Mask);
  Inc(SpaceState^.NextPacketNumber);
  Inc(State^.Statistics.PacketsSent);
  Stored := SpaceState^.Sent.Add;
  Stored^.PacketNumber := PacketNumber;
  Stored^.TimeSent := Now;
  Stored^.Size := Size;
  Stored^.AckEliciting := True;
  Stored^.InFlight := False;
  Stored^.IsPathMtuProbe := True;
  OnPacketSent(State, SpaceApplication, Stored);
  State^.PathMtu := PathMtuProbing;
  Result := Size;
end;

function PathMtuProbeIsDue(State: PQuicConnectionState): Boolean;
begin
  Result := State^.Options.ProbePathMtu and State^.HandshakeConfirmed and (State^.PathMtu = PathMtuIdle) and
    (State^.MaximumDatagramSize < MaximumDatagramSize) and (State^.Phase = PhaseEstablished) and
    (State^.PeerParameters.MaxUdpPayloadSize >= MaximumDatagramSize);
end;

{ Builds the next datagram into the send buffer: its length, or 0. }
function BuildDatagram(State: PQuicConnectionState; Now: Int64; out NextSendTime: Int64): Integer;
var
  Room, Used, Built, Space, LastSpace: Integer;
  Permissions, SpacePermissions: TPacketPermissions;
  Wanted: array[0..SpaceCount - 1] of Boolean;
  Probing, AnyEliciting, IncludesInitial: Boolean;
  Allowance: QWord;
  PacingWait: Int64;
begin
  Result := 0;
  NextSendTime := 0;
  Room := State^.MaximumDatagramSize;
  { A server's amplification limit. }
  if (State^.Role = RoleServer) and not State^.AddressValidated then
  begin
    Allowance := 3 * State^.BytesReceivedOnPath;
    if Allowance <= State^.BytesSentOnPath then
      Exit;
    if Allowance - State^.BytesSentOnPath < QWord(Room) then
      Room := Allowance - State^.BytesSentOnPath;
    if Room < MinimumDatagramSize div 4 then
      Exit;
  end;

  Probing := False;
  for Space := 0 to SpaceCount - 1 do
    if SpaceCanSend(State, Space) and (State^.Spaces[Space].ProbesWanted > 0) then
      Probing := True;
  Permissions.Now := Now;
  Permissions.AllowEliciting := Probing or CongestionAllows(State^.Congestion, Room);
  Permissions.AllowStreamData := Permissions.AllowEliciting;
  if Permissions.AllowEliciting and not Probing and State^.HandshakeComplete then
    if not PacingAllows(State^.Congestion, State^.Rtt, Room, Now, PacingWait) then
    begin
      Permissions.AllowStreamData := False;
      if ApplicationHasFrames(State, True) then
        NextSendTime := Now + PacingWait;
    end;
  if State^.ClosePending then
    Permissions.AllowEliciting := False;

  LastSpace := -1;
  AnyEliciting := False;
  for Space := 0 to SpaceCount - 1 do
  begin
    Wanted[Space] := False;
    if not SpaceCanSend(State, Space) then
      Continue;
    if State^.Spaces[Space].Sent.IsFull and not State^.ClosePending then
      Wanted[Space] := AckIsDue(State, Space, Now)
    else
    begin
      Wanted[Space] := AckIsDue(State, Space, Now) or State^.ClosePending or
        (Permissions.AllowEliciting and SpaceHasElicitingFrames(State, Space, Permissions.AllowStreamData));
      if Permissions.AllowEliciting and SpaceHasElicitingFrames(State, Space, Permissions.AllowStreamData) then
        AnyEliciting := True;
    end;
    { While closing, the close goes in every space there are keys for
      (the peer may not have the newest ones yet). }
    if Wanted[Space] then
      LastSpace := Space;
  end;
  if LastSpace < 0 then
  begin
    if PathMtuProbeIsDue(State) and CongestionAllows(State^.Congestion, 0) then
    begin
      Result := BuildPathMtuProbe(State, @State^.SendBuffer[0], MaximumDatagramSize, Now);
      Exit;
    end;
    Exit;
  end;
  IncludesInitial := Wanted[SpaceInitial] and ((State^.Role = RoleClient) or AnyEliciting);

  Used := 0;
  for Space := 0 to SpaceCount - 1 do
  begin
    if not Wanted[Space] then
      Continue;
    SpacePermissions := Permissions;
    SpacePermissions.Pad := IncludesInitial and (Space = LastSpace);
    { What goes in a full ring could not be sent again if lost. }
    if State^.Spaces[Space].Sent.IsFull then
      SpacePermissions.AllowEliciting := False;
    Built := BuildPacket(State, Space, @State^.SendBuffer[Used], Room - Used, SpacePermissions);
    Used := Used + Built;
    if (Built > 0) and (Space = SpaceHandshake) and (State^.Role = RoleClient) and
       not State^.Spaces[SpaceInitial].Discarded then
      { A client is done with Initial keys once it sends a Handshake
        packet (RFC 9001 section 4.9.1). }
      DiscardSpace(State, SpaceInitial);
    if Room - Used < 64 then
      Break;
  end;
  Result := Used;
end;

procedure SendPendingPackets(State: PQuicConnectionState; out NextSendTime: Int64);
var
  Length, Count: Integer;
  Error: LongInt;
  Now: Int64;
begin
  NextSendTime := 0;
  if State^.Phase in [PhaseDraining, PhaseClosed] then
    Exit;
  Now := QuicMilliseconds;
  if (State^.Phase = PhaseEstablished) and State^.HandshakeConfirmed and not State^.KeyUpdateUnconfirmed and
     (State^.KeyUpdateRequested or ((State^.Options.KeyUpdateInterval > 0) and
     (State^.PacketsInPhase >= State^.Options.KeyUpdateInterval))) then
  begin
    State^.KeyUpdateRequested := False;
    StartKeyUpdate(State);
  end;
  Count := 0;
  while Count < 64 do
  begin
    Length := BuildDatagram(State, Now, NextSendTime);
    if Length = 0 then
      Break;
    Error := State^.Transport.Send(State^.Transport.Context, @State^.SendBuffer[0], Length);
    if Error <> QuicErrorNone then
    begin
      FailSilently(State, QuicErrorTransportFailed, 'sending a datagram failed');
      Exit;
    end;
    State^.BytesSentOnPath := State^.BytesSentOnPath + QWord(Length);
    State^.Statistics.BytesSent := State^.Statistics.BytesSent + QWord(Length);
    if State^.HandshakeComplete then
      OnPacketPaced(State^.Congestion, Length);
    Inc(Count);
    if State^.ClosePending then
    begin
      { One CONNECTION_CLOSE; more only in answer to the peer. }
      State^.ClosePending := False;
      Break;
    end;
  end;
end;

end.
