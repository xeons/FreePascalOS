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
  What a socket can be asked, for every kind of socket: the kernel's
  side of the socket system calls (Processes.SocketCalls copies the
  arguments in and out), usable by the kernel itself (the network self
  test) as well. Each operation takes the network lock and passes the
  work to TCP (Network.TcpSockets), UDP (Network.Udp) or ICMP
  (Network.IcmpSockets). Buffers are kernel memory. Errors are Abi
  error codes; the operations that move data return the byte count or
  minus an error code.
}
unit Network.SocketOperations;

{$mode objfpc}

interface

uses
  Network.Addresses,
  Network.Sockets;

{ A new socket (referenced once). CallerIsRoot: raw sockets are root's. }
function CreateSocket(Family, Kind, Protocol: LongWord; constref Owner: TSocketOwner; CallerIsRoot: Boolean;
  out Socket: PSocket): LongInt;
function BindSocket(Socket: PSocket; constref Endpoint: TNetworkEndpoint; CallerIsRoot: Boolean): LongInt;
function ListenOnSocket(Socket: PSocket; Backlog: LongWord): LongInt;
{ NewSocket is referenced once, for its handle, and belongs to Owner. }
function AcceptOnSocket(Socket: PSocket; constref Owner: TSocketOwner; out NewSocket: PSocket;
  out Peer: TNetworkEndpoint): LongInt;
function ConnectSocket(Socket: PSocket; constref Endpoint: TNetworkEndpoint): LongInt;
{ Destination nil: the connected peer. }
function SendOnSocket(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord;
  Destination: PNetworkEndpoint): Int64;
function ReceiveOnSocket(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord;
  out Source: TNetworkEndpoint): Int64;
function ShutdownSocket(Socket: PSocket; How: LongWord): LongInt;
function GetSocketOption(Socket: PSocket; Option: LongWord; out Value: Int64): LongInt;
function SetSocketOption(Socket: PSocket; Option: LongWord; Value: Int64; CallerIsRoot: Boolean): LongInt;
{ SocketAddressLocal or SocketAddressPeer. }
function GetSocketEndpoint(Socket: PSocket; Which: LongWord; out Endpoint: TNetworkEndpoint): LongInt;
{ Waits until one of Conditions (SocketReadable, SocketWritable) holds,
  at most TimeoutMilliseconds (negative: as long as it takes). Returns
  the conditions that hold, or minus ErrorTimedOut / ErrorInterrupted. }
function WaitForSocketConditions(Socket: PSocket; Conditions: LongWord; TimeoutMilliseconds: Int64): Int64;

implementation

uses
  Abi.SystemCalls,
  Kernel.Events,
  Kernel.Threads,
  Kernel.Scheduler,
  Network.Core,
  Network.Interfaces,
  Network.Datagrams,
  Network.Ports,
  Network.Udp,
  Network.IcmpSockets,
  Network.DatagramSockets,
  Network.IpOutput,
  Network.TcpSockets;

function CreateSocket(Family, Kind, Protocol: LongWord; constref Owner: TSocketOwner; CallerIsRoot: Boolean;
  out Socket: PSocket): LongInt;
var
  BaseKind: LongWord;
  SocketProtocol: TSocketProtocol;
begin
  Socket := nil;
  if (Family <> AddressFamilyIPv4) and (Family <> AddressFamilyIPv6) then
    Exit(ErrorAddressFamilyNotSupported);
  { ICMPv6 is IPv6's ICMP; an IPv6 socket may name it either way. }
  if (Protocol = ProtocolIcmpv6) and (Family = AddressFamilyIPv6) then
    Protocol := ProtocolIcmp;
  if (Kind and not (SocketKindNonBlocking or $FF)) <> 0 then
    Exit(ErrorInvalidArgument);
  BaseKind := Kind and $FF;
  case BaseKind of
    SocketKindStream:
      begin
        if (Protocol <> ProtocolDefault) and (Protocol <> ProtocolTcp) then
          Exit(ErrorProtocolNotSupported);
        SocketProtocol := SocketProtocolTcp;
      end;
    SocketKindDatagram:
      case Protocol of
        ProtocolDefault, ProtocolUdp: SocketProtocol := SocketProtocolUdp;
        ProtocolIcmp: SocketProtocol := SocketProtocolIcmpEcho;
      else
        Exit(ErrorProtocolNotSupported);
      end;
    SocketKindRaw:
      begin
        if Protocol <> ProtocolIcmp then
          Exit(ErrorProtocolNotSupported);
        if not CallerIsRoot then
          Exit(ErrorNotPermitted);
        SocketProtocol := SocketProtocolIcmpRaw;
      end;
  else
    Exit(ErrorInvalidArgument);
  end;
  LockNetwork;
  Socket := AllocateSocket(Family, BaseKind, SocketProtocol, Owner);
  if Socket <> nil then
    Socket^.NonBlocking := (Kind and SocketKindNonBlocking) <> 0;
  UnlockNetwork;
  if Socket = nil then
    Exit(ErrorOutOfMemory);
  Result := ErrorNone;
end;

function AddressIsBindable(Socket: PSocket; constref Endpoint: TNetworkEndpoint): Boolean;
begin
  if EndpointIsUnspecified(Endpoint) or IsLocalEndpointAddress(Endpoint) then
    Exit(True);
  Result := (Endpoint.Family = AddressFamilyIPv4) and (Socket^.Protocol = SocketProtocolUdp) and
    IsBroadcastAddress(Endpoint.Address, nil);
end;

function BindSocket(Socket: PSocket; constref Endpoint: TNetworkEndpoint; CallerIsRoot: Boolean): LongInt;
var
  Port: Word;
begin
  LockNetwork;
  if Socket^.IsBound or (Socket^.Connection <> nil) then
    Result := ErrorInvalidArgument
  else if Endpoint.Family <> Socket^.Family then
    Result := ErrorAddressFamilyNotSupported
  else if not AddressIsBindable(Socket, Endpoint) then
    Result := ErrorAddressNotAvailable
  else if (Endpoint.Port <> 0) and (Endpoint.Port < FirstUnprivilegedPort) and not CallerIsRoot and
          (Socket^.Protocol in [SocketProtocolUdp, SocketProtocolTcp]) then
    Result := ErrorAccessDenied
  else
  begin
    Result := ErrorNone;
    Port := Endpoint.Port;
    if Socket^.Protocol = SocketProtocolIcmpRaw then
      Port := 0
    else if Port = 0 then
    begin
      Port := ChooseDynamicPort(Socket, Endpoint);
      if Port = 0 then
        Result := ErrorAddressInUse;
    end
    else if not PortIsFree(Socket, Endpoint, Port, Socket^.ReuseAddress) then
      Result := ErrorAddressInUse;
    if Result = ErrorNone then
    begin
      Socket^.Local := Endpoint;
      Socket^.Local.Port := Port;
      Socket^.IsBound := True;
    end;
  end;
  UnlockNetwork;
end;

function ListenOnSocket(Socket: PSocket; Backlog: LongWord): LongInt;
begin
  if Socket^.Protocol <> SocketProtocolTcp then
    Exit(ErrorUnsupported);
  LockNetwork;
  Result := ListenOnTcpSocket(Socket, Backlog);
  UnlockNetwork;
end;

function AcceptOnSocket(Socket: PSocket; constref Owner: TSocketOwner; out NewSocket: PSocket;
  out Peer: TNetworkEndpoint): LongInt;
begin
  NewSocket := nil;
  Peer := UnspecifiedEndpoint(Socket^.Family);
  if Socket^.Protocol <> SocketProtocolTcp then
    Exit(ErrorUnsupported);
  LockNetwork;
  Result := AcceptOnTcpSocket(Socket, Owner, NewSocket);
  if Result = ErrorNone then
    Peer := NewSocket^.Peer;
  UnlockNetwork;
end;

function ConnectSocket(Socket: PSocket; constref Endpoint: TNetworkEndpoint): LongInt;
begin
  if (Endpoint.Family <> Socket^.Family) and
     ((Endpoint.Family <> AddressFamilyUnspecified) or (Socket^.Protocol = SocketProtocolTcp)) then
    Exit(ErrorAddressFamilyNotSupported);
  LockNetwork;
  if Socket^.Protocol = SocketProtocolTcp then
    Result := ConnectTcpSocket(Socket, Endpoint)
  else
    Result := ConnectDatagramSocket(Socket, Endpoint);
  UnlockNetwork;
end;

function SendOnSocket(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord;
  Destination: PNetworkEndpoint): Int64;
var
  Target: TNetworkEndpoint;
  Error: LongInt;
begin
  LockNetwork;
  if Socket^.Protocol = SocketProtocolTcp then
  begin
    { A stream goes to its peer; an address given is ignored. }
    Result := SendOnTcpSocket(Socket, Data, Length, Flags);
    UnlockNetwork;
    Exit;
  end;
  Error := TakePendingError(Socket);
  if Error <> ErrorNone then
    Result := -Error
  else if Socket^.SendIsShut then
    Result := -ErrorBrokenPipe
  else if (Destination = nil) and not Socket^.IsConnected then
    Result := -ErrorDestinationRequired
  else if (Destination <> nil) and (Destination^.Family <> Socket^.Family) then
    Result := -ErrorAddressFamilyNotSupported
  else
  begin
    if Destination = nil then
      Target := Socket^.Peer
    else
      Target := Destination^;
    if Socket^.Protocol = SocketProtocolUdp then
      Result := SendUdpDatagram(Socket, Data, Length, Target)
    else
      Result := SendIcmpMessage(Socket, Data, Length, Target);
  end;
  UnlockNetwork;
end;

function ReceiveOnSocket(Socket: PSocket; Data: PByte; Length: LongWord; Flags: LongWord;
  out Source: TNetworkEndpoint): Int64;
var
  Peer: TNetworkEndpoint;
begin
  Source := UnspecifiedEndpoint(Socket^.Family);
  LockNetwork;
  if Socket^.Protocol = SocketProtocolTcp then
  begin
    Result := ReceiveOnTcpSocket(Socket, Data, Length, Flags);
    if TcpPeer(Socket, Peer) then
      Source := Peer;
  end
  else
    Result := ReceiveDatagram(Socket, Data, Length, Flags, Source);
  UnlockNetwork;
end;

function ShutdownSocket(Socket: PSocket; How: LongWord): LongInt;
begin
  if (How = 0) or ((How and not SocketShutdownBoth) <> 0) then
    Exit(ErrorInvalidArgument);
  LockNetwork;
  if Socket^.Protocol = SocketProtocolTcp then
    Result := ShutdownTcpSocket(Socket, How)
  else
  begin
    if (How and SocketShutdownReceive) <> 0 then
      Socket^.ReceiveIsShut := True;
    if (How and SocketShutdownSend) <> 0 then
      Socket^.SendIsShut := True;
    UpdateSocketReadiness(Socket);
    Result := ErrorNone;
  end;
  UnlockNetwork;
end;

function ReadableBytes(Socket: PSocket): Int64;
var
  First: PDatagramEntry;
begin
  if Socket^.Protocol = SocketProtocolTcp then
    Exit(TcpReadableBytes(Socket));
  Result := 0;
  First := FirstDatagram(Socket^.Datagrams);
  if First <> nil then
    Result := First^.Length;
end;

function GetSocketOption(Socket: PSocket; Option: LongWord; out Value: Int64): LongInt;
begin
  Value := 0;
  Result := ErrorNone;
  LockNetwork;
  case Option of
    SocketOptionReceiveTimeout: Value := Socket^.ReceiveTimeout;
    SocketOptionSendTimeout: Value := Socket^.SendTimeout;
    SocketOptionBroadcast: Value := Ord(Socket^.BroadcastAllowed);
    SocketOptionReuseAddress: Value := Ord(Socket^.ReuseAddress);
    SocketOptionTimeToLive: Value := Socket^.TimeToLive;
    SocketOptionNonBlocking: Value := Ord(Socket^.NonBlocking);
    SocketOptionError:
      begin
        Value := TakePendingError(Socket);
        if (Value = ErrorNone) and (Socket^.Protocol = SocketProtocolTcp) then
          Value := TakeTcpError(Socket);
      end;
    SocketOptionNoDelay: Value := Ord(Socket^.NoDelay);
    SocketOptionKind: Value := Socket^.Kind;
    SocketOptionReceivedTimeToLive: Value := Socket^.ReceivedTimeToLive;
    SocketOptionInterface:
      if Socket^.BoundInterface <> nil then
        Value := Socket^.BoundInterface^.Index;
    SocketOptionReadableBytes: Value := ReadableBytes(Socket);
  else
    Result := ErrorInvalidArgument;
  end;
  UnlockNetwork;
end;

function SetSocketOption(Socket: PSocket; Option: LongWord; Value: Int64; CallerIsRoot: Boolean): LongInt;
var
  NetworkInterface: PNetworkInterface;
begin
  Result := ErrorNone;
  LockNetwork;
  case Option of
    SocketOptionReceiveTimeout, SocketOptionSendTimeout:
      if (Value < 0) or (Value > High(LongWord)) then
        Result := ErrorInvalidArgument
      else if Option = SocketOptionReceiveTimeout then
        Socket^.ReceiveTimeout := LongWord(Value)
      else
        Socket^.SendTimeout := LongWord(Value);
    SocketOptionBroadcast: Socket^.BroadcastAllowed := Value <> 0;
    SocketOptionReuseAddress: Socket^.ReuseAddress := Value <> 0;
    SocketOptionTimeToLive:
      if (Value < 1) or (Value > 255) then
        Result := ErrorInvalidArgument
      else
        Socket^.TimeToLive := Byte(Value);
    SocketOptionNonBlocking: Socket^.NonBlocking := Value <> 0;
    SocketOptionNoDelay: Socket^.NoDelay := Value <> 0;
    SocketOptionInterface:
      if not CallerIsRoot then
        Result := ErrorNotPermitted
      else if Value = 0 then
        Socket^.BoundInterface := nil
      else
      begin
        NetworkInterface := nil;
        if (Value > 0) and (Value <= High(LongWord)) then
          NetworkInterface := FindInterfaceByIndex(LongWord(Value));
        if NetworkInterface = nil then
          Result := ErrorNoDevice
        else
          Socket^.BoundInterface := NetworkInterface;
      end;
  else
    Result := ErrorInvalidArgument;
  end;
  if (Result = ErrorNone) and (Socket^.Protocol = SocketProtocolTcp) then
    ApplyTcpOptions(Socket);
  UnlockNetwork;
end;

function GetSocketEndpoint(Socket: PSocket; Which: LongWord; out Endpoint: TNetworkEndpoint): LongInt;
begin
  Endpoint := UnspecifiedEndpoint(Socket^.Family);
  Result := ErrorNone;
  LockNetwork;
  case Which of
    SocketAddressLocal:
      Endpoint := Socket^.Local;
    SocketAddressPeer:
      if Socket^.Protocol = SocketProtocolTcp then
      begin
        if not TcpPeer(Socket, Endpoint) then
          Result := ErrorNotConnected;
      end
      else if Socket^.IsConnected then
        Endpoint := Socket^.Peer
      else
        Result := ErrorNotConnected;
  else
    Result := ErrorInvalidArgument;
  end;
  UnlockNetwork;
end;

function ConditionsThatHold(Socket: PSocket; Conditions: LongWord): LongWord;
begin
  UpdateSocketReadiness(Socket);
  Result := 0;
  if ((Conditions and SocketReadable) <> 0) and EventIsSignaled(Socket^.Readable) then
    Result := Result or SocketReadable;
  if ((Conditions and SocketWritable) <> 0) and EventIsSignaled(Socket^.Writable) then
    Result := Result or SocketWritable;
end;

function WaitForSocketConditions(Socket: PSocket; Conditions: LongWord; TimeoutMilliseconds: Int64): Int64;
var
  Events: array[0..1] of PEvent;
  Count: LongInt;
  Signaled: LongInt;
  Timeout: QWord;
  Outcome: TWaitResult;
  Holding: LongWord;
begin
  Conditions := Conditions and (SocketReadable or SocketWritable);
  if Conditions = 0 then
    Exit(-ErrorInvalidArgument);
  Count := 0;
  if (Conditions and SocketReadable) <> 0 then
  begin
    Events[Count] := @Socket^.Readable;
    Inc(Count);
  end;
  if (Conditions and SocketWritable) <> 0 then
  begin
    Events[Count] := @Socket^.Writable;
    Inc(Count);
  end;
  if TimeoutMilliseconds < 0 then
    Timeout := InfiniteTimeout
  else
    Timeout := QWord(TimeoutMilliseconds);
  LockNetwork;
  Holding := ConditionsThatHold(Socket, Conditions);
  UnlockNetwork;
  if Holding <> 0 then
    Exit(Holding);
  Outcome := WaitForAnyEvent(@Events[0], Count, Timeout, True, Signaled);
  case Outcome of
    WaitTimedOut: Exit(-ErrorTimedOut);
    WaitAlerted: Exit(-ErrorInterrupted);
  end;
  LockNetwork;
  Result := ConditionsThatHold(Socket, Conditions);
  UnlockNetwork;
end;

end.
