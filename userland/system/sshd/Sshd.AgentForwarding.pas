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
  to the client (Ssh.AgentChannels relays it).
}
unit Sshd.AgentForwarding;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Connection,
  Ssh.PolledChannels;

type
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
  Ssh.AgentChannels,
  Sshd.Log;

var
  NextPortNumber: Integer = 1;

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
