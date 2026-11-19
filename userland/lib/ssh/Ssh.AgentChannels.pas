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
  The agent over local channels (Ssh.AgentProtocol has the messages):

  - TAgentRelayChannel joins an auth-agent@openssh.com channel to a
    local channel end: sshd's agent forwarding (a program of the session
    connected to the session's agent port) and ssh -A (the server opened
    the channel; the end is a connection to the agent of SSH_AUTH_SOCK).
    The agent protocol's bytes go through unchanged: local messages (up
    to 16 KiB each) one way, channel data the other.
  - TSshAgentClient asks an agent for its keys and for signatures, each
    a request and the reply, waited for (ssh, ssh-add).
  - TSshAgentKeyIdentity is a key of the agent for user authentication.

  SSH_AUTH_SOCK names the agent as "port:NAME", a named port: the
  system has no Unix domain sockets (see sshd's agent forwarding).
}
unit Ssh.AgentChannels;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Connection,
  Ssh.PolledChannels,
  Ssh.AgentProtocol,
  Ssh.ClientIdentities;

const
  AgentChannelType = 'auth-agent@openssh.com';

type
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
    { LocalChannel (owned) is a channel end to the agent's user. }
    constructor Create(Owner: TSshConnection; LocalChannel: Int64);
    destructor Destroy; override;
    procedure CollectWaits(var Waits: TSshWaitList); override;
    procedure Poll; override;
  end;

  TSshAgentClient = class
  private
    FChannel: Int64;
    FReader: TSshAgentFrameReader;
    function Exchange(const Request: string; out Reply: string): Boolean;
  public
    destructor Destroy; override;
    { Connects to the agent SocketText names ("port:NAME"); False when
      there is none. }
    function Connect(const SocketText: string): Boolean;
    function ListKeys(out Identities: TSshAgentIdentities): Boolean;
    function Sign(const Blob, Data: string; Flags: LongWord; out Signature: string): Boolean;
  end;

  TSshAgentKeyIdentity = class(TSshClientIdentity)
  private
    FAgent: TSshAgentClient;
    FBlob: string;
    FComment: string;
  public
    { Agent is not owned. }
    constructor Create(Agent: TSshAgentClient; const Blob, Comment: string);
    function PublicBlob: string; override;
    function Description: string; override;
    function Sign(const Data, Algorithm: string): string; override;
  end;

{ A new connection to the agent SocketText names, as a channel end;
  minus an error code when there is none. }
function ConnectToAgent(const SocketText: string): Int64;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Objects,
  Ssh.Wire;

const
  OutputBackLog = 64 * 1024;
  AgentReplyMilliseconds = 30000;

function ConnectToAgent(const SocketText: string): Int64;
begin
  if Copy(SocketText, 1, Length(AgentPortPrefix)) <> AgentPortPrefix then
    Exit(-ErrorNotFound);
  Result := ConnectPort(PChar(Copy(SocketText, Length(AgentPortPrefix) + 1, MaxInt)));
end;

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

destructor TSshAgentClient.Destroy;
begin
  if FChannel > 0 then
    CloseHandle(FChannel);
  inherited Destroy;
end;

function TSshAgentClient.Connect(const SocketText: string): Boolean;
begin
  FChannel := ConnectToAgent(SocketText);
  Result := FChannel >= 0;
  if not Result then
    FChannel := 0;
end;

function TSshAgentClient.Exchange(const Request: string; out Reply: string): Boolean;
var
  Buffer: array[0..MaximumMessageBytes - 1] of Byte;
  Handles: array[0..0] of Int64;
  Length_, HandleCount, Position: QWord;
  Chunk: string;
begin
  Reply := '';
  Result := False;
  if FChannel <= 0 then
    Exit;
  Position := 1;
  while Position <= QWord(Length(Request)) do
  begin
    Chunk := Copy(Request, Position, MaximumMessageBytes);
    if SendMessage(FChannel, @Chunk[1], Length(Chunk), []) <> ErrorNone then
      Exit;
    Inc(Position, Length(Chunk));
  end;
  try
    while not FReader.NextMessage(Reply) do
    begin
      if WaitForMessage(FChannel, @Buffer[0], SizeOf(Buffer), Length_, Handles, HandleCount,
        AgentReplyMilliseconds) <> ErrorNone then
        Exit;
      FReader.Append(BytesToString(@Buffer[0], Integer(Length_)));
    end;
  except
    on ESshProtocolError do
      Exit;
  end;
  Result := True;
end;

function TSshAgentClient.ListKeys(out Identities: TSshAgentIdentities): Boolean;
var
  Reply: string;
begin
  Identities := nil;
  Result := Exchange(MakeIdentitiesRequest, Reply) and ParseIdentitiesAnswer(Reply, Identities);
end;

function TSshAgentClient.Sign(const Blob, Data: string; Flags: LongWord; out Signature: string): Boolean;
var
  Reply: string;
begin
  Signature := '';
  Result := Exchange(MakeSignRequest(Blob, Data, Flags), Reply) and ParseSignResponse(Reply, Signature);
end;

constructor TSshAgentKeyIdentity.Create(Agent: TSshAgentClient; const Blob, Comment: string);
begin
  inherited Create;
  FAgent := Agent;
  FBlob := Blob;
  FComment := Comment;
end;

function TSshAgentKeyIdentity.PublicBlob: string;
begin
  Result := FBlob;
end;

function TSshAgentKeyIdentity.Description: string;
begin
  Result := 'agent: ' + FComment;
end;

function TSshAgentKeyIdentity.Sign(const Data, Algorithm: string): string;
begin
  if not FAgent.Sign(FBlob, Data, SignFlagsFor(Algorithm), Result) then
    Result := '';
end;

end.
