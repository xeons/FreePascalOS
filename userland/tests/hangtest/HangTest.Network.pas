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
  Getting stuck on a socket: receiving on a TCP connection whose other
  end (a thread of this program, keeping it open) never sends, the same
  with the receive in a second thread (as a TLS reader would be), an
  accept nobody connects to, a connect nobody answers, and a UDP
  receive nothing arrives for. Each never returns.
}
unit HangTest.Network;

{$mode objfpc}{$H+}

interface

{ Runs Mode if it is one of these and returns False otherwise. }
function RunNetworkMode(const Mode: string): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Sys.Sockets,
  HangTest.Report;

const
  ListenPort = 47811;
  UdpPort = 47812;

var
  Listener: Int64;

function ListenOnLoopback(Port: Word): Int64;
var
  Address: TAbiSocketAddress;
begin
  Result := CreateSocket(AddressFamilyIPv4, SocketKindStream, ProtocolTcp);
  if Result < 0 then
    GiveUp('creating a socket', Result);
  { The port may be waiting out a connection of the run before. }
  SetSocketOption(Result, SocketOptionReuseAddress, 1);
  Address := MakeSocketAddress(LoopbackIpv4Address, Port);
  if BindSocket(Result, Address) <> 0 then
    GiveUp('binding', -1);
  if ListenOnSocket(Result, 4) <> 0 then
    GiveUp('listening', -1);
end;

{ Accepts connections and keeps them open, sending nothing. }
function AcceptAndKeepThread(Argument: Pointer): LongInt;
var
  Peer: TAbiSocketAddress;
begin
  while AcceptOnSocket(Listener, Peer) >= 0 do
    ;
  SleepForever;
  Result := 0;
end;

function ConnectToLoopback(Port: Word): Int64;
var
  Address: TAbiSocketAddress;
  Error: LongInt;
begin
  Result := CreateSocket(AddressFamilyIPv4, SocketKindStream, ProtocolTcp);
  if Result < 0 then
    GiveUp('creating a socket', Result);
  Address := MakeSocketAddress(LoopbackIpv4Address, Port);
  Error := ConnectSocket(Result, Address);
  if Error <> 0 then
    GiveUp('connecting', Error);
end;

procedure ReceiveNothing(Socket: Int64);
var
  Buffer: array[0..255] of Byte;
begin
  ReceiveOnSocket(Socket, @Buffer[0], SizeOf(Buffer), 0);
  GiveUp('receiving (it returned)', 0);
end;

var
  ReaderSocket: Int64;

function ReceiveThread(Argument: Pointer): LongInt;
begin
  ReceiveNothing(ReaderSocket);
  Result := 0;
end;

{ Each mode listens on a port of its own, so two can run at once. }
procedure ReceiveOnSilentConnection(const Mode: string; Port: Word; InSecondThread: Boolean);
begin
  Listener := ListenOnLoopback(Port);
  StartThreadOrGiveUp(@AcceptAndKeepThread, nil);
  ReaderSocket := ConnectToLoopback(Port);
  if InSecondThread then
  begin
    StartThreadOrGiveUp(@ReceiveThread, nil);
    SayReady(Mode);
    SleepForever;
  end;
  SayReady(Mode);
  ReceiveNothing(ReaderSocket);
end;

procedure AcceptNobody(const Mode: string);
var
  Peer: TAbiSocketAddress;
begin
  Listener := ListenOnLoopback(ListenPort + 1);
  SayReady(Mode);
  AcceptOnSocket(Listener, Peer);
  GiveUp('accepting (it returned)', 0);
end;

{ An address in a private range nothing answers at: the connection
  attempt goes on until TCP gives up (minutes). }
procedure ConnectToNobody(const Mode: string);
var
  Socket: Int64;
  Address: TAbiSocketAddress;
begin
  Socket := CreateSocket(AddressFamilyIPv4, SocketKindStream, ProtocolTcp);
  if Socket < 0 then
    GiveUp('creating a socket', Socket);
  Address := MakeSocketAddress(Ipv4Address(10, 255, 255, 1), 81);
  SayReady(Mode);
  ConnectSocket(Socket, Address);
  SayReady(Mode + '-gave-up');
  ReceiveOnSilentConnection(Mode, ListenPort + 3, False);
end;

procedure ReceiveDatagramNobodySends(const Mode: string);
var
  Socket: Int64;
  Address: TAbiSocketAddress;
begin
  Socket := CreateSocket(AddressFamilyIPv4, SocketKindDatagram, ProtocolUdp);
  if Socket < 0 then
    GiveUp('creating a socket', Socket);
  SetSocketOption(Socket, SocketOptionReuseAddress, 1);
  Address := MakeSocketAddress(LoopbackIpv4Address, UdpPort);
  if BindSocket(Socket, Address) <> 0 then
    GiveUp('binding', -1);
  SayReady(Mode);
  ReceiveNothing(Socket);
end;

function RunNetworkMode(const Mode: string): Boolean;
begin
  Result := True;
  if Mode = 'tcp-receive' then
    ReceiveOnSilentConnection(Mode, ListenPort, False)
  else if Mode = 'tcp-receive-thread' then
    ReceiveOnSilentConnection(Mode, ListenPort + 2, True)
  else if Mode = 'tcp-accept' then
    AcceptNobody(Mode)
  else if Mode = 'tcp-connect' then
    ConnectToNobody(Mode)
  else if Mode = 'udp-receive' then
    ReceiveDatagramNobodySends(Mode)
  else
    Result := False;
end;

end.
