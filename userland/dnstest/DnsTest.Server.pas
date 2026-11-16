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
  dnstest's DNS server: the zone of DnsTest.Zone over UDP and TCP on
  127.0.0.1 port 53 (root's), and over UDP on [::1]:53, until its stop
  event is set (or, run as "dnstest --serve", until the program is
  asked to end).

  It remembers the id and source port of the last two UDP queries, so
  the test can see that the resolver changes both every time.
}
unit DnsTest.Server;

{$mode objfpc}
{$pointermath on}

interface

const
  TestServerPort = 53;

type
  TServerRecord = record
    Queries: LongWord;
    LastIds: array[0..1] of Word;
    LastPorts: array[0..1] of Word;
  end;

var
  ServerRecord: TServerRecord;

{ Binds the sockets; ErrorNone, or why not. }
function OpenTestServer: LongInt;
{ Serves until StopHandle (an event, or NotificationsHandle) is ready. }
procedure ServeTestZone(StopHandle: Int64);
procedure CloseTestServer;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Sys.Objects,
  Sys.Sockets,
  Sys.InternetAddresses,
  DnsTest.Zone;

var
  UdpSocket: Int64 = -1;
  Udp6Socket: Int64 = -1;
  TcpListener: Int64 = -1;

function ServerAddress: TAbiSocketAddress;
begin
  Result := MakeSocketAddress(LoopbackIpv4Address, TestServerPort);
end;

{ The UDP socket on [::1]:53. }
function OpenIpv6Server: LongInt;
begin
  Udp6Socket := CreateSocket(AddressFamilyIPv6, SocketKindDatagram or SocketKindNonBlocking, ProtocolUdp);
  if Udp6Socket < 0 then
    Exit(LongInt(-Udp6Socket));
  Result := BindSocket(Udp6Socket, MakeSocketAddress(LoopbackIpv6Address, TestServerPort));
end;

function OpenTestServer: LongInt;
begin
  UdpSocket := CreateSocket(AddressFamilyIPv4, SocketKindDatagram or SocketKindNonBlocking, ProtocolUdp);
  if UdpSocket < 0 then
    Exit(LongInt(-UdpSocket));
  Result := BindSocket(UdpSocket, ServerAddress);
  if Result <> ErrorNone then
    Exit;
  TcpListener := CreateSocket(AddressFamilyIPv4, SocketKindStream or SocketKindNonBlocking, ProtocolTcp);
  if TcpListener < 0 then
    Exit(LongInt(-TcpListener));
  SetSocketOption(TcpListener, SocketOptionReuseAddress, 1);
  Result := BindSocket(TcpListener, ServerAddress);
  if Result = ErrorNone then
    Result := ListenOnSocket(TcpListener, 8);
  if Result = ErrorNone then
    Result := OpenIpv6Server;
end;

procedure CloseTestServer;
begin
  if UdpSocket >= 0 then
    CloseSocket(UdpSocket);
  if TcpListener >= 0 then
    CloseSocket(TcpListener);
  if Udp6Socket >= 0 then
    CloseSocket(Udp6Socket);
  UdpSocket := -1;
  Udp6Socket := -1;
  TcpListener := -1;
end;

procedure NoteQuery(Query: PByte; constref Source: TAbiSocketAddress);
begin
  ServerRecord.LastIds[0] := ServerRecord.LastIds[1];
  ServerRecord.LastPorts[0] := ServerRecord.LastPorts[1];
  ServerRecord.LastIds[1] := (Word(Query[0]) shl 8) or Query[1];
  ServerRecord.LastPorts[1] := Source.Port;
  Inc(ServerRecord.Queries);
end;

procedure AnswerUdpQueries(Socket: Int64);
var
  Query: array[0..511] of Byte;
  Source: TAbiSocketAddress;
  Received: Int64;
  Answer: TAnswer;
begin
  repeat
    Received := ReceiveSocketFrom(Socket, @Query[0], SizeOf(Query), SocketFlagDontWait, Source);
    if Received < 2 then
      Exit;
    NoteQuery(@Query[0], Source);
    if not BuildAnswer(@Query[0], LongWord(Received), True, Answer) then
      Continue;
    if Answer.HasDecoy then
      SendSocketTo(Socket, @Answer.Decoy[0], Answer.DecoyLength, 0, Source);
    SendSocketTo(Socket, @Answer.Data[0], Answer.Length, 0, Source);
  until False;
end;

function ReceiveExactly(Socket: Int64; Buffer: PByte; Count: LongWord): Boolean;
var
  Done: LongWord;
  Received: Int64;
begin
  Done := 0;
  while Done < Count do
  begin
    Received := ReceiveOnSocket(Socket, Buffer + Done, Count - Done, 0);
    if Received <= 0 then
      Exit(False);
    Done := Done + LongWord(Received);
  end;
  Result := True;
end;

{ One query on a connection, answered whole (no truncation). }
procedure AnswerTcpConnection;
var
  Connection: Int64;
  Peer: TAbiSocketAddress;
  LengthBytes: array[0..1] of Byte;
  Query: array[0..511] of Byte;
  QueryLength: LongWord;
  Answer: TAnswer;
begin
  Connection := AcceptOnSocket(TcpListener, Peer);
  if Connection < 0 then
    Exit;
  SetSocketOption(Connection, SocketOptionNonBlocking, 0);
  SetSocketOption(Connection, SocketOptionReceiveTimeout, 2000);
  if ReceiveExactly(Connection, @LengthBytes[0], 2) then
  begin
    QueryLength := (LongWord(LengthBytes[0]) shl 8) or LengthBytes[1];
    if (QueryLength <= SizeOf(Query)) and ReceiveExactly(Connection, @Query[0], QueryLength) and
       BuildAnswer(@Query[0], QueryLength, False, Answer) then
    begin
      LengthBytes[0] := Byte(Answer.Length shr 8);
      LengthBytes[1] := Byte(Answer.Length);
      SendAll(Connection, @LengthBytes[0], 2);
      SendAll(Connection, @Answer.Data[0], Answer.Length);
    end;
  end;
  CloseSocket(Connection);
end;

procedure ServeTestZone(StopHandle: Int64);
var
  Ready: Int64;
begin
  repeat
    Ready := WaitForHandles([StopHandle, UdpSocket, TcpListener, Udp6Socket], InfiniteWait);
    case Ready of
      0: Exit;
      1: AnswerUdpQueries(UdpSocket);
      2: AnswerTcpConnection;
      3: AnswerUdpQueries(Udp6Socket);
    else
      Exit;
    end;
  until False;
end;

end.
