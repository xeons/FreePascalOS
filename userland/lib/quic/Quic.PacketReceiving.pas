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
  Taking received datagrams apart (RFC 9000 sections 12, 17; RFC 9001
  section 5): each packet in the datagram is matched to this
  connection, its header protection removed, its payload opened with
  the keys of its space (and, for 1-RTT packets, of its key phase), and
  its frames handled; then its number is noted for acknowledgement.
  Packets that do not open are dropped quietly, unless the datagram ends
  in one of the peer's stateless reset tokens (section 10.3).

  Packets of a space whose keys are not there yet (a Handshake packet
  coalesced behind the Initial whose ServerHello makes those keys) are
  kept and handled once the keys come (RFC 9001 section 5.7).

  A client also takes Version Negotiation (only before anything else
  came, and only when it does not list version 1) and Retry packets
  (once, before any Initial, with a valid integrity tag): a Retry gives
  a new Destination Connection ID, new Initial keys and a token, and
  the ClientHello goes again.
}
unit Quic.PacketReceiving;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Quic.ConnectionState;

procedure ProcessDatagram(State: PQuicConnectionState; Data: PByte; Length: PtrUInt; Now: Int64);
{ Handles the packets kept for a space whose receive keys just came. }
procedure ProcessBufferedPackets(State: PQuicConnectionState; Space: Integer);

implementation

uses
  SysUtils,
  Crypto.Bits,
  Quic.Buffers,
  Quic.ConnectionIds,
  Quic.Constants,
  Quic.DatagramTransports,
  Quic.Errors,
  Quic.FrameHandling,
  Quic.InitialSecrets,
  Quic.LossRecovery,
  Quic.PacketHeaders,
  Quic.PacketProtection;

function SpaceOfPacket(PacketType: TQuicPacketType): Integer;
begin
  case PacketType of
    PacketInitial: Result := SpaceInitial;
    PacketHandshake: Result := SpaceHandshake;
  else
    Result := SpaceApplication;
  end;
end;

function IsStatelessReset(State: PQuicConnectionState; Datagram: PByte; Length: PtrUInt): Boolean;
var
  Index: Integer;
  Tail: PByte;
begin
  if Length < MinimumStatelessResetLength then
    Exit(False);
  Tail := Datagram + Length - StatelessResetTokenLength;
  for Index := 0 to MaximumPeerConnectionIds - 1 do
    if State^.PeerIds[Index].InUse and State^.PeerIds[Index].HasResetToken and
       ConstantTimeEqual(Tail, @State^.PeerIds[Index].ResetToken[0], StatelessResetTokenLength) then
      Exit(True);
  Result := False;
end;

procedure HandleVersionNegotiation(State: PQuicConnectionState; Packet: PByte; Length: PtrUInt;
  constref Header: TQuicPacketHeader);
var
  Reader: TQuicReader;
  Version: LongWord;
  Offered: string;
begin
  if (State^.Role <> RoleClient) or State^.PeerAddressFixed or State^.RetryReceived then
    Exit;
  if not SameConnectionId(Header.DestinationId, State^.LocalId) or
     not SameConnectionId(Header.SourceId, CurrentDestinationId(State)) then
    Exit;
  Reader.Initialize(Packet + Header.PacketNumberOffset, Length - Header.PacketNumberOffset);
  Offered := '';
  while Reader.ReadUInt32(Version) do
  begin
    { A list with the version sent is to be ignored (RFC 9000 6.2). }
    if Version = QuicVersion1 then
      Exit;
    if Offered <> '' then
      Offered := Offered + ', ';
    Offered := Offered + '0x' + IntToHex(Version, 8);
  end;
  FailSilently(State, QuicErrorVersionNegotiation, 'the server offers ' + Offered);
end;

procedure HandleRetry(State: PQuicConnectionState; Packet: PByte; Length: PtrUInt;
  constref Header: TQuicPacketHeader);
var
  ClientKeys, ServerKeys: TQuicPacketKeys;
begin
  if (State^.Role <> RoleClient) or State^.RetryReceived or State^.PeerAddressFixed then
    Exit;
  if (Header.TokenLength = 0) or SameConnectionId(Header.SourceId, CurrentDestinationId(State)) then
    Exit;
  if not RetryIntegrityTagIsValid(State^.OriginalDestinationId, Packet, Length) then
    Exit;
  State^.RetryReceived := True;
  State^.RetrySourceId := Header.SourceId;
  SetLength(State^.Token, Header.TokenLength);
  Move(Header.Token^, State^.Token[0], Header.TokenLength);
  State^.PeerIds[State^.CurrentPeerId].Id := Header.SourceId;
  DeriveInitialKeys(Header.SourceId, ClientKeys, ServerKeys);
  State^.Spaces[SpaceInitial].SendKeys := ClientKeys;
  State^.Spaces[SpaceInitial].ReceiveKeys := ServerKeys;
  WipePacketKeys(ClientKeys);
  WipePacketKeys(ServerKeys);
  RequeueInitialPackets(State);
end;

procedure BufferPacket(State: PQuicConnectionState; Space: Integer; Packet: PByte; Length: PtrUInt);
begin
  if (State^.BufferedPacketCount >= MaximumBufferedPackets) or (Length > ReceiveBufferSize) then
    Exit;
  State^.BufferedPackets[State^.BufferedPacketCount].Space := Space;
  State^.BufferedPackets[State^.BufferedPacketCount].Length := Length;
  Move(Packet^, State^.BufferedPackets[State^.BufferedPacketCount].Data[0], Length);
  Inc(State^.BufferedPacketCount);
end;

{ Which keys open a 1-RTT packet with this key phase bit and (full)
  packet number; Rotate says the packet starts a new key phase. }
function SelectReceiveKeys(State: PQuicConnectionState; PhaseBit: Byte; PacketNumber: QWord;
  out Rotate: Boolean): PQuicPacketKeys;
begin
  Rotate := False;
  if PhaseBit = State^.ReceiveKeyPhase then
  begin
    if State^.PreviousKeysValid and (PacketNumber < State^.FirstReceivedOfPhase) then
      Exit(@State^.PreviousReceiveKeys);
    Exit(@State^.Spaces[SpaceApplication].ReceiveKeys);
  end;
  if State^.PreviousKeysValid and (PacketNumber < State^.FirstReceivedOfPhase) then
    Exit(@State^.PreviousReceiveKeys);
  Rotate := True;
  Result := @State^.NextReceiveKeys;
end;

{ The peer moved to the next key phase: so does this side's receiving,
  and its sending too if it had not started the update itself. }
procedure RotateReceiveKeys(State: PQuicConnectionState; PacketNumber: QWord; Now: Int64);
var
  Next: TQuicPacketKeys;
begin
  State^.PreviousReceiveKeys := State^.Spaces[SpaceApplication].ReceiveKeys;
  State^.PreviousKeysValid := True;
  State^.PreviousKeysDeadline := Now + 3 * ProbeTimeout(State, SpaceApplication);
  State^.Spaces[SpaceApplication].ReceiveKeys := State^.NextReceiveKeys;
  DeriveNextPhaseKeys(State^.NextReceiveKeys, Next);
  State^.NextReceiveKeys := Next;
  WipePacketKeys(Next);
  State^.ReceiveKeyPhase := State^.ReceiveKeyPhase xor 1;
  State^.FirstReceivedOfPhase := PacketNumber;
  if State^.KeyPhase <> State^.ReceiveKeyPhase then
  begin
    DeriveNextPhaseKeys(State^.Spaces[SpaceApplication].SendKeys, Next);
    State^.Spaces[SpaceApplication].SendKeys := Next;
    WipePacketKeys(Next);
    State^.KeyPhase := State^.ReceiveKeyPhase;
    State^.KeyUpdateUnconfirmed := True;
    State^.FirstPacketOfPhase := State^.Spaces[SpaceApplication].NextPacketNumber;
    State^.PacketsInPhase := 0;
    Inc(State^.Statistics.KeyUpdates);
  end;
end;

procedure NoteReceived(State: PQuicConnectionState; Space: Integer; PacketNumber: QWord; AckEliciting: Boolean;
  Now: Int64);
var
  SpaceState: ^TQuicPacketSpace;
  OutOfOrder: Boolean;
begin
  SpaceState := @State^.Spaces[Space];
  { Older than the largest, or leaving a gap: acknowledge at once
    (RFC 9000 section 13.2.1). }
  OutOfOrder := (Int64(PacketNumber) < SpaceState^.LargestReceived) or
    (Int64(PacketNumber) > SpaceState^.LargestReceived + 1);
  SpaceState^.Received.Add(PacketNumber, PacketNumber + 1);
  if Int64(PacketNumber) > SpaceState^.LargestReceived then
  begin
    SpaceState^.LargestReceived := Int64(PacketNumber);
    SpaceState^.LargestReceivedTime := Now;
  end;
  if not AckEliciting then
    Exit;
  SpaceState^.AckPending := True;
  Inc(SpaceState^.AckElicitingSinceAck);
  if (Space <> SpaceApplication) or OutOfOrder then
    SpaceState^.AckDeadline := Now
  else if SpaceState^.AckDeadline = 0 then
    SpaceState^.AckDeadline := Now + Int64(State^.LocalParameters.MaxAckDelay);
end;

{ Header protection off, the payload opened: True with the packet
  number and the payload's place, False to drop the packet. }
function OpenPacket(State: PQuicConnectionState; Space: Integer; Packet: PByte; Length: PtrUInt;
  constref Header: TQuicPacketHeader; Now: Int64; out PacketNumber: QWord; out Payload: PByte;
  out PayloadLength: PtrUInt): Boolean;
var
  Keys: PQuicPacketKeys;
  Mask: TQuicHeaderMask;
  FirstByte: Byte;
  NumberLength, Index: Integer;
  Truncated: QWord;
  HeaderLength: PtrUInt;
  Rotate: Boolean;
begin
  Result := False;
  PacketNumber := 0;
  Payload := nil;
  PayloadLength := 0;
  if Length < Header.PacketNumberOffset + 4 + HeaderSampleLength then
    Exit;
  Keys := @State^.Spaces[Space].ReceiveKeys;
  ComputeHeaderMask(Keys^, Packet + Header.PacketNumberOffset + 4, Mask);
  if Header.IsLongHeader then
    FirstByte := Packet[0] xor (Mask[0] and $0F)
  else
    FirstByte := Packet[0] xor (Mask[0] and $1F);
  NumberLength := (FirstByte and $03) + 1;
  Truncated := 0;
  for Index := 0 to NumberLength - 1 do
    Truncated := (Truncated shl 8) or (Packet[Header.PacketNumberOffset + PtrUInt(Index)] xor Mask[1 + Index]);
  PacketNumber := DecodePacketNumber(State^.Spaces[Space].LargestReceived, Truncated, NumberLength);
  HeaderLength := Header.PacketNumberOffset + PtrUInt(NumberLength);
  if Length < HeaderLength + PacketTagLength then
    Exit;
  Rotate := False;
  if not Header.IsLongHeader then
    Keys := SelectReceiveKeys(State, (FirstByte shr 2) and 1, PacketNumber, Rotate);
  if not Keys^.Ready then
    Exit;
  { The header as it was before protection is the associated data. }
  Packet[0] := FirstByte;
  for Index := 0 to NumberLength - 1 do
    Packet[Header.PacketNumberOffset + PtrUInt(Index)] := Packet[Header.PacketNumberOffset + PtrUInt(Index)] xor
      Mask[1 + Index];
  if not OpenPayload(Keys^, PacketNumber, Packet, HeaderLength, Packet + HeaderLength, Length - HeaderLength) then
    Exit;
  { Reserved bits must be zero once the packet is authentic. }
  if (Header.IsLongHeader and ((FirstByte and $0C) <> 0)) or (not Header.IsLongHeader and ((FirstByte and $18) <> 0)) then
  begin
    CloseWithTransportError(State, TransportProtocolViolation, 0, 'reserved bits set', QuicErrorProtocolViolation);
    Exit;
  end;
  if Rotate then
  begin
    { A new phase must come after packets of the old one. }
    if Int64(PacketNumber) < State^.Spaces[SpaceApplication].LargestReceived then
      Exit;
    RotateReceiveKeys(State, PacketNumber, Now);
  end;
  Payload := Packet + HeaderLength;
  PayloadLength := Length - HeaderLength - PacketTagLength;
  Result := True;
end;

function PacketIsForThisConnection(State: PQuicConnectionState; constref Header: TQuicPacketHeader): Boolean;
begin
  if SameConnectionId(Header.DestinationId, State^.LocalId) then
    Exit(True);
  { The client's first Initial packets go to the ID it chose. }
  Result := (State^.Role = RoleServer) and Header.IsLongHeader and
    SameConnectionId(Header.DestinationId, State^.OriginalDestinationId);
end;

procedure ProcessPacket(State: PQuicConnectionState; Packet: PByte; Length: PtrUInt;
  constref Header: TQuicPacketHeader; Datagram: PByte; DatagramLength: PtrUInt; Now: Int64);
var
  Space: Integer;
  PacketNumber: QWord;
  Payload: PByte;
  PayloadLength: PtrUInt;
  AckEliciting: Boolean;
begin
  if Header.PacketType = PacketVersionNegotiation then
  begin
    HandleVersionNegotiation(State, Packet, Length, Header);
    Exit;
  end;
  if Header.Version <> QuicVersion1 then
    Exit;
  if not PacketIsForThisConnection(State, Header) then
  begin
    { A stateless reset looks like a short header packet to anyone. }
    if not Header.IsLongHeader and IsStatelessReset(State, Datagram, DatagramLength) then
      FailSilently(State, QuicErrorStatelessReset, 'the peer sent a stateless reset');
    Exit;
  end;
  if Header.PacketType = PacketRetry then
  begin
    HandleRetry(State, Packet, Length, Header);
    Exit;
  end;
  if Header.PacketType = PacketZeroRtt then
    Exit;
  Space := SpaceOfPacket(Header.PacketType);
  if State^.Spaces[Space].Discarded then
    Exit;
  if (State^.Role = RoleClient) and (Header.PacketType = PacketInitial) and State^.PeerAddressFixed and
     not SameConnectionId(Header.SourceId, State^.PeerInitialSourceId) then
    Exit;
  if not State^.Spaces[Space].ReceiveKeys.Ready then
  begin
    if Space <> SpaceInitial then
      BufferPacket(State, Space, Packet, Length);
    Exit;
  end;
  if not OpenPacket(State, Space, Packet, Length, Header, Now, PacketNumber, Payload, PayloadLength) then
  begin
    if not Header.IsLongHeader and IsStatelessReset(State, Datagram, DatagramLength) then
      FailSilently(State, QuicErrorStatelessReset, 'the peer sent a stateless reset');
    Exit;
  end;
  if (PacketNumber < State^.Spaces[Space].IgnoreBelow) or State^.Spaces[Space].Received.Contains(PacketNumber) then
    Exit;

  { The first packet from the server fixes its connection ID. }
  if (State^.Role = RoleClient) and (Header.PacketType = PacketInitial) and not State^.PeerAddressFixed then
  begin
    State^.PeerAddressFixed := True;
    State^.PeerInitialSourceId := Header.SourceId;
    State^.PeerIds[State^.CurrentPeerId].Id := Header.SourceId;
  end;
  Inc(State^.Statistics.PacketsReceived);
  State^.LastReceiveTime := Now;
  State^.LastActivityTime := Now;
  State^.AckElicitingSentSinceReceive := False;
  if not HandleFrames(State, Space, Payload, PayloadLength, Now, AckEliciting) then
    Exit;
  NoteReceived(State, Space, PacketNumber, AckEliciting, Now);
  if (State^.Role = RoleServer) and (Space = SpaceHandshake) then
  begin
    { The client's address is validated, and its Initial keys are no
      longer needed (RFC 9001 section 4.9.1). }
    State^.AddressValidated := True;
    DiscardSpace(State, SpaceInitial);
  end;
end;

procedure ProcessDatagram(State: PQuicConnectionState; Data: PByte; Length: PtrUInt; Now: Int64);
var
  Offset: PtrUInt;
  Header: TQuicPacketHeader;
begin
  State^.BytesReceivedOnPath := State^.BytesReceivedOnPath + Length;
  State^.Statistics.BytesReceived := State^.Statistics.BytesReceived + Length;
  if State^.Phase = PhaseDraining then
    Exit;
  if State^.Phase = PhaseClosing then
  begin
    { Answer with the close again. }
    State^.ClosePending := True;
    Exit;
  end;
  if State^.Phase = PhaseClosed then
    Exit;
  Offset := 0;
  while Offset < Length do
  begin
    if not ParsePacketHeader(Data + Offset, Length - Offset, LocalConnectionIdLength, Header) then
      Break;
    ProcessPacket(State, Data + Offset, Header.PacketLength, Header, Data, Length, Now);
    if not (State^.Phase in [PhaseHandshaking, PhaseEstablished]) then
      Break;
    Offset := Offset + Header.PacketLength;
    if not Header.IsLongHeader then
      Break;
  end;
end;

procedure ProcessBufferedPackets(State: PQuicConnectionState; Space: Integer);
var
  Index, Kept: Integer;
  Header: TQuicPacketHeader;
  Now: Int64;
begin
  Now := QuicMilliseconds;
  Kept := 0;
  Index := 0;
  while Index < State^.BufferedPacketCount do
  begin
    if State^.BufferedPackets[Index].Space = Space then
    begin
      if ParsePacketHeader(@State^.BufferedPackets[Index].Data[0], State^.BufferedPackets[Index].Length,
        LocalConnectionIdLength, Header) then
        ProcessPacket(State, @State^.BufferedPackets[Index].Data[0], Header.PacketLength, Header,
          @State^.BufferedPackets[Index].Data[0], State^.BufferedPackets[Index].Length, Now);
    end
    else
    begin
      if Kept <> Index then
        State^.BufferedPackets[Kept] := State^.BufferedPackets[Index];
      Inc(Kept);
    end;
    Inc(Index);
  end;
  State^.BufferedPacketCount := Kept;
end;

end.
