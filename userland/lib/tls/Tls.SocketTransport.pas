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
  A TLS transport over a connected TCP socket (Sys.Sockets). Receiving
  waits at most the timeout for the server (0: as long as it takes) and
  gives TlsErrorTimedOut after it; the system's error code of a failed
  call is kept in LastSystemError for messages.
}
unit Tls.SocketTransport;

{$mode objfpc}

interface

uses
  Tls.Transport;

type
  TSocketTransportContext = record
    Socket: Int64;
    TimeoutMilliseconds: Int64;
    LastSystemError: LongInt;
  end;
  PSocketTransportContext = ^TSocketTransportContext;

{ Context must stay where it is while the transport is used. }
procedure MakeSocketTransport(Context: PSocketTransportContext; Socket: Int64; TimeoutMilliseconds: Int64;
  out Transport: TTlsTransport);

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Sockets,
  Tls.Errors;

function SendOverSocket(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
var
  Transport: PSocketTransportContext;
  Error: LongInt;
begin
  Transport := PSocketTransportContext(Context);
  Error := SendAll(Transport^.Socket, Buffer, Length);
  if Error <> ErrorNone then
  begin
    Transport^.LastSystemError := Error;
    if Error = ErrorTimedOut then
      Exit(TlsErrorTimedOut);
    Exit(TlsErrorTransportFailed);
  end;
  Result := Int64(Length);
end;

function ReceiveFromSocket(Context: Pointer; Buffer: PByte; Length: PtrUInt): Int64;
var
  Transport: PSocketTransportContext;
  Waited: Int64;
  Received: Int64;
begin
  Transport := PSocketTransportContext(Context);
  if Transport^.TimeoutMilliseconds > 0 then
  begin
    Waited := WaitForSocket(Transport^.Socket, SocketReadable, Transport^.TimeoutMilliseconds);
    if Waited < 0 then
    begin
      Transport^.LastSystemError := ErrorCodeOf(Waited);
      if Transport^.LastSystemError = ErrorTimedOut then
        Exit(TlsErrorTimedOut);
      Exit(TlsErrorTransportFailed);
    end;
  end;
  Received := ReceiveOnSocket(Transport^.Socket, Buffer, Length, 0);
  if Received < 0 then
  begin
    Transport^.LastSystemError := ErrorCodeOf(Received);
    if Transport^.LastSystemError = ErrorTimedOut then
      Exit(TlsErrorTimedOut);
    Exit(TlsErrorTransportFailed);
  end;
  Result := Received;
end;

procedure MakeSocketTransport(Context: PSocketTransportContext; Socket: Int64; TimeoutMilliseconds: Int64;
  out Transport: TTlsTransport);
begin
  Context^.Socket := Socket;
  Context^.TimeoutMilliseconds := TimeoutMilliseconds;
  Context^.LastSystemError := ErrorNone;
  if TimeoutMilliseconds > 0 then
    SetSocketOption(Socket, SocketOptionSendTimeout, TimeoutMilliseconds);
  Transport.Context := Context;
  Transport.Send := @SendOverSocket;
  Transport.Receive := @ReceiveFromSocket;
end;

end.
