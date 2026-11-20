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
  libhttp's client against scripts/test-web-server.py in its https-h2
  mode (the HTTP/2 server QEMU's wget test uses), over a host TCP
  socket and libtls (run-interop.sh starts the server, "HttpTest
  interop PORT" runs this): HTTP/2 chosen by ALPN, a body larger than
  the server's first window, keep-alive, Digest, gzip, cookies across a
  redirect, a range, and HTTP/1.1 when HTTP/2 is not offered.
}
unit HttpTest.Interop;

{$mode objfpc}
{$H+}

interface

procedure TestInterop(Port: Word);

implementation

uses
  Sockets,
  BaseUnix,
  SysUtils,
  DateUtils,
  TestChecks,
  Tls.Client,
  Tls.Connections,
  Tls.Errors,
  Tls.Transport,
  Http.Authentication,
  Http.BodySinks,
  Http.Client,
  Http.Connectors,
  Http.Cookies,
  Http.Messages,
  Http.Observers,
  Http.Results,
  Http.Transports,
  Url.Records;

type
  THostSocket = record
    Handle: LongInt;
  end;
  PHostSocket = ^THostSocket;

  THostTlsTransport = class(THttpTransport)
  private
    FSocket: THostSocket;
    FConnection: PTlsConnection;
  public
    function Open(Port: Word; AllowHttp2: Boolean): THttpResult;
    destructor Destroy; override;
    function Read(Buffer: Pointer; Count: PtrUInt): Int64; override;
    function Write(Buffer: Pointer; Count: PtrUInt): Boolean; override;
    procedure Shutdown; override;
    procedure Close; override;
  end;

  THostConnector = class(THttpConnector)
  public
    Port: Word;
    Connects: Integer;
    function Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings; Observer: THttpClientObserver;
      out Transport: THttpTransport): THttpResult; override;
  end;

function SendOnHostSocket(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
var
  Done: PtrUInt;
  Sent: ssize_t;
begin
  Done := 0;
  while Done < Length do
  begin
    Sent := fpSend(PHostSocket(Context)^.Handle, Buffer + Done, Length - Done, 0);
    if Sent <= 0 then
      Exit(TlsErrorTransportFailed);
    Done := Done + PtrUInt(Sent);
  end;
  Result := Length;
end;

function ReceiveOnHostSocket(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
var
  Received: ssize_t;
begin
  Received := fpRecv(PHostSocket(Context)^.Handle, Buffer, Length, 0);
  if Received < 0 then
    Exit(TlsErrorTransportFailed);
  Result := Received;
end;

function THostTlsTransport.Open(Port: Word; AllowHttp2: Boolean): THttpResult;
var
  Address: TInetSockAddr;
  Transport: TTlsTransport;
  Options: TTlsClientOptions;
  Error: LongInt;
begin
  FSocket.Handle := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := htons(Port);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  if fpConnect(FSocket.Handle, @Address, SizeOf(Address)) <> 0 then
    Exit(HttpFailure(HttpConnectFailed, 'cannot connect'));
  Transport.Context := @FSocket;
  Transport.Send := @SendOnHostSocket;
  Transport.Receive := @ReceiveOnHostSocket;
  Options := Default(TTlsClientOptions);
  Options.ServerName := 'localhost';
  Options.VerifyCertificates := False;
  Options.VerificationTime := DateTimeToUnix(Now, False);
  if AllowHttp2 then
    Options.ApplicationProtocol := 'h2,http/1.1'
  else
    Options.ApplicationProtocol := 'http/1.1';
  Error := CreateTlsClient(Transport, Options, FConnection);
  if Error = TlsErrorNone then
    Error := TlsHandshake(FConnection);
  if Error <> TlsErrorNone then
    Exit(HttpFailure(HttpTlsFailed, TlsErrorDescription(FConnection, Error), Error));
  FNegotiatedProtocol := TlsSelectedProtocol(FConnection);
  Result := HttpOk;
end;

destructor THostTlsTransport.Destroy;
begin
  Close;
  inherited Destroy;
end;

function THostTlsTransport.Read(Buffer: Pointer; Count: PtrUInt): Int64;
begin
  Result := TlsRead(FConnection, Buffer, Count);
  if Result < 0 then
  begin
    SetFailure(TransportFailureTls, Result, TlsErrorDescription(FConnection, Result));
    Result := -1;
  end;
end;

function THostTlsTransport.Write(Buffer: Pointer; Count: PtrUInt): Boolean;
begin
  Result := TlsWrite(FConnection, Buffer, Count) = Int64(Count);
  if not Result then
    SetFailure(TransportFailureTls, TlsErrorTransportFailed, 'the TLS connection failed');
end;

procedure THostTlsTransport.Shutdown;
begin
  fpShutdown(FSocket.Handle, 2);
end;

procedure THostTlsTransport.Close;
begin
  if FConnection <> nil then
  begin
    TlsClose(FConnection);
    FreeTlsClient(FConnection);
    CloseSocket(FSocket.Handle);
  end;
end;

function THostConnector.Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings;
  Observer: THttpClientObserver; out Transport: THttpTransport): THttpResult;
var
  Secure: THostTlsTransport;
begin
  Inc(Connects);
  Secure := THostTlsTransport.Create;
  Result := Secure.Open(Port, Settings.AllowHttp2);
  if HttpSucceeded(Result) then
    Transport := Secure
  else
  begin
    Transport := nil;
    Secure.Free;
  end;
end;

function Fetch(Client: THttpClient; const Path: string; out Response: THttpResponse; const Range: string = ''): string;
var
  Request: THttpRequest;
  Sink: THttpMemorySink;
  Outcome: THttpResult;
begin
  THttpRequest.FromText('GET', 'https://localhost' + Path, Request);
  if Range <> '' then
    Request.Headers.Add('range', Range);
  Sink := THttpMemorySink.Create;
  try
    Outcome := Client.Fetch(Request, Sink, Response);
    if HttpSucceeded(Outcome) then
      Result := Sink.Text
    else
      Result := 'FAILED: ' + Outcome.Text;
  finally
    Sink.Free;
    Request.Free;
  end;
end;

function DataIsRight(const Data: string): Boolean;
var
  Index: Integer;
begin
  if Length(Data) <> 200000 then
    Exit(False);
  for Index := 0 to 199999 do
    if Ord(Data[Index + 1]) <> (Index * 7 + Index div 256) mod 256 then
      Exit(False);
  Result := True;
end;

procedure TestInterop(Port: Word);
var
  Connector: THostConnector;
  Client: THttpClient;
  Settings: THttpClientSettings;
  Response: THttpResponse;
  Text, First: string;
  Jar: TCookieJar;
  Authenticator: TAuthenticator;
begin
  Connector := THostConnector.Create;
  Connector.Port := Port;
  Client := THttpClient.Create(DefaultClientSettings, Connector, True);
  Jar := TCookieJar.Create;
  Authenticator := TAuthenticator.Create('user', 'secret', True);
  try
    Text := Fetch(Client, '/hello.txt', Response);
    Check((Text = 'Hello from the FreePascalOS test server'#10) and (Response.Version = 20), 'interop: HTTP/2 GET');
    Response.Free;
    Text := Fetch(Client, '/data.bin', Response);
    Check(DataIsRight(Text), 'interop: 200000 bytes over HTTP/2');
    Response.Free;
    First := Fetch(Client, '/count', Response);
    Response.Free;
    Text := Fetch(Client, '/count', Response);
    Response.Free;
    Check((StrToIntDef(Trim(Text), 0) = StrToIntDef(Trim(First), -1) + 1) and (Connector.Connects = 1),
      'interop: every request on one connection');
    Text := Fetch(Client, '/gzip.txt', Response);
    Check(Copy(Text, Length(Text) - 33, MaxInt) = 'line 100 of the compressible text'#10, 'interop: gzip decoded');
    Response.Free;
    Text := Fetch(Client, '/data.bin', Response, 'bytes=199990-');
    Check((Response.Status = 206) and (Length(Text) = 10), 'interop: a range');
    Response.Free;
    Client.Authenticator := Authenticator;
    Text := Fetch(Client, '/digest', Response);
    Check(Text = 'digest ok'#10, 'interop: Digest');
    Response.Free;
    Client.Cookies := Jar;
    Text := Fetch(Client, '/cookie/redirect', Response);
    Check(Text = 'session=abc123; persistent=yes'#10, 'interop: cookies across a redirect');
    Response.Free;
  finally
    Client.Free;
    Jar.Free;
    Authenticator.Free;
  end;
  Connector := THostConnector.Create;
  Connector.Port := Port;
  Settings := DefaultClientSettings;
  Settings.AllowHttp2 := False;
  Client := THttpClient.Create(Settings, Connector, True);
  try
    Text := Fetch(Client, '/hello.txt', Response);
    Check((Text = 'Hello from the FreePascalOS test server'#10) and (Response.Version = 11),
      'interop: HTTP/1.1 when HTTP/2 is not offered');
    Response.Free;
  finally
    Client.Free;
  end;
end;

end.
