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
  One ssh connection from start to end: the TCP connection, the
  transport (the host key checked against known_hosts), user
  authentication (the agent's keys, the key files, keyboard-interactive,
  the password), then the connection protocol in one loop that waits on
  the socket, standard input, the forwarding listeners and the forwarded
  sockets at once (Ssh.PolledChannels):

  - the session channel (unless -N), with a pseudo-terminal in raw mode
    when one is asked for or the session is interactive on a terminal;
  - -L: a listener per forwarding, each connection a direct-tcpip
    channel to the server;
  - -R: tcpip-forward asked of the server; the forwarded-tcpip channels
    it opens are connected to the local target;
  - -A: auth-agent@openssh.com channels the server opens go to the
    agent of SSH_AUTH_SOCK.

  The exit status is the remote program's, or 255 when the connection
  failed.
}
unit SshClient.Session;

{$mode objfpc}{$H+}

interface

uses
  SshClient.Options;

function RunClient(const Options: TSshClientOptions): LongInt;

implementation

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.AddressText,
  Sys.Console,
  Sys.Errors,
  Sys.HostLookup,
  Sys.InternetAddresses,
  Sys.Kernel,
  Sys.Objects,
  Sys.Sockets,
  Ssh.Constants,
  Ssh.Wire,
  Ssh.Algorithms,
  Ssh.HostKeys,
  Ssh.KeyFiles,
  Ssh.PublicKeys,
  Ssh.Transport,
  Ssh.ClientTransport,
  Ssh.ClientIdentities,
  Ssh.ClientAuthentication,
  Ssh.Connection,
  Ssh.PolledChannels,
  Ssh.SocketChannels,
  Ssh.AgentProtocol,
  Ssh.AgentChannels,
  SshClient.Channels,
  SshClient.HostKeyCheck,
  SshClient.Prompts,
  SshClient.Terminal;

const
  SoftwareVersion = 'FreePascalOS_1.0';
  ReceiveChunkBytes = 32 * 1024;
  PollMilliseconds = 1000;
  QuickPollMilliseconds = 20;

type
  TClient = class
  private
    FOptions: TSshClientOptions;
    FSocket: Int64;
    FProgressEvent: Int64;
    FTransport: TSshClientTransport;
    FChecker: THostKeyChecker;
    FAuthenticator: TSshClientAuthenticator;
    FConnection: TSshConnection;
    FSession: TClientSessionChannel;
    FAgent: TSshAgentClient;
    FIdentities: TSshClientIdentityArray;
    FListeners: array of TSshTcpListener;
    FEnded: Boolean;
    FFailed: Boolean;
    FRawMode: Boolean;
    procedure Note(const Text: string);
    function ConnectSocket_: Boolean;
    procedure LoadIdentities;
    function SendOutput: Boolean;
    procedure SocketReadable;
    procedure ProgressSignaled;
    procedure HandleMessages;
    function Password(out Text: string): Boolean;
    function Prompt(const Name, Instruction, PromptText: string; Echo: Boolean; out Response: string): Boolean;
    procedure Banner(const Text: string);
    procedure StartConnectionProtocol;
    function WantsTerminal: Boolean;
    procedure LocalConnection(Listener: TSshTcpListener; Socket: Int64; const PeerHost: string; PeerPort: Word);
    procedure RemoteForwardAnswered(Succeeded: Boolean; const ReplyData: string);
    function ChannelOpened(Connection: TSshConnection; const ChannelType: string; var Reader: TSshReader;
      out FailureReason: LongWord): TSshChannel;
    procedure WaitOnce;
  public
    constructor Create(const Options: TSshClientOptions);
    destructor Destroy; override;
    function Run: LongInt;
  end;

constructor TClient.Create(const Options: TSshClientOptions);
begin
  inherited Create;
  FOptions := Options;
  FSocket := NoHandle;
  FProgressEvent := CreateEvent(False, False);
end;

destructor TClient.Destroy;
var
  Index: Integer;
begin
  if FRawMode then
    LeaveRawMode;
  for Index := 0 to High(FListeners) do
    FListeners[Index].Free;
  FConnection.Free;
  FAuthenticator.Free;
  FTransport.Free;
  FChecker.Free;
  for Index := 0 to High(FIdentities) do
    FIdentities[Index].Free;
  FAgent.Free;
  if FSocket >= 0 then
    CloseSocket(FSocket);
  if FProgressEvent >= 0 then
    CloseHandle(FProgressEvent);
  inherited Destroy;
end;

procedure TClient.Note(const Text: string);
begin
  if FOptions.Verbose > 0 then
    WriteLn(ErrOutput, 'debug1: ', Text);
end;

function TClient.ConnectSocket_: Boolean;
var
  Addresses: TInternetAddressArray;
  Index: Integer;
  Error: LongInt;
  Family: LongWord;
begin
  Result := False;
  Error := ResolveHost(FOptions.Host, AddressFamilyUnspecified, Addresses);
  if (Error <> ErrorNone) or (Length(Addresses) = 0) then
  begin
    WriteLn(ErrOutput, 'ssh: Could not resolve hostname ', FOptions.Host, ': ', ErrorMessage(Error));
    Exit;
  end;
  OrderAddressesForConnecting(Addresses);
  for Index := 0 to High(Addresses) do
  begin
    if Addresses[Index].Family = AddressFamilyIPv6 then
      Family := AddressFamilyIPv6
    else
      Family := AddressFamilyIPv4;
    FSocket := CreateSocket(Family, SocketKindStream, ProtocolDefault);
    if FSocket < 0 then
      Continue;
    Note(Format('connecting to %s port %d', [AddressToText(Addresses[Index]), FOptions.Port]));
    Error := ConnectSocket(FSocket, MakeSocketAddress(Addresses[Index], FOptions.Port));
    if Error = ErrorNone then
    begin
      SetSocketOption(FSocket, SocketOptionNoDelay, 1);
      Exit(True);
    end;
    CloseSocket(FSocket);
    FSocket := NoHandle;
  end;
  WriteLn(ErrOutput, 'ssh: connect to host ', FOptions.Host, ' port ', FOptions.Port, ': ', ErrorMessage(Error));
end;

procedure TClient.LoadIdentities;
var
  Keys: TSshAgentIdentities;
  Paths: TStringArray;
  Index: Integer;
  Text: string;
  Key: TSshHostKey;
  Home: string;

  procedure Add(Identity: TSshClientIdentity);
  begin
    SetLength(FIdentities, Length(FIdentities) + 1);
    FIdentities[High(FIdentities)] := Identity;
  end;

  function ReadFile(const Path: string; out Contents: string): Boolean;
  var
    Stream: TFileStream;
  begin
    Contents := '';
    Result := False;
    try
      Stream := TFileStream.Create(Path, fmOpenRead);
      try
        SetLength(Contents, Stream.Size);
        if Stream.Size > 0 then
          Stream.ReadBuffer(Contents[1], Stream.Size);
        Result := True;
      finally
        Stream.Free;
      end;
    except
      on Exception do
        Result := False;
    end;
  end;

begin
  if not FOptions.IdentitiesOnly and (GetEnvironmentVariable('SSH_AUTH_SOCK') <> '') then
  begin
    FAgent := TSshAgentClient.Create;
    if FAgent.Connect(GetEnvironmentVariable('SSH_AUTH_SOCK')) and FAgent.ListKeys(Keys) then
      for Index := 0 to High(Keys) do
        Add(TSshAgentKeyIdentity.Create(FAgent, Keys[Index].Blob, Keys[Index].Comment))
    else
      Note('no agent at ' + GetEnvironmentVariable('SSH_AUTH_SOCK'));
  end;
  Paths := Copy(FOptions.IdentityFiles);
  if Length(Paths) = 0 then
  begin
    Home := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME'));
    Paths := TStringArray.Create(Home + '.ssh/id_ed25519', Home + '.ssh/id_ecdsa');
  end;
  for Index := 0 to High(Paths) do
  begin
    if not FileExists(Paths[Index]) then
      Continue;
    Key := nil;
    if ReadFile(Paths[Index], Text) then
      Key := DecodePrivateKeyFile(Text);
    WipeString(Text);
    if Key = nil then
    begin
      WriteLn(ErrOutput, 'ssh: cannot use the key ', Paths[Index],
        ' (an ed25519 or ecdsa key without a passphrase is needed)');
      Continue;
    end;
    Add(TSshKeyFileIdentity.Create(Key, Paths[Index]));
  end;
end;

function TClient.SendOutput: Boolean;
var
  Output: string;
begin
  Result := True;
  if not FTransport.HasOutput then
    Exit;
  Output := FTransport.TakeOutput;
  Result := SendAll(FSocket, @Output[1], Length(Output)) = ErrorNone;
end;

procedure TClient.SocketReadable;
var
  Buffer: array[0..ReceiveChunkBytes - 1] of Byte;
  Count: Int64;
begin
  Count := ReceiveOnSocket(FSocket, @Buffer[0], SizeOf(Buffer), 0);
  if Count <= 0 then
  begin
    if not FTransport.Closed and ((FSession = nil) or not FSession.Done) then
    begin
      WriteLn(ErrOutput, 'ssh: connection to ', FOptions.Host, ' closed by the remote host.');
      FFailed := FSession = nil;
    end;
    FEnded := True;
    Exit;
  end;
  FTransport.Receive(BytesToString(@Buffer[0], Integer(Count)));
  HandleMessages;
end;

procedure TClient.ProgressSignaled;
begin
end;

function TClient.Password(out Text: string): Boolean;
begin
  Result := not FOptions.BatchMode and
    AskLine(FOptions.User + '@' + FOptions.Host + '''s password: ', False, Text);
end;

function TClient.Prompt(const Name, Instruction, PromptText: string; Echo: Boolean; out Response: string): Boolean;
begin
  if Name <> '' then
    WriteLn(ErrOutput, Name);
  if Instruction <> '' then
    WriteLn(ErrOutput, Instruction);
  Result := not FOptions.BatchMode and AskLine('(' + FOptions.User + '@' + FOptions.Host + ') ' + PromptText,
    Echo, Response);
end;

procedure TClient.Banner(const Text: string);
begin
  if not FOptions.Quiet then
    Write(ErrOutput, Text);
end;

function TClient.WantsTerminal: Boolean;
begin
  case FOptions.Terminal of
    TerminalForce: Result := True;
    TerminalNo: Result := False;
    TerminalYes:
      begin
        Result := IsConsole(StandardInputHandle);
        if not Result and not FOptions.Quiet then
          WriteLn(ErrOutput, 'Pseudo-terminal will not be allocated because stdin is not a terminal.');
      end;
  else
    Result := (FOptions.Command = '') and IsConsole(StandardInputHandle);
  end;
end;

procedure TClient.LocalConnection(Listener: TSshTcpListener; Socket: Int64; const PeerHost: string;
  PeerPort: Word);
begin
  Note(Format('connection to local port %d forwarded to %s port %d', [Listener.Port, Listener.TargetHost,
    Listener.TargetPort]));
  FConnection.OpenChannel(TSshSocketChannel.Create(FConnection, Socket, FProgressEvent, 'local forwarding'),
    'direct-tcpip', SshString(Listener.TargetHost) + SshUInt32(Listener.TargetPort) + SshString(PeerHost) +
    SshUInt32(PeerPort));
end;

procedure TClient.RemoteForwardAnswered(Succeeded: Boolean; const ReplyData: string);
var
  Reader: TSshReader;
begin
  if not Succeeded then
    WriteLn(ErrOutput, 'Warning: remote port forwarding failed')
  else if Length(ReplyData) = 4 then
  begin
    Reader.Start(ReplyData);
    WriteLn(ErrOutput, 'Allocated port ', Reader.ReadUInt32, ' for remote forward');
  end;
end;

function TClient.ChannelOpened(Connection: TSshConnection; const ChannelType: string; var Reader: TSshReader;
  out FailureReason: LongWord): TSshChannel;
var
  Address, Originator: string;
  Port: LongWord;
  Index: Integer;
  Socket, Local: Int64;
  Error: LongInt;
begin
  Result := nil;
  FailureReason := OpenAdministrativelyProhibited;
  if ChannelType = 'forwarded-tcpip' then
  begin
    Address := Reader.ReadString;
    Port := Reader.ReadUInt32;
    Originator := Reader.ReadString;
    Reader.ReadUInt32;
    for Index := 0 to High(FOptions.RemoteForwards) do
      if FOptions.RemoteForwards[Index].Port = Port then
      begin
        Error := StartConnectingToHost(FOptions.RemoteForwards[Index].TargetHost,
          FOptions.RemoteForwards[Index].TargetPort, Socket);
        if Error <> ErrorNone then
        begin
          FailureReason := OpenConnectFailed;
          Exit;
        end;
        Note('remote forwarding from ' + Originator + ' to ' + FOptions.RemoteForwards[Index].TargetHost);
        Exit(TSshSocketChannel.CreateConnecting(Connection, Socket, FProgressEvent, 'remote forwarding'));
      end;
  end
  else if (ChannelType = AgentChannelType) and FOptions.ForwardAgent then
  begin
    Local := ConnectToAgent(GetEnvironmentVariable('SSH_AUTH_SOCK'));
    if Local < 0 then
    begin
      FailureReason := OpenConnectFailed;
      Exit;
    end;
    Result := TAgentRelayChannel.Create(Connection, Local);
  end
  else
    FailureReason := OpenUnknownChannelType;
end;

procedure TClient.StartConnectionProtocol;
var
  Index: Integer;
  Specification: TForwardSpecification;
  Socket: Int64;
  BoundPort: Word;
  Error: LongInt;
  Listener: TSshTcpListener;
  Terminal: Boolean;
begin
  FConnection := TSshConnection.Create(FTransport);
  FConnection.OnChannelOpen := @ChannelOpened;
  for Index := 0 to High(FOptions.LocalForwards) do
  begin
    Specification := FOptions.LocalForwards[Index];
    if Specification.BindHost = '' then
      Specification.BindHost := 'localhost';
    Error := OpenTcpListener(Specification.BindHost, Specification.Port, Socket, BoundPort);
    if Error <> ErrorNone then
    begin
      WriteLn(ErrOutput, 'ssh: cannot listen on port ', Specification.Port, ': ', ErrorMessage(Error));
      Continue;
    end;
    Listener := TSshTcpListener.Create(Socket, Specification.BindHost, BoundPort, @LocalConnection);
    Listener.TargetHost := Specification.TargetHost;
    Listener.TargetPort := Specification.TargetPort;
    SetLength(FListeners, Length(FListeners) + 1);
    FListeners[High(FListeners)] := Listener;
  end;
  for Index := 0 to High(FOptions.RemoteForwards) do
    FConnection.SendGlobalRequest('tcpip-forward', SshString(FOptions.RemoteForwards[Index].BindHost) +
      SshUInt32(FOptions.RemoteForwards[Index].Port), True, @RemoteForwardAnswered);
  if FOptions.NoCommand then
    Exit;
  Terminal := WantsTerminal;
  FSession := TClientSessionChannel.Create(FConnection, FOptions.Command, Terminal,
    FOptions.ForwardAgent and (GetEnvironmentVariable('SSH_AUTH_SOCK') <> ''), FOptions.EscapeCharacter);
  FConnection.OpenChannel(FSession, 'session', '');
  if Terminal and IsConsole(StandardInputHandle) then
  begin
    EnterRawMode(StandardInputHandle);
    FRawMode := True;
  end;
end;

procedure TClient.HandleMessages;
var
  Message: TSshReceivedMessage;
begin
  while not FEnded and FTransport.NextMessage(Message) do
  begin
    if (FConnection = nil) and FAuthenticator.HandleMessage(Message) then
    begin
      if FAuthenticator.Succeeded then
      begin
        Note('authenticated with ' + FAuthenticator.Method);
        StartConnectionProtocol;
      end
      else if FAuthenticator.Failed then
      begin
        WriteLn(ErrOutput, FOptions.User, '@', FOptions.Host, ': Permission denied.');
        FFailed := True;
        FEnded := True;
      end;
      Continue;
    end;
    if (FConnection = nil) or not FConnection.HandleMessage(Message) then
      FTransport.SendUnimplemented(Message.SequenceNumber);
  end;
end;

procedure TClient.WaitOnce;
var
  Waits: TSshWaitList;
  Handles: array of Int64;
  Index, Count: Integer;
  Ready, Timeout: Int64;
begin
  Waits := nil;
  AddWait(Waits, FSocket, @SocketReadable);
  AddWait(Waits, FProgressEvent, @ProgressSignaled);
  for Index := 0 to High(FListeners) do
    FListeners[Index].CollectWaits(Waits);
  CollectChannelWaits(FConnection, Waits);
  Count := Length(Waits);
  if Count > MaximumWaitHandles then
    Count := MaximumWaitHandles;
  Handles := nil;
  SetLength(Handles, Count);
  for Index := 0 to Count - 1 do
    Handles[Index] := Waits[Index].Handle;
  Timeout := PollMilliseconds;
  if AnyChannelWantsQuickPoll(FConnection) then
    Timeout := QuickPollMilliseconds;
  Ready := WaitForHandles(Handles, Timeout);
  if (Ready >= 0) and (Ready < Count) then
    Waits[Ready].OnReady();
end;

function TClient.Run: LongInt;
var
  Offer: TSshAlgorithmOffer;
  Index: Integer;
  AuthenticationStarted: Boolean;
begin
  Result := 255;
  SetPromptsAllowed(not FOptions.BatchMode);
  if not ConnectSocket_ then
    Exit;
  Offer.KeyExchange := FOptions.KeyExchanges;
  Offer.Ciphers := FOptions.Ciphers;
  Offer.HostKey := FOptions.HostKeyAlgorithms;
  FTransport := TSshClientTransport.Create(Offer, SoftwareVersion);
  FChecker := THostKeyChecker.Create(FOptions);
  FTransport.OnHostKey := @FChecker.Check;
  FAuthenticator := TSshClientAuthenticator.Create(FTransport, FOptions.User);
  FAuthenticator.AllowPublicKey := FOptions.PublicKeyAuthentication;
  FAuthenticator.AllowPassword := FOptions.PasswordAuthentication;
  FAuthenticator.AllowKeyboardInteractive := FOptions.KeyboardInteractive;
  FAuthenticator.OnPassword := @Password;
  FAuthenticator.OnPrompt := @Prompt;
  FAuthenticator.OnBanner := @Banner;
  FAuthenticator.OnNote := @Note;
  LoadIdentities;
  for Index := 0 to High(FIdentities) do
    FAuthenticator.AddIdentity(FIdentities[Index]);
  AuthenticationStarted := False;
  FTransport.Start;
  try
    while not FEnded do
    begin
      if not SendOutput then
      begin
        WriteLn(ErrOutput, 'ssh: connection to ', FOptions.Host, ' lost');
        FFailed := FSession = nil;
        Break;
      end;
      WaitOnce;
      if FEnded then
        Break;
      if not AuthenticationStarted and FTransport.FirstExchangeDone then
      begin
        Note('key exchange ' + FTransport.Negotiated.KeyExchange + ', host key ' + FTransport.Negotiated.HostKey +
          ', cipher ' + FTransport.Negotiated.CipherServerToClient);
        AuthenticationStarted := True;
        FAuthenticator.Start;
      end;
      PollChannels(FConnection);
      if FConnection <> nil then
        FConnection.Flush;
      if (FSession <> nil) and FSession.DisconnectRequested then
      begin
        FTransport.SendDisconnect(DisconnectByApplication, 'disconnected by user');
        FEnded := True;
      end;
      if (FSession <> nil) and FSession.Done then
        FEnded := True;
      if FTransport.Closed then
        FEnded := True;
    end;
    if FConnection <> nil then
      FConnection.Flush;
    SendOutput;
  except
    on Error: ESshDisconnect do
    begin
      WriteLn(ErrOutput, 'ssh: ', Error.Message);
      FTransport.SendDisconnect(Error.Reason, Error.Message);
      SendOutput;
      FFailed := True;
    end;
    on Error: ESshPeerDisconnected do
      FFailed := FSession = nil;
    on Error: ESshProtocolError do
    begin
      WriteLn(ErrOutput, 'ssh: protocol error: ', Error.Message);
      FFailed := True;
    end;
  end;
  if FRawMode then
  begin
    LeaveRawMode;
    FRawMode := False;
  end;
  if FFailed then
    Exit(255);
  if FSession <> nil then
    Result := FSession.ExitStatus
  else
    Result := 0;
end;

function RunClient(const Options: TSshClientOptions): LongInt;
var
  Client: TClient;
begin
  Client := TClient.Create(Options);
  try
    Result := Client.Run;
  finally
    Client.Free;
  end;
end;

end.
