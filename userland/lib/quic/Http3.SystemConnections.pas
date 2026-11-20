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
  HTTP/3 for libhttp's clients on this system. libhttp does not depend
  on libquic: a program that wants HTTP/3 links libquic and calls

    EnableHttp3;                        (once: registers the factory)
    Client := CreateSystemClient(...);  (Http.SocketConnector)

  or CreateHttp3Client(Settings), which does both. From then on an https
  origin that advertised h3 by Alt-Svc is reached over QUIC
  (TQuicSession: the alternative's host, or the origin's, and port;
  the certificate checked for the origin's host with the client's
  trust settings; the handshake within the settings'
  AltServiceTimeoutMilliseconds), unless the settings say AllowHttp3 =
  False. The observer hears ConnectingAlternative, then Connected or
  ConnectFailed; the client falls back to TCP after a failure.

  FreePascalOS only.
}
unit Http3.SystemConnections;

{$mode objfpc}
{$H+}

interface

uses
  Http.AltServices,
  Http.Client,
  Http.Connections,
  Http.Observers,
  Http.Results,
  Url.Records;

{ The "h3" connection factory (THttpConnectionFactory). }
function OpenHttp3Connection(constref Url: TUrlRecord; constref Service: THttpAltService;
  constref Settings: THttpClientSettings; Observer: THttpClientObserver; out Failure: THttpResult): THttpConnection;
{ Registers OpenHttp3Connection for "h3" with libhttp. }
procedure EnableHttp3;
{ CreateSystemClient with HTTP/3 enabled. }
function CreateHttp3Client(constref Settings: THttpClientSettings): THttpClient;

implementation

uses
  SysUtils,
  Http.Connectors,
  Http.SocketConnector,
  Http3.HttpConnections,
  Quic.Errors,
  Quic.Sessions;

function FailureOf(Error: LongInt; const Text: string): THttpResult;
begin
  case Error of
    QuicErrorHostNotFound:
      Result := HttpFailure(HttpLookupFailed, Text, Error);
    QuicErrorHandshakeTimedOut, QuicErrorTimedOut, QuicErrorIdleTimeout:
      Result := HttpFailure(HttpTimedOut, Text, Error);
    QuicErrorHandshakeFailed:
      Result := HttpFailure(HttpTlsFailed, Text, Error);
  else
    Result := HttpFailure(HttpConnectFailed, Text, Error);
  end;
end;

function OpenHttp3Connection(constref Url: TUrlRecord; constref Service: THttpAltService;
  constref Settings: THttpClientSettings; Observer: THttpClientObserver; out Failure: THttpResult): THttpConnection;
var
  Session: TQuicSession;
  Host: string;
  Error: LongInt;
  Connection: THttp3Connection;
begin
  Result := nil;
  Host := Service.Host;
  if Host = '' then
    Host := HostNameOf(Url);
  Observer.ConnectingAlternative(Host, Service.Port, Service.ProtocolId);
  Session := TQuicSession.Create;
  try
    Session.ServerName := HostNameOf(Url);
    Session.ApplicationProtocol := 'h3';
    Session.VerifyCertificates := Settings.VerifyCertificates;
    if Settings.HasTrustFile then
      Session.TrustFile := Settings.TrustFile;
    Session.CipherSuites := Settings.CipherSuites;
    if Settings.AltServiceTimeoutMilliseconds > 0 then
      Session.TimeoutMilliseconds := Settings.AltServiceTimeoutMilliseconds;
    Error := Session.Open(Host, Service.Port);
    if Error <> QuicErrorNone then
    begin
      Failure := FailureOf(Error, Session.DescribeError(Error));
      Observer.ConnectFailed(Failure.Text);
      FreeAndNil(Session);
      Exit;
    end;
    if Settings.TimeoutMilliseconds > 0 then
      Session.Connection.Timeout := Settings.TimeoutMilliseconds;
    Connection := THttp3Connection.Create(Session.Connection, Session, Settings.TimeoutMilliseconds);
    Session := nil;
    Failure := Connection.Start;
    if not HttpSucceeded(Failure) then
    begin
      Observer.ConnectFailed(Failure.Text);
      Connection.Free;
      Exit;
    end;
    Observer.Connected;
    Result := Connection;
  finally
    Session.Free;
  end;
end;

procedure EnableHttp3;
begin
  RegisterConnectionFactory('h3', @OpenHttp3Connection);
end;

function CreateHttp3Client(constref Settings: THttpClientSettings): THttpClient;
begin
  EnableHttp3;
  Result := CreateSystemClient(Settings);
end;

end.
