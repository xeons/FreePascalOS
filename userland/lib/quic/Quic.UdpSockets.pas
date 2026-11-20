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
  A QUIC datagram transport over a UDP socket of the system
  (Sys.Sockets), IPv4 or IPv6, connected to the server's address: the
  kernel then delivers datagrams from that address and port only, and
  sends without an address each time. Waiting is CallWaitForSocket
  with the timeout the connection asks for; reading never waits
  (SocketFlagDontWait). The system's error code of a failed call is
  kept for messages.
}
unit Quic.UdpSockets;

{$mode objfpc}
{$H+}

interface

uses
  Sys.InternetAddresses,
  Quic.DatagramTransports;

type
  TQuicUdpSocket = record
    Socket: Int64;
    LastSystemError: LongInt;
  end;
  PQuicUdpSocket = ^TQuicUdpSocket;

{ A UDP socket of the address's family connected to Address:Port:
  QuicErrorNone, or QuicErrorTransportFailed (LastSystemError says
  why). }
function OpenUdpSocket(constref Address: TInternetAddress; Port: Word; out Socket: TQuicUdpSocket): LongInt;
procedure CloseUdpSocket(var Socket: TQuicUdpSocket);
{ Socket must stay where it is while the transport is used. }
procedure MakeUdpTransport(Socket: PQuicUdpSocket; out Transport: TQuicDatagramTransport);

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Sockets,
  Quic.Errors;

function OpenUdpSocket(constref Address: TInternetAddress; Port: Word; out Socket: TQuicUdpSocket): LongInt;
var
  Error: LongInt;
begin
  Socket.LastSystemError := ErrorNone;
  Socket.Socket := CreateSocket(Address.Family, SocketKindDatagram, ProtocolUdp);
  if Socket.Socket < 0 then
  begin
    Socket.LastSystemError := ErrorCodeOf(Socket.Socket);
    Socket.Socket := -1;
    Exit(QuicErrorTransportFailed);
  end;
  Error := ConnectSocket(Socket.Socket, MakeSocketAddress(Address, Port));
  if Error <> ErrorNone then
  begin
    Socket.LastSystemError := Error;
    CloseSocket(Socket.Socket);
    Socket.Socket := -1;
    Exit(QuicErrorTransportFailed);
  end;
  Result := QuicErrorNone;
end;

procedure CloseUdpSocket(var Socket: TQuicUdpSocket);
begin
  if Socket.Socket >= 0 then
    CloseSocket(Socket.Socket);
  Socket.Socket := -1;
end;

function SendDatagram(Context: Pointer; Data: PByte; Length: PtrUInt): LongInt;
var
  Socket: PQuicUdpSocket;
  Sent: Int64;
begin
  Socket := PQuicUdpSocket(Context);
  Sent := SendOnSocket(Socket^.Socket, Data, Length, 0);
  if Sent < 0 then
  begin
    Socket^.LastSystemError := ErrorCodeOf(Sent);
    { A datagram the network would not take now is as good as lost;
      QUIC sends it again. }
    if Socket^.LastSystemError = ErrorWouldBlock then
      Exit(QuicErrorNone);
    Exit(QuicErrorTransportFailed);
  end;
  Result := QuicErrorNone;
end;

function ReceiveDatagram(Context: Pointer; Buffer: PByte; Capacity: PtrUInt; TimeoutMilliseconds: Int64): Int64;
var
  Socket: PQuicUdpSocket;
  Waited, Received: Int64;
  Error: LongInt;
begin
  Socket := PQuicUdpSocket(Context);
  if TimeoutMilliseconds > 0 then
  begin
    Waited := WaitForSocket(Socket^.Socket, SocketReadable, TimeoutMilliseconds);
    if Waited < 0 then
    begin
      Error := ErrorCodeOf(Waited);
      if Error = ErrorTimedOut then
        Exit(0);
      Socket^.LastSystemError := Error;
      Exit(QuicErrorTransportFailed);
    end;
  end;
  Received := ReceiveOnSocket(Socket^.Socket, Buffer, Capacity, SocketFlagDontWait);
  if Received < 0 then
  begin
    Error := ErrorCodeOf(Received);
    if (Error = ErrorWouldBlock) or (Error = ErrorTimedOut) then
      Exit(0);
    { An ICMP error (port unreachable) on a connected socket: the
      datagram is lost, nothing more. }
    if Error = ErrorConnectionRefused then
      Exit(0);
    Socket^.LastSystemError := Error;
    Exit(QuicErrorTransportFailed);
  end;
  Result := Received;
end;

procedure MakeUdpTransport(Socket: PQuicUdpSocket; out Transport: TQuicDatagramTransport);
begin
  Transport.Context := Socket;
  Transport.Send := @SendDatagram;
  Transport.Receive := @ReceiveDatagram;
end;

end.
