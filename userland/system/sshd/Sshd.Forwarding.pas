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
  TCP forwarding (RFC 4254 section 7), the server's part:

  - direct-tcpip channels (ssh -L): the server connects to the host and
    port the client names, and the channel carries the connection. Allowed
    by AllowTcpForwarding yes/all/local, PermitOpen and the key's
    permitopen=; refused by no-port-forwarding (or a certificate without
    permit-port-forwarding).
  - tcpip-forward (ssh -R): the server listens and opens a
    forwarded-tcpip channel to the client for each connection;
    cancel-tcpip-forward stops it. Allowed by AllowTcpForwarding
    yes/all/remote and the key's permitlisten=. GatewayPorts says where
    it listens: no - the loopback address only; yes - every address;
    clientspecified - where the client asks ("" or * every address,
    localhost the loopback address). Ports below 1024 only for root.
    Port 0 asks for any port; the reply names it.
}
unit Sshd.Forwarding;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Wire,
  Ssh.Connection,
  Ssh.PolledChannels,
  Ssh.SocketChannels,
  Ssh.AuthorizedKeys,
  Sshd.Configuration;

type
  TForwardingContext = record
    Configuration: TSshdConfiguration;
    Options: TSshKeyOptions;
    UserName: string;
    IsRoot: Boolean;
    ProgressEvent: Int64;
  end;

  TRemoteForwards = class
  private
    FConnection: TSshConnection;
    FContext: TForwardingContext;
    FListeners: array of TSshTcpListener;
    procedure ConnectionAccepted(Listener: TSshTcpListener; Socket: Int64; const PeerHost: string; PeerPort: Word);
    function Add(const Host: string; Port: Word; out BoundPort: Word): Boolean;
    function Cancel(const Host: string; Port: Word): Boolean;
  public
    constructor Create(Connection: TSshConnection; const Context: TForwardingContext);
    destructor Destroy; override;
    { tcpip-forward and cancel-tcpip-forward; False for other requests. }
    function HandleGlobalRequest(const RequestName: string; var Reader: TSshReader; out Handled: Boolean;
      out ReplyData: string): Boolean;
    procedure CollectWaits(var Waits: TSshWaitList);
  end;

{ A direct-tcpip channel for an open request (Reader past the window
  and packet size), connecting; nil with a failure reason when it is not
  allowed or cannot connect. }
function OpenDirectChannel(Connection: TSshConnection; var Reader: TSshReader; const Context: TForwardingContext;
  out FailureReason: LongWord): TSshChannel;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Sockets,
  Ssh.Constants,
  Sshd.Log;

function LocalForwardingAllowed(const Context: TForwardingContext): Boolean;
begin
  Result := (Context.Configuration.AllowTcpForwarding in [ForwardingAll, ForwardingLocal]) and
    not Context.Options.NoPortForwarding;
end;

function RemoteForwardingAllowed(const Context: TForwardingContext): Boolean;
begin
  Result := (Context.Configuration.AllowTcpForwarding in [ForwardingAll, ForwardingRemote]) and
    not Context.Options.NoPortForwarding;
end;

function OpenDirectChannel(Connection: TSshConnection; var Reader: TSshReader; const Context: TForwardingContext;
  out FailureReason: LongWord): TSshChannel;
var
  Host, Originator, What: string;
  Port, OriginatorPort: LongWord;
  Socket: Int64;
  Error: LongInt;
begin
  Result := nil;
  FailureReason := OpenAdministrativelyProhibited;
  Host := Reader.ReadString;
  Port := Reader.ReadUInt32;
  Originator := Reader.ReadString;
  OriginatorPort := Reader.ReadUInt32;
  What := Format('%s port %d (for %s port %d)', [Host, Port, Originator, OriginatorPort]);
  if (Port = 0) or (Port > 65535) then
    Exit;
  if not LocalForwardingAllowed(Context) or Context.Configuration.PermitOpenNone or
    ((Length(Context.Configuration.PermitOpen) > 0) and
    not PermitOpenAllows(Context.Configuration.PermitOpen, Host, Port)) or
    ((Length(Context.Options.PermitOpen) > 0) and not PermitOpenAllows(Context.Options.PermitOpen, Host, Port)) then
  begin
    LogLine('forwarding to ' + What + ' refused for ' + Context.UserName);
    Exit;
  end;
  Error := StartConnectingToHost(Host, Word(Port), Socket);
  if Error <> ErrorNone then
  begin
    LogLine('forwarding to ' + What + ': ' + ErrorMessage(Error));
    FailureReason := OpenConnectFailed;
    Exit;
  end;
  LogLine('forwarding to ' + What + ' for ' + Context.UserName);
  Result := TSshSocketChannel.CreateConnecting(Connection, Socket, Context.ProgressEvent, Host + ':' + IntToStr(Port));
end;

constructor TRemoteForwards.Create(Connection: TSshConnection; const Context: TForwardingContext);
begin
  inherited Create;
  FConnection := Connection;
  FContext := Context;
end;

destructor TRemoteForwards.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(FListeners) do
    FListeners[Index].Free;
  inherited Destroy;
end;

{ Where to listen for what the client asked. }
function ListenHost(const Requested: string; GatewayPorts: TSshdGatewayPorts): string;
begin
  case GatewayPorts of
    GatewayPortsNo: Result := 'localhost';
    GatewayPortsYes: Result := '';
  else
    if (Requested = '') or (Requested = '*') or (Requested = '0.0.0.0') then
      Result := ''
    else
      Result := Requested;
  end;
end;

function TRemoteForwards.Add(const Host: string; Port: Word; out BoundPort: Word): Boolean;
var
  Socket: Int64;
  Error: LongInt;
  Listener: TSshTcpListener;
begin
  Result := False;
  BoundPort := 0;
  if not RemoteForwardingAllowed(FContext) or
    ((Length(FContext.Options.PermitListen) > 0) and not PermitListenAllows(FContext.Options.PermitListen, Host, Port)) then
  begin
    LogLine(Format('remote forwarding of %s port %d refused for %s', [Host, Port, FContext.UserName]));
    Exit;
  end;
  if (Port <> 0) and (Port < 1024) and not FContext.IsRoot then
  begin
    LogLine(Format('remote forwarding of port %d refused: a privileged port', [Port]));
    Exit;
  end;
  Error := OpenTcpListener(ListenHost(Host, FContext.Configuration.GatewayPorts), Port, Socket, BoundPort);
  if Error <> ErrorNone then
  begin
    LogLine(Format('cannot listen on %s port %d: %s', [Host, Port, ErrorMessage(Error)]));
    Exit;
  end;
  Listener := TSshTcpListener.Create(Socket, Host, BoundPort, @ConnectionAccepted);
  { The client knows the forwarding by the port it asked for. }
  if Port <> 0 then
    Listener.TargetPort := Port
  else
    Listener.TargetPort := BoundPort;
  SetLength(FListeners, Length(FListeners) + 1);
  FListeners[High(FListeners)] := Listener;
  LogLine(Format('remote forwarding: listening on port %d for %s', [BoundPort, FContext.UserName]));
  Result := True;
end;

function TRemoteForwards.Cancel(const Host: string; Port: Word): Boolean;
var
  Index, Last: Integer;
begin
  for Index := 0 to High(FListeners) do
    if (FListeners[Index].BindHost = Host) and (FListeners[Index].TargetPort = Port) then
    begin
      FListeners[Index].Free;
      for Last := Index to High(FListeners) - 1 do
        FListeners[Last] := FListeners[Last + 1];
      SetLength(FListeners, Length(FListeners) - 1);
      Exit(True);
    end;
  Result := False;
end;

function TRemoteForwards.HandleGlobalRequest(const RequestName: string; var Reader: TSshReader;
  out Handled: Boolean; out ReplyData: string): Boolean;
var
  Host: string;
  Port: LongWord;
  BoundPort: Word;
begin
  Result := False;
  ReplyData := '';
  Handled := (RequestName = 'tcpip-forward') or (RequestName = 'cancel-tcpip-forward');
  if not Handled then
    Exit;
  Host := Reader.ReadString;
  Port := Reader.ReadUInt32;
  if Port > 65535 then
    Exit;
  if RequestName = 'tcpip-forward' then
  begin
    Result := Add(Host, Word(Port), BoundPort);
    if Result and (Port = 0) then
      ReplyData := SshUInt32(BoundPort);
  end
  else
    Result := Cancel(Host, Word(Port));
end;

procedure TRemoteForwards.ConnectionAccepted(Listener: TSshTcpListener; Socket: Int64; const PeerHost: string;
  PeerPort: Word);
var
  Channel: TSshSocketChannel;
begin
  Channel := TSshSocketChannel.Create(FConnection, Socket, FContext.ProgressEvent,
    'forwarded port ' + IntToStr(Listener.Port));
  FConnection.OpenChannel(Channel, 'forwarded-tcpip', SshString(Listener.BindHost) +
    SshUInt32(Listener.TargetPort) + SshString(PeerHost) + SshUInt32(PeerPort));
end;

procedure TRemoteForwards.CollectWaits(var Waits: TSshWaitList);
var
  Index: Integer;
begin
  for Index := 0 to High(FListeners) do
    FListeners[Index].CollectWaits(Waits);
end;

end.
