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
  Agent forwarding (OpenSSH's auth-agent-req@openssh.com): programs of a
  session reach the client's ssh-agent through the connection.

  OpenSSH's sshd makes a Unix domain socket and puts its path in
  SSH_AUTH_SOCK. The system has no Unix domain sockets; the nearest is a
  named port (Processes.Channels), which also tells who connected. So a
  session that asks gets a port of its own, "sshagent-PROCESS-N", and
  SSH_AUTH_SOCK=port:sshagent-PROCESS-N; the system's ssh and ssh-add
  connect to it. Each connection to the port (by the session's user or
  root; others are turned away) opens an auth-agent@openssh.com channel
  to the client, and the agent protocol's bytes go through unchanged:
  channel messages (up to 16 KiB each) one way, channel data the other.
}
unit Sshd.AgentForwarding;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Connection,
  Ssh.PolledChannels;

const
  AgentChannelType = 'auth-agent@openssh.com';

type
  { One forwarded agent connection: a local channel end and an SSH
    channel. }
  TAgentRelayChannel = class(TSshPolledChannel)
  private
    FLocal: Int64;
    FPendingToLocal: string;
    FLocalEnded: Boolean;
    procedure LocalReadable;
    procedure PushToLocal;
    procedure ReleaseLocal;
  protected
    procedure HandleData(const Data: string); override;
    procedure HandleEof; override;
    procedure HandleClose; override;
    procedure HandleOpenFailed(Reason: LongWord; const Description: string); override;
  public
    constructor Create(Owner: TSshConnection; LocalChannel: Int64);
    destructor Destroy; override;
    procedure CollectWaits(var Waits: TSshWaitList); override;
    procedure Poll; override;
  end;

  { The port of one session; owned by the session. }
  TAgentListener = class
  private
    FConnection: TSshConnection;
    FPort: Int64;
    FName: string;
    FUserId: LongWord;
    procedure ConnectionWaiting;
  public
    constructor Create(Connection: TSshConnection; UserId: LongWord);
    destructor Destroy; override;
    { False if no port could be made. }
    function Open: Boolean;
    procedure CollectWaits(var Waits: TSshWaitList);
    { SSH_AUTH_SOCK's value. }
    function SocketText: string;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Objects,
  Sys.Processes,
  Ssh.Wire,
  Ssh.AgentProtocol,
  Sshd.Log;

const
  OutputBackLog = 64 * 1024;

var
  NextPortNumber: Integer = 1;

constructor TAgentRelayChannel.Create(Owner: TSshConnection; LocalChannel: Int64);
begin
  inherited Create(Owner);
  FLocal := LocalChannel;
end;

destructor TAgentRelayChannel.Destroy;
begin
  ReleaseLocal;
  inherited Destroy;
end;

procedure TAgentRelayChannel.ReleaseLocal;
begin
  if FLocal >= 0 then
    CloseHandle(FLocal);
  FLocal := NoHandle;
end;

procedure TAgentRelayChannel.LocalReadable;
var
  Buffer: array[0..MaximumMessageBytes - 1] of Byte;
  Handles: array[0..MaximumMessageHandles - 1] of Int64;
  Length_, HandleCount, Index: QWord;
  Error: LongInt;
begin
  Error := ReceiveMessage(FLocal, @Buffer[0], SizeOf(Buffer), Length_, Handles, HandleCount);
  if Error = ErrorWouldBlock then
    Exit;
  if Error <> ErrorNone then
  begin
    FLocalEnded := True;
    Finish(False, 0);
    Exit;
  end;
  { Handles have no place in the agent protocol. }
  Index := 0;
  while Index < HandleCount do
  begin
    CloseHandle(Handles[Index]);
    Inc(Index);
  end;
  if Length_ > 0 then
    SendData(BytesToString(@Buffer[0], Integer(Length_)));
end;

procedure TAgentRelayChannel.PushToLocal;
var
  Chunk: string;
  Error: LongInt;
begin
  while (FPendingToLocal <> '') and (FLocal >= 0) do
  begin
    Chunk := Copy(FPendingToLocal, 1, MaximumMessageBytes);
    Error := SendMessage(FLocal, @Chunk[1], Length(Chunk), []);
    if Error = ErrorWouldBlock then
      Exit;
    if Error <> ErrorNone then
    begin
      FPendingToLocal := '';
      CloseNow;
      Exit;
    end;
    Delete(FPendingToLocal, 1, Length(Chunk));
    InputConsumed(Length(Chunk));
  end;
end;

procedure TAgentRelayChannel.HandleData(const Data: string);
begin
  FPendingToLocal := FPendingToLocal + Data;
  PushToLocal;
end;

procedure TAgentRelayChannel.HandleEof;
begin
  if FPendingToLocal = '' then
    Finish(False, 0);
end;

procedure TAgentRelayChannel.HandleClose;
begin
  ReleaseLocal;
end;

procedure TAgentRelayChannel.HandleOpenFailed(Reason: LongWord; const Description: string);
begin
  LogLine('the client refused the agent channel: ' + Description);
  ReleaseLocal;
end;

procedure TAgentRelayChannel.CollectWaits(var Waits: TSshWaitList);
begin
  if (FLocal >= 0) and IsOpen and not FLocalEnded and (PendingOutput < OutputBackLog) then
    AddWait(Waits, FLocal, @LocalReadable);
end;

procedure TAgentRelayChannel.Poll;
begin
  if FPendingToLocal <> '' then
    PushToLocal;
  if EofReceived and (FPendingToLocal = '') then
    Finish(False, 0);
end;

constructor TAgentListener.Create(Connection: TSshConnection; UserId: LongWord);
begin
  inherited Create;
  FConnection := Connection;
  FUserId := UserId;
  FPort := NoHandle;
end;

destructor TAgentListener.Destroy;
begin
  if FPort >= 0 then
    CloseHandle(FPort);
  inherited Destroy;
end;

function TAgentListener.Open: Boolean;
var
  Attempt: Integer;
begin
  for Attempt := 1 to 8 do
  begin
    FName := Format('sshagent-%d-%d', [CurrentProcessId, NextPortNumber]);
    Inc(NextPortNumber);
    FPort := CreatePort(PChar(FName));
    if FPort >= 0 then
      Exit(True);
    if ErrorCodeOf(FPort) <> ErrorExists then
      Break;
  end;
  LogLine('no port for agent forwarding: ' + ErrorMessage(ErrorCodeOf(FPort)));
  FPort := NoHandle;
  Result := False;
end;

function TAgentListener.SocketText: string;
begin
  Result := AgentPortPrefix + FName;
end;

procedure TAgentListener.CollectWaits(var Waits: TSshWaitList);
begin
  if FPort >= 0 then
    AddWait(Waits, FPort, @ConnectionWaiting);
end;

procedure TAgentListener.ConnectionWaiting;
var
  Local: Int64;
  Peer: TAbiChannelPeer;
begin
  Local := AcceptConnection(FPort);
  if Local < 0 then
    Exit;
  if (GetChannelPeer(Local, Peer) <> ErrorNone) or ((Peer.UserId <> FUserId) and (Peer.UserId <> 0)) then
  begin
    LogLine('agent port ' + FName + ': a connection from another user turned away');
    CloseHandle(Local);
    Exit;
  end;
  FConnection.OpenChannel(TAgentRelayChannel.Create(FConnection, Local), AgentChannelType, '');
end;

end.
