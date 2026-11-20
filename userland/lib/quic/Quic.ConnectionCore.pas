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
  Running a connection: starting it as a client or a server, the
  handshake's side of things (CRYPTO bytes in and out per level, the
  traffic secrets the TLS handshake hands over, the peer's transport
  parameters checked against the connection IDs seen, RFC 9000 section
  7.3), and the pump: send what is due, wait for a datagram until the
  next timer (loss detection, acknowledgement delay, pacing, idle
  timeout, the end of closing), handle what came and the timers that
  ran out, send again.

  Everything is driven from the calling thread: the pump runs when a
  caller waits (for handshake bytes, stream data, room to write), so a
  connection needs no thread of its own.
}
unit Quic.ConnectionCore;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Quic.ConnectionIds,
  Quic.ConnectionState;

procedure StartClientConnection(State: PQuicConnectionState);
{ A server connection for a client's Initial: the Destination ID its
  Initial packets use now (the Initial keys'), its Source ID, the
  Destination ID it first used (transport parameter) and, after a
  Retry, the Retry's Source ID (empty otherwise). }
procedure StartServerConnection(State: PQuicConnectionState; constref InitialDestinationId, ClientSourceId,
  OriginalDestinationId, RetrySourceId: TQuicConnectionId);
function EncodedLocalParameters(State: PQuicConnectionState): TBytes;
{ The peer's transport parameters: QuicErrorNone, or the connection
  closes with TRANSPORT_PARAMETER_ERROR. }
function ApplyPeerTransportParameters(State: PQuicConnectionState; Data: PByte; Length: PtrUInt): LongInt;
{ A traffic secret for a space (SpaceHandshake, SpaceApplication). }
function InstallTrafficSecret(State: PQuicConnectionState; Space: Integer; ForReading: Boolean; CipherSuite: Word;
  Secret: PByte; SecretLength: Integer): LongInt;
procedure CompleteHandshake(State: PQuicConnectionState);
{ Handshake bytes to send at a level: QuicErrorNone or an error. }
function AppendCryptoData(State: PQuicConnectionState; Space: Integer; Data: PByte; Length: PtrUInt): LongInt;
{ Handshake bytes received at a level, in order: how many were read. }
function ReadCryptoData(State: PQuicConnectionState; Space: Integer; Buffer: PByte; Capacity: PtrUInt): PtrUInt;
{ One round: send, wait (at most until Deadline, a QuicMilliseconds
  time) for a datagram or a timer, handle it, send. QuicErrorNone while
  the connection is open, else the error it ended with. }
function PumpConnection(State: PQuicConnectionState; Deadline: Int64): LongInt;
{ Sends what is due without waiting. }
procedure FlushConnection(State: PQuicConnectionState);
{ QuicErrorNone while open, else why it is not. }
function ConnectionError(State: PQuicConnectionState): LongInt;

implementation

uses
  Crypto.Digests,
  Tls.CipherSuites,
  Quic.Constants,
  Quic.DatagramTransports,
  Quic.Errors,
  Quic.InitialSecrets,
  Quic.LossRecovery,
  Quic.PacketProtection,
  Quic.PacketReceiving,
  Quic.PacketSending,
  Quic.StreamTable,
  Quic.TransportParameters;

procedure SetLocalParameters(State: PQuicConnectionState);
var
  Parameters: ^TQuicTransportParameters;
begin
  Parameters := @State^.LocalParameters;
  DefaultTransportParameters(Parameters^);
  Parameters^.MaxIdleTimeout := State^.Options.IdleTimeout;
  Parameters^.MaxUdpPayloadSize := ReceiveBufferSize - 64;
  Parameters^.InitialMaxData := State^.Options.ConnectionWindow;
  Parameters^.InitialMaxStreamDataBidiLocal := State^.Options.StreamWindow;
  Parameters^.InitialMaxStreamDataBidiRemote := State^.Options.StreamWindow;
  Parameters^.InitialMaxStreamDataUni := State^.Options.StreamWindow;
  Parameters^.InitialMaxStreamsBidi := State^.Options.MaximumPeerBidirectionalStreams;
  Parameters^.InitialMaxStreamsUni := State^.Options.MaximumPeerUnidirectionalStreams;
  Parameters^.ActiveConnectionIdLimit := MaximumPeerConnectionIds;
  Parameters^.HasInitialSourceConnectionId := True;
  Parameters^.InitialSourceConnectionId := State^.LocalId;
  Parameters^.DisableActiveMigration := True;
end;

procedure StartClientConnection(State: PQuicConnectionState);
var
  Now: Int64;
begin
  State^.PeerIds[0].InUse := True;
  State^.PeerIds[0].Sequence := 0;
  State^.PeerIds[0].Id := RandomConnectionId(8);
  State^.CurrentPeerId := 0;
  State^.OriginalDestinationId := State^.PeerIds[0].Id;
  DeriveInitialKeys(State^.OriginalDestinationId, State^.Spaces[SpaceInitial].SendKeys,
    State^.Spaces[SpaceInitial].ReceiveKeys);
  SetLocalParameters(State);
  Now := QuicMilliseconds;
  State^.HandshakeDeadline := Now + State^.Options.HandshakeTimeout;
  State^.LastActivityTime := Now;
end;

procedure StartServerConnection(State: PQuicConnectionState; constref InitialDestinationId, ClientSourceId,
  OriginalDestinationId, RetrySourceId: TQuicConnectionId);
var
  Now: Int64;
begin
  State^.PeerIds[0].InUse := True;
  State^.PeerIds[0].Sequence := 0;
  State^.PeerIds[0].Id := ClientSourceId;
  State^.CurrentPeerId := 0;
  State^.PeerAddressFixed := True;
  State^.PeerInitialSourceId := ClientSourceId;
  State^.OriginalDestinationId := InitialDestinationId;
  DeriveInitialKeys(InitialDestinationId, State^.Spaces[SpaceInitial].ReceiveKeys,
    State^.Spaces[SpaceInitial].SendKeys);
  SetLocalParameters(State);
  State^.LocalParameters.HasOriginalDestinationConnectionId := True;
  State^.LocalParameters.OriginalDestinationConnectionId := OriginalDestinationId;
  State^.LocalParameters.HasStatelessResetToken := True;
  State^.LocalParameters.StatelessResetToken := State^.LocalResetToken;
  if RetrySourceId.Length > 0 then
  begin
    State^.LocalParameters.HasRetrySourceConnectionId := True;
    State^.LocalParameters.RetrySourceConnectionId := RetrySourceId;
    { The Retry token proved the address. }
    State^.AddressValidated := True;
  end;
  Now := QuicMilliseconds;
  State^.HandshakeDeadline := Now + State^.Options.HandshakeTimeout;
  State^.LastActivityTime := Now;
end;

function EncodedLocalParameters(State: PQuicConnectionState): TBytes;
begin
  Result := EncodeTransportParameters(State^.LocalParameters);
end;

function ParameterError(State: PQuicConnectionState; const Reason: string): LongInt;
begin
  CloseWithTransportError(State, TransportParameterError, 0, Reason, QuicErrorProtocolViolation);
  Result := QuicErrorProtocolViolation;
end;

function ApplyPeerTransportParameters(State: PQuicConnectionState; Data: PByte; Length: PtrUInt): LongInt;
var
  Parameters: TQuicTransportParameters;
begin
  if not DecodeTransportParameters(Data, Length, State^.Role = RoleClient, Parameters) then
    Exit(ParameterError(State, 'malformed transport parameters'));
  { Every connection ID the handshake saw must be confirmed. }
  if not Parameters.HasInitialSourceConnectionId or
     not SameConnectionId(Parameters.InitialSourceConnectionId, State^.PeerInitialSourceId) then
    Exit(ParameterError(State, 'initial_source_connection_id does not match'));
  if State^.Role = RoleClient then
  begin
    if not Parameters.HasOriginalDestinationConnectionId or
       not SameConnectionId(Parameters.OriginalDestinationConnectionId, State^.OriginalDestinationId) then
      Exit(ParameterError(State, 'original_destination_connection_id does not match'));
    if State^.RetryReceived <> Parameters.HasRetrySourceConnectionId then
      Exit(ParameterError(State, 'retry_source_connection_id missing or unexpected'));
    if State^.RetryReceived and not SameConnectionId(Parameters.RetrySourceConnectionId, State^.RetrySourceId) then
      Exit(ParameterError(State, 'retry_source_connection_id does not match'));
    if Parameters.HasStatelessResetToken then
    begin
      State^.PeerIds[0].HasResetToken := True;
      State^.PeerIds[0].ResetToken := Parameters.StatelessResetToken;
    end;
  end;
  State^.PeerParameters := Parameters;
  State^.PeerParametersKnown := True;
  if (Parameters.MaxIdleTimeout > 0) and ((State^.IdleTimeout = 0) or (Int64(Parameters.MaxIdleTimeout) <
    State^.IdleTimeout)) then
    State^.IdleTimeout := Int64(Parameters.MaxIdleTimeout);
  ApplyPeerStreamLimits(State);
  Result := QuicErrorNone;
end;

function InstallTrafficSecret(State: PQuicConnectionState; Space: Integer; ForReading: Boolean; CipherSuite: Word;
  Secret: PByte; SecretLength: Integer): LongInt;
var
  Suite: TCipherSuiteInfo;
begin
  if not FindCipherSuite(CipherSuite, Suite) or Suite.IsTls12 or (Space = SpaceInitial) then
    Exit(QuicErrorInternal);
  if State^.Spaces[Space].Discarded then
    Exit(QuicErrorNone);
  if ForReading then
  begin
    DerivePacketKeys(State^.Spaces[Space].ReceiveKeys, Suite.Aead, Suite.Hash, Secret, SecretLength);
    if Space = SpaceApplication then
      DeriveNextPhaseKeys(State^.Spaces[Space].ReceiveKeys, State^.NextReceiveKeys);
    ProcessBufferedPackets(State, Space);
  end
  else
    DerivePacketKeys(State^.Spaces[Space].SendKeys, Suite.Aead, Suite.Hash, Secret, SecretLength);
  Result := QuicErrorNone;
end;

procedure CompleteHandshake(State: PQuicConnectionState);
begin
  State^.HandshakeComplete := True;
  if State^.Phase = PhaseHandshaking then
    State^.Phase := PhaseEstablished;
  if State^.Role = RoleServer then
  begin
    { A server's handshake is confirmed when it completes (RFC 9001
      section 4.1.2). }
    State^.HandshakeConfirmed := True;
    State^.HandshakeDonePending := True;
    DiscardSpace(State, SpaceHandshake);
  end;
end;

function AppendCryptoData(State: PQuicConnectionState; Space: Integer; Data: PByte; Length: PtrUInt): LongInt;
begin
  if State^.Spaces[Space].Discarded then
    Exit(QuicErrorInternal);
  if State^.Spaces[Space].CryptoSend.Append(Data, Length) <> Length then
    Exit(QuicErrorOutOfMemory);
  Result := QuicErrorNone;
end;

function ReadCryptoData(State: PQuicConnectionState; Space: Integer; Buffer: PByte; Capacity: PtrUInt): PtrUInt;
begin
  if State^.Spaces[Space].Discarded then
    Exit(0);
  Result := State^.Spaces[Space].CryptoReceive.Read(Buffer, Capacity);
end;

function ConnectionError(State: PQuicConnectionState): LongInt;
begin
  if ConnectionIsOpen(State) then
    Exit(QuicErrorNone);
  Result := State^.Error;
  if Result = QuicErrorNone then
    Result := QuicErrorClosed;
end;

function IdleDeadline(State: PQuicConnectionState): Int64;
var
  Timeout: Int64;
begin
  Timeout := State^.IdleTimeout;
  if Timeout < 3 * ProbeTimeout(State, SpaceApplication) then
    Timeout := 3 * ProbeTimeout(State, SpaceApplication);
  Result := State^.LastActivityTime + Timeout;
end;

procedure HandleTimers(State: PQuicConnectionState; Now: Int64);
begin
  if (State^.LossDetectionDeadline <> 0) and (Now >= State^.LossDetectionDeadline) and ConnectionIsOpen(State) then
    OnLossDetectionTimeout(State, Now);
  if ConnectionIsOpen(State) and (Now >= IdleDeadline(State)) then
    FailSilently(State, QuicErrorIdleTimeout, 'nothing came from the peer for the idle timeout');
  if (State^.Phase in [PhaseClosing, PhaseDraining]) and (Now >= State^.CloseDeadline) then
    State^.Phase := PhaseClosed;
  if State^.PreviousKeysValid and (Now >= State^.PreviousKeysDeadline) then
  begin
    WipePacketKeys(State^.PreviousReceiveKeys);
    State^.PreviousKeysValid := False;
  end;
end;

{ The earliest time something has to happen, Deadline at the latest. }
function NextWakeTime(State: PQuicConnectionState; Deadline, PacingTime: Int64): Int64;
var
  Space: Integer;

  procedure Consider(Time: Int64);
  begin
    if (Time <> 0) and (Time < Result) then
      Result := Time;
  end;

begin
  Result := Deadline;
  Consider(State^.LossDetectionDeadline);
  Consider(PacingTime);
  for Space := 0 to SpaceCount - 1 do
    if State^.Spaces[Space].AckPending then
      Consider(State^.Spaces[Space].AckDeadline);
  if ConnectionIsOpen(State) then
    Consider(IdleDeadline(State));
  if State^.Phase in [PhaseClosing, PhaseDraining] then
    Consider(State^.CloseDeadline);
  if State^.PreviousKeysValid then
    Consider(State^.PreviousKeysDeadline);
end;

procedure FlushConnection(State: PQuicConnectionState);
var
  PacingTime: Int64;
begin
  SendPendingPackets(State, PacingTime);
end;

function PumpConnection(State: PQuicConnectionState; Deadline: Int64): LongInt;
var
  PacingTime, Now, Wake: Int64;
  Received: Int64;
  Drained: Integer;
begin
  SendPendingPackets(State, PacingTime);
  if State^.Phase = PhaseClosed then
    Exit(ConnectionError(State));
  Now := QuicMilliseconds;
  Wake := NextWakeTime(State, Deadline, PacingTime);
  if Wake < Now then
    Wake := Now;
  Received := State^.Transport.Receive(State^.Transport.Context, @State^.ReceiveBuffer[0], ReceiveBufferSize,
    Wake - Now);
  Drained := 0;
  while Received > 0 do
  begin
    ProcessDatagram(State, @State^.ReceiveBuffer[0], Received, QuicMilliseconds);
    Inc(Drained);
    if (Drained >= 64) or (State^.Phase = PhaseClosed) then
      Break;
    Received := State^.Transport.Receive(State^.Transport.Context, @State^.ReceiveBuffer[0], ReceiveBufferSize, 0);
  end;
  if Received < 0 then
    FailSilently(State, QuicErrorTransportFailed, 'receiving failed');
  HandleTimers(State, QuicMilliseconds);
  SendPendingPackets(State, PacingTime);
  RemoveFinishedStreams(State);
  Result := ConnectionError(State);
  { A connection closed cleanly by this side reports nothing while it
    lingers. }
  if (State^.Phase = PhaseClosing) and (State^.Error = QuicErrorClosed) then
    Result := QuicErrorClosed;
end;

end.
