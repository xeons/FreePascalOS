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
  System calls for sockets (CallCreateSocket to CallWaitForSocket), and
  reading and writing socket handles with CallRead and CallWrite.

  Each call takes a reference to the socket behind the handle for its
  duration, copies addresses and data between the program and kernel
  buffers (data in pieces of at most TransferChunkSize), and leaves the
  work to Network.SocketOperations.
}
unit Processes.SocketCalls;

{$mode objfpc}

interface

function PerformCreateSocket(Family, Kind, Protocol: QWord): Int64;
function PerformBindSocket(Handle: Int64; AddressAddress: QWord): Int64;
function PerformListenSocket(Handle: Int64; Backlog: QWord): Int64;
function PerformAcceptSocket(Handle: Int64; PeerAddress: QWord): Int64;
function PerformConnectSocket(Handle: Int64; AddressAddress: QWord): Int64;
function PerformSendSocket(Handle: Int64; BufferAddress, Length, Flags, AddressAddress: QWord): Int64;
function PerformReceiveSocket(Handle: Int64; BufferAddress, Length, Flags, AddressAddress: QWord): Int64;
function PerformShutdownSocket(Handle: Int64; How: QWord): Int64;
function PerformGetSocketOption(Handle: Int64; Option: QWord): Int64;
function PerformSetSocketOption(Handle: Int64; Option: QWord; Value: Int64): Int64;
function PerformGetSocketAddress(Handle: Int64; Which, AddressAddress: QWord): Int64;
function PerformWaitForSocket(Handle: Int64; Conditions: QWord; Timeout: Int64): Int64;

{ CallRead and CallWrite on a socket handle (ObjectBody is the socket):
  a receive or send without an address or flags. }
function ReadSocketHandle(ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
function WriteSocketHandle(ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Objects.Manager,
  Kernel.Mutex,
  Processes.Handles,
  Processes.Process,
  Processes.Thread,
  Processes.UserAccess,
  Processes.ObjectCalls,
  Processes.Restrictions,
  Network.Addresses,
  Network.Sockets,
  Network.SocketOperations;

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

function CallerIsRoot: Boolean;
begin
  Result := CurrentProcess^.Credentials.EffectiveUserId = RootUserId;
end;

function ReferenceSocket(Handle: Int64): PSocket;
begin
  Result := PSocket(ReferenceHandleOfKind(Handle, HandleKindSocket));
end;

function CopyEndpointFromUser(AddressAddress: QWord; out Endpoint: TNetworkEndpoint): LongInt;
var
  Address: TAbiSocketAddress;
begin
  Endpoint := MakeEndpoint(AnyAddress, 0);
  Result := CopyFromUser(@Address, AddressAddress, SizeOf(Address));
  if Result <> ErrorNone then
    Exit;
  Result := EndpointFromAbi(Address, Endpoint);
end;

function CopyEndpointToUser(AddressAddress: QWord; constref Endpoint: TNetworkEndpoint): LongInt;
var
  Address: TAbiSocketAddress;
begin
  if AddressAddress = 0 then
    Exit(ErrorNone);
  EndpointToAbi(Endpoint, Address);
  Result := CopyToUser(AddressAddress, @Address, SizeOf(Address));
end;

function InsertSocketHandle(Socket: PSocket): Int64;
var
  Process: PProcess;
begin
  Process := CurrentProcess;
  AcquireMutex(Process^.Lock);
  Result := InsertHandle(Process^.Handles, HandleKindSocket, Socket, 0);
  ReleaseMutex(Process^.Lock);
  if Result < 0 then
    Result := Failure(ErrorTooManyHandles);
end;

{ The calling process, as the owner of the sockets it makes or accepts. }
function CallerAsOwner: TSocketOwner;
begin
  Result.UserId := CurrentProcess^.Credentials.EffectiveUserId;
  Result.ProcessId := CurrentProcess^.ProcessId;
end;

function PerformCreateSocket(Family, Kind, Protocol: QWord): Int64;
var
  Socket: PSocket;
  Error: LongInt;
begin
  if CallerRestricted(RestrictNetwork) then
    Exit(Failure(ErrorAccessDenied));
  if (Family > $FFFF) or (Kind > $FFFF) or (Protocol > $FF) then
    Exit(Failure(ErrorInvalidArgument));
  Error := CreateSocket(LongWord(Family), LongWord(Kind), LongWord(Protocol), CallerAsOwner, CallerIsRoot,
    Socket);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := InsertSocketHandle(Socket);
  DereferenceObject(Socket);
end;

function PerformBindSocket(Handle: Int64; AddressAddress: QWord): Int64;
var
  Socket: PSocket;
  Endpoint: TNetworkEndpoint;
  Error: LongInt;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Error := CopyEndpointFromUser(AddressAddress, Endpoint);
  if Error = ErrorNone then
    Error := BindSocket(Socket, Endpoint, CallerIsRoot);
  DereferenceObject(Socket);
  Result := Failure(Error);
end;

function PerformListenSocket(Handle: Int64; Backlog: QWord): Int64;
var
  Socket: PSocket;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  if Backlog > MaximumListenBacklog then
    Backlog := MaximumListenBacklog;
  Result := Failure(ListenOnSocket(Socket, LongWord(Backlog)));
  DereferenceObject(Socket);
end;

function PerformAcceptSocket(Handle: Int64; PeerAddress: QWord): Int64;
var
  Socket: PSocket;
  NewSocket: PSocket;
  Peer: TNetworkEndpoint;
  Error: LongInt;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Error := AcceptOnSocket(Socket, CallerAsOwner, NewSocket, Peer);
  DereferenceObject(Socket);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Error := CopyEndpointToUser(PeerAddress, Peer);
  if Error = ErrorNone then
    Result := InsertSocketHandle(NewSocket)
  else
    Result := Failure(Error);
  DereferenceObject(NewSocket);
end;

function PerformConnectSocket(Handle: Int64; AddressAddress: QWord): Int64;
var
  Socket: PSocket;
  Address: TAbiSocketAddress;
  Endpoint: TNetworkEndpoint;
  Error: LongInt;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Error := CopyFromUser(@Address, AddressAddress, SizeOf(Address));
  if Error = ErrorNone then
  begin
    if Address.Family = AddressFamilyUnspecified then
    begin
      { Forgets a datagram socket's peer. }
      Endpoint := MakeEndpoint(AnyAddress, 0);
      Endpoint.Family := AddressFamilyUnspecified;
    end
    else
      Error := EndpointFromAbi(Address, Endpoint);
  end;
  if Error = ErrorNone then
    Error := ConnectSocket(Socket, Endpoint);
  DereferenceObject(Socket);
  Result := Failure(Error);
end;

{ Sends from user memory: a stream in pieces, a datagram whole. }
function SendFromUser(Socket: PSocket; BufferAddress, Length, Flags: QWord; Destination: PNetworkEndpoint): Int64;
var
  Buffer: PByte;
  BufferSize: QWord;
  Total: QWord;
  Piece: QWord;
  Sent: Int64;
begin
  if not UserRangeIsValid(BufferAddress, Length, False) then
    Exit(Failure(ErrorBadAddress));
  if (Socket^.Protocol <> SocketProtocolTcp) and (Length > TransferChunkSize) then
    Exit(Failure(ErrorMessageTooLong));
  Buffer := PByte(AllocateTransferBuffer(Length, BufferSize));
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory));
  Total := 0;
  Result := 0;
  repeat
    Piece := Length - Total;
    if Piece > BufferSize then
      Piece := BufferSize;
    if CopyFromUser(Buffer, BufferAddress + Total, Piece) <> ErrorNone then
      Sent := Failure(ErrorBadAddress)
    else
      Sent := SendOnSocket(Socket, Buffer, LongWord(Piece), LongWord(Flags), Destination);
    if Sent < 0 then
    begin
      if Total = 0 then
        Result := Sent;
      Break;
    end;
    Total := Total + QWord(Sent);
  until (QWord(Sent) < Piece) or (Total >= Length);
  if Total > 0 then
    Result := Int64(Total);
  FreeTransferBuffer(Buffer);
end;

function PerformSendSocket(Handle: Int64; BufferAddress, Length, Flags, AddressAddress: QWord): Int64;
var
  Socket: PSocket;
  Destination: TNetworkEndpoint;
  Error: LongInt;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  if AddressAddress <> 0 then
  begin
    Error := CopyEndpointFromUser(AddressAddress, Destination);
    if Error <> ErrorNone then
    begin
      DereferenceObject(Socket);
      Exit(Failure(Error));
    end;
    Result := SendFromUser(Socket, BufferAddress, Length, Flags, @Destination);
  end
  else
    Result := SendFromUser(Socket, BufferAddress, Length, Flags, nil);
  DereferenceObject(Socket);
end;

function ReceiveToUser(Socket: PSocket; BufferAddress, Length, Flags, AddressAddress: QWord): Int64;
var
  Buffer: PByte;
  BufferSize: QWord;
  Source: TNetworkEndpoint;
  Error: LongInt;
begin
  if not UserRangeIsValid(BufferAddress, Length, True) then
    Exit(Failure(ErrorBadAddress));
  Buffer := PByte(AllocateTransferBuffer(Length, BufferSize));
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory));
  if Length = 0 then
    BufferSize := 0;
  Result := ReceiveOnSocket(Socket, Buffer, LongWord(BufferSize), LongWord(Flags), Source);
  if Result > 0 then
  begin
    if CopyToUser(BufferAddress, Buffer, QWord(Result)) <> ErrorNone then
      Result := Failure(ErrorBadAddress);
  end;
  if Result >= 0 then
  begin
    Error := CopyEndpointToUser(AddressAddress, Source);
    if Error <> ErrorNone then
      Result := Failure(Error);
  end;
  FreeTransferBuffer(Buffer);
end;

function PerformReceiveSocket(Handle: Int64; BufferAddress, Length, Flags, AddressAddress: QWord): Int64;
var
  Socket: PSocket;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Result := ReceiveToUser(Socket, BufferAddress, Length, Flags, AddressAddress);
  DereferenceObject(Socket);
end;

function PerformShutdownSocket(Handle: Int64; How: QWord): Int64;
var
  Socket: PSocket;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Result := Failure(ShutdownSocket(Socket, LongWord(How and $FF)));
  DereferenceObject(Socket);
end;

function PerformGetSocketOption(Handle: Int64; Option: QWord): Int64;
var
  Socket: PSocket;
  Value: Int64;
  Error: LongInt;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Error := GetSocketOption(Socket, LongWord(Option), Value);
  DereferenceObject(Socket);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  Result := Value;
end;

{ SocketOptionJoinGroup and SocketOptionLeaveGroup: Value is the
  address of a TAbiMulticastMembership. }
function SetMembershipFromUser(Socket: PSocket; Option: LongWord; Value: Int64): LongInt;
var
  Request: TAbiMulticastMembership;
begin
  Result := CopyFromUser(@Request, QWord(Value), SizeOf(Request));
  if Result = ErrorNone then
    Result := SetSocketMembership(Socket, Option, Request);
end;

function PerformSetSocketOption(Handle: Int64; Option: QWord; Value: Int64): Int64;
var
  Socket: PSocket;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  if (Option = SocketOptionJoinGroup) or (Option = SocketOptionLeaveGroup) then
    Result := Failure(SetMembershipFromUser(Socket, LongWord(Option), Value))
  else
    Result := Failure(SetSocketOption(Socket, LongWord(Option), Value, CallerIsRoot));
  DereferenceObject(Socket);
end;

function PerformGetSocketAddress(Handle: Int64; Which, AddressAddress: QWord): Int64;
var
  Socket: PSocket;
  Endpoint: TNetworkEndpoint;
  Error: LongInt;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Error := GetSocketEndpoint(Socket, LongWord(Which), Endpoint);
  DereferenceObject(Socket);
  if Error = ErrorNone then
    Error := CopyEndpointToUser(AddressAddress, Endpoint);
  Result := Failure(Error);
end;

function PerformWaitForSocket(Handle: Int64; Conditions: QWord; Timeout: Int64): Int64;
var
  Socket: PSocket;
begin
  Socket := ReferenceSocket(Handle);
  if Socket = nil then
    Exit(Failure(ErrorBadHandle));
  Result := WaitForSocketConditions(Socket, LongWord(Conditions), Timeout);
  DereferenceObject(Socket);
end;

function ReadSocketHandle(ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
begin
  ReferenceObject(ObjectBody);
  Result := ReceiveToUser(PSocket(ObjectBody), BufferAddress, ByteCount, 0, 0);
  DereferenceObject(ObjectBody);
end;

function WriteSocketHandle(ObjectBody: Pointer; BufferAddress, ByteCount: QWord): Int64;
begin
  ReferenceObject(ObjectBody);
  Result := SendFromUser(PSocket(ObjectBody), BufferAddress, ByteCount, 0, nil);
  DereferenceObject(ObjectBody);
end;

end.
