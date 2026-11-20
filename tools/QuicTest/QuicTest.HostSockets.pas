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
  UDP sockets of the host (Linux) for the loopback tests, as QUIC
  datagram transports: an endpoint bound to 127.0.0.1 or ::1 on a port
  the system chooses, sending to one peer (fixed, or the first that
  sends to it). For loss tests an endpoint may drop every Nth datagram
  it sends or receives.
}
unit QuicTest.HostSockets;

{$mode objfpc}
{$H+}

interface

uses
  Quic.DatagramTransports;

type
  TTestEndpoint = record
    Handle: LongInt;
    Ipv6: Boolean;
    Port: Word;
    PeerAddress: array[0..127] of Byte;
    PeerAddressLength: LongWord;
    HasPeer: Boolean;
    { 0: no loss. }
    DropEverySent: Integer;
    DropEveryReceived: Integer;
    SentCount: Integer;
    ReceivedCount: Integer;
    { Datagrams handed over by the test instead of the socket (the
      server's first one). }
    Injected: array of Byte;
  end;
  PTestEndpoint = ^TTestEndpoint;

{ Binds a socket on the loopback address (Port 0: one the system
  chooses); False when that fails. }
function OpenEndpoint(out Endpoint: TTestEndpoint; Ipv6: Boolean; Port: Word = 0): Boolean;
procedure CloseEndpoint(var Endpoint: TTestEndpoint);
{ Sends to the endpoint at Port on the same loopback address. }
procedure SetPeerPort(var Endpoint: TTestEndpoint; Port: Word);
{ Waits up to TimeoutMilliseconds for a datagram (the sender becomes
  the peer when there is none yet): its length, 0 for none. }
function ReceiveRaw(var Endpoint: TTestEndpoint; Buffer: PByte; Capacity: PtrUInt; TimeoutMilliseconds: Int64): Int64;
function SendRaw(var Endpoint: TTestEndpoint; Data: PByte; Length: PtrUInt): LongInt;
procedure MakeTransport(Endpoint: PTestEndpoint; out Transport: TQuicDatagramTransport);

implementation

uses
  BaseUnix,
  Sockets,
  Quic.Errors;

function OpenEndpoint(out Endpoint: TTestEndpoint; Ipv6: Boolean; Port: Word): Boolean;
var
  Address4: TInetSockAddr;
  Address6: TInetSockAddr6;
  Length: TSockLen;
begin
  Endpoint := Default(TTestEndpoint);
  Endpoint.Ipv6 := Ipv6;
  if Ipv6 then
  begin
    Endpoint.Handle := fpSocket(AF_INET6, SOCK_DGRAM, 0);
    if Endpoint.Handle < 0 then
      Exit(False);
    Address6 := Default(TInetSockAddr6);
    Address6.sin6_family := AF_INET6;
    Address6.sin6_addr.u6_addr8[15] := 1;
    Address6.sin6_port := HToNs(Port);
    if fpBind(Endpoint.Handle, @Address6, SizeOf(Address6)) <> 0 then
      Exit(False);
    Length := SizeOf(Address6);
    fpGetSockName(Endpoint.Handle, @Address6, @Length);
    Endpoint.Port := NToHs(Address6.sin6_port);
  end
  else
  begin
    Endpoint.Handle := fpSocket(AF_INET, SOCK_DGRAM, 0);
    if Endpoint.Handle < 0 then
      Exit(False);
    Address4 := Default(TInetSockAddr);
    Address4.sin_family := AF_INET;
    Address4.sin_addr.s_addr := HToNl($7F000001);
    Address4.sin_port := HToNs(Port);
    if fpBind(Endpoint.Handle, @Address4, SizeOf(Address4)) <> 0 then
      Exit(False);
    Length := SizeOf(Address4);
    fpGetSockName(Endpoint.Handle, @Address4, @Length);
    Endpoint.Port := NToHs(Address4.sin_port);
  end;
  Result := True;
end;

procedure CloseEndpoint(var Endpoint: TTestEndpoint);
begin
  if Endpoint.Handle > 0 then
    fpClose(Endpoint.Handle);
  Endpoint.Handle := -1;
end;

procedure SetPeerPort(var Endpoint: TTestEndpoint; Port: Word);
var
  Address4: TInetSockAddr;
  Address6: TInetSockAddr6;
begin
  if Endpoint.Ipv6 then
  begin
    Address6 := Default(TInetSockAddr6);
    Address6.sin6_family := AF_INET6;
    Address6.sin6_addr.u6_addr8[15] := 1;
    Address6.sin6_port := HToNs(Port);
    Move(Address6, Endpoint.PeerAddress[0], SizeOf(Address6));
    Endpoint.PeerAddressLength := SizeOf(Address6);
  end
  else
  begin
    Address4 := Default(TInetSockAddr);
    Address4.sin_family := AF_INET;
    Address4.sin_addr.s_addr := HToNl($7F000001);
    Address4.sin_port := HToNs(Port);
    Move(Address4, Endpoint.PeerAddress[0], SizeOf(Address4));
    Endpoint.PeerAddressLength := SizeOf(Address4);
  end;
  Endpoint.HasPeer := True;
end;

function ReceiveRaw(var Endpoint: TTestEndpoint; Buffer: PByte; Capacity: PtrUInt; TimeoutMilliseconds: Int64): Int64;
var
  Poll: TPollFd;
  From: array[0..127] of Byte;
  FromLength: TSockLen;
  Ready: LongInt;
begin
  if Length(Endpoint.Injected) > 0 then
  begin
    Result := Length(Endpoint.Injected);
    Move(Endpoint.Injected[0], Buffer^, Result);
    Endpoint.Injected := nil;
    Exit;
  end;
  Poll.fd := Endpoint.Handle;
  Poll.events := POLLIN;
  Poll.revents := 0;
  if TimeoutMilliseconds < 0 then
    TimeoutMilliseconds := 0;
  Ready := FpPoll(@Poll, 1, TimeoutMilliseconds);
  if Ready <= 0 then
    Exit(0);
  FromLength := SizeOf(From);
  Result := fpRecvFrom(Endpoint.Handle, Buffer, Capacity, 0, @From[0], @FromLength);
  if Result < 0 then
    Exit(0);
  if not Endpoint.HasPeer then
  begin
    Move(From[0], Endpoint.PeerAddress[0], FromLength);
    Endpoint.PeerAddressLength := FromLength;
    Endpoint.HasPeer := True;
  end;
end;

function SendRaw(var Endpoint: TTestEndpoint; Data: PByte; Length: PtrUInt): LongInt;
begin
  if not Endpoint.HasPeer then
    Exit(QuicErrorTransportFailed);
  if fpSendTo(Endpoint.Handle, Data, Length, 0, @Endpoint.PeerAddress[0], Endpoint.PeerAddressLength) < 0 then
    Exit(QuicErrorTransportFailed);
  Result := QuicErrorNone;
end;

function SendDatagram(Context: Pointer; Data: PByte; Length: PtrUInt): LongInt;
var
  Endpoint: PTestEndpoint;
begin
  Endpoint := PTestEndpoint(Context);
  Inc(Endpoint^.SentCount);
  if (Endpoint^.DropEverySent > 0) and (Endpoint^.SentCount mod Endpoint^.DropEverySent = 0) then
    Exit(QuicErrorNone);
  Result := SendRaw(Endpoint^, Data, Length);
end;

function ReceiveDatagram(Context: Pointer; Buffer: PByte; Capacity: PtrUInt; TimeoutMilliseconds: Int64): Int64;
var
  Endpoint: PTestEndpoint;
begin
  Endpoint := PTestEndpoint(Context);
  repeat
    Result := ReceiveRaw(Endpoint^, Buffer, Capacity, TimeoutMilliseconds);
    if Result <= 0 then
      Exit;
    Inc(Endpoint^.ReceivedCount);
    if (Endpoint^.DropEveryReceived = 0) or (Endpoint^.ReceivedCount mod Endpoint^.DropEveryReceived <> 0) then
      Exit;
    { Dropped: look for the next one without waiting again. }
    TimeoutMilliseconds := 0;
  until False;
end;

procedure MakeTransport(Endpoint: PTestEndpoint; out Transport: TQuicDatagramTransport);
begin
  Transport.Context := Endpoint;
  Transport.Send := @SendDatagram;
  Transport.Receive := @ReceiveDatagram;
end;

end.
