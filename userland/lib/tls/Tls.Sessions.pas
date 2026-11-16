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

    Session := TTlsSocketSession.Create;
    try
      Session.ServerName := 'example.com';
      Error := Session.Open(Socket);
      if Error <> TlsErrorNone then
        ... Session.DescribeError(Error) ...
      Session.Write(Request, Length);
      Count := Session.Read(@Buffer, SizeOf(Buffer));
      Session.Close;
    finally
      Session.Free;
    end;

  The session checks the server's certificate against the system's
  roots (or a PEM file the program names) at the system clock's time,
  unless told not to. The socket stays the program's: closing the
  session sends close_notify but leaves the socket open.
}
unit Tls.Sessions;

{$mode objfpc}
{$H+}

interface

uses
  Tls.CipherSuites,
  Tls.ClientConnections,
  Tls.Connections,
  Tls.SocketTransport,
  Tls.TrustStore;

type
  TTlsSocketSession = class
  private
    FServerName: string;
    FVerifyCertificates: Boolean;
    FTrustFile: string;
    FHasTrustFile: Boolean;
    FTimeoutMilliseconds: Int64;
    FApplicationProtocol: string;
    FCipherSuites: TCipherSuiteList;
    FTransportContext: TSocketTransportContext;
    FStore: PTlsTrustStore;
    FClient: TTlsClientConnection;
    procedure SetTrustFile(const Value: string);
    function GetConnection: PTlsConnection;
  public
    constructor Create;
    destructor Destroy; override;
    { Loads the roots, makes the connection and runs the handshake. }
    function Open(Socket: Int64): LongInt;
    function Read(Buffer: Pointer; Length: PtrUInt): Int64;
    function Write(Buffer: Pointer; Length: PtrUInt): Int64;
    function Close: LongInt;
    function DescribeError(Error: LongInt): string;
    { With VerifyCertificates off: what the check would have refused. }
    function IgnoredCertificateError: LongInt;
    property ServerName: string read FServerName write FServerName;
    { On unless turned off. }
    property VerifyCertificates: Boolean read FVerifyCertificates write FVerifyCertificates;
    { A PEM file of trusted certificates instead of the system's (once
      set, even to '', it is the one read). }
    property TrustFile: string read FTrustFile write SetTrustFile;
    { For each wait on the server; 0: no limit. }
    property TimeoutMilliseconds: Int64 read FTimeoutMilliseconds write FTimeoutMilliseconds;
    property ApplicationProtocol: string read FApplicationProtocol write FApplicationProtocol;
    { Count 0: the default. }
    property CipherSuites: TCipherSuiteList read FCipherSuites write FCipherSuites;
    { nil until Open has made the connection. }
    property Client: TTlsClientConnection read FClient;
    property Connection: PTlsConnection read GetConnection;
  end;

implementation

uses
  SysUtils,
  Sys.Time,
  Tls.Client,
  Tls.Errors,
  Tls.SystemTrust,
  Tls.Transport;

constructor TTlsSocketSession.Create;
begin
  inherited Create;
  FVerifyCertificates := True;
end;

destructor TTlsSocketSession.Destroy;
begin
  FClient.Free;
  FreeTrustStore(FStore);
  inherited Destroy;
end;

procedure TTlsSocketSession.SetTrustFile(const Value: string);
begin
  FTrustFile := Value;
  FHasTrustFile := True;
end;

function TTlsSocketSession.GetConnection: PTlsConnection;
begin
  Result := nil;
  if FClient <> nil then
    Result := FClient.Connection;
end;

function TTlsSocketSession.Open(Socket: Int64): LongInt;
var
  Transport: TTlsTransport;
  ClientOptions: TTlsClientOptions;
begin
  if FClient <> nil then
    Exit(TlsErrorInvalidArgument);
  if FHasTrustFile then
    Result := LoadTrustStoreFile(FTrustFile, FStore)
  else
    Result := LoadSystemTrustStore(FStore);
  { Without roots only an unchecked connection can go ahead. }
  if (Result <> TlsErrorNone) and FVerifyCertificates then
    Exit;
  MakeSocketTransport(@FTransportContext, Socket, FTimeoutMilliseconds, Transport);
  ClientOptions := Default(TTlsClientOptions);
  ClientOptions.ServerName := FServerName;
  ClientOptions.TrustStore := FStore;
  ClientOptions.VerifyCertificates := FVerifyCertificates;
  ClientOptions.VerificationTime := CurrentTime;
  ClientOptions.ApplicationProtocol := FApplicationProtocol;
  ClientOptions.CipherSuites := FCipherSuites;
  try
    FClient := TTlsClientConnection.Create(Transport, ClientOptions);
  except
    on Error: ETlsError do
      Exit(Error.Code);
  end;
  Result := FClient.Handshake;
end;

function TTlsSocketSession.Read(Buffer: Pointer; Length: PtrUInt): Int64;
begin
  if FClient = nil then
    Exit(TlsErrorInvalidArgument);
  Result := FClient.Read(Buffer, Length);
end;

function TTlsSocketSession.Write(Buffer: Pointer; Length: PtrUInt): Int64;
begin
  if FClient = nil then
    Exit(TlsErrorInvalidArgument);
  Result := FClient.Write(Buffer, Length);
end;

function TTlsSocketSession.Close: LongInt;
begin
  if FClient = nil then
    Exit(TlsErrorInvalidArgument);
  Result := FClient.Close;
end;

function TTlsSocketSession.DescribeError(Error: LongInt): string;
begin
  Result := TlsErrorDescription(GetConnection, Error);
end;

function TTlsSocketSession.IgnoredCertificateError: LongInt;
begin
  Result := TlsIgnoredCertificateError(GetConnection);
end;

end.
