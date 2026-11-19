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
  One client connection, served by a process of its own (sshd
  --connection, the socket as its standard input): the transport, user
  authentication, then the channels, in one loop that waits on the
  socket, the writers' progress event, and everything the channels and
  forwardings wait on (Ssh.PolledChannels) at once.

  The client has LoginGraceTime seconds to log in. Once it has, the
  configuration is the one for this user and address (Match blocks).
  With ClientAliveInterval, a client silent for that long is asked
  (keepalive@openssh.com, a global request any reply answers); after
  ClientAliveCountMax questions without an answer the connection ends.
  Whatever ends the connection - the client leaving, a protocol error,
  a DISCONNECT - ends every session's programs with it.
}
unit Sshd.ConnectionLoop;

{$mode objfpc}{$H+}

interface

uses
  Sshd.Configuration;

{ Serves the connection on Socket until it ends; returns the exit code. }
function ServeConnection(Socket: Int64; const Configuration: TSshdConfiguration): LongInt;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.AddressText,
  Sys.Errors,
  Sys.Kernel,
  Sys.Objects,
  Sys.Sockets,
  Util.Accounts,
  Util.Logins,
  Ssh.Constants,
  Ssh.Wire,
  Ssh.HostKeys,
  Ssh.Transport,
  Ssh.ServerTransport,
  Ssh.UserAuthentication,
  Ssh.Connection,
  Ssh.PolledChannels,
  Sshd.Accounts,
  Sshd.Forwarding,
  Sshd.HostKeyStore,
  Sshd.Sessions,
  Sshd.Log;

const
  SoftwareVersion = 'FreePascalOS_1.0';
  ReceiveChunkBytes = 32 * 1024;
  PollMilliseconds = 1000;
  QuickPollMilliseconds = 20;
  KeepAliveRequest = 'keepalive@openssh.com';

type
  TConnectionServer = class
  private
    FSocket: Int64;
    FConfiguration: TSshdConfiguration;
    FHostKeys: THostKeyArray;
    FTransport: TSshServerTransport;
    FPolicy: TSystemAccountPolicy;
    FAuthenticator: TSshUserAuthenticator;
    FConnection: TSshConnection;
    FForwards: TRemoteForwards;
    FContext: TSessionContext;
    FPeerText: string;
    FPeerAddress: string;
    FLocalPort: Word;
    FStartTime: QWord;
    FLastReceiveTime: QWord;
    FLastProbeTime: QWord;
    FUnansweredProbes: Integer;
    FEnded: Boolean;
    function DescribeEnds: Boolean;
    function SendOutput: Boolean;
    procedure SocketReadable;
    procedure ProgressSignaled;
    procedure HandleMessages;
    procedure BeginConnectionProtocol;
    function OpenChannel(Connection: TSshConnection; const ChannelType: string; var Reader: TSshReader;
      out FailureReason: LongWord): TSshChannel;
    function GlobalRequest(Connection: TSshConnection; const RequestName: string; var Reader: TSshReader;
      out ReplyData: string): Boolean;
    procedure KeepAliveAnswered(Succeeded: Boolean; const ReplyData: string);
    function SessionCount: Integer;
    procedure CheckClientAlive;
    function WaitTimeout: Int64;
    procedure WaitOnce;
    procedure Disconnect(Reason: LongWord; const Description: string);
  public
    constructor Create(Socket: Int64; const Configuration: TSshdConfiguration);
    destructor Destroy; override;
    function Run: LongInt;
  end;

constructor TConnectionServer.Create(Socket: Int64; const Configuration: TSshdConfiguration);
begin
  inherited Create;
  FSocket := Socket;
  FConfiguration := Configuration;
  FContext.ProgressEvent := CreateEvent(False, False);
  FContext.Configuration := Configuration;
end;

destructor TConnectionServer.Destroy;
var
  Index: Integer;
begin
  { Ends every session's programs and forwarding. }
  FForwards.Free;
  FConnection.Free;
  FAuthenticator.Free;
  FPolicy.Free;
  FTransport.Free;
  for Index := 0 to High(FHostKeys) do
    FHostKeys[Index].Free;
  if FContext.ProgressEvent >= 0 then
    CloseHandle(FContext.ProgressEvent);
  inherited Destroy;
end;

{ SSH_CONNECTION and the log's "from" text. }
function TConnectionServer.DescribeEnds: Boolean;
var
  Peer, Local: TAbiSocketAddress;
begin
  Result := (GetPeerSocketAddress(FSocket, Peer) = ErrorNone) and
    (GetLocalSocketAddress(FSocket, Local) = ErrorNone);
  if not Result then
    Exit;
  FPeerAddress := SocketHostToText(Peer);
  FLocalPort := Local.Port;
  FPeerText := FPeerAddress + ' port ' + IntToStr(Peer.Port);
  FContext.ConnectionText := FPeerAddress + ' ' + IntToStr(Peer.Port) + ' ' +
    SocketHostToText(Local) + ' ' + IntToStr(Local.Port);
end;

function TConnectionServer.SendOutput: Boolean;
var
  Output: string;
begin
  Result := True;
  if not FTransport.HasOutput then
    Exit;
  Output := FTransport.TakeOutput;
  Result := SendAll(FSocket, @Output[1], Length(Output)) = ErrorNone;
end;

procedure TConnectionServer.Disconnect(Reason: LongWord; const Description: string);
begin
  LogLine('disconnecting ' + FPeerText + ': ' + Description);
  FTransport.SendDisconnect(Reason, Description);
  SendOutput;
  FEnded := True;
end;

procedure TConnectionServer.SocketReadable;
var
  Buffer: array[0..ReceiveChunkBytes - 1] of Byte;
  Count: Int64;
begin
  Count := ReceiveOnSocket(FSocket, @Buffer[0], SizeOf(Buffer), 0);
  if Count <= 0 then
  begin
    LogLine('connection from ' + FPeerText + ' closed');
    FEnded := True;
    Exit;
  end;
  FLastReceiveTime := GetTickCount64;
  FTransport.Receive(BytesToString(@Buffer[0], Integer(Count)));
  HandleMessages;
end;

procedure TConnectionServer.ProgressSignaled;
begin
  { A writer took input; Poll opens the windows. }
end;

function TConnectionServer.SessionCount: Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to FConnection.ChannelCount - 1 do
    if FConnection.ChannelAt(Index) is TSessionChannel then
      Inc(Result);
end;

function TConnectionServer.OpenChannel(Connection: TSshConnection; const ChannelType: string;
  var Reader: TSshReader; out FailureReason: LongWord): TSshChannel;
var
  Forwarding: TForwardingContext;
begin
  Result := nil;
  FailureReason := OpenUnknownChannelType;
  if ChannelType = 'session' then
  begin
    if SessionCount >= FContext.Configuration.MaximumSessions then
    begin
      FailureReason := OpenResourceShortage;
      Exit;
    end;
    Result := TSessionChannel.Create(Connection, FContext);
  end
  else if ChannelType = 'direct-tcpip' then
  begin
    Forwarding.Configuration := FContext.Configuration;
    Forwarding.Options := FContext.Options;
    Forwarding.UserName := FContext.Account.Name;
    Forwarding.IsRoot := FContext.Account.Identity.UserId = RootId;
    Forwarding.ProgressEvent := FContext.ProgressEvent;
    Result := OpenDirectChannel(Connection, Reader, Forwarding, FailureReason);
  end;
end;

function TConnectionServer.GlobalRequest(Connection: TSshConnection; const RequestName: string;
  var Reader: TSshReader; out ReplyData: string): Boolean;
var
  Handled: Boolean;
begin
  ReplyData := '';
  Result := FForwards.HandleGlobalRequest(RequestName, Reader, Handled, ReplyData);
end;

procedure TConnectionServer.KeepAliveAnswered(Succeeded: Boolean; const ReplyData: string);
begin
  { Any answer, even a refusal, says the client is there. }
  FUnansweredProbes := 0;
end;

procedure TConnectionServer.BeginConnectionProtocol;
var
  Forwarding: TForwardingContext;
begin
  if not FindLoginAccount(FAuthenticator.UserName, FContext.Account) then
  begin
    Disconnect(DisconnectByApplication, 'the account is gone');
    Exit;
  end;
  FContext.Configuration := ConfigurationFor(FConfiguration,
    MatchContextFor(FAuthenticator.UserName, FPeerAddress, FLocalPort));
  FContext.Options := FAuthenticator.Options;
  LogLine(Format('%s logged in with %s from %s', [FAuthenticator.UserName, FAuthenticator.Method, FPeerText]));
  FConnection := TSshConnection.Create(FTransport);
  FConnection.OnChannelOpen := @OpenChannel;
  FConnection.OnGlobalRequest := @GlobalRequest;
  Forwarding.Configuration := FContext.Configuration;
  Forwarding.Options := FContext.Options;
  Forwarding.UserName := FContext.Account.Name;
  Forwarding.IsRoot := FContext.Account.Identity.UserId = RootId;
  Forwarding.ProgressEvent := FContext.ProgressEvent;
  FForwards := TRemoteForwards.Create(FConnection, Forwarding);
end;

procedure TConnectionServer.HandleMessages;
var
  Message: TSshReceivedMessage;
  MessageType: Byte;
begin
  while not FEnded and FTransport.NextMessage(Message) do
  begin
    MessageType := Ord(Message.Payload[1]);
    if FAuthenticator.HandleMessage(Message) then
    begin
      if FAuthenticator.Succeeded and (FConnection = nil) then
        BeginConnectionProtocol;
      Continue;
    end;
    if FConnection = nil then
    begin
      if MessageType >= MessageGlobalRequest then
        raise ESshDisconnect.CreateWithReason(DisconnectProtocolError, 'not logged in');
      FTransport.SendUnimplemented(Message.SequenceNumber);
      Continue;
    end;
    if not FConnection.HandleMessage(Message) then
      FTransport.SendUnimplemented(Message.SequenceNumber);
  end;
end;

procedure TConnectionServer.CheckClientAlive;
var
  Interval, Now: QWord;
begin
  if (FConnection = nil) or (FContext.Configuration.ClientAliveInterval <= 0) then
    Exit;
  Interval := QWord(FContext.Configuration.ClientAliveInterval) * 1000;
  Now := GetTickCount64;
  if (Now - FLastReceiveTime < Interval) or (Now - FLastProbeTime < Interval) then
    Exit;
  if FUnansweredProbes >= FContext.Configuration.ClientAliveCountMax then
  begin
    Disconnect(DisconnectByApplication, 'Timeout, client not responding');
    Exit;
  end;
  Inc(FUnansweredProbes);
  FLastProbeTime := Now;
  FConnection.SendGlobalRequest(KeepAliveRequest, '', True, @KeepAliveAnswered);
end;

function TConnectionServer.WaitTimeout: Int64;
begin
  Result := PollMilliseconds;
  if AnyChannelWantsQuickPoll(FConnection) then
    Result := QuickPollMilliseconds;
end;

procedure TConnectionServer.WaitOnce;
var
  Waits: TSshWaitList;
  Handles: array of Int64;
  Index, Count: Integer;
  Ready: Int64;
  Elapsed: QWord;
begin
  Waits := nil;
  AddWait(Waits, FSocket, @SocketReadable);
  AddWait(Waits, FContext.ProgressEvent, @ProgressSignaled);
  if FForwards <> nil then
    FForwards.CollectWaits(Waits);
  CollectChannelWaits(FConnection, Waits);
  Count := Length(Waits);
  if Count > MaximumWaitHandles then
    Count := MaximumWaitHandles;
  Handles := nil;
  SetLength(Handles, Count);
  for Index := 0 to Count - 1 do
    Handles[Index] := Waits[Index].Handle;

  if not FAuthenticator.Succeeded and (FConfiguration.LoginGraceSeconds > 0) then
  begin
    Elapsed := GetTickCount64 - FStartTime;
    if Elapsed >= QWord(FConfiguration.LoginGraceSeconds) * 1000 then
    begin
      Disconnect(DisconnectByApplication, 'no login within the grace time');
      Exit;
    end;
  end;

  Ready := WaitForHandles(Handles, WaitTimeout);
  if (Ready >= 0) and (Ready < Count) then
    Waits[Ready].OnReady();
end;

function TConnectionServer.Run: LongInt;
begin
  Result := 0;
  FStartTime := GetTickCount64;
  FLastReceiveTime := FStartTime;
  if not DescribeEnds then
  begin
    LogLine('the connection is gone before it was served');
    Exit(1);
  end;
  LogLine('connection from ' + FPeerText);
  FHostKeys := LoadOrCreateHostKeys(FConfiguration.HostKeyPaths, False);
  FHostKeys := AddHostCertificates(FHostKeys, FConfiguration.HostCertificatePaths);
  if Length(FHostKeys) = 0 then
  begin
    LogLine('no host keys: connection refused');
    Exit(1);
  end;
  FTransport := TSshServerTransport.Create(FHostKeys, SoftwareVersion);
  FPolicy := TSystemAccountPolicy.Create(FConfiguration, FPeerAddress, FLocalPort);
  FAuthenticator := TSshUserAuthenticator.Create(FTransport, FPolicy);
  FTransport.Start;
  try
    while not FEnded do
    begin
      if not SendOutput then
      begin
        LogLine('connection from ' + FPeerText + ' lost');
        Break;
      end;
      WaitOnce;
      if FEnded then
        Break;
      PollChannels(FConnection);
      if FConnection <> nil then
        FConnection.Flush;
      CheckClientAlive;
      if FTransport.Closed then
        FEnded := True;
    end;
    SendOutput;
  except
    on Error: ESshDisconnect do
      Disconnect(Error.Reason, Error.Message);
    on Error: ESshPeerDisconnected do
      LogLine(FPeerText + ' disconnected');
    on Error: ESshProtocolError do
      Disconnect(DisconnectProtocolError, Error.Message);
  end;
end;

function ServeConnection(Socket: Int64; const Configuration: TSshdConfiguration): LongInt;
var
  Server: TConnectionServer;
begin
  Server := TConnectionServer.Create(Socket, Configuration);
  try
    Result := Server.Run;
  finally
    Server.Free;
  end;
  ShutdownSocket(Socket, SocketShutdownBoth);
  CloseSocket(Socket);
end;

end.
