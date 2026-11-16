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
  The state of one TLS client connection, shared by the record layer
  (Tls.RecordLayer), the handshake (Tls.Handshake) and the interface
  programs use (Tls.Client): the options it was made with, the keys of
  each direction, the buffers, and how it failed.

  A connection fails once: the first error is kept, the matching alert
  is sent to the server if the connection still carries anything, and
  every later call returns the same error.
}
unit Tls.Connections;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Tls.ByteBuffers,
  Tls.Constants,
  Tls.Certificates,
  Tls.CipherSuites,
  Tls.KeySchedule,
  Tls.RecordProtection,
  Tls.Transcript,
  Tls.Transport,
  Tls.TrustStore;

const
  { A whole protected record, and room to spare. }
  InputBufferSize = RecordHeaderLength + MaximumCiphertextLength + 64;

type
  TTlsClientOptions = record
    { The host: sent as server_name (unless it is an IP address) and
      checked against the certificate. }
    ServerName: string;
    { The roots; needed when VerifyCertificates is set. }
    TrustStore: PTlsTrustStore;
    VerifyCertificates: Boolean;
    { Unix seconds, for the certificates' validity. }
    VerificationTime: Int64;
    { One ALPN protocol name ("http/1.1"), or empty. }
    ApplicationProtocol: string;
    { Count 0: the default list. }
    CipherSuites: TCipherSuiteList;
  end;

  TTlsConnectionState = (ConnectionNew, ConnectionHandshaking, ConnectionOpen, ConnectionClosed, ConnectionFailed);

  TTlsConnection = record
    Transport: TTlsTransport;
    Options: TTlsClientOptions;
    State: TTlsConnectionState;

    Error: LongInt;
    { The alert the server sent, or -1. }
    ReceivedAlert: LongInt;
    { More about Error (which certificate, ...), or empty. }
    ErrorDetail: string;
    { What the chain check said when certificates are not verified. }
    IgnoredCertificateError: LongInt;

    Suite: TCipherSuiteInfo;
    Schedule: TTlsKeySchedule;
    Transcript: TTlsTranscript;
    ReadProtection: TRecordProtection;
    WriteProtection: TRecordProtection;
    { change_cipher_spec records are dropped between the ClientHello and
      the server's Finished (RFC 8446 section 5). }
    AllowChangeCipherSpec: Boolean;
    { The first ClientHello goes in a record marked TLS 1.0. }
    FirstRecordSent: Boolean;

    { Received bytes not yet made into records. }
    Input: PByte;
    InputStart: PtrUInt;
    InputEnd: PtrUInt;
    { A record being sent. }
    Output: PByte;
    { Handshake messages being put together, and how much of the front
      the last message handed out takes. }
    HandshakeBuffer: TTlsBuilder;
    HandshakeConsumed: PtrUInt;
    { Application data received and not yet read. }
    Plain: PByte;
    PlainStart: PtrUInt;
    PlainEnd: PtrUInt;

    { The stream from the server ended; with its close_notify or not. }
    PeerClosed: Boolean;
    CloseNotifyReceived: Boolean;
    CloseNotifySent: Boolean;

    { The server's certificates as it sent them, its own first. }
    ServerCertificates: array of PTlsCertificate;
    { The ALPN protocol the server chose, or empty. }
    SelectedProtocol: string;
  end;
  PTlsConnection = ^TTlsConnection;

function AllocateConnection(constref Transport: TTlsTransport; constref Options: TTlsClientOptions): PTlsConnection;
procedure ReleaseConnection(var Connection: PTlsConnection);

{ Fails the connection with Error (if it had not failed already) and
  returns the error it failed with. }
function FailConnection(Connection: PTlsConnection; Error: LongInt): LongInt;
procedure SetErrorDetail(Connection: PTlsConnection; const Text: string);

implementation

uses
  Crypto.Bits,
  Tls.Errors,
  Tls.RecordLayer;

function AllocateConnection(constref Transport: TTlsTransport; constref Options: TTlsClientOptions): PTlsConnection;
var
  Connection: PTlsConnection;
begin
  { Zeroed memory is also an empty string and an empty array. }
  Connection := AllocMem(SizeOf(TTlsConnection));
  Connection^.Transport := Transport;
  Connection^.Options := Options;
  if Connection^.Options.CipherSuites.Count = 0 then
    DefaultCipherSuites(Connection^.Options.CipherSuites);
  Connection^.State := ConnectionNew;
  Connection^.ReceivedAlert := -1;
  Connection^.IgnoredCertificateError := TlsErrorNone;
  Connection^.Input := GetMem(InputBufferSize);
  Connection^.Output := GetMem(InputBufferSize);
  Connection^.Plain := GetMem(MaximumPlaintextLength + 256);
  InitializeBuilder(Connection^.HandshakeBuffer);
  InitializeTranscript(Connection^.Transcript);
  Result := Connection;
end;

procedure ReleaseConnection(var Connection: PTlsConnection);
var
  Index: Integer;
begin
  if Connection = nil then
    Exit;
  for Index := 0 to High(Connection^.ServerCertificates) do
    FreeCertificate(Connection^.ServerCertificates[Index]);
  FreeBuilder(Connection^.HandshakeBuffer);
  FreeTranscript(Connection^.Transcript);
  WipeKeySchedule(Connection^.Schedule);
  WipeRecordProtection(Connection^.ReadProtection);
  WipeRecordProtection(Connection^.WriteProtection);
  WipeMemory(Connection^.Input, InputBufferSize);
  WipeMemory(Connection^.Output, InputBufferSize);
  WipeMemory(Connection^.Plain, MaximumPlaintextLength + 256);
  FreeMem(Connection^.Input);
  FreeMem(Connection^.Output);
  FreeMem(Connection^.Plain);
  Finalize(Connection^);
  FreeMem(Connection);
  Connection := nil;
end;

function FailConnection(Connection: PTlsConnection; Error: LongInt): LongInt;
var
  Alert: LongInt;
begin
  if Connection^.State = ConnectionFailed then
    Exit(Connection^.Error);
  Connection^.Error := Error;
  Connection^.State := ConnectionFailed;
  { Nothing goes to a peer that is gone or that sent the alert. }
  if (Error <> TlsErrorTransportFailed) and (Error <> TlsErrorTimedOut) and (Error <> TlsErrorConnectionClosed) and
     (Error <> TlsErrorAlertReceived) then
  begin
    Alert := TlsAlertForError(Error);
    if Alert >= 0 then
      SendAlert(Connection, Alert);
  end;
  Result := Error;
end;

procedure SetErrorDetail(Connection: PTlsConnection; const Text: string);
begin
  Connection^.ErrorDetail := Text;
end;

end.
