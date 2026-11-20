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
  The client's TLS 1.3 handshake over QUIC (RFC 9001 section 4), with
  libtls in its QUIC mode (Tls.Quic): libtls writes its messages to the
  CRYPTO stream of the level it is at, waits for the server's by pumping
  the connection until CRYPTO bytes of the level it reads are there, and
  hands over each traffic secret, from which the packet protection keys
  are made at once. When the handshake is done the server's transport
  parameters are checked and taken.

  A handshake that fails closes the connection with CRYPTO_ERROR (0x100
  + the TLS alert), unless the connection was already gone.
}
unit Quic.ClientHandshake;

{$mode objfpc}
{$H+}

interface

uses
  Quic.ConnectionState;

type
  TQuicHandshakeResult = record
    Error: LongInt;
    { Words for a TLS failure ("the certificate has expired ..."). }
    TlsDescription: string;
    CipherSuiteName: string;
    ApplicationProtocol: string;
  end;

procedure RunClientHandshake(State: PQuicConnectionState; out Outcome: TQuicHandshakeResult);

implementation

uses
  SysUtils,
  Tls.Client,
  Tls.Connections,
  Tls.Errors,
  Tls.Quic,
  Tls.Transport,
  Tls.TrustStore,
  Quic.ConnectionCore,
  Quic.Constants,
  Quic.DatagramTransports,
  Quic.Errors;

function SpaceOfLevel(Level: TTlsQuicLevel): Integer;
begin
  case Level of
    QuicLevelInitial: Result := SpaceInitial;
    QuicLevelHandshake: Result := SpaceHandshake;
  else
    Result := SpaceApplication;
  end;
end;

function SendHandshakeBytes(Context: Pointer; Level: TTlsQuicLevel; Data: PByte; Length: PtrUInt): LongInt;
begin
  if AppendCryptoData(PQuicConnectionState(Context), SpaceOfLevel(Level), Data, Length) <> QuicErrorNone then
    Exit(TlsErrorInternal);
  Result := TlsErrorNone;
end;

function ReceiveHandshakeBytes(Context: Pointer; Level: TTlsQuicLevel; Buffer: PByte; Length: PtrUInt): Int64;
var
  State: PQuicConnectionState;
  Count: PtrUInt;
begin
  State := PQuicConnectionState(Context);
  while True do
  begin
    Count := ReadCryptoData(State, SpaceOfLevel(Level), Buffer, Length);
    if Count > 0 then
      Exit(Count);
    if not ConnectionIsOpen(State) then
      Exit(TlsErrorTransportFailed);
    if QuicMilliseconds >= State^.HandshakeDeadline then
      Exit(TlsErrorTimedOut);
    PumpConnection(State, State^.HandshakeDeadline);
  end;
end;

function InstallSecret(Context: Pointer; Level: TTlsQuicLevel; Direction: TTlsQuicDirection; CipherSuite: Word;
  Secret: PByte; SecretLength: Integer): LongInt;
begin
  if InstallTrafficSecret(PQuicConnectionState(Context), SpaceOfLevel(Level), Direction = QuicDirectionRead,
    CipherSuite, Secret, SecretLength) <> QuicErrorNone then
    Exit(TlsErrorInternal);
  Result := TlsErrorNone;
end;

procedure FailHandshake(State: PQuicConnectionState; Connection: PTlsConnection; TlsError: LongInt;
  var Outcome: TQuicHandshakeResult);
var
  Alert: LongInt;
begin
  if not ConnectionIsOpen(State) then
  begin
    Outcome.Error := ConnectionError(State);
    Exit;
  end;
  if TlsError = TlsErrorTimedOut then
  begin
    FailSilently(State, QuicErrorHandshakeTimedOut, 'the handshake took too long');
    Outcome.Error := QuicErrorHandshakeTimedOut;
    Exit;
  end;
  Alert := TlsQuicAlert(Connection);
  if Alert < 0 then
    Alert := TlsAlertInternalError;
  CloseWithTransportError(State, TransportCryptoError + QWord(Alert), FrameCrypto, Outcome.TlsDescription,
    QuicErrorHandshakeFailed);
  FlushConnection(State);
  Outcome.Error := QuicErrorHandshakeFailed;
end;

procedure RunClientHandshake(State: PQuicConnectionState; out Outcome: TQuicHandshakeResult);
var
  Callbacks: TTlsQuicCallbacks;
  Options: TTlsClientOptions;
  Transport: TTlsTransport;
  Connection: PTlsConnection;
  TlsError: LongInt;
  Parameters: TBytes;
begin
  Outcome := Default(TQuicHandshakeResult);
  StartClientConnection(State);
  Callbacks := Default(TTlsQuicCallbacks);
  Callbacks.Context := State;
  Callbacks.SendHandshake := @SendHandshakeBytes;
  Callbacks.ReceiveHandshake := @ReceiveHandshakeBytes;
  Callbacks.InstallSecret := @InstallSecret;
  Callbacks.TransportParameters := EncodedLocalParameters(State);
  Options := Default(TTlsClientOptions);
  Options.ServerName := State^.Options.ServerName;
  Options.TrustStore := PTlsTrustStore(State^.Options.TrustStore);
  Options.VerifyCertificates := State^.Options.VerifyCertificates;
  Options.VerificationTime := State^.Options.VerificationTime;
  Options.ApplicationProtocol := State^.Options.ApplicationProtocol;
  Options.CipherSuites := State^.Options.CipherSuites;
  Options.Quic := @Callbacks;
  Transport := Default(TTlsTransport);
  TlsError := CreateTlsClient(Transport, Options, Connection);
  if TlsError <> TlsErrorNone then
  begin
    Outcome.TlsDescription := TlsErrorMessage(TlsError);
    Outcome.Error := QuicErrorInvalidArgument;
    Exit;
  end;
  try
    TlsError := TlsHandshake(Connection);
    if TlsError <> TlsErrorNone then
    begin
      Outcome.TlsDescription := TlsErrorDescription(Connection, TlsError);
      FailHandshake(State, Connection, TlsError, Outcome);
      Exit;
    end;
    Outcome.CipherSuiteName := TlsCipherSuiteName(Connection);
    Outcome.ApplicationProtocol := TlsSelectedProtocol(Connection);
    Parameters := TlsQuicPeerTransportParameters(Connection);
    if Length(Parameters) = 0 then
      Outcome.Error := ApplyPeerTransportParameters(State, nil, 0)
    else
      Outcome.Error := ApplyPeerTransportParameters(State, @Parameters[0], Length(Parameters));
    if Outcome.Error <> QuicErrorNone then
    begin
      FlushConnection(State);
      Exit;
    end;
    CompleteHandshake(State);
    FlushConnection(State);
    Outcome.Error := ConnectionError(State);
  finally
    FreeTlsClient(Connection);
  end;
end;

end.
