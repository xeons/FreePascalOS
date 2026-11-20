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
  The system's connector: the host looked up (Sys.HostLookup: numeric
  addresses without DNS, IPv6 first when this machine can reach it), a
  non-blocking TCP connect within the timeout to each address in turn
  until one takes it, and for https TLS over it (Http.SocketTransports)
  offering "h2" when HTTP/2 is allowed. The observer hears each step.

  CreateSystemClient makes a client with this connector and the
  system's clock.

  FreePascalOS only.
}
unit Http.SocketConnector;

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
  THttpSocketConnector = class(THttpConnector)
  public
    function Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings; Observer: THttpClientObserver;
      out Transport: THttpTransport): THttpResult; override;
  end;

function SystemUnixTime: Int64;
function CreateSystemClient(constref Settings: THttpClientSettings): THttpClient;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.AddressText,
  Sys.Errors,
  Sys.HostLookup,
  Sys.HostNames,
  Sys.InternetAddresses,
  Sys.Sockets,
  Sys.Time,
  Http.SocketTransports;

function SystemUnixTime: Int64;
begin
  Result := Int64(CurrentTime);
end;

function CreateSystemClient(constref Settings: THttpClientSettings): THttpClient;
begin
  Result := THttpClient.Create(Settings, THttpSocketConnector.Create, True);
  Result.Clock := @SystemUnixTime;
end;

{ A non-blocking connect, waited for at most the timeout. }
function ConnectWithTimeout(Socket: Int64; constref Target: TAbiSocketAddress; TimeoutMilliseconds: Int64): LongInt;
var
  Waited, Pending, Timeout: Int64;
begin
  Result := ConnectSocket(Socket, Target);
  if Result = ErrorInProgress then
  begin
    Timeout := TimeoutMilliseconds;
    if Timeout <= 0 then
      Timeout := InfiniteWait;
    Waited := WaitForSocket(Socket, SocketWritable, Timeout);
    if Waited < 0 then
      Exit(ErrorCodeOf(Waited));
    Result := GetSocketOption(Socket, SocketOptionError, Pending);
    if Result = ErrorNone then
      Result := LongInt(Pending);
  end;
  if Result = ErrorNone then
    SetSocketOption(Socket, SocketOptionNonBlocking, 0);
end;

function ResolveUrlHost(const Host: string; Observer: THttpClientObserver;
  out Addresses: TInternetAddressArray): THttpResult;
var
  Error: LongInt;
  Numeric: TInternetAddress;
  IsName: Boolean;
  Texts: array of string;
  Index: Integer;
begin
  IsName := not TextToAddress(Host, Numeric);
  if IsName then
    Observer.LookingUp(Host);
  Error := ResolveHost(Host, HostFamilyAny, Addresses);
  if (Error = ErrorNone) and (Length(Addresses) = 0) then
    Error := ErrorNotFound;
  if Error <> ErrorNone then
  begin
    if IsName then
      Observer.LookUpFailed(Host, ErrorMessage(Error));
    Exit(HttpFailure(HttpLookupFailed, 'unable to resolve host address', Error));
  end;
  if IsName then
  begin
    Texts := nil;
    SetLength(Texts, Length(Addresses));
    for Index := 0 to High(Addresses) do
      Texts[Index] := AddressToText(Addresses[Index]);
    Observer.LookedUp(Host, Texts);
  end;
  Result := HttpOk;
end;

function ConnectToAddress(const Host: string; constref Address: TInternetAddress; Port: Word;
  constref Settings: THttpClientSettings; Observer: THttpClientObserver; out Socket: Int64): THttpResult;
var
  Error: LongInt;
begin
  Observer.Connecting(Host, AddressToText(Address), Port);
  Socket := CreateSocket(Address.Family, SocketKindStream or SocketKindNonBlocking, ProtocolDefault);
  if Socket < 0 then
  begin
    Error := ErrorCodeOf(Socket);
    Socket := -1;
    Observer.ConnectFailed(ErrorMessage(Error));
    Exit(HttpFailure(HttpConnectFailed, ErrorMessage(Error), Error));
  end;
  Error := ConnectWithTimeout(Socket, MakeSocketAddress(Address, Port), Settings.TimeoutMilliseconds);
  if Error <> ErrorNone then
  begin
    Observer.ConnectFailed(ErrorMessage(Error));
    CloseSocket(Socket);
    Socket := -1;
    if Error = ErrorTimedOut then
      Exit(HttpFailure(HttpTimedOut, ErrorMessage(Error), Error));
    Exit(HttpFailure(HttpConnectFailed, ErrorMessage(Error), Error));
  end;
  Observer.Connected;
  Result := HttpOk;
end;

function THttpSocketConnector.Connect(constref Url: TUrlRecord; constref Settings: THttpClientSettings;
  Observer: THttpClientObserver; out Transport: THttpTransport): THttpResult;
var
  Addresses: TInternetAddressArray;
  Address: TInternetAddress;
  Host: string;
  Port: Word;
  Socket: Int64;
  Secure: THttpSocketTransport;
begin
  Transport := nil;
  Host := HostNameOf(Url);
  Port := UrlEffectivePort(Url);
  Result := ResolveUrlHost(Host, Observer, Addresses);
  if not HttpSucceeded(Result) then
    Exit;
  Socket := -1;
  for Address in Addresses do
  begin
    Result := ConnectToAddress(Host, Address, Port, Settings, Observer, Socket);
    if HttpSucceeded(Result) then
      Break;
  end;
  if Socket < 0 then
    Exit;
  Secure := THttpSocketTransport.Create(Socket, Settings.TimeoutMilliseconds);
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

end.
