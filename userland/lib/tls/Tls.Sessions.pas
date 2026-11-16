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
  TLS over a connected socket, the way programs use it:

    InitializeTlsSessionOptions(Options);
    Options.ServerName := 'example.com';
    Error := OpenTlsSession(Socket, Options, Session);
    if Error <> TlsErrorNone then
      ... DescribeTlsSessionError(Session, Error, Buffer, SizeOf(Buffer)) ...
    WriteTlsSession(Session, Request, Length);
    Count := ReadTlsSession(Session, @Buffer, SizeOf(Buffer));
    CloseTlsSession(Session);
    FreeTlsSession(Session);

  The session checks the server's certificate against the system's
  roots (or a PEM file the program names) at the system clock's time,
  unless told not to. The socket stays the program's: closing the
  session sends close_notify but leaves the socket open.
}
unit Tls.Sessions;

{$mode objfpc}

interface

uses
  Tls.CipherSuites,
  Tls.Connections,
  Tls.SocketTransport,
  Tls.TrustStore;

type
  TTlsSessionOptions = record
    ServerName: PChar;
    VerifyCertificates: Boolean;
    { A PEM file of trusted certificates instead of the system's. }
    TrustFile: PChar;
    { For each wait on the server; 0: no limit. }
    TimeoutMilliseconds: Int64;
    ApplicationProtocol: PChar;
    { Count 0: the default. }
    CipherSuites: TCipherSuiteList;
  end;

  TTlsSession = record
    Connection: PTlsConnection;
    TransportContext: TSocketTransportContext;
    Store: PTlsTrustStore;
  end;
  PTlsSession = ^TTlsSession;

procedure InitializeTlsSessionOptions(out Options: TTlsSessionOptions);
{ Makes the session and runs the handshake. Session is set (for
  DescribeTlsSessionError) unless memory ran out; free it either way. }
function OpenTlsSession(Socket: Int64; constref Options: TTlsSessionOptions; out Session: PTlsSession): LongInt;
function ReadTlsSession(Session: PTlsSession; Buffer: Pointer; Length: PtrUInt): Int64;
function WriteTlsSession(Session: PTlsSession; Buffer: Pointer; Length: PtrUInt): Int64;
function CloseTlsSession(Session: PTlsSession): LongInt;
procedure FreeTlsSession(var Session: PTlsSession);
function DescribeTlsSessionError(Session: PTlsSession; Error: LongInt; Buffer: PChar; Capacity: PtrUInt): PChar;

implementation

uses
  Sys.Time,
  Tls.Client,
  Tls.Errors,
  Tls.SystemTrust,
  Tls.Transport;

procedure InitializeTlsSessionOptions(out Options: TTlsSessionOptions);
begin
  FillChar(Options, SizeOf(Options), 0);
  Options.VerifyCertificates := True;
end;

function OpenTlsSession(Socket: Int64; constref Options: TTlsSessionOptions; out Session: PTlsSession): LongInt;
var
  Transport: TTlsTransport;
  ClientOptions: TTlsClientOptions;
begin
  Session := AllocMem(SizeOf(TTlsSession));
  if Session = nil then
    Exit(TlsErrorOutOfMemory);
  if Options.TrustFile <> nil then
    Result := LoadTrustStoreFile(Options.TrustFile, Session^.Store)
  else
    Result := LoadSystemTrustStore(Session^.Store);
  { Without roots only an unchecked connection can go ahead. }
  if (Result <> TlsErrorNone) and Options.VerifyCertificates then
    Exit;
  MakeSocketTransport(@Session^.TransportContext, Socket, Options.TimeoutMilliseconds, Transport);
  FillChar(ClientOptions, SizeOf(ClientOptions), 0);
  ClientOptions.ServerName := Options.ServerName;
  ClientOptions.TrustStore := Session^.Store;
  ClientOptions.VerifyCertificates := Options.VerifyCertificates;
  ClientOptions.VerificationTime := CurrentTime;
  ClientOptions.ApplicationProtocol := Options.ApplicationProtocol;
  ClientOptions.CipherSuites := Options.CipherSuites;
  Result := CreateTlsClient(Transport, ClientOptions, Session^.Connection);
  if Result <> TlsErrorNone then
    Exit;
  Result := TlsHandshake(Session^.Connection);
end;

function ReadTlsSession(Session: PTlsSession; Buffer: Pointer; Length: PtrUInt): Int64;
begin
  if (Session = nil) or (Session^.Connection = nil) then
    Exit(TlsErrorInvalidArgument);
  Result := TlsRead(Session^.Connection, Buffer, Length);
end;

function WriteTlsSession(Session: PTlsSession; Buffer: Pointer; Length: PtrUInt): Int64;
begin
  if (Session = nil) or (Session^.Connection = nil) then
    Exit(TlsErrorInvalidArgument);
  Result := TlsWrite(Session^.Connection, Buffer, Length);
end;

function CloseTlsSession(Session: PTlsSession): LongInt;
begin
  if (Session = nil) or (Session^.Connection = nil) then
    Exit(TlsErrorInvalidArgument);
  Result := TlsClose(Session^.Connection);
end;

procedure FreeTlsSession(var Session: PTlsSession);
begin
  if Session = nil then
    Exit;
  FreeTlsClient(Session^.Connection);
  FreeTrustStore(Session^.Store);
  FreeMem(Session);
  Session := nil;
end;

function DescribeTlsSessionError(Session: PTlsSession; Error: LongInt; Buffer: PChar; Capacity: PtrUInt): PChar;
var
  Connection: PTlsConnection;
begin
  Connection := nil;
  if Session <> nil then
    Connection := Session^.Connection;
  Result := TlsDescribeError(Connection, Error, Buffer, Capacity);
end;

end.
