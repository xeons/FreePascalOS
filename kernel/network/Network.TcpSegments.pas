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
  over the pseudo-header, and the MSS option), and building the ones a
  connection sends - with the acknowledgment and the window it
  advertises filled in, and the MSS option on a SYN - and resets for
  segments that belong to no connection (RFC 793, "Reset Generation").
}
unit Network.TcpSegments;

{$mode objfpc}
{$pointermath on}

interface

uses
  Network.Addresses,
  Network.Interfaces,
  Network.Ipv4,
  Network.TcpTypes;

type
  TTcpSegment = record
    SourcePort: Word;
    DestinationPort: Word;
    Sequence: LongWord;
    Acknowledgment: LongWord;
    Flags: Byte;
    Window: Word;
    { The MSS option; 0 if there was none. }
    PeerMss: Word;
    Data: PByte;
    DataLength: LongWord;
  end;

{ False for a segment too short or with a wrong checksum. }
function ParseTcpSegment(constref Datagram: TIpv4Datagram; Payload: PByte; Length: LongWord;
  out Segment: TTcpSegment): Boolean;
{ The sequence space a segment takes: its data, and one each for SYN and
  FIN. }
function SegmentSequenceLength(constref Segment: TTcpSegment): LongWord;
{ The window we can advertise: the room in the receive buffer. }
function ReceiveWindow(Connection: PTcpConnection): LongWord;
{ The MSS we advertise: what the route's MTU leaves for data. }
function OwnMaximumSegment(Remote: TIpv4Address; BoundInterface: PNetworkInterface): LongWord;
{ Sends a segment of Connection: Flags (ACK added in every state but
  SYN_SENT), Sequence, and DataLength bytes of the send buffer from
  DataOffset. Clears a pending ACK. }
function SendConnectionSegment(Connection: PTcpConnection; Sequence: LongWord; Flags: Byte;
  DataOffset, DataLength: LongWord): LongInt;
{ Answers a segment that belongs to no connection with a reset (unless
  it is a reset itself). }
procedure SendResetFor(constref Datagram: TIpv4Datagram; constref Segment: TTcpSegment);

implementation

uses
  Runtime.Memory,
  Network.ByteOrder,
  Network.Checksums,
  Network.Packets,
  Network.ByteRings;

const
  OptionEnd = 0;
  OptionNoOperation = 1;
  OptionMaximumSegment = 2;

procedure ReadOptions(Options: PByte; Length: LongWord; var Segment: TTcpSegment);
var
  Position: LongWord;
  OptionLength: LongWord;
begin
  Position := 0;
  while Position < Length do
  begin
    case Options[Position] of
      OptionEnd: Exit;
      OptionNoOperation: Inc(Position);
    else
      if Position + 1 >= Length then
        Exit;
      OptionLength := Options[Position + 1];
      if (OptionLength < 2) or (Position + OptionLength > Length) then
        Exit;
      if (Options[Position] = OptionMaximumSegment) and (OptionLength = 4) then
        Segment.PeerMss := ReadBigEndian16(Options + Position + 2);
      Position := Position + OptionLength;
    end;
  end;
end;

function ParseTcpSegment(constref Datagram: TIpv4Datagram; Payload: PByte; Length: LongWord;
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
  Sum := PseudoHeaderSum(Datagram.Source, Datagram.Destination, IpProtocolTcp, Length);
  if FinishChecksum(AddToChecksum(Sum, Payload, Length)) <> 0 then
    Exit(False);
  Segment.SourcePort := ReadBigEndian16(Payload);
  Segment.DestinationPort := ReadBigEndian16(Payload + 2);
  Segment.Sequence := ReadBigEndian32(Payload + 4);
  Segment.Acknowledgment := ReadBigEndian32(Payload + 8);
  Segment.Flags := Payload[13] and $3F;
  Segment.Window := ReadBigEndian16(Payload + 14);
  ReadOptions(Payload + TcpHeaderBytes, HeaderLength - TcpHeaderBytes, Segment);
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

function ReceiveWindow(Connection: PTcpConnection): LongWord;
begin
  if Connection^.ReceiveBuffer.Data = nil then
    Exit(0);
  Result := ByteRingFreeSpace(Connection^.ReceiveBuffer);
  if Result > $FFFF then
    Result := $FFFF;
end;

function OwnMaximumSegment(Remote: TIpv4Address; BoundInterface: PNetworkInterface): LongWord;
var
  Limit: LongWord;
begin
  Limit := PayloadLimit(Remote, BoundInterface);
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

procedure WriteChecksum(Segment: PByte; Length: LongWord; Source, Destination: TIpv4Address);
var
  Sum: LongWord;
begin
  Sum := PseudoHeaderSum(Source, Destination, IpProtocolTcp, Length);
  WriteBigEndian16(Segment + 16, FinishChecksum(AddToChecksum(Sum, Segment, Length)));
end;

function SendConnectionSegment(Connection: PTcpConnection; Sequence: LongWord; Flags: Byte;
  DataOffset, DataLength: LongWord): LongInt;
var
  Packet: PPacket;
  Header: PByte;
  HeaderLength: LongWord;
  Window: LongWord;
  Acknowledgment: LongWord;
begin
  HeaderLength := TcpHeaderBytes;
  if (Flags and TcpFlagSyn) <> 0 then
    HeaderLength := HeaderLength + TcpMssOptionBytes;
  if Connection^.State <> TcpSynSent then
    Flags := Flags or TcpFlagAck;
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit(-1);
  Header := AppendToPacket(Packet, HeaderLength + DataLength);
  if Header = nil then
  begin
    FreePacket(Packet);
    Exit(-1);
  end;
  Window := ReceiveWindow(Connection);
  Acknowledgment := 0;
  if (Flags and TcpFlagAck) <> 0 then
    Acknowledgment := Connection^.ReceiveNext;
  WriteHeader(Header, Connection^.Local.Port, Connection^.Remote.Port, Sequence, Acknowledgment,
    HeaderLength, Flags, Word(Window));
  if (Flags and TcpFlagSyn) <> 0 then
  begin
    Header[TcpHeaderBytes] := OptionMaximumSegment;
    Header[TcpHeaderBytes + 1] := TcpMssOptionBytes;
    WriteBigEndian16(Header + TcpHeaderBytes + 2,
      Word(OwnMaximumSegment(Connection^.Remote.Address, Connection^.BoundInterface)));
  end;
  if DataLength > 0 then
    CopyFromByteRing(Connection^.SendBuffer, DataOffset, Header + HeaderLength, DataLength);
  WriteChecksum(Header, HeaderLength + DataLength, Connection^.Local.Address, Connection^.Remote.Address);
  if (Flags and TcpFlagAck) <> 0 then
  begin
    Connection^.AdvertisedEdge := Connection^.ReceiveNext + Window;
    Connection^.AckPending := False;
    Connection^.AckDeadline := 0;
    Connection^.SegmentsSinceAck := 0;
  end;
  Result := SendIpv4(Packet, Connection^.Local.Address, Connection^.Remote.Address, IpProtocolTcp,
    Connection^.TimeToLive, True, Connection^.BoundInterface);
end;

procedure SendBareSegment(Source, Destination: TIpv4Address; SourcePort, DestinationPort: Word;
  Sequence, Acknowledgment: LongWord; Flags: Byte);
var
  Packet: PPacket;
  Header: PByte;
begin
  Packet := AllocatePacket(PacketHeadroom);
  if Packet = nil then
    Exit;
  Header := AppendToPacket(Packet, TcpHeaderBytes);
  WriteHeader(Header, SourcePort, DestinationPort, Sequence, Acknowledgment, TcpHeaderBytes, Flags, 0);
  WriteChecksum(Header, TcpHeaderBytes, Source, Destination);
  SendIpv4(Packet, Source, Destination, IpProtocolTcp, DefaultTimeToLive, True, nil);
end;

procedure SendResetFor(constref Datagram: TIpv4Datagram; constref Segment: TTcpSegment);
begin
  if ((Segment.Flags and TcpFlagReset) <> 0) or Datagram.IsBroadcast then
    Exit;
  if (Segment.Flags and TcpFlagAck) <> 0 then
    SendBareSegment(Datagram.Destination, Datagram.Source, Segment.DestinationPort, Segment.SourcePort,
      Segment.Acknowledgment, 0, TcpFlagReset)
  else
    SendBareSegment(Datagram.Destination, Datagram.Source, Segment.DestinationPort, Segment.SourcePort,
      0, Segment.Sequence + SegmentSequenceLength(Segment), TcpFlagReset or TcpFlagAck);
end;

end.
