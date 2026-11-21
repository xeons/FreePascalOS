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
  libhttp on the Linux host: a connector that looks names up with the C
  library (getaddrinfo: IPv6 and IPv4, /etc/hosts), connects over TCP
  within the timeout, and for https runs libtls over the socket with the
  host's roots (/etc/ssl/certs/ca-certificates.crt) and session
  resumption, offering "h2" when HTTP/2 is allowed. Reads wait at most
  the timeout (poll); Shutdown wakes a blocked read.

  The host counterpart of Http.SocketConnector and
  Http.SocketTransports, for tools/WebBrowse.
}
unit WebBrowse.HostNetwork;

{$mode objfpc}
{$H+}

interface

uses
  Http.Client,
  Http.Connectors,
  Http.Observers,
  Http.Results,
  Http.Transports,
  Url.Records;

type
  THostConnector = class(THttpConnector)
  public
    function Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings; Observer: THttpClientObserver;
      out Transport: THttpTransport): THttpResult; override;
  end;

{ Unix seconds now (the client's clock). }
function HostUnixTime: Int64;
function CreateHostClient(constref Settings: THttpClientSettings): THttpClient;

implementation

uses
  SysUtils,
  DateUtils,
  BaseUnix,
  Unix,
  Sockets,
  cnetdb,
  Tls.Client,
  Tls.Connections,
  Tls.Errors,
  Tls.SystemTrust,
  Tls.Transport,
  Tls.TrustStore;

type
  THostSocketContext = record
    Handle: LongInt;
    TimeoutMilliseconds: Int64;
  end;
  PHostSocketContext = ^THostSocketContext;

  THostSocketTransport = class(THttpTransport)
  private
    FContext: THostSocketContext;
    FConnection: PTlsConnection;
  public
    constructor Create(Handle: LongInt; Timeout: Int64);
    destructor Destroy; override;
    function StartTls(const ServerName: string; Port: Word; constref Settings: THttpClientSettings;
      Observer: THttpClientObserver): THttpResult;
    function Read(Buffer: Pointer; Count: PtrUInt): Int64; override;
    function Write(Buffer: Pointer; Count: PtrUInt): Boolean; override;
    procedure Shutdown; override;
    procedure Close; override;
  end;

var
  TrustLock: TRTLCriticalSection;
  SharedTrustStore: PTlsTrustStore = nil;
  TrustLoaded: Boolean = False;

function HostUnixTime: Int64;
begin
  Result := DateTimeToUnix(Now, False);
end;

function CreateHostClient(constref Settings: THttpClientSettings): THttpClient;
begin
  Result := THttpClient.Create(Settings, THostConnector.Create, True);
  Result.Clock := @HostUnixTime;
end;

function HostTrustStore: PTlsTrustStore;
begin
  EnterCriticalSection(TrustLock);
  try
    if not TrustLoaded then
    begin
      TrustLoaded := True;
      if LoadSystemTrustStore(SharedTrustStore) <> TlsErrorNone then
        SharedTrustStore := nil;
    end;
    Result := SharedTrustStore;
  finally
    LeaveCriticalSection(TrustLock);
  end;
end;

{ Waits until the socket can be read (Events POLLIN) or written; False on
  a timeout or failure. }
function WaitForHostSocket(Handle: LongInt; Events: SmallInt; TimeoutMilliseconds: Int64): Boolean;
var
  Poll: TPollFd;
  Timeout: LongInt;
  Status: LongInt;
begin
  Poll.fd := Handle;
  Poll.events := Events;
  Poll.revents := 0;
  if TimeoutMilliseconds <= 0 then
    Timeout := -1
  else
    Timeout := LongInt(TimeoutMilliseconds);
  repeat
    Status := fpPoll(@Poll, 1, Timeout);
  until (Status >= 0) or (fpgeterrno <> ESysEINTR);
  Result := Status > 0;
end;

function SendOnHostSocket(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
var
  Done: PtrUInt;
  Sent: ssize_t;
begin
  Done := 0;
  while Done < Length do
  begin
    Sent := fpSend(PHostSocketContext(Context)^.Handle, Buffer + Done, Length - Done, MSG_NOSIGNAL);
    if Sent <= 0 then
    begin
      if (Sent < 0) and (fpgeterrno = ESysEINTR) then
        Continue;
      Exit(TlsErrorTransportFailed);
    end;
    Done := Done + PtrUInt(Sent);
  end;
  Result := Length;
end;

function ReceiveOnHostSocket(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
var
  Received: ssize_t;
begin
  if not WaitForHostSocket(PHostSocketContext(Context)^.Handle, POLLIN, PHostSocketContext(Context)^.TimeoutMilliseconds) then
    Exit(TlsErrorTimedOut);
  repeat
    Received := fpRecv(PHostSocketContext(Context)^.Handle, Buffer, Length, 0);
  until (Received >= 0) or (fpgeterrno <> ESysEINTR);
  if Received < 0 then
    Exit(TlsErrorTransportFailed);
  Result := Received;
end;

constructor THostSocketTransport.Create(Handle: LongInt; Timeout: Int64);
begin
  inherited Create;
  FContext.Handle := Handle;
  FContext.TimeoutMilliseconds := Timeout;
  FTimeoutMilliseconds := Timeout;
end;

destructor THostSocketTransport.Destroy;
begin
  Close;
  inherited Destroy;
end;

function THostSocketTransport.StartTls(const ServerName: string; Port: Word; constref Settings: THttpClientSettings;
  Observer: THttpClientObserver): THttpResult;
var
  Transport: TTlsTransport;
  Options: TTlsClientOptions;
  Error, Ignored: LongInt;
begin
  Transport.Context := @FContext;
  Transport.Send := @SendOnHostSocket;
  Transport.Receive := @ReceiveOnHostSocket;
  Options := Default(TTlsClientOptions);
  Options.ServerName := ServerName;
  Options.TrustStore := HostTrustStore;
  Options.VerifyCertificates := Settings.VerifyCertificates and (Options.TrustStore <> nil);
  Options.VerificationTime := HostUnixTime;
  if Settings.AllowHttp2 then
    Options.ApplicationProtocol := 'h2,http/1.1'
  else
    Options.ApplicationProtocol := 'http/1.1';
  Options.CipherSuites := Settings.CipherSuites;
  Options.SessionCacheKey := LowerCase(ServerName) + ':' + IntToStr(Port);
  Error := CreateTlsClient(Transport, Options, FConnection);
  if Error = TlsErrorNone then
    Error := TlsHandshake(FConnection);
  if Error <> TlsErrorNone then
  begin
    if TlsErrorIsCertificateError(Error) then
      Exit(HttpFailure(HttpCertificateFailed, TlsErrorDescription(FConnection, Error), Error));
    if Error = TlsErrorTimedOut then
      Exit(HttpFailure(HttpTimedOut, TlsErrorDescription(FConnection, Error), Error));
    Exit(HttpFailure(HttpTlsFailed, TlsErrorDescription(FConnection, Error), Error));
  end;
  Ignored := TlsIgnoredCertificateError(FConnection);
  if (Ignored <> TlsErrorNone) and (Observer <> nil) then
    Observer.CertificateNotVerified(ServerName, TlsErrorDescription(FConnection, Ignored));
  FNegotiatedProtocol := TlsSelectedProtocol(FConnection);
  Result := HttpOk;
end;

function THostSocketTransport.Read(Buffer: Pointer; Count: PtrUInt): Int64;
begin
  if FContext.Handle < 0 then
    Exit(0);
  FContext.TimeoutMilliseconds := FTimeoutMilliseconds;
  if FConnection <> nil then
  begin
    Result := TlsRead(FConnection, Buffer, Count);
    if Result < 0 then
    begin
      if Result = TlsErrorTimedOut then
        SetFailure(TransportFailureTimeout, LongInt(Result), 'Connection timed out')
      else
        SetFailure(TransportFailureTls, LongInt(Result), TlsErrorDescription(FConnection, LongInt(Result)));
      Result := -1;
    end;
    Exit;
  end;
  Result := ReceiveOnHostSocket(@FContext, Buffer, Count);
  if Result < 0 then
  begin
    if Result = TlsErrorTimedOut then
      SetFailure(TransportFailureTimeout, LongInt(Result), 'Connection timed out')
    else
      SetFailure(TransportFailureTransfer, fpgeterrno, 'receive failed');
    Result := -1;
  end;
end;

function THostSocketTransport.Write(Buffer: Pointer; Count: PtrUInt): Boolean;
begin
  if FContext.Handle < 0 then
  begin
    SetFailure(TransportFailureClosed, 0, 'the connection is closed');
    Exit(False);
  end;
  if FConnection <> nil then
    Result := TlsWrite(FConnection, Buffer, Count) = Int64(Count)
  else
    Result := SendOnHostSocket(@FContext, Buffer, Count) = Int64(Count);
  if not Result then
    SetFailure(TransportFailureTransfer, 0, 'send failed');
end;

procedure THostSocketTransport.Shutdown;
begin
  if FContext.Handle >= 0 then
    fpShutdown(FContext.Handle, 2);
end;

procedure THostSocketTransport.Close;
begin
  if FConnection <> nil then
  begin
    FContext.TimeoutMilliseconds := 1000;
    TlsClose(FConnection);
    FreeTlsClient(FConnection);
  end;
  if FContext.Handle >= 0 then
    CloseSocket(FContext.Handle);
  FContext.Handle := -1;
end;

{ A non-blocking connect to one address, waited for at most the timeout. }
function ConnectAddress(Info: PAddrInfo; TimeoutMilliseconds: Int64; out Handle: LongInt): Boolean;
var
  Flags: LongInt;
  Pending: LongInt;
  Size: TSockLen;
begin
  Result := False;
  Handle := fpSocket(Info^.ai_family, SOCK_STREAM, 0);
  if Handle < 0 then
    Exit;
  Flags := fpFcntl(Handle, F_GETFL);
  fpFcntl(Handle, F_SETFL, Flags or O_NONBLOCK);
  if fpConnect(Handle, Info^.ai_addr, Info^.ai_addrlen) <> 0 then
  begin
    if fpgeterrno <> ESysEINPROGRESS then
    begin
      CloseSocket(Handle);
      Exit;
    end;
    if not WaitForHostSocket(Handle, POLLOUT, TimeoutMilliseconds) then
    begin
      CloseSocket(Handle);
      Exit;
    end;
    Pending := 0;
    Size := SizeOf(Pending);
    if (fpGetSockOpt(Handle, SOL_SOCKET, SO_ERROR, @Pending, @Size) <> 0) or (Pending <> 0) then
    begin
      CloseSocket(Handle);
      Exit;
    end;
  end;
  fpFcntl(Handle, F_SETFL, Flags and not O_NONBLOCK);
  Result := True;
end;

function AddressText(Info: PAddrInfo): string;
begin
  if Info^.ai_family = AF_INET6 then
    Result := NetAddrToStr6(PInetSockAddr6(Info^.ai_addr)^.sin6_addr)
  else
    Result := NetAddrToStr(PInetSockAddr(Info^.ai_addr)^.sin_addr);
end;

function THostConnector.Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings;
  Observer: THttpClientObserver; out Transport: THttpTransport): THttpResult;
var
  Host: string;
  Port: Word;
  Hints: TAddrInfo;
  List, Info: PAddrInfo;
  Status: LongInt;
  Handle: LongInt;
  Texts: array of string;
  Secure: THostSocketTransport;
begin
  Transport := nil;
  Host := HostNameOf(Url);
  Port := UrlEffectivePort(Url);
  Hints := Default(TAddrInfo);
  Hints.ai_family := AF_UNSPEC;
  Hints.ai_socktype := SOCK_STREAM;
  List := nil;
  if Observer <> nil then
    Observer.LookingUp(Host);
  Status := getaddrinfo(PChar(Host), PChar(IntToStr(Port)), @Hints, @List);
  if (Status <> 0) or (List = nil) then
  begin
    if Observer <> nil then
      Observer.LookUpFailed(Host, gai_strerror(Status));
    Exit(HttpFailure(HttpLookupFailed, 'unable to resolve host address ' + Host));
  end;
  try
    Texts := nil;
    Info := List;
    while Info <> nil do
    begin
      SetLength(Texts, Length(Texts) + 1);
      Texts[High(Texts)] := AddressText(Info);
      Info := Info^.ai_next;
    end;
    if Observer <> nil then
      Observer.LookedUp(Host, Texts);
    Handle := -1;
    Info := List;
    while Info <> nil do
    begin
      if Observer <> nil then
        Observer.Connecting(Host, AddressText(Info), Port);
      if ConnectAddress(Info, Settings.TimeoutMilliseconds, Handle) then
        Break;
      if Observer <> nil then
        Observer.ConnectFailed('cannot connect');
      Handle := -1;
      Info := Info^.ai_next;
    end;
  finally
    freeaddrinfo(List);
  end;
  if Handle < 0 then
    Exit(HttpFailure(HttpConnectFailed, 'cannot connect to ' + Host));
  if Observer <> nil then
    Observer.Connected;
  Secure := THostSocketTransport.Create(Handle, Settings.TimeoutMilliseconds);
  if Url.Scheme = 'https' then
  begin
    Result := Secure.StartTls(Host, Port, Settings, Observer);
    if not HttpSucceeded(Result) then
    begin
      Secure.Free;
      Exit;
    end;
  end;
  Transport := Secure;
  Result := HttpOk;
end;

initialization
  InitCriticalSection(TrustLock);
finalization
  DoneCriticalSection(TrustLock);
end.
