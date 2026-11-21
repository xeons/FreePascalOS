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
  A transport over a connected TCP socket, with TLS for https (libtls's
  TTlsSocketSession: the system's roots or a trust file, ALPN "h2" and
  "http/1.1" or "http/1.1" alone, the session ticket cache keyed by
  host and port). Reads wait at most the timeout (the socket's wait,
  or libtls's), Shutdown ends the socket so a blocked read returns.

  FreePascalOS only (sockets and TLS sessions).
}
unit Http.SocketTransports;

{$mode objfpc}
{$H+}

interface

uses
  Tls.Sessions,
  Http.Observers,
  Http.Results,
  Http.Transports;

type
  THttpSocketTransport = class(THttpTransport)
  private
    FSocket: Int64;
    FSession: TTlsSocketSession;
  public
    { Takes over a connected socket. }
    constructor Create(Socket: Int64; Timeout: Int64);
    destructor Destroy; override;
    { TLS over the socket. A certificate failure is HttpCertificateFailed. }
    function StartTls(const ServerName: string; Port: Word; constref Settings: THttpClientSettings;
      Observer: THttpClientObserver): THttpResult;
    function Read(Buffer: Pointer; Count: PtrUInt): Int64; override;
    function Write(Buffer: Pointer; Count: PtrUInt): Boolean; override;
    procedure Shutdown; override;
    procedure Close; override;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Sockets,
  Tls.Errors,
  Tls.Certificates,
  Tls.CertificateSummaries,
  Tls.Connections,
  Http.ConnectionSecurity;

function TlsVersionName(Version: Word): string;
begin
  case Version of
    $0304: Result := 'TLS 1.3';
    $0303: Result := 'TLS 1.2';
    $0302: Result := 'TLS 1.1';
    $0301: Result := 'TLS 1.0';
  else
    Result := 'TLS';
  end;
end;

{ What the handshake that just succeeded was (Http.ConnectionSecurity). }
procedure NoteConnectionSecurity(Session: TTlsSocketSession; const ServerName: string; Port: Word);
var
  Info: THttpConnectionSecurity;
  Connection: PTlsConnection;
  Index, Count: Integer;
  IssuerSent: Boolean;
begin
  Connection := Session.Connection;
  if Connection = nil then
    Exit;
  Info := Default(THttpConnectionSecurity);
  Info.Secure := True;
  Info.Host := ServerName;
  Info.Port := Port;
  Info.Protocol := TlsVersionName(Connection^.Version);
  if Session.Client <> nil then
    Info.Cipher := Session.Client.CipherSuiteName;
  Count := Length(Connection^.ServerCertificates);
  IssuerSent := Connection^.ServerIssuer = nil;
  SetLength(Info.Chain, Count);
  for Index := 0 to Count - 1 do
  begin
    Info.Chain[Index] := SummarizeCertificate(Connection^.ServerCertificates[Index]^);
    if Connection^.ServerCertificates[Index] = Connection^.ServerIssuer then
      IssuerSent := True;
  end;
  if not IssuerSent then
  begin
    SetLength(Info.Chain, Count + 1);
    Info.Chain[Count] := SummarizeCertificate(Connection^.ServerIssuer^);
  end;
  RecordConnectionSecurity(Info);
end;

const
  TimeoutText = 'Connection timed out';

constructor THttpSocketTransport.Create(Socket: Int64; Timeout: Int64);
begin
  inherited Create;
  FSocket := Socket;
  FTimeoutMilliseconds := Timeout;
end;

destructor THttpSocketTransport.Destroy;
begin
  Close;
  inherited Destroy;
end;

function THttpSocketTransport.StartTls(const ServerName: string; Port: Word; constref Settings: THttpClientSettings;
  Observer: THttpClientObserver): THttpResult;
var
  Error, Ignored: LongInt;
begin
  FSession := TTlsSocketSession.Create;
  FSession.ServerName := ServerName;
  FSession.Port := Port;
  FSession.VerifyCertificates := Settings.VerifyCertificates;
  if Settings.HasTrustFile then
    FSession.TrustFile := Settings.TrustFile;
  FSession.TimeoutMilliseconds := FTimeoutMilliseconds;
  if Settings.AllowHttp2 then
    FSession.ApplicationProtocol := 'h2,http/1.1'
  else
    FSession.ApplicationProtocol := 'http/1.1';
  FSession.CipherSuites := Settings.CipherSuites;
  Error := FSession.Open(FSocket);
  if Error <> TlsErrorNone then
  begin
    if TlsErrorIsCertificateError(Error) then
      Exit(HttpFailure(HttpCertificateFailed, FSession.DescribeError(Error), Error));
    if Error = TlsErrorTimedOut then
      Exit(HttpFailure(HttpTimedOut, FSession.DescribeError(Error), Error));
    Exit(HttpFailure(HttpTlsFailed, FSession.DescribeError(Error), Error));
  end;
  Ignored := FSession.IgnoredCertificateError;
  if (Ignored <> TlsErrorNone) and (Observer <> nil) then
    Observer.CertificateNotVerified(ServerName, FSession.DescribeError(Ignored));
  if FSession.Client <> nil then
    FNegotiatedProtocol := FSession.Client.SelectedProtocol;
  NoteConnectionSecurity(FSession, ServerName, Port);
  Result := HttpOk;
end;

function THttpSocketTransport.Read(Buffer: Pointer; Count: PtrUInt): Int64;
var
  Waited: Int64;
begin
  if FSocket < 0 then
    Exit(0);
  if FSession <> nil then
  begin
    Result := FSession.Read(Buffer, Count);
    if Result < 0 then
    begin
      if Result = TlsErrorTimedOut then
        SetFailure(TransportFailureTimeout, LongInt(Result), TimeoutText)
      else
        SetFailure(TransportFailureTls, LongInt(Result), FSession.DescribeError(LongInt(Result)));
      Result := -1;
    end;
    Exit;
  end;
  if FTimeoutMilliseconds > 0 then
  begin
    Waited := WaitForSocket(FSocket, SocketReadable, FTimeoutMilliseconds);
    if Waited < 0 then
    begin
      if ErrorCodeOf(Waited) = ErrorTimedOut then
        SetFailure(TransportFailureTimeout, ErrorTimedOut, TimeoutText)
      else
        SetFailure(TransportFailureTransfer, ErrorCodeOf(Waited), ErrorMessage(ErrorCodeOf(Waited)));
      Exit(-1);
    end;
  end;
  Result := ReceiveOnSocket(FSocket, Buffer, Count, 0);
  if Result < 0 then
  begin
    SetFailure(TransportFailureTransfer, ErrorCodeOf(Result), ErrorMessage(ErrorCodeOf(Result)));
    Result := -1;
  end;
end;

function THttpSocketTransport.Write(Buffer: Pointer; Count: PtrUInt): Boolean;
var
  Error: LongInt;
begin
  if FSocket < 0 then
  begin
    SetFailure(TransportFailureClosed, ErrorBadHandle, 'the connection is closed');
    Exit(False);
  end;
  if FSession <> nil then
  begin
    Result := FSession.Write(Buffer, Count) = Int64(Count);
    if not Result then
      SetFailure(TransportFailureTls, TlsErrorTransportFailed, 'the TLS connection failed');
    Exit;
  end;
  Error := SendAll(FSocket, Buffer, Count);
  Result := Error = ErrorNone;
  if not Result then
    SetFailure(TransportFailureTransfer, Error, ErrorMessage(Error));
end;

procedure THttpSocketTransport.Shutdown;
begin
  if FSocket >= 0 then
    ShutdownSocket(FSocket, SocketShutdownBoth);
end;

procedure THttpSocketTransport.Close;
begin
  if FSession <> nil then
  begin
    FSession.Close;
    FreeAndNil(FSession);
  end;
  if FSocket >= 0 then
    CloseSocket(FSocket);
  FSocket := -1;
end;

end.
