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
  Network sockets for programs: TCP streams, UDP datagrams and ICMP echo
  (for ping), in the manner of BSD sockets.

    Socket := CreateSocket(AddressFamilyIPv4, SocketKindStream, ProtocolDefault);
    ConnectSocket(Socket, MakeSocketAddress(Ipv4Address(10, 0, 2, 2), 80));
    SendAll(Socket, Request, RequestLength);
    Count := ReceiveOnSocket(Socket, @Buffer, SizeOf(Buffer), 0);
    CloseSocket(Socket);

  A socket is a handle (HandleKindSocket): CloseSocket (or CallClose)
  closes it, CallRead and CallWrite work on a connected one, it is
  inherited and passed in messages like any handle, and
  WaitForHandles waits until it is readable (Sys.Objects); WaitForSocket
  also waits until it is writable. Calls return ErrorNone or an Abi
  error code; those that move data return the byte count or minus the
  error code; CreateSocket and AcceptOnSocket the new handle or minus
  the error code. Addresses are Sys.InternetAddresses' socket
  addresses.
}
unit Sys.Sockets;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

function CreateSocket(Family, Kind, Protocol: LongWord): Int64;
function CloseSocket(Socket: Int64): LongInt;
function BindSocket(Socket: Int64; constref Address: TAbiSocketAddress): LongInt;
function ListenOnSocket(Socket: Int64; Backlog: LongWord): LongInt;
{ A new handle for the next connection, and where it comes from. }
function AcceptOnSocket(Socket: Int64; out Peer: TAbiSocketAddress): Int64;
function ConnectSocket(Socket: Int64; constref Address: TAbiSocketAddress): LongInt;
function SendOnSocket(Socket: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord): Int64;
function SendSocketTo(Socket: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord;
  constref Address: TAbiSocketAddress): Int64;
{ Sends all Length bytes of a stream (as many calls as it takes). }
function SendAll(Socket: Int64; Buffer: Pointer; Length: QWord): LongInt;
function ReceiveOnSocket(Socket: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord): Int64;
function ReceiveSocketFrom(Socket: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord;
  out Address: TAbiSocketAddress): Int64;
{ SocketShutdownReceive, SocketShutdownSend or SocketShutdownBoth. }
function ShutdownSocket(Socket: Int64; How: LongWord): LongInt;
function GetSocketOption(Socket: Int64; Option: LongWord; out Value: Int64): LongInt;
function SetSocketOption(Socket: Int64; Option: LongWord; Value: Int64): LongInt;
{ Joins (Join) or leaves a multicast group: Family and the sixteen
  address bytes of the group (IPv4 in the first four), on the interface
  with InterfaceIndex (0: the one the routes give). }
function ChangeMulticastMembership(Socket: Int64; Join: Boolean; Family: Word; Group: PByte;
  InterfaceIndex: LongWord): LongInt;
function GetLocalSocketAddress(Socket: Int64; out Address: TAbiSocketAddress): LongInt;
function GetPeerSocketAddress(Socket: Int64; out Address: TAbiSocketAddress): LongInt;
{ Waits up to Timeout ms (InfiniteWait: as long as it takes) until one
  of Conditions (SocketReadable, SocketWritable) holds; returns those
  that hold, or minus ErrorTimedOut. }
function WaitForSocket(Socket: Int64; Conditions: LongWord; Timeout: Int64): Int64;

{ "tcp", "udp", "icmp" for a ProtocolTcp ... }
function ProtocolName(Protocol: LongWord): PChar;
{ "ESTABLISHED", "LISTEN", ... for a TcpState*; "" for 0. }
function TcpStateName(State: LongWord): PChar;

implementation

uses
  Sys.Kernel,
  Sys.Errors;

function CreateSocket(Family, Kind, Protocol: LongWord): Int64;
begin
  Result := KernelCreateSocket(Family, Kind, Protocol);
end;

function CloseSocket(Socket: Int64): LongInt;
begin
  Result := ErrorCodeOf(KernelClose(Socket));
end;

function BindSocket(Socket: Int64; constref Address: TAbiSocketAddress): LongInt;
begin
  Result := ErrorCodeOf(KernelBindSocket(Socket, Address));
end;

function ListenOnSocket(Socket: Int64; Backlog: LongWord): LongInt;
begin
  Result := ErrorCodeOf(KernelListenSocket(Socket, Backlog));
end;

function AcceptOnSocket(Socket: Int64; out Peer: TAbiSocketAddress): Int64;
begin
  FillChar(Peer, SizeOf(Peer), 0);
  Result := KernelAcceptSocket(Socket, @Peer);
end;

function ConnectSocket(Socket: Int64; constref Address: TAbiSocketAddress): LongInt;
begin
  Result := ErrorCodeOf(KernelConnectSocket(Socket, Address));
end;

function SendOnSocket(Socket: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord): Int64;
begin
  Result := KernelSendSocket(Socket, Buffer, Length, Flags, nil);
end;

function SendSocketTo(Socket: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord;
  constref Address: TAbiSocketAddress): Int64;
begin
  Result := KernelSendSocket(Socket, Buffer, Length, Flags, @Address);
end;

function SendAll(Socket: Int64; Buffer: Pointer; Length: QWord): LongInt;
var
  Done: QWord;
  Sent: Int64;
begin
  Done := 0;
  while Done < Length do
  begin
    Sent := KernelSendSocket(Socket, PByte(Buffer) + Done, Length - Done, 0, nil);
    if Sent < 0 then
      Exit(ErrorCodeOf(Sent));
    if Sent = 0 then
      Exit(ErrorBrokenPipe);
    Done := Done + QWord(Sent);
  end;
  Result := ErrorNone;
end;

function ReceiveOnSocket(Socket: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord): Int64;
begin
  Result := KernelReceiveSocket(Socket, Buffer, Length, Flags, nil);
end;

function ReceiveSocketFrom(Socket: Int64; Buffer: Pointer; Length: QWord; Flags: LongWord;
  out Address: TAbiSocketAddress): Int64;
begin
  FillChar(Address, SizeOf(Address), 0);
  Result := KernelReceiveSocket(Socket, Buffer, Length, Flags, @Address);
end;

function ShutdownSocket(Socket: Int64; How: LongWord): LongInt;
begin
  Result := ErrorCodeOf(KernelShutdownSocket(Socket, How));
end;

function GetSocketOption(Socket: Int64; Option: LongWord; out Value: Int64): LongInt;
var
  CallResult: Int64;
begin
  CallResult := KernelGetSocketOption(Socket, Option);
  Value := 0;
  Result := ErrorCodeOf(CallResult);
  if Result = ErrorNone then
    Value := CallResult;
end;

function SetSocketOption(Socket: Int64; Option: LongWord; Value: Int64): LongInt;
begin
  Result := ErrorCodeOf(KernelSetSocketOption(Socket, Option, Value));
end;

function ChangeMulticastMembership(Socket: Int64; Join: Boolean; Family: Word; Group: PByte;
  InterfaceIndex: LongWord): LongInt;
var
  Request: TAbiMulticastMembership;
  Option: LongWord;
begin
  FillChar(Request, SizeOf(Request), 0);
  Request.Family := Family;
  Request.InterfaceIndex := InterfaceIndex;
  Move(Group^, Request.Group[0], SizeOf(Request.Group));
  if Join then
    Option := SocketOptionJoinGroup
  else
    Option := SocketOptionLeaveGroup;
  Result := SetSocketOption(Socket, Option, Int64(PtrUInt(@Request)));
end;

function GetLocalSocketAddress(Socket: Int64; out Address: TAbiSocketAddress): LongInt;
begin
  Result := ErrorCodeOf(KernelGetSocketAddress(Socket, SocketAddressLocal, Address));
end;

function GetPeerSocketAddress(Socket: Int64; out Address: TAbiSocketAddress): LongInt;
begin
  Result := ErrorCodeOf(KernelGetSocketAddress(Socket, SocketAddressPeer, Address));
end;

function WaitForSocket(Socket: Int64; Conditions: LongWord; Timeout: Int64): Int64;
begin
  Result := KernelWaitForSocket(Socket, Conditions, Timeout);
end;

function ProtocolName(Protocol: LongWord): PChar;
begin
  case Protocol of
    ProtocolTcp: Result := 'tcp';
    ProtocolUdp: Result := 'udp';
    ProtocolIcmp: Result := 'icmp';
  else
    Result := '?';
  end;
end;

function TcpStateName(State: LongWord): PChar;
begin
  case State of
    TcpStateClosed: Result := 'CLOSED';
    TcpStateListen: Result := 'LISTEN';
    TcpStateSynSent: Result := 'SYN_SENT';
    TcpStateSynReceived: Result := 'SYN_RECV';
    TcpStateEstablished: Result := 'ESTABLISHED';
    TcpStateFinWait1: Result := 'FIN_WAIT1';
    TcpStateFinWait2: Result := 'FIN_WAIT2';
    TcpStateCloseWait: Result := 'CLOSE_WAIT';
    TcpStateClosing: Result := 'CLOSING';
    TcpStateLastAck: Result := 'LAST_ACK';
    TcpStateTimeWait: Result := 'TIME_WAIT';
  else
    Result := '';
  end;
end;

end.
