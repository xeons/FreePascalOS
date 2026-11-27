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
  nc -l: waiting for a peer. TCP takes one connection (with -k one
  after another, until nc is ended) and relays it; UDP waits for the
  first datagram, then talks with its sender alone. -v says:

    Listening on 0.0.0.0 7000
    Connection received on 127.0.0.1 49152
}
unit Netcat.Listener;

{$mode objfpc}
{$H+}

interface

uses
  Sys.InternetAddresses;

{ Returns the exit status. }
function RunListener(constref LocalAddress: TInternetAddress; Port: Word): Integer;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.AddressText,
  Sys.Errors,
  Sys.Kernel,
  Sys.Sockets,
  Util.Messages,
  Netcat.Settings,
  Netcat.Sockets,
  Netcat.Relay;

const
  ListenBacklog = 8;
  FirstDatagramBytes = 65536;

procedure ReportPeer(constref Peer: TAbiSocketAddress);
begin
  ReportProgress('Connection received on ' + HostText(Peer) + ' ' + IntToStr(Peer.Port));
end;

function RunStreamListener(Listener: Int64): Integer;
var
  Connection: Int64;
  Peer: TAbiSocketAddress;
begin
  Result := 0;
  repeat
    Connection := AcceptOnSocket(Listener, Peer);
    if Connection < 0 then
    begin
      ReportError(ErrorCodeOf(Connection), 'accept failed');
      Exit(1);
    end;
    ReportPeer(Peer);
    if not RelayConnection(Connection) then
      Result := 1;
    CloseSocket(Connection);
  until not Settings.KeepListening;
end;

{ The first datagram fixes the peer: the socket is connected to its
  sender and what it carried is written out before the relay begins. }
function RunDatagramListener(Socket: Int64): Integer;
var
  Peer: TAbiSocketAddress;
  Data: array of Byte;
  Count: Int64;
  Error: LongInt;
begin
  SetLength(Data, FirstDatagramBytes);
  Count := ReceiveSocketFrom(Socket, @Data[0], FirstDatagramBytes, 0, Peer);
  if Count >= 0 then
  begin
    Error := ConnectSocket(Socket, Peer);
    if Error = ErrorNone then
      KernelWrite(StandardOutputHandle, @Data[0], QWord(Count));
  end
  else
    Error := ErrorCodeOf(Count);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'cannot receive the first datagram');
    Exit(1);
  end;
  ReportPeer(Peer);
  if RelayConnection(Socket) then
    Result := 0
  else
    Result := 1;
end;

function RunListener(constref LocalAddress: TInternetAddress; Port: Word): Integer;
var
  Socket: Int64;
  Error: LongInt;
begin
  Socket := OpenSocket(LocalAddress, Port);
  if not Settings.Datagrams then
  begin
    Error := ListenOnSocket(Socket, ListenBacklog);
    if Error <> ErrorNone then
      FailWithError(1, Error, 'cannot listen on port ' + IntToStr(Port));
  end;
  ReportProgress('Listening on ' + AddressToText(LocalAddress) + ' ' + IntToStr(Port));
  if Settings.Datagrams then
    Result := RunDatagramListener(Socket)
  else
    Result := RunStreamListener(Socket);
  CloseSocket(Socket);
end;

end.
