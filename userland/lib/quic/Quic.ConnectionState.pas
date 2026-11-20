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
  The state of one QUIC connection, shared by the units that work on it
  (Quic.StreamTable, Quic.LossRecovery, Quic.PacketSending,
  Quic.FrameHandling, Quic.PacketReceiving, Quic.ConnectionCore) and
  wrapped for programs by TQuicConnection (Quic.Connections).

  Everything a connection needs is allocated when it is made: the
  datagram buffers, the rings of sent packets, room for a few packets
  that arrive before their keys; streams take memory as their data
  needs it, up to their windows. A connection fails once: the first
  error is kept (Error, and what was sent or received in
  CONNECTION_CLOSE), and every later call returns it.
}
unit Quic.ConnectionState;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Tls.CipherSuites,
  Quic.Congestion,
  Quic.ConnectionIds,
  Quic.Constants,
  Quic.DatagramTransports,
  Quic.PacketProtection,
  Quic.RangeSets,
  Quic.ReceiveBuffers,
  Quic.SendBuffers,
  Quic.SentPackets,
  Quic.Streams,
  Quic.TransportParameters;

const
  LocalConnectionIdLength = 8;
  { The largest datagram that is read whole. }
  ReceiveBufferSize = 2048;
  { Packets kept for keys that are not there yet (RFC 9001 section 5.7). }
  MaximumBufferedPackets = 8;
  MaximumPeerConnectionIds = 4;
  { The bytes of a CRYPTO stream held either way. }
  CryptoBufferLimit = 65536;

type
  TQuicRole = (RoleClient, RoleServer);
  TQuicPhase = (PhaseHandshaking, PhaseEstablished, PhaseClosing, PhaseDraining, PhaseClosed);

  TQuicConnectionOptions = record
    { The server's name: for TLS (server_name, the certificate check). }
    ServerName: string;
    { The ALPN protocol ("h3"). }
    ApplicationProtocol: string;
    { TLS: the roots (a PTlsTrustStore), whether to check, the time
      (Unix seconds), the suites (Count 0: the default). }
    TrustStore: Pointer;
    VerifyCertificates: Boolean;
    VerificationTime: Int64;
    CipherSuites: TCipherSuiteList;
    { Milliseconds: the idle timeout offered (0: 30 s) and how long the
      handshake may take (0: 10 s). }
    IdleTimeout: Int64;
    HandshakeTimeout: Int64;
    { The datagrams to send (0: 1200, at most 1452); with
      ProbePathMtu, 1452 is tried once the handshake is confirmed. }
    MaximumDatagramSize: Integer;
    ProbePathMtu: Boolean;
    { What the peer may send: on the connection and on each stream
      (0: 1 MiB and 256 KiB), and how many streams it may open of each
      kind (0: 100). }
    ConnectionWindow: QWord;
    StreamWindow: QWord;
    MaximumPeerBidirectionalStreams: QWord;
    MaximumPeerUnidirectionalStreams: QWord;
    { Bytes a stream holds unacknowledged (0: 256 KiB). }
    StreamSendBuffer: PtrUInt;
    { An address validation token from the server's NEW_TOKEN on an
      earlier connection, for the first Initial. }
    Token: TBytes;
    { Packets sent with one set of 1-RTT keys before a key update (0:
      never, but when the peer starts one). }
    KeyUpdateInterval: QWord;
  end;

  TQuicPacketSpace = record
    SendKeys: TQuicPacketKeys;
    ReceiveKeys: TQuicPacketKeys;
    Discarded: Boolean;
    NextPacketNumber: QWord;
    { High(QWord): nothing acknowledged yet. }
    LargestAcknowledged: QWord;
    Sent: TQuicSentPacketRing;
    TimeOfLastAckEliciting: Int64;
    { 0: no packet waits for the time threshold. }
    LossTime: Int64;
    { The newest ranges of this side's packet numbers the peer
      acknowledged (for persistent congestion). }
    AcknowledgedSent: TQuicRangeSet;
    Received: TQuicRangeSet;
    LargestReceived: Int64;
    LargestReceivedTime: Int64;
    { Ack-eliciting packets received since the last ACK was sent. }
    AckElicitingSinceAck: Integer;
    AckPending: Boolean;
    { When an ACK must go at the latest (0: none due). }
    AckDeadline: Int64;
    { Packet numbers below this are treated as duplicates. }
    IgnoreBelow: QWord;
    CryptoSend: TQuicSendBuffer;
    CryptoReceive: TQuicReceiveBuffer;
    { Probe packets the probe timeout asks for. }
    ProbesWanted: Integer;
  end;

  TQuicPeerConnectionId = record
    InUse: Boolean;
    Sequence: QWord;
    Id: TQuicConnectionId;
    HasResetToken: Boolean;
    ResetToken: TStatelessResetToken;
  end;

  TQuicBufferedPacket = record
    Space: Integer;
    Length: Integer;
    Data: array[0..ReceiveBufferSize - 1] of Byte;
  end;

  TQuicPathMtuState = (PathMtuIdle, PathMtuProbing, PathMtuDone);

  TQuicStatistics = record
    PacketsSent: QWord;
    PacketsReceived: QWord;
    PacketsLost: QWord;
    BytesSent: QWord;
    BytesReceived: QWord;
    KeyUpdates: Integer;
  end;

  { The server's TLS (for the test's server) runs outside; it is told
    when the handshake is done through the core's routines. }
  TQuicConnectionState = record
    Role: TQuicRole;
    Phase: TQuicPhase;
    Options: TQuicConnectionOptions;
    Transport: TQuicDatagramTransport;

    Error: LongInt;
    ErrorDetail: string;
    { The CONNECTION_CLOSE this side sends (or sent). }
    CloseCode: QWord;
    CloseIsApplication: Boolean;
    CloseFrameType: QWord;
    CloseReason: string;
    ClosePending: Boolean;
    { When closing or draining ends. }
    CloseDeadline: Int64;
    { The peer's CONNECTION_CLOSE. }
    PeerClosed: Boolean;
    PeerCloseCode: QWord;
    PeerCloseIsApplication: Boolean;
    PeerCloseReason: string;

    LocalId: TQuicConnectionId;
    LocalResetToken: TStatelessResetToken;
    { The client's first Destination Connection ID (the Initial keys'). }
    OriginalDestinationId: TQuicConnectionId;
    RetryReceived: Boolean;
    RetrySourceId: TQuicConnectionId;
    { The peer's Source Connection ID of its first Initial. }
    PeerInitialSourceId: TQuicConnectionId;
    { Client: the server's first Initial was taken (its Source Connection
      ID is now the Destination). }
    PeerAddressFixed: Boolean;
    PeerIds: array[0..MaximumPeerConnectionIds - 1] of TQuicPeerConnectionId;
    CurrentPeerId: Integer;
    RetireQueue: array of QWord;
    Token: TBytes;
    { The newest NEW_TOKEN from the server. }
    ReceivedToken: TBytes;

    LocalParameters: TQuicTransportParameters;
    PeerParameters: TQuicTransportParameters;
    PeerParametersKnown: Boolean;

    Spaces: array[0..SpaceCount - 1] of TQuicPacketSpace;
    { 1-RTT key updates (RFC 9001 section 6). }
    KeyPhase: Byte;
    NextReceiveKeys: TQuicPacketKeys;
    PreviousReceiveKeys: TQuicPacketKeys;
    PreviousKeysDeadline: Int64;
    { This side moved its keys and waits for an acknowledgement of a
      packet with the new ones before it may move again. }
    KeyUpdateUnconfirmed: Boolean;
    FirstPacketOfPhase: QWord;
    PacketsInPhase: QWord;
    KeyUpdateRequested: Boolean;
    { The receiving side's key phase and the first packet received in
      it; the previous keys stay for late packets until the deadline. }
    ReceiveKeyPhase: Byte;
    FirstReceivedOfPhase: QWord;
    PreviousKeysValid: Boolean;

    HandshakeComplete: Boolean;
    HandshakeConfirmed: Boolean;
    HandshakeDonePending: Boolean;
    HandshakeDeadline: Int64;
    { Server: the client's address is validated (a Handshake packet
      came), so the three-times limit is off. }
    AddressValidated: Boolean;
    BytesReceivedOnPath: QWord;
    BytesSentOnPath: QWord;

    Rtt: TQuicRttEstimator;
    Congestion: TQuicCongestionControl;
    ProbeCount: Integer;
    { 0: no timer. }
    LossDetectionDeadline: Int64;
    MaximumDatagramSize: Integer;
    PathMtu: TQuicPathMtuState;

    IdleTimeout: Int64;
    LastReceiveTime: Int64;
    { The first ack-eliciting packet after a received one restarts the
      idle timer too. }
    AckElicitingSentSinceReceive: Boolean;
    LastActivityTime: Int64;

    Streams: array of PQuicStream;
    StreamCount: Integer;
    { Streams this side opened of each kind. }
    LocalBidirectionalOpened: QWord;
    LocalUnidirectionalOpened: QWord;
    PeerMaxStreamsBidirectional: QWord;
    PeerMaxStreamsUnidirectional: QWord;
    { Streams the peer opened of each kind, and how many it may. }
    PeerBidirectionalOpened: QWord;
    PeerUnidirectionalOpened: QWord;
    LocalMaxStreamsBidirectional: QWord;
    LocalMaxStreamsUnidirectional: QWord;
    MaxStreamsBidirectionalPending: Boolean;
    MaxStreamsUnidirectionalPending: Boolean;
    StreamsBlockedBidirectionalPending: Boolean;
    StreamsBlockedUnidirectionalPending: Boolean;
    PeerMaxData: QWord;
    DataSent: QWord;
    DataBlockedPending: Boolean;
    DataBlockedReportedAt: QWord;
    LocalMaxData: QWord;
    DataReceived: QWord;
    DataConsumed: QWord;
    MaxDataPending: Boolean;
    NextStreamToSend: Integer;

    PathResponsePending: Boolean;
    PathResponseData: array[0..7] of Byte;

    SendBuffer: array[0..Quic.Constants.MaximumDatagramSize + 63] of Byte;
    ReceiveBuffer: array[0..Quic.ConnectionState.ReceiveBufferSize - 1] of Byte;
    BufferedPackets: array of TQuicBufferedPacket;
    BufferedPacketCount: Integer;

    Statistics: TQuicStatistics;
  end;
  PQuicConnectionState = ^TQuicConnectionState;

function CreateConnectionState(Role: TQuicRole; constref Options: TQuicConnectionOptions;
  constref Transport: TQuicDatagramTransport): PQuicConnectionState;
procedure FreeConnectionState(var State: PQuicConnectionState);
{ The Destination Connection ID packets go out with. }
function CurrentDestinationId(State: PQuicConnectionState): TQuicConnectionId;
{ Starts closing with a transport error (this side found a problem):
  CONNECTION_CLOSE goes out, the connection fails with Error. }
procedure CloseWithTransportError(State: PQuicConnectionState; Code, FrameType: QWord; const Reason: string;
  Error: LongInt);
{ The application closes (CONNECTION_CLOSE 0x1d, or 0x1c with
  APPLICATION_ERROR while the handshake runs). }
procedure CloseByApplication(State: PQuicConnectionState; Code: QWord; const Reason: string);
{ Fails without sending anything (the peer is gone, or reset). }
procedure FailSilently(State: PQuicConnectionState; Error: LongInt; const Detail: string);
function ConnectionIsOpen(State: PQuicConnectionState): Boolean;
{ The probe timeout with max_ack_delay (for the Application space)
  and the backoff. }
function ProbeTimeout(State: PQuicConnectionState; Space: Integer): Int64;

implementation

uses
  Crypto.Bits,
  Crypto.Random,
  Quic.Errors;

function CreateConnectionState(Role: TQuicRole; constref Options: TQuicConnectionOptions;
  constref Transport: TQuicDatagramTransport): PQuicConnectionState;
var
  State: PQuicConnectionState;
  Space: Integer;
begin
  { Zeroed memory is also empty strings and arrays. }
  State := AllocMem(SizeOf(TQuicConnectionState));
  State^.Role := Role;
  State^.Options := Options;
  State^.Transport := Transport;
  with State^.Options do
  begin
    if IdleTimeout <= 0 then
      IdleTimeout := 30000;
    if HandshakeTimeout <= 0 then
      HandshakeTimeout := 10000;
    if (MaximumDatagramSize <= 0) or (MaximumDatagramSize < MinimumDatagramSize) then
      MaximumDatagramSize := MinimumDatagramSize;
    if MaximumDatagramSize > Quic.Constants.MaximumDatagramSize then
      MaximumDatagramSize := Quic.Constants.MaximumDatagramSize;
    if ConnectionWindow = 0 then
      ConnectionWindow := 1048576;
    if StreamWindow = 0 then
      StreamWindow := 262144;
    if MaximumPeerBidirectionalStreams = 0 then
      MaximumPeerBidirectionalStreams := 100;
    if MaximumPeerUnidirectionalStreams = 0 then
      MaximumPeerUnidirectionalStreams := 100;
    if StreamSendBuffer = 0 then
      StreamSendBuffer := 262144;
  end;
  State^.Phase := PhaseHandshaking;
  State^.MaximumDatagramSize := State^.Options.MaximumDatagramSize;
  for Space := 0 to SpaceCount - 1 do
  begin
    State^.Spaces[Space].LargestAcknowledged := High(QWord);
    State^.Spaces[Space].LargestReceived := -1;
    State^.Spaces[Space].Received.MaximumRanges := 32;
    State^.Spaces[Space].AcknowledgedSent.MaximumRanges := 16;
    State^.Spaces[Space].CryptoSend.Initialize(CryptoBufferLimit);
    State^.Spaces[Space].CryptoReceive.Initialize(CryptoBufferLimit);
    if Space = SpaceApplication then
      State^.Spaces[Space].Sent.Initialize(ApplicationRingSize)
    else
      State^.Spaces[Space].Sent.Initialize(HandshakeRingSize);
  end;
  InitializeRtt(State^.Rtt);
  InitializeCongestion(State^.Congestion, State^.MaximumDatagramSize);
  State^.LocalId := RandomConnectionId(LocalConnectionIdLength);
  RandomBytes(@State^.LocalResetToken[0], StatelessResetTokenLength);
  State^.LocalMaxData := State^.Options.ConnectionWindow;
  State^.LocalMaxStreamsBidirectional := State^.Options.MaximumPeerBidirectionalStreams;
  State^.LocalMaxStreamsUnidirectional := State^.Options.MaximumPeerUnidirectionalStreams;
  State^.IdleTimeout := State^.Options.IdleTimeout;
  SetLength(State^.BufferedPackets, MaximumBufferedPackets);
  State^.Token := Copy(State^.Options.Token);
  Result := State;
end;

procedure FreeConnectionState(var State: PQuicConnectionState);
var
  Index, Space: Integer;
begin
  if State = nil then
    Exit;
  for Index := 0 to State^.StreamCount - 1 do
  begin
    State^.Streams[Index]^.Send.Release;
    State^.Streams[Index]^.Receive.Release;
    Dispose(State^.Streams[Index]);
  end;
  for Space := 0 to SpaceCount - 1 do
  begin
    WipePacketKeys(State^.Spaces[Space].SendKeys);
    WipePacketKeys(State^.Spaces[Space].ReceiveKeys);
    State^.Spaces[Space].Sent.Release;
    State^.Spaces[Space].CryptoSend.Release;
    State^.Spaces[Space].CryptoReceive.Release;
    State^.Spaces[Space].Received.Ranges := nil;
    State^.Spaces[Space].AcknowledgedSent.Ranges := nil;
  end;
  WipePacketKeys(State^.NextReceiveKeys);
  WipePacketKeys(State^.PreviousReceiveKeys);
  Finalize(State^);
  FreeMem(State);
  State := nil;
end;

function CurrentDestinationId(State: PQuicConnectionState): TQuicConnectionId;
begin
  Result := State^.PeerIds[State^.CurrentPeerId].Id;
end;

function ConnectionIsOpen(State: PQuicConnectionState): Boolean;
begin
  Result := State^.Phase in [PhaseHandshaking, PhaseEstablished];
end;

function ProbeTimeout(State: PQuicConnectionState; Space: Integer): Int64;
var
  Backoff: Integer;
begin
  Result := ProbeTimeoutBase(State^.Rtt);
  if (Space = SpaceApplication) and State^.HandshakeConfirmed then
    Result := Result + Int64(State^.PeerParameters.MaxAckDelay);
  Backoff := State^.ProbeCount;
  if Backoff > 16 then
    Backoff := 16;
  Result := Result shl Backoff;
end;

procedure EnterClosing(State: PQuicConnectionState);
begin
  State^.Phase := PhaseClosing;
  State^.ClosePending := True;
  State^.CloseDeadline := QuicMilliseconds + 3 * ProbeTimeout(State, SpaceApplication);
end;

procedure CloseWithTransportError(State: PQuicConnectionState; Code, FrameType: QWord; const Reason: string;
  Error: LongInt);
begin
  if not ConnectionIsOpen(State) then
    Exit;
  State^.Error := Error;
  State^.ErrorDetail := Reason;
  State^.CloseCode := Code;
  State^.CloseFrameType := FrameType;
  State^.CloseIsApplication := False;
  State^.CloseReason := Reason;
  EnterClosing(State);
end;

procedure CloseByApplication(State: PQuicConnectionState; Code: QWord; const Reason: string);
begin
  if not ConnectionIsOpen(State) then
    Exit;
  State^.Error := QuicErrorClosed;
  State^.CloseCode := Code;
  State^.CloseFrameType := 0;
  State^.CloseIsApplication := True;
  State^.CloseReason := Reason;
  EnterClosing(State);
end;

procedure FailSilently(State: PQuicConnectionState; Error: LongInt; const Detail: string);
begin
  if State^.Phase = PhaseClosed then
    Exit;
  if State^.Error = 0 then
  begin
    State^.Error := Error;
    State^.ErrorDetail := Detail;
  end;
  State^.Phase := PhaseClosed;
  State^.ClosePending := False;
end;

end.
