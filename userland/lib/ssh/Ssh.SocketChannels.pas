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
  A channel joined to a TCP connection: what is forwarded with -L
  (direct-tcpip) and -R (forwarded-tcpip), on either side. What the
  channel receives goes into the socket through a writer thread
  (Ssh.HandleWriters), the channel's window opening as the socket takes
  it; what the socket gives is sent on the channel, read only while
  little waits for the peer's window.

  A channel may start with its socket still connecting (StartConnecting:
  a channel the peer opened, answered once the connection is made or
  refused) or with a connection already there (the other cases: the
  channel opened by this side, the relay starting when the peer
  confirms). End of file goes each way on its own (a socket shut down
  for sending, or EOF on the channel); once both ways are done, or the
  socket breaks, the channel closes. When the peer closes first, what
  it sent before its CLOSE may still be on its way into the socket (the
  peer often sends data, EOF and CLOSE at once): the socket is kept and
  this side's CLOSE held back until the writer has put it all in.

  TSshTcpListener is the listening end of a forwarding (ssh -L on the
  client, tcpip-forward on the server): each connection it accepts goes
  to its OnAccept.
}
unit Ssh.SocketChannels;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.InternetAddresses,
  Ssh.Connection,
  Ssh.PolledChannels,
  Ssh.HandleWriters;

type
  TSshSocketChannel = class(TSshPolledChannel)
  private
    FSocket: Int64;
    FProgressEvent: Int64;
    FWriter: TInputWriter;
    FConnecting: Boolean;
    FRelaying: Boolean;
    FSocketEnded: Boolean;
    FDraining: Boolean;
    FDescription: string;
    procedure SocketReadable;
    procedure StartRelay;
    procedure ReleaseSocket;
  protected
    procedure HandleData(const Data: string); override;
    procedure HandleEof; override;
    procedure HandleClose; override;
    procedure HandleOpenConfirmed; override;
    procedure HandleOpenFailed(Reason: LongWord; const Description: string); override;
  public
    { Socket (owned) is connected; the relay starts at once for a
      channel the peer opened, or when the peer confirms one this side
      opens. ProgressEvent (not owned) is the loop's. }
    constructor Create(Owner: TSshConnection; Socket, ProgressEvent: Int64; const Description: string);
    { A channel the peer opened whose socket connects now: confirmed or
      refused when the connection is made or fails. }
    constructor CreateConnecting(Owner: TSshConnection; Socket, ProgressEvent: Int64; const Description: string);
    destructor Destroy; override;
    procedure CollectWaits(var Waits: TSshWaitList); override;
    procedure Poll; override;
    function WantsQuickPoll: Boolean; override;
    property Description: string read FDescription;
  end;

  TSshTcpListener = class;

  TSshAcceptEvent = procedure(Listener: TSshTcpListener; Socket: Int64; const PeerHost: string;
    PeerPort: Word) of object;

  TSshTcpListener = class
  private
    FSocket: Int64;
    FBindHost: string;
    FPort: Word;
    FOnAccept: TSshAcceptEvent;
    procedure ConnectionWaiting;
  public
    TargetHost: string;
    TargetPort: Word;
    { Socket (owned) listens; BindHost and Port are as asked (Port the
      one bound when 0 was asked). }
    constructor Create(Socket: Int64; const BindHost: string; Port: Word; OnAccept: TSshAcceptEvent);
    destructor Destroy; override;
    procedure CollectWaits(var Waits: TSshWaitList);
    property BindHost: string read FBindHost;
    property Port: Word read FPort;
  end;

{ Listens on Host:Port: '' or '*' every address, 'localhost' the
  loopback address, else an address or a name. BoundPort is the port
  bound (Port, or the one chosen for 0). }
function OpenTcpListener(const Host: string; Port: Word; out Socket: Int64; out BoundPort: Word): LongInt;

{ A TCP socket connecting to Address:Port without waiting (its handle);
  minus an error code when it cannot even start. }
function StartConnecting(constref Address: TInternetAddress; Port: Word): Int64;
{ Host:Port resolved and a connection started to the first address. }
function StartConnectingToHost(const Host: string; Port: Word; out Socket: Int64): LongInt;

implementation

uses
  Sys.AddressText,
  Sys.Errors,
  Sys.HostLookup,
  Sys.HostNames,
  Sys.Kernel,
  Sys.Objects,
  Sys.Sockets,
  Ssh.Constants,
  Ssh.Wire;

const
  ReadChunkBytes = 16 * 1024;
  OutputBackLog = 64 * 1024;
  ListenBacklog = 8;

function ListenAddressFor(const Host: string; out Address: TInternetAddress): LongInt;
var
  Addresses: TInternetAddressArray;
  ScopeId: LongWord;
begin
  Result := ErrorNone;
  if (Host = '') or (Host = '*') or (Host = '0.0.0.0') then
    Address := AnyIpv4Address
  else if SameText(Host, 'localhost') then
    Address := LoopbackIpv4Address
  else if not TextToScopedAddress(Host, Address, ScopeId) then
  begin
    Result := ResolveHost(Host, HostFamilyAny, Addresses);
    if (Result = ErrorNone) and (Length(Addresses) = 0) then
      Result := ErrorNotFound;
    if Result = ErrorNone then
      Address := Addresses[0];
  end;
end;

function OpenTcpListener(const Host: string; Port: Word; out Socket: Int64; out BoundPort: Word): LongInt;
var
  Address: TInternetAddress;
  Family: LongWord;
  Bound: TAbiSocketAddress;
begin
  Socket := NoHandle;
  BoundPort := Port;
  Result := ListenAddressFor(Host, Address);
  if Result <> ErrorNone then
    Exit;
  if Address.Family = AddressFamilyIPv6 then
    Family := AddressFamilyIPv6
  else
    Family := AddressFamilyIPv4;
  Socket := CreateSocket(Family, SocketKindStream, ProtocolDefault);
  if Socket < 0 then
  begin
    Result := LongInt(-Socket);
    Socket := NoHandle;
    Exit;
  end;
  SetSocketOption(Socket, SocketOptionReuseAddress, 1);
  Result := BindSocket(Socket, MakeSocketAddress(Address, Port));
  if Result = ErrorNone then
    Result := ListenOnSocket(Socket, ListenBacklog);
  if Result <> ErrorNone then
  begin
    CloseSocket(Socket);
    Socket := NoHandle;
    Exit;
  end;
  if GetLocalSocketAddress(Socket, Bound) = ErrorNone then
    BoundPort := Bound.Port;
end;

constructor TSshTcpListener.Create(Socket: Int64; const BindHost: string; Port: Word; OnAccept: TSshAcceptEvent);
begin
  inherited Create;
  FSocket := Socket;
  FBindHost := BindHost;
  FPort := Port;
  FOnAccept := OnAccept;
end;

destructor TSshTcpListener.Destroy;
begin
  if FSocket >= 0 then
    CloseSocket(FSocket);
  inherited Destroy;
end;

procedure TSshTcpListener.CollectWaits(var Waits: TSshWaitList);
begin
  if FSocket >= 0 then
    AddWait(Waits, FSocket, @ConnectionWaiting);
end;

procedure TSshTcpListener.ConnectionWaiting;
var
  Socket: Int64;
  Peer: TAbiSocketAddress;
begin
  Socket := AcceptOnSocket(FSocket, Peer);
  if Socket < 0 then
    Exit;
  if Assigned(FOnAccept) then
    FOnAccept(Self, Socket, SocketHostToText(Peer), Peer.Port)
  else
    CloseSocket(Socket);
end;

function StartConnecting(constref Address: TInternetAddress; Port: Word): Int64;
var
  Family: LongWord;
  Error: LongInt;
begin
  if Address.Family = AddressFamilyIPv6 then
    Family := AddressFamilyIPv6
  else
    Family := AddressFamilyIPv4;
  Result := CreateSocket(Family, SocketKindStream, ProtocolDefault);
  if Result < 0 then
    Exit;
  SetSocketOption(Result, SocketOptionNonBlocking, 1);
  Error := ConnectSocket(Result, MakeSocketAddress(Address, Port));
  if (Error <> ErrorNone) and (Error <> ErrorInProgress) and (Error <> ErrorWouldBlock) then
  begin
    CloseSocket(Result);
    Result := -Error;
  end;
end;

function StartConnectingToHost(const Host: string; Port: Word; out Socket: Int64): LongInt;
var
  Addresses: TInternetAddressArray;
begin
  Socket := NoHandle;
  Result := ResolveHost(Host, HostFamilyAny, Addresses);
  if Result <> ErrorNone then
    Exit;
  if Length(Addresses) = 0 then
    Exit(ErrorNotFound);
  OrderAddressesForConnecting(Addresses);
  Socket := StartConnecting(Addresses[0], Port);
  if Socket < 0 then
  begin
    Result := LongInt(-Socket);
    Socket := NoHandle;
  end;
end;

constructor TSshSocketChannel.Create(Owner: TSshConnection; Socket, ProgressEvent: Int64; const Description: string);
begin
  inherited Create(Owner);
  FSocket := Socket;
  FProgressEvent := ProgressEvent;
  FDescription := Description;
end;

constructor TSshSocketChannel.CreateConnecting(Owner: TSshConnection; Socket, ProgressEvent: Int64;
  const Description: string);
begin
  Create(Owner, Socket, ProgressEvent, Description);
  FConnecting := True;
  DeferOpenConfirmation := True;
end;

destructor TSshSocketChannel.Destroy;
begin
  ReleaseSocket;
  inherited Destroy;
end;

procedure TSshSocketChannel.ReleaseSocket;
begin
  FreeAndNil(FWriter);
  if FSocket >= 0 then
    CloseSocket(FSocket);
  FSocket := NoHandle;
  FRelaying := False;
end;

procedure TSshSocketChannel.StartRelay;
begin
  if FRelaying or (FSocket < 0) then
    Exit;
  FRelaying := True;
  FWriter := TInputWriter.CreateWithEnd(FSocket, FProgressEvent, WriterEndShutdownSocket);
end;

procedure TSshSocketChannel.HandleOpenConfirmed;
begin
  StartRelay;
end;

procedure TSshSocketChannel.HandleOpenFailed(Reason: LongWord; const Description: string);
begin
  ReleaseSocket;
end;

procedure TSshSocketChannel.HandleData(const Data: string);
begin
  if (FWriter = nil) or FWriter.Broken then
    InputConsumed(Length(Data))
  else
    FWriter.Write(Data);
end;

procedure TSshSocketChannel.HandleEof;
begin
  if FWriter <> nil then
    FWriter.FinishWhenEmpty;
end;

procedure TSshSocketChannel.HandleClose;
begin
  if (FWriter <> nil) and not FWriter.Finished and not FWriter.Broken then
  begin
    FWriter.FinishWhenEmpty;
    FDraining := True;
    CloseReplyDeferred := True;
    Exit;
  end;
  ReleaseSocket;
end;

procedure TSshSocketChannel.SocketReadable;
var
  Buffer: array[0..ReadChunkBytes - 1] of Byte;
  Count: Int64;
begin
  Count := ReceiveOnSocket(FSocket, @Buffer[0], SizeOf(Buffer), 0);
  if Count > 0 then
    SendData(BytesToString(@Buffer[0], Integer(Count)))
  else if (Count = 0) or (ErrorCodeOf(Count) <> ErrorWouldBlock) then
  begin
    FSocketEnded := True;
    SendEofWhenFlushed;
  end;
end;

procedure TSshSocketChannel.CollectWaits(var Waits: TSshWaitList);
begin
  if FRelaying and not FSocketEnded and IsOpen and (PendingOutput < OutputBackLog) then
    AddWait(Waits, FSocket, @SocketReadable);
end;

function TSshSocketChannel.WantsQuickPoll: Boolean;
begin
  Result := FConnecting or FDraining;
end;

procedure TSshSocketChannel.Poll;
var
  Ready: Int64;
  Outcome: Int64;
  Written: QWord;
begin
  if FConnecting then
  begin
    Ready := WaitForSocket(FSocket, SocketWritable, 0);
    if Ready <= 0 then
      Exit;
    FConnecting := False;
    GetSocketOption(FSocket, SocketOptionError, Outcome);
    if Outcome <> ErrorNone then
    begin
      RejectOpen(OpenConnectFailed, FDescription + ': ' + ErrorMessage(LongInt(Outcome)));
      ReleaseSocket;
      Exit;
    end;
    SetSocketOption(FSocket, SocketOptionNonBlocking, 0);
    ConfirmOpen;
    StartRelay;
    Exit;
  end;
  if FDraining then
  begin
    if not FWriter.Finished and not FWriter.Broken then
      Exit;
    FDraining := False;
    ReleaseSocket;
    CloseNow;
    Exit;
  end;
  if not FRelaying then
    Exit;
  Written := FWriter.TakeWrittenCount;
  if Written > 0 then
    InputConsumed(Written);
  if FWriter.Broken then
  begin
    CloseNow;
    Exit;
  end;
  { Both ways ended: the socket gave its end and the peer's EOF is
    written out. }
  if FSocketEnded and EofSent and EofReceived and (FWriter.Pending = 0) then
    CloseNow;
end;

end.
