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
  A QUIC connection to a host and port, the way programs open one:

    Session := TQuicSession.Create;
    try
      Error := Session.Open('example.org', 443);
      if Error <> QuicErrorNone then
        ... Session.DescribeError(Error) ...
      ... Session.Connection (a TQuicConnection) ...
    finally
      Session.Free;
    end;

  The host is resolved (both families, in the order Sys.HostLookup
  gives) and each address is tried in turn with a UDP socket connected
  to it until a handshake completes; the server's certificate is
  checked against the system's roots (or a PEM file) at the system
  clock's time unless told not to, for ServerName when set (an
  alternative service of another host serves the origin's name), else
  for the host. Address validation tokens from the
  server's NEW_TOKEN are kept in the process (by "host:port") for the
  next session to the same server. Freeing the session closes the
  connection (CONNECTION_CLOSE) and the socket.
}
unit Quic.Sessions;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Tls.CipherSuites,
  Quic.Connections,
  Quic.ConnectionState,
  Quic.UdpSockets;

type
  TQuicSession = class
  private
    FSocket: TQuicUdpSocket;
    FConnection: TQuicConnection;
    FStore: Pointer;
    FApplicationProtocol: string;
    FServerName: string;
    FVerifyCertificates: Boolean;
    FTrustFile: string;
    FHasTrustFile: Boolean;
    FCipherSuites: TCipherSuiteList;
    FTimeoutMilliseconds: Int64;
    FMaximumDatagramSize: Integer;
    FAddressText: string;
    FCacheKey: string;
    FSystemError: LongInt;
    procedure SetTrustFile(const Value: string);
    procedure Release;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(const Host: string; Port: Word): LongInt;
    function DescribeError(Error: LongInt): string;
    { nil until Open succeeded. }
    property Connection: TQuicConnection read FConnection;
    { "h3" unless set. }
    property ApplicationProtocol: string read FApplicationProtocol write FApplicationProtocol;
    { The name for TLS (server_name, the certificate check); '' for the
      host given to Open. }
    property ServerName: string read FServerName write FServerName;
    property VerifyCertificates: Boolean read FVerifyCertificates write FVerifyCertificates;
    property TrustFile: string read FTrustFile write SetTrustFile;
    property CipherSuites: TCipherSuiteList read FCipherSuites write FCipherSuites;
    { For the handshake and every wait; 30 s unless set. }
    property TimeoutMilliseconds: Int64 read FTimeoutMilliseconds write FTimeoutMilliseconds;
    { 0: 1200 bytes, with path MTU probing up to 1452. }
    property MaximumDatagramSize: Integer read FMaximumDatagramSize write FMaximumDatagramSize;
    { The address the connection went to. }
    property AddressText: string read FAddressText;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.HostLookup,
  Sys.HostNames,
  Sys.InternetAddresses,
  Sys.Locks,
  Sys.Time,
  Tls.SystemTrust,
  Tls.TrustStore,
  Quic.DatagramTransports,
  Quic.Errors;

type
  TTokenEntry = record
    Key: string;
    Token: TBytes;
  end;

var
  TokenCache: array of TTokenEntry;
  TokenLock: TLock;

function TakeToken(const Key: string): TBytes;
var
  Index: Integer;
begin
  Result := nil;
  AcquireLock(TokenLock);
  try
    for Index := 0 to High(TokenCache) do
      if TokenCache[Index].Key = Key then
      begin
        Result := TokenCache[Index].Token;
        Delete(TokenCache, Index, 1);
        Exit;
      end;
  finally
    ReleaseLock(TokenLock);
  end;
end;

procedure KeepToken(const Key: string; const Token: TBytes);
var
  Index: Integer;
begin
  if Length(Token) = 0 then
    Exit;
  AcquireLock(TokenLock);
  try
    for Index := 0 to High(TokenCache) do
      if TokenCache[Index].Key = Key then
      begin
        TokenCache[Index].Token := Token;
        Exit;
      end;
    { A few servers' tokens at most. }
    if Length(TokenCache) >= 16 then
      Delete(TokenCache, 0, 1);
    SetLength(TokenCache, Length(TokenCache) + 1);
    TokenCache[High(TokenCache)].Key := Key;
    TokenCache[High(TokenCache)].Token := Token;
  finally
    ReleaseLock(TokenLock);
  end;
end;

constructor TQuicSession.Create;
begin
  inherited Create;
  FSocket.Socket := -1;
  FApplicationProtocol := 'h3';
  FVerifyCertificates := True;
  FTimeoutMilliseconds := 30000;
end;

destructor TQuicSession.Destroy;
var
  Store: PTlsTrustStore;
begin
  Release;
  Store := PTlsTrustStore(FStore);
  FreeTrustStore(Store);
  inherited Destroy;
end;

procedure TQuicSession.Release;
begin
  if FConnection <> nil then
  begin
    if FCacheKey <> '' then
      KeepToken(FCacheKey, FConnection.NewToken);
    FreeAndNil(FConnection);
  end;
  CloseUdpSocket(FSocket);
end;

procedure TQuicSession.SetTrustFile(const Value: string);
begin
  FTrustFile := Value;
  FHasTrustFile := True;
end;

function TQuicSession.Open(const Host: string; Port: Word): LongInt;
var
  Addresses: TInternetAddressArray;
  Store: PTlsTrustStore;
  Options: TQuicConnectionOptions;
  Transport: TQuicDatagramTransport;
  Index: Integer;
begin
  if FConnection <> nil then
    Exit(QuicErrorInvalidArgument);
  Store := nil;
  if FHasTrustFile then
    Result := LoadTrustStoreFile(FTrustFile, Store)
  else
    Result := LoadSystemTrustStore(Store);
  FStore := Store;
  if (Result <> 0) and FVerifyCertificates then
    Exit(QuicErrorHandshakeFailed);
  FSystemError := ResolveHost(Host, HostFamilyAny, Addresses);
  if (FSystemError <> ErrorNone) or (Length(Addresses) = 0) then
    Exit(QuicErrorHostNotFound);
  FCacheKey := LowerCase(Host) + ':' + IntToStr(Port);
  Options := Default(TQuicConnectionOptions);
  Options.ServerName := FServerName;
  if Options.ServerName = '' then
    Options.ServerName := Host;
  Options.ApplicationProtocol := FApplicationProtocol;
  Options.TrustStore := Store;
  Options.VerifyCertificates := FVerifyCertificates;
  Options.VerificationTime := CurrentTime;
  Options.CipherSuites := FCipherSuites;
  Options.HandshakeTimeout := FTimeoutMilliseconds;
  Options.IdleTimeout := 30000;
  Options.MaximumDatagramSize := FMaximumDatagramSize;
  Options.ProbePathMtu := FMaximumDatagramSize = 0;
  Options.Token := TakeToken(FCacheKey);
  Result := QuicErrorHostNotFound;
  for Index := 0 to High(Addresses) do
  begin
    Release;
    Result := OpenUdpSocket(Addresses[Index], Port, FSocket);
    if Result <> QuicErrorNone then
    begin
      FSystemError := FSocket.LastSystemError;
      Continue;
    end;
    MakeUdpTransport(@FSocket, Transport);
    FConnection := TQuicConnection.Create(Transport, Options);
    FConnection.Timeout := FTimeoutMilliseconds;
    Result := FConnection.Connect;
    FAddressText := AddressToText(Addresses[Index]);
    if Result = QuicErrorNone then
      Exit;
    { A certificate or protocol failure is the server's answer; another
      address would say the same. }
    if (Result = QuicErrorHandshakeFailed) or (Result = QuicErrorClosedByPeer) or
       (Result = QuicErrorVersionNegotiation) then
      Exit;
    FSystemError := FSocket.LastSystemError;
  end;
end;

function TQuicSession.DescribeError(Error: LongInt): string;
begin
  if Error = QuicErrorHostNotFound then
    Exit(QuicErrorMessage(Error) + ' (' + HostLookupErrorMessage(FSystemError) + ')');
  if FConnection <> nil then
    Result := FConnection.ErrorDescription(Error)
  else
    Result := QuicErrorMessage(Error);
  if (Error = QuicErrorTransportFailed) and (FSystemError <> 0) then
    Result := Result + ' (' + string(ErrorMessage(FSystemError)) + ')';
end;

end.
