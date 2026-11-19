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
  TCP segments: reading an arriving segment's header (with its checksum
  over the pseudo-header, and its options), and building the ones a
  connection sends - with the acknowledgment and the window it
  advertises filled in, and resets for segments that belong to no
  connection (RFC 793, "Reset Generation").

  Options sent (Network.TcpOptions): on a SYN the MSS, and SACK
  permitted, timestamps and the window scale as far as the connection
  offers or agreed them; on every other segment but a reset the
  timestamps if agreed, and on an acknowledgment the SACK blocks of
  what waits out of order (as many as fit beside the data: data and
  options together never exceed the MSS, RFC 6691).

  Windows: the field of a SYN is never scaled; on other segments ours
  is in units of 2^ReceiveWindowShift and never takes back what an
  earlier advertisement promised (RFC 7323 2.4), and the peer's is
  shifted by SendWindowShift. Timestamps count milliseconds.
}
unit Network.TcpSegments;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.Interfaces,
  Network.Ipv4,
  Network.TcpTypes,
  Network.TcpOptions,
  Network.IpDatagrams;

type
  TTcpSegment = record
    SourcePort: Word;
    DestinationPort: Word;
    Sequence: LongWord;
    Acknowledgment: LongWord;
    Flags: Byte;
    { The window field as it came (see SegmentWindow). }
    Window: Word;
    Options: TTcpOptions;
    Data: PByte;
    DataLength: LongWord;
  end;

{ False for a segment too short or with a wrong checksum. }
function ParseTcpSegment(constref Datagram: TIpDatagram; Payload: PByte; Length: LongWord;
  out Segment: TTcpSegment): Boolean;
{ The sequence space a segment takes: its data, and one each for SYN and
  FIN. }
function SegmentSequenceLength(constref Segment: TTcpSegment): LongWord;
{ The peer's window a segment gives, in bytes. }
function SegmentWindow(Connection: PTcpConnection; constref Segment: TTcpSegment): LongWord;
{ The room in the receive buffer (at most the largest window the
  connection can advertise). }
function ReceiveBufferRoom(Connection: PTcpConnection): LongWord;
{ The window segments are checked against: the room, or what the last
  advertisement promised if that reaches further. }
function ReceiveWindow(Connection: PTcpConnection): LongWord;
{ The most data a segment we send carries: the MSS less the options
  every segment has (the timestamps). }
function SenderSegmentSize(Connection: PTcpConnection): LongWord;
{ Our timestamp clock (milliseconds). }
function TimestampNow: LongWord;
{ The MSS we advertise: what the route's MTU leaves for data. }
function OwnMaximumSegment(constref Remote: TNetworkEndpoint; BoundInterface: PNetworkInterface): LongWord;
{ Sends a segment of Connection: Flags (ACK added in every state but
  SYN_SENT), Sequence, and DataLength bytes of the send buffer from
  DataOffset. Clears a pending ACK. }
function SendConnectionSegment(Connection: PTcpConnection; Sequence: LongWord; Flags: Byte;
  DataOffset, DataLength: LongWord): LongInt;
{ Answers a segment that belongs to no connection with a reset (unless
  it is a reset itself). }
procedure SendResetFor(constref Datagram: TIpDatagram; constref Segment: TTcpSegment);

implementation

uses
  Runtime.Memory,
  Network.Core,
  Network.TcpWindows,
  Network.ByteOrder,
  Network.Checksums,
  Network.Packets,
  Network.ByteRings,
  Network.IpOutput,
  Network.Statistics;

function ParseTcpSegment(constref Datagram: TIpDatagram; Payload: PByte; Length: LongWord;
  out Segment: TTcpSegment): Boolean;
var
  HeaderLength: LongWord;
  Sum: LongWord;
begin
  FillMemory(@Segment, SizeOf(Segment), 0);
  if Length < TcpHeaderBytes then
    Exit(False);
  HeaderLength := LongWord(Payload[12] shr 4) * 4;
  if (HeaderLength < TcpHeaderBytes) or (HeaderLength > Length) then
    Exit(False);
  Sum := DatagramPseudoHeaderSum(Datagram, IpProtocolTcp, Length);
  if FinishChecksum(AddToChecksum(Sum, Payload, Length)) <> 0 then
    Exit(False);
  Segment.SourcePort := ReadBigEndian16(Payload);
  Segment.DestinationPort := ReadBigEndian16(Payload + 2);
  Segment.Sequence := ReadBigEndian32(Payload + 4);
  Segment.Acknowledgment := ReadBigEndian32(Payload + 8);
  Segment.Flags := Payload[13] and $3F;
  Segment.Window := ReadBigEndian16(Payload + 14);
  ParseTcpOptions(Payload + TcpHeaderBytes, HeaderLength - TcpHeaderBytes, Segment.Options);
  Segment.Data := Payload + HeaderLength;
  Segment.DataLength := Length - HeaderLength;
  Result := True;
end;

function SegmentSequenceLength(constref Segment: TTcpSegment): LongWord;
begin
  Result := Segment.DataLength;
  if (Segment.Flags and TcpFlagSyn) <> 0 then
    Inc(Result);
  if (Segment.Flags and TcpFlagFin) <> 0 then
    Inc(Result);
end;

function SegmentWindow(Connection: PTcpConnection; constref Segment: TTcpSegment): LongWord;
begin
  if (Segment.Flags and TcpFlagSyn) <> 0 then
    Result := Segment.Window
  else
    Result := WindowFromField(Segment.Window, Connection^.SendWindowShift);
end;

function ReceiveBufferRoom(Connection: PTcpConnection): LongWord;
var
  Limit: LongWord;
begin
  if Connection^.ReceiveBuffer.Data = nil then
    Exit(0);
  Result := ByteRingFreeSpace(Connection^.ReceiveBuffer);
  Limit := LargestWindow(Connection^.ReceiveWindowShift);
  if Result > Limit then
    Result := Limit;
end;

function PromisedWindow(Connection: PTcpConnection): LongWord;
begin
  if SequenceAfter(Connection^.AdvertisedEdge, Connection^.ReceiveNext) then
    Result := Connection^.AdvertisedEdge - Connection^.ReceiveNext
  else
    Result := 0;
end;

function ReceiveWindow(Connection: PTcpConnection): LongWord;
begin
  Result := ReceiveBufferRoom(Connection);
  if PromisedWindow(Connection) > Result then
    Result := PromisedWindow(Connection);
end;

function SenderSegmentSize(Connection: PTcpConnection): LongWord;
begin
  Result := Connection^.MaximumSegment;
  if Connection^.Timestamps and (Result > 2 * TimestampOptionBytes) then
    Result := Result - TimestampOptionBytes;
end;

function TimestampNow: LongWord;
begin
  Result := LongWord(NetworkNow div NanosecondsPerMillisecond);
end;

function OwnMaximumSegment(constref Remote: TNetworkEndpoint; BoundInterface: PNetworkInterface): LongWord;
var
  Limit: LongWord;
begin
  Limit := IpPayloadLimit(Remote, BoundInterface);
  if Limit <= TcpHeaderBytes + DefaultPeerMss then
    Exit(DefaultPeerMss);
  Result := Limit - TcpHeaderBytes;
end;

procedure WriteHeader(Header: PByte; SourcePort, DestinationPort: Word; Sequence, Acknowledgment: LongWord;
  HeaderLength: LongWord; Flags: Byte; Window: Word);
begin
  WriteBigEndian16(Header, SourcePort);
  WriteBigEndian16(Header + 2, DestinationPort);
  WriteBigEndian32(Header + 4, Sequence);
  WriteBigEndian32(Header + 8, Acknowledgment);
  Header[12] := Byte((HeaderLength div 4) shl 4);
  Header[13] := Flags;
  WriteBigEndian16(Header + 14, Window);
  WriteBigEndian16(Header + 16, 0);
  WriteBigEndian16(Header + 18, 0);
end;

procedure WriteChecksum(Segment: PByte; Length: LongWord; constref Source, Destination: TNetworkEndpoint);
var
  Sum: LongWord;
begin
  Sum := TransportPseudoHeaderSum(Source, Destination, IpProtocolTcp, Length);
  WriteBigEndian16(Segment + 16, FinishChecksum(AddToChecksum(Sum, Segment, Length)));
end;

{ Counts a segment sent: a retransmission carries data, a SYN or a FIN
  from before the furthest sequence number sent. }
procedure CountSegmentSent(Connection: PTcpConnection; Sequence: LongWord; Flags: Byte; DataLength: LongWord);
var
  TakesSequence: Boolean;
begin
  if (Flags and TcpFlagReset) <> 0 then
    Inc(NetworkStatistics.Tcp.ResetsSent);
  TakesSequence := (DataLength > 0) or ((Flags and (TcpFlagSyn or TcpFlagFin)) <> 0);
  if TakesSequence and (Connection <> nil) and SequenceBefore(Sequence, Connection^.SendMaximum) then
  begin
    Inc(NetworkStatistics.Tcp.SegmentsRetransmitted);
    Inc(Connection^.RetransmittedSegments);
  end
  else
    Inc(NetworkStatistics.Tcp.SegmentsSent);
end;

{ The options a segment of Connection carries. }
procedure ChooseOptions(Connection: PTcpConnection; Flags: Byte; DataLength: LongWord; out Options: TTcpOptions);
var
  Room: LongWord;
  Count: LongWord;
  Index: LongWord;
begin
  ClearTcpOptions(Options);
  if (Flags and TcpFlagReset) <> 0 then
    Exit;
  if (Flags and TcpFlagSyn) <> 0 then
  begin
    Options.HasMaximumSegment := True;
    Options.MaximumSegment := Word(OwnMaximumSegment(Connection^.Remote, Connection^.BoundInterface));
    Options.SackPermitted := Connection^.SackPermitted;
    Options.HasWindowScale := Connection^.WindowScaling;
    Options.WindowShift := OwnWindowShift;
  end;
  if Connection^.Timestamps then
  begin
    Options.HasTimestamps := True;
    Options.TimestampValue := TimestampNow;
    if (Flags and TcpFlagAck) <> 0 then
      Options.TimestampEcho := Connection^.TimestampRecent;
  end;
  if ((Flags and (TcpFlagSyn or TcpFlagAck)) <> TcpFlagAck) or not Connection^.SackPermitted or
     (Connection^.ReceivedBlocks.Count = 0) then
    Exit;
  Room := MaximumTcpOptionBytes;
  if DataLength > 0 then
  begin
    if Connection^.MaximumSegment > DataLength then
      Room := Connection^.MaximumSegment - DataLength
    else
      Room := 0;
  end;
  Count := SackBlocksThatFit(Options, Room);
  if Count > Connection^.ReceivedBlocks.Count then
    Count := Connection^.ReceivedBlocks.Count;
  Index := 0;
  while Index < Count do
  begin
    Options.SackBlocks[Index] := Connection^.ReceivedBlocks.Blocks[Index];
    Inc(Index);
  end;
  Options.SackBlockCount := Count;
end;

{ The window field to send, and the window (in bytes) it gives. }
function ChooseWindowField(Connection: PTcpConnection; Flags: Byte; out Window: LongWord): Word;
var
  Room: LongWord;
begin
  Room := ReceiveBufferRoom(Connection);
  if (Flags and TcpFlagSyn) <> 0 then
  begin
    if Room > UnscaledWindowLimit then
      Room := UnscaledWindowLimit;
    Result := Word(Room);
    Window := Room;
    Exit;
  end;
  Result := ScaledWindowField(Room, PromisedWindow(Connection), Connection^.ReceiveWindowShift);
  Window := WindowFromField(Result, Connection^.ReceiveWindowShift);
end;

function SendConnectionSegment(Connection: PTcpConnection; Sequence: LongWord; Flags: Byte;
  DataOffset, DataLength: LongWord): LongInt;
var
  Packet: PPacket;
  Header: PByte;
  HeaderLength: LongWord;
  Options: TTcpOptions;
  IsSyn: Boolean;
  WindowField: Word;
  Window: LongWord;
  Acknowledgment: LongWord;
begin
  if Connection^.State <> TcpSynSent then
    Flags := Flags or TcpFlagAck;
  IsSyn := (Flags and TcpFlagSyn) <> 0;
  ChooseOptions(Connection, Flags, DataLength, Options);
  HeaderLength := TcpHeaderBytes + TcpOptionsLength(Options, IsSyn);
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit(-1);
  Header := AppendToPacket(Packet, HeaderLength + DataLength);
  if Header = nil then
  begin
    FreePacket(Packet);
    Exit(-1);
  end;
  WindowField := ChooseWindowField(Connection, Flags, Window);
  Acknowledgment := 0;
  if (Flags and TcpFlagAck) <> 0 then
    Acknowledgment := Connection^.ReceiveNext;
  WriteHeader(Header, Connection^.Local.Port, Connection^.Remote.Port, Sequence, Acknowledgment,
    HeaderLength, Flags, WindowField);
  WriteTcpOptions(Header + TcpHeaderBytes, Options, IsSyn);
  if DataLength > 0 then
    CopyFromByteRing(Connection^.SendBuffer, DataOffset, Header + HeaderLength, DataLength);
  WriteChecksum(Header, HeaderLength + DataLength, Connection^.Local, Connection^.Remote);
  if (Flags and TcpFlagAck) <> 0 then
  begin
    Connection^.AdvertisedEdge := Connection^.ReceiveNext + Window;
    Connection^.LastAckSent := Connection^.ReceiveNext;
    Connection^.AckPending := False;
    Connection^.AckDeadline := 0;
    Connection^.SegmentsSinceAck := 0;
  end;
  CountSegmentSent(Connection, Sequence, Flags, DataLength);
  Result := SendIpPacket(Packet, Connection^.Local, Connection^.Remote, IpProtocolTcp,
    Connection^.TimeToLive, True, Connection^.BoundInterface);
end;

procedure SendBareSegment(constref Source, Destination: TNetworkEndpoint; Sequence, Acknowledgment: LongWord;
  Flags: Byte);
var
  Packet: PPacket;
  Header: PByte;
begin
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Header := AppendToPacket(Packet, TcpHeaderBytes);
  WriteHeader(Header, Source.Port, Destination.Port, Sequence, Acknowledgment, TcpHeaderBytes, Flags, 0);
  WriteChecksum(Header, TcpHeaderBytes, Source, Destination);
  CountSegmentSent(nil, Sequence, Flags, 0);
  SendIpPacket(Packet, Source, Destination, IpProtocolTcp, DefaultTimeToLive, True, nil);
end;

procedure SendResetFor(constref Datagram: TIpDatagram; constref Segment: TTcpSegment);
var
  Local: TNetworkEndpoint;
  Remote: TNetworkEndpoint;
begin
  if ((Segment.Flags and TcpFlagReset) <> 0) or Datagram.IsBroadcast then
    Exit;
  Local := DatagramDestination(Datagram, Segment.DestinationPort);
  Remote := DatagramSource(Datagram, Segment.SourcePort);
  if (Segment.Flags and TcpFlagAck) <> 0 then
    SendBareSegment(Local, Remote, Segment.Acknowledgment, 0, TcpFlagReset)
  else
    SendBareSegment(Local, Remote, 0, Segment.Sequence + SegmentSequenceLength(Segment), TcpFlagReset or TcpFlagAck);
end;

end.
