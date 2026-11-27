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
  networktest's TCP extension pieces, over 127.0.0.1: the keep-alive
  options (defaults, set and read back, wrong values refused, taken by
  an accepted connection from its listener); window scaling, SACK and
  timestamps agreed by both ends; and transfers that make the stack
  work - through a forced 4 KiB receive window, and with every 20th
  data segment dropped on arrival (the root-only test hook
  SocketOptionTestDropEvery), which only SACK recovery and
  retransmission get through intact. Each function answers one
  question; the program turns the answers into its check lines.
}
unit NetworkTest.TcpFeatures;

{$mode objfpc}
{$H+}

interface

{ The keep-alive options read back as Linux's defaults, then as set. }
function KeepAliveOptionsWork: Boolean;
{ Wrong keep-alive values are refused. }
function KeepAliveRefusesWrongValues: Boolean;
{ An accepted connection has its listener's keep-alive options. }
function AcceptedTakesKeepAlive: Boolean;
{ Both ends of a loopback connection agreed on window scaling, SACK and
  timestamps. }
function TcpFeaturesAgreed: Boolean;
{ Bytes through a connection whose receiver keeps a 4 KiB buffer: all
  arrive, in order, and the buffer stays 4 KiB. }
function TransferThroughSmallWindow(Bytes: QWord): Boolean;
{ Bytes through a connection that loses every DropEvery'th data
  segment: all arrive in order; Retransmissions is how many segments the
  sender sent again. }
function TransferWithLoss(Bytes: QWord; DropEvery: LongWord; out Retransmissions: Int64): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Sys.Sockets,
  Sys.Threads;

const
  WaitMilliseconds = 15000;
  ChunkBytes = 16384;
  SmallWindowBytes = 4096;

function PatternByte(Position: QWord): Byte;
begin
  Result := Byte(Position * 13 + (Position shr 9));
end;

function Loopback(Port: Word): TAbiSocketAddress;
begin
  Result := MakeSocketAddress(LoopbackIpv4Address, Port);
end;

function LocalPortOf(Socket: Int64): Word;
var
  Address: TAbiSocketAddress;
begin
  Result := 0;
  if GetLocalSocketAddress(Socket, Address) = ErrorNone then
    Result := Address.Port;
end;

function OptionIs(Socket: Int64; Option: LongWord; Expected: Int64): Boolean;
var
  Value: Int64;
begin
  Result := (GetSocketOption(Socket, Option, Value) = ErrorNone) and (Value = Expected);
end;

function NewStreamSocket: Int64;
begin
  Result := CreateSocket(AddressFamilyIPv4, SocketKindStream, ProtocolTcp);
end;

{ A listener on 127.0.0.1 with a port of its own; -1 if that failed. }
function NewListener: Int64;
begin
  Result := NewStreamSocket;
  if Result < 0 then
    Exit;
  SetSocketOption(Result, SocketOptionReceiveTimeout, WaitMilliseconds);
  if BindSocket(Result, Loopback(0)) <> ErrorNone then
  begin
    CloseSocket(Result);
    Result := -1;
  end;
end;

{ Connects a client to Listener (which must listen) and accepts it. }
function ConnectPair(Listener: Int64; out Client, Accepted: Int64): Boolean;
var
  Peer: TAbiSocketAddress;
begin
  Accepted := -1;
  Client := NewStreamSocket;
  if Client < 0 then
    Exit(False);
  SetSocketOption(Client, SocketOptionReceiveTimeout, WaitMilliseconds);
  SetSocketOption(Client, SocketOptionSendTimeout, WaitMilliseconds);
  if ConnectSocket(Client, Loopback(LocalPortOf(Listener))) <> ErrorNone then
    Exit(False);
  Accepted := AcceptOnSocket(Listener, Peer);
  if Accepted < 0 then
    Exit(False);
  SetSocketOption(Accepted, SocketOptionReceiveTimeout, WaitMilliseconds);
  Result := True;
end;

procedure CloseAll(const Sockets: array of Int64);
var
  Index: Integer;
begin
  for Index := 0 to High(Sockets) do
    if Sockets[Index] >= 0 then
      CloseSocket(Sockets[Index]);
end;

function KeepAliveOptionsWork: Boolean;
var
  Socket: Int64;
begin
  Socket := NewStreamSocket;
  try
    Result := OptionIs(Socket, SocketOptionKeepAlive, 0) and OptionIs(Socket, SocketOptionKeepIdle, 7200) and
      OptionIs(Socket, SocketOptionKeepInterval, 75) and OptionIs(Socket, SocketOptionKeepCount, 9);
    Result := Result and (SetSocketOption(Socket, SocketOptionKeepAlive, 1) = ErrorNone) and
      (SetSocketOption(Socket, SocketOptionKeepIdle, 30) = ErrorNone) and
      (SetSocketOption(Socket, SocketOptionKeepInterval, 5) = ErrorNone) and
      (SetSocketOption(Socket, SocketOptionKeepCount, 3) = ErrorNone);
    Result := Result and OptionIs(Socket, SocketOptionKeepAlive, 1) and OptionIs(Socket, SocketOptionKeepIdle, 30) and
      OptionIs(Socket, SocketOptionKeepInterval, 5) and OptionIs(Socket, SocketOptionKeepCount, 3);
  finally
    CloseSocket(Socket);
  end;
end;

function KeepAliveRefusesWrongValues: Boolean;
var
  Socket: Int64;
begin
  Socket := NewStreamSocket;
  try
    Result := (SetSocketOption(Socket, SocketOptionKeepIdle, 0) = ErrorInvalidArgument) and
      (SetSocketOption(Socket, SocketOptionKeepInterval, -5) = ErrorInvalidArgument) and
      (SetSocketOption(Socket, SocketOptionKeepCount, 0) = ErrorInvalidArgument) and
      (SetSocketOption(Socket, SocketOptionReceiveBuffer, 100) = ErrorInvalidArgument) and
      OptionIs(Socket, SocketOptionKeepIdle, 7200);
  finally
    CloseSocket(Socket);
  end;
end;

function AcceptedTakesKeepAlive: Boolean;
var
  Listener: Int64;
  Client: Int64;
  Accepted: Int64;
begin
  Result := False;
  Client := -1;
  Accepted := -1;
  Listener := NewListener;
  try
    if Listener < 0 then
      Exit;
    SetSocketOption(Listener, SocketOptionKeepAlive, 1);
    SetSocketOption(Listener, SocketOptionKeepIdle, 600);
    SetSocketOption(Listener, SocketOptionKeepCount, 4);
    if (ListenOnSocket(Listener, 2) <> ErrorNone) or not ConnectPair(Listener, Client, Accepted) then
      Exit;
    Result := OptionIs(Accepted, SocketOptionKeepAlive, 1) and OptionIs(Accepted, SocketOptionKeepIdle, 600) and
      OptionIs(Accepted, SocketOptionKeepCount, 4) and OptionIs(Client, SocketOptionKeepAlive, 0);
  finally
    CloseAll([Accepted, Client, Listener]);
  end;
end;

function TcpFeaturesAgreed: Boolean;
const
  Everything = TcpFeatureWindowScaling or TcpFeatureSack or TcpFeatureTimestamps;
var
  Listener: Int64;
  Client: Int64;
  Accepted: Int64;
begin
  Result := False;
  Client := -1;
  Accepted := -1;
  Listener := NewListener;
  try
    if (Listener < 0) or (ListenOnSocket(Listener, 2) <> ErrorNone) or
       not ConnectPair(Listener, Client, Accepted) then
      Exit;
    Result := OptionIs(Client, SocketOptionTcpFeatures, Everything) and
      OptionIs(Accepted, SocketOptionTcpFeatures, Everything);
  finally
    CloseAll([Accepted, Client, Listener]);
  end;
end;

{ --- Transfers --------------------------------------------------------------- }

type
  TSenderJob = record
    Socket: Int64;
    Bytes: QWord;
  end;
  PSenderJob = ^TSenderJob;

{ Sends the pattern, then shuts the sending side. }
function RunSender(Argument: Pointer): LongInt;
var
  Job: PSenderJob;
  Buffer: array[0..ChunkBytes - 1] of Byte;
  Done: QWord;
  Count: QWord;
  Index: QWord;
begin
  Job := PSenderJob(Argument);
  Done := 0;
  while Done < Job^.Bytes do
  begin
    Count := Job^.Bytes - Done;
    if Count > ChunkBytes then
      Count := ChunkBytes;
    for Index := 0 to Count - 1 do
      Buffer[Index] := PatternByte(Done + Index);
    if SendAll(Job^.Socket, @Buffer[0], Count) <> ErrorNone then
      Exit(1);
    Done := Done + Count;
  end;
  ShutdownSocket(Job^.Socket, SocketShutdownSend);
  Result := 0;
end;

{ Reads to the end; True if exactly Bytes of the pattern came. }
function ReceivePattern(Socket: Int64; Bytes: QWord): Boolean;
var
  Buffer: array[0..ChunkBytes - 1] of Byte;
  Received: QWord;
  Length: Int64;
  Index: Int64;
begin
  Received := 0;
  Result := True;
  repeat
    Length := ReceiveOnSocket(Socket, @Buffer[0], SizeOf(Buffer), 0);
    if Length < 0 then
      Exit(False);
    for Index := 0 to Length - 1 do
      if Buffer[Index] <> PatternByte(Received + QWord(Index)) then
        Result := False;
    Received := Received + QWord(Length);
  until Length = 0;
  Result := Result and (Received = Bytes);
end;

{ Sends Bytes from Client to Accepted on a sender thread; True if they
  all arrived in order and the sender finished. }
function Transfer(Client, Accepted: Int64; Bytes: QWord): Boolean;
var
  Job: TSenderJob;
  Sender: Int64;
  SenderCode: LongInt;
begin
  Job.Socket := Client;
  Job.Bytes := Bytes;
  Sender := CreateThread(@RunSender, @Job);
  if Sender < 0 then
    Exit(False);
  Result := ReceivePattern(Accepted, Bytes);
  Result := (WaitForThread(Sender, WaitMilliseconds, SenderCode) = 0) and (SenderCode = 0) and Result;
  CloseThreadHandle(Sender);
end;

function TransferThroughSmallWindow(Bytes: QWord): Boolean;
var
  Listener: Int64;
  Client: Int64;
  Accepted: Int64;
begin
  Result := False;
  Client := -1;
  Accepted := -1;
  Listener := NewListener;
  try
    if Listener < 0 then
      Exit;
    SetSocketOption(Listener, SocketOptionReceiveBuffer, SmallWindowBytes);
    if (ListenOnSocket(Listener, 2) <> ErrorNone) or not ConnectPair(Listener, Client, Accepted) then
      Exit;
    Result := Transfer(Client, Accepted, Bytes) and OptionIs(Accepted, SocketOptionReceiveBuffer, SmallWindowBytes);
  finally
    CloseAll([Accepted, Client, Listener]);
  end;
end;

function TransferWithLoss(Bytes: QWord; DropEvery: LongWord; out Retransmissions: Int64): Boolean;
var
  Listener: Int64;
  Client: Int64;
  Accepted: Int64;
begin
  Result := False;
  Retransmissions := 0;
  Client := -1;
  Accepted := -1;
  Listener := NewListener;
  try
    if (Listener < 0) or (SetSocketOption(Listener, SocketOptionTestDropEvery, DropEvery) <> ErrorNone) then
      Exit;
    if (ListenOnSocket(Listener, 2) <> ErrorNone) or not ConnectPair(Listener, Client, Accepted) then
      Exit;
    Result := Transfer(Client, Accepted, Bytes);
    GetSocketOption(Client, SocketOptionTcpRetransmissions, Retransmissions);
  finally
    CloseAll([Accepted, Client, Listener]);
  end;
end;

end.
