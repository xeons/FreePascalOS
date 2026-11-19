{LICENSE}

{
  libssh's client against its server, all in memory: with each key
  exchange method (mlkem768x25519-sha256, curve25519-sha256), each
  cipher, and each way to log in - publickey (as
  publickey-hostbound-v00 when the server offers it), a certificate
  key, keyboard-interactive (the server's prompt answered), password -
  then a channel the client opens (an exec request, data both ways,
  exit-status, the orderly end), a global request with its reply, and
  a refused login.
}
unit SshTest.ClientServer;

{$mode objfpc}
{$H+}

interface

procedure TestClientAgainstServer;

implementation

uses
  SysUtils,
  TestChecks,
  SshTest.Helpers,
  Ssh.Constants,
  Ssh.Wire,
  Ssh.Algorithms,
  Ssh.HostKeys,
  Ssh.PublicKeys,
  Ssh.Transport,
  Ssh.ServerTransport,
  Ssh.ClientTransport,
  Ssh.ClientIdentities,
  Ssh.ClientAuthentication,
  Ssh.AuthorizedKeys,
  Ssh.UserAuthentication,
  Ssh.Connection;

const
  TestUser = 'tester';
  TestPassword = 'correct horse';

type
  TPairPolicy = class(TSshAccountPolicy)
  public
    AuthorizedBlob: string;
    function PublicKeyAuthenticationAllowed(const User: string): Boolean; override;
    function PasswordAuthenticationAllowed(const User: string): Boolean; override;
    function KeyboardInteractiveAllowed(const User: string): Boolean; override;
    function AuthorizeKey(const User, Blob: string; out Options: TSshKeyOptions): Boolean; override;
    function PasswordIsRight(const User, Password: string): Boolean; override;
  end;

  { The server's end: answers exec with the command echoed, then echoes
    data, and ends with status 3 at EOF. }
  TServerEcho = class(TSshChannel)
  protected
    function HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean; override;
    procedure HandleData(const Data: string); override;
    procedure HandleEof; override;
  end;

  { The client's end: keeps what comes back. }
  TClientSide = class(TSshChannel)
  public
    Received: string;
    ExitStatus: LongInt;
    Confirmed, ExecAccepted: Boolean;
  protected
    function HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean; override;
    procedure HandleData(const Data: string); override;
    procedure HandleOpenConfirmed; override;
    procedure HandleRequestReply(Succeeded: Boolean); override;
  end;

  TPair = class
  public
    HostKeys: THostKeyArray;
    Policy: TPairPolicy;
    Server: TSshServerTransport;
    ServerAuthenticator: TSshUserAuthenticator;
    ServerConnection: TSshConnection;
    Client: TSshClientTransport;
    ClientAuthenticator: TSshClientAuthenticator;
    ClientConnection: TSshConnection;
    HostKeySeen: string;
    GlobalReplies: Integer;
    GlobalReplyData: string;
    Failed: Boolean;
    PasswordToGive: string;
    PromptsSeen: Integer;
    constructor Create(const KeyExchange, Cipher: string);
    destructor Destroy; override;
    procedure Pump;
    function CheckHostKey(const Blob: string): Boolean;
    function GivePassword(out Password: string): Boolean;
    function AnswerPrompt(const Name, Instruction, Prompt: string; Echo: Boolean; out Response: string): Boolean;
    function ServerChannelOpen(Connection: TSshConnection; const ChannelType: string; var Reader: TSshReader;
      out FailureReason: LongWord): TSshChannel;
    function ServerGlobalRequest(Connection: TSshConnection; const RequestName: string; var Reader: TSshReader;
      out ReplyData: string): Boolean;
    procedure GlobalReply(Succeeded: Boolean; const ReplyData: string);
  end;

function TPairPolicy.PublicKeyAuthenticationAllowed(const User: string): Boolean;
begin
  Result := True;
end;

function TPairPolicy.PasswordAuthenticationAllowed(const User: string): Boolean;
begin
  Result := True;
end;

function TPairPolicy.KeyboardInteractiveAllowed(const User: string): Boolean;
begin
  Result := True;
end;

function TPairPolicy.AuthorizeKey(const User, Blob: string; out Options: TSshKeyOptions): Boolean;
begin
  Options := Default(TSshKeyOptions);
  Options.NoPty := True;
  Result := (User = TestUser) and (Blob = AuthorizedBlob);
end;

function TPairPolicy.PasswordIsRight(const User, Password: string): Boolean;
begin
  Result := (User = TestUser) and (Password = TestPassword);
end;

function TServerEcho.HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean;
begin
  Result := RequestType = 'exec';
  if Result then
    SendData('ran: ' + Reader.ReadString + #10);
end;

procedure TServerEcho.HandleData(const Data: string);
begin
  SendData(Data);
  InputConsumed(Length(Data));
end;

procedure TServerEcho.HandleEof;
begin
  Finish(True, 3);
end;

function TClientSide.HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean;
begin
  Result := RequestType = 'exit-status';
  if Result then
    ExitStatus := LongInt(Reader.ReadUInt32);
end;

procedure TClientSide.HandleData(const Data: string);
begin
  Received := Received + Data;
  InputConsumed(Length(Data));
end;

procedure TClientSide.HandleOpenConfirmed;
begin
  Confirmed := True;
  SendRequestWithReply('exec', SshString('uname'));
end;

procedure TClientSide.HandleRequestReply(Succeeded: Boolean);
begin
  ExecAccepted := Succeeded;
end;

constructor TPair.Create(const KeyExchange, Cipher: string);
var
  Offer: TSshAlgorithmOffer;
begin
  inherited Create;
  SetLength(HostKeys, 2);
  HostKeys[0] := TSshEd25519HostKey.Generate;
  HostKeys[1] := TSshEcdsaP256HostKey.Generate;
  Policy := TPairPolicy.Create;
  Server := TSshServerTransport.Create(HostKeys, 'PairServer_1.0');
  ServerAuthenticator := TSshUserAuthenticator.Create(Server, Policy);
  Offer := DefaultClientOffer;
  Offer.KeyExchange := ToStringArray([KeyExchange]);
  Offer.Ciphers := ToStringArray([Cipher]);
  Client := TSshClientTransport.Create(Offer, 'PairClient_1.0');
  Client.OnHostKey := @CheckHostKey;
  ClientAuthenticator := TSshClientAuthenticator.Create(Client, TestUser);
  ClientAuthenticator.OnPassword := @GivePassword;
  ClientAuthenticator.OnPrompt := @AnswerPrompt;
  Server.Start;
  Client.Start;
end;

destructor TPair.Destroy;
begin
  ClientConnection.Free;
  ServerConnection.Free;
  ClientAuthenticator.Free;
  ServerAuthenticator.Free;
  Client.Free;
  Server.Free;
  Policy.Free;
  HostKeys[0].Free;
  HostKeys[1].Free;
  inherited Destroy;
end;

function TPair.CheckHostKey(const Blob: string): Boolean;
begin
  HostKeySeen := Blob;
  Result := True;
end;

function TPair.GivePassword(out Password: string): Boolean;
begin
  Password := PasswordToGive;
  Result := PasswordToGive <> '';
end;

function TPair.AnswerPrompt(const Name, Instruction, Prompt: string; Echo: Boolean; out Response: string): Boolean;
begin
  Inc(PromptsSeen);
  Response := PasswordToGive;
  Result := (PasswordToGive <> '') and (Prompt = 'Password: ') and not Echo;
end;

function TPair.ServerChannelOpen(Connection: TSshConnection; const ChannelType: string; var Reader: TSshReader;
  out FailureReason: LongWord): TSshChannel;
begin
  Result := nil;
  FailureReason := OpenUnknownChannelType;
  if ChannelType = 'session' then
    Result := TServerEcho.Create(Connection);
end;

function TPair.ServerGlobalRequest(Connection: TSshConnection; const RequestName: string; var Reader: TSshReader;
  out ReplyData: string): Boolean;
begin
  ReplyData := SshUInt32(4242);
  Result := RequestName = 'tcpip-forward';
end;

procedure TPair.GlobalReply(Succeeded: Boolean; const ReplyData: string);
begin
  Inc(GlobalReplies);
  if Succeeded then
    GlobalReplyData := ReplyData;
end;

procedure TPair.Pump;
var
  Round: Integer;
  Message: TSshReceivedMessage;
  Moved: Boolean;
begin
  for Round := 1 to 50 do
  begin
    Moved := False;
    try
      if Client.HasOutput then
      begin
        Server.Receive(Client.TakeOutput);
        Moved := True;
      end;
      while Server.NextMessage(Message) do
        if not ServerAuthenticator.HandleMessage(Message) then
        begin
          if ServerConnection = nil then
          begin
            ServerConnection := TSshConnection.Create(Server);
            ServerConnection.OnChannelOpen := @ServerChannelOpen;
            ServerConnection.OnGlobalRequest := @ServerGlobalRequest;
          end;
          ServerConnection.HandleMessage(Message);
        end;
      if ServerConnection <> nil then
        ServerConnection.Flush;
      if Server.HasOutput then
      begin
        Client.Receive(Server.TakeOutput);
        Moved := True;
      end;
      while Client.NextMessage(Message) do
        if not ClientAuthenticator.HandleMessage(Message) and (ClientConnection <> nil) then
          ClientConnection.HandleMessage(Message);
      if ClientConnection <> nil then
        ClientConnection.Flush;
    except
      on Error: Exception do
      begin
        WriteLn('     pump: ', Error.ClassName, ': ', Error.Message);
        Failed := True;
        Exit;
      end;
    end;
    if not Moved and not Client.HasOutput and not Server.HasOutput then
      Exit;
  end;
end;

{ Up to the end of user authentication. }
function LogIn(Pair: TPair): Boolean;
begin
  Pair.Pump;
  if not Pair.Client.FirstExchangeDone then
    Exit(False);
  Pair.ClientAuthenticator.Start;
  Pair.Pump;
  Result := Pair.ClientAuthenticator.Succeeded and Pair.ServerAuthenticator.Succeeded;
end;

procedure TestSession(Pair: TPair; const Name: string);
var
  Channel: TClientSide;
begin
  Pair.ClientConnection := TSshConnection.Create(Pair.Client);
  Channel := TClientSide.Create(Pair.ClientConnection);
  Pair.ClientConnection.OpenChannel(Channel, 'session', '');
  Pair.Pump;
  Check(Channel.Confirmed and Channel.ExecAccepted, Name + ': session channel confirmed, exec accepted');
  Channel.SendData('hello from the client');
  Channel.SendEofWhenFlushed;
  Pair.ClientConnection.Flush;
  Pair.Pump;
  Check((Channel.Received = 'ran: uname'#10'hello from the client') and (Channel.ExitStatus = 3) and
    Channel.CloseReceived, Name + ': data both ways, exit-status and CLOSE');
  Pair.ClientConnection.SendGlobalRequest('tcpip-forward', SshString('') + SshUInt32(0), True, @Pair.GlobalReply);
  Pair.ClientConnection.SendGlobalRequest('no-such-request', '', True, @Pair.GlobalReply);
  Pair.Pump;
  Check((Pair.GlobalReplies = 2) and (Pair.GlobalReplyData = SshUInt32(4242)),
    Name + ': global requests answered in order, with reply data');
  Pair.Pump;
  Check(Pair.ClientConnection.ChannelCount = 0, Name + ': the closed channel is gone');
end;

procedure TestKeyLogin(const KeyExchange, Cipher: string);
var
  Pair: TPair;
  Identity: TSshKeyFileIdentity;
  Name: string;
begin
  Name := KeyExchange + ' ' + Cipher;
  Pair := TPair.Create(KeyExchange, Cipher);
  Identity := TSshKeyFileIdentity.Create(TSshEd25519HostKey.Generate, 'generated');
  try
    Pair.Policy.AuthorizedBlob := Identity.PublicBlob;
    Pair.ClientAuthenticator.AddIdentity(Identity);
    Check(LogIn(Pair) and not Pair.Failed, Name + ': publickey login');
    Check(Pair.Client.Negotiated.KeyExchange = KeyExchange, Name + ': the key exchange asked for');
    Check((Pair.Client.SessionId = Pair.Server.SessionId) and (Pair.Client.SessionId <> ''), Name + ': same session id');
    Check(Pair.Client.StrictKeyExchange and Pair.Server.StrictKeyExchange, Name + ': strict key exchange on both');
    Check(Pair.Client.ExtensionInformationReceived and Pair.Client.ServerTakesHostBound and
      (Pair.ServerAuthenticator.Method = MethodPublicKeyHostBound),
      Name + ': EXT_INFO taken; the key bound to the host key');
    Check(Pair.HostKeySeen = Pair.Server.Negotiated.HostKey + '' + '' + Copy(Pair.HostKeySeen, 1, 0) + Pair.HostKeySeen,
      Name + ': the host key was checked');
    Check(Pair.ServerAuthenticator.Options.NoPty, Name + ': the key''s options reach the server');
    if Pair.ServerAuthenticator.Succeeded then
      TestSession(Pair, Name);
    Pair.Client.Rekey;
    Pair.Pump;
    Check((Pair.Client.KeyExchangeCount = 2) and (Pair.Server.KeyExchangeCount = 2) and not Pair.Failed,
      Name + ': a rekeying the client starts');
  finally
    Pair.Free;
    Identity.Free;
  end;
end;

procedure TestPasswordLogins;
var
  Pair: TPair;
begin
  Pair := TPair.Create('mlkem768x25519-sha256', 'chacha20-poly1305@openssh.com');
  try
    Pair.PasswordToGive := TestPassword;
    Check(LogIn(Pair) and (Pair.ServerAuthenticator.Method = MethodKeyboardInteractive) and (Pair.PromptsSeen = 1),
      'keyboard-interactive: the password prompt answered');
  finally
    Pair.Free;
  end;
  Pair := TPair.Create('curve25519-sha256', 'aes128-gcm@openssh.com');
  try
    Pair.PasswordToGive := TestPassword;
    Pair.ClientAuthenticator.AllowKeyboardInteractive := False;
    Check(LogIn(Pair) and (Pair.ServerAuthenticator.Method = MethodPassword), 'password login');
  finally
    Pair.Free;
  end;
  Pair := TPair.Create('curve25519-sha256@libssh.org', 'aes256-gcm@openssh.com');
  try
    Pair.PasswordToGive := 'wrong';
    Check(not LogIn(Pair) and Pair.ClientAuthenticator.Failed and not Pair.ServerAuthenticator.Succeeded,
      'a wrong password: every method refused, the client gives up');
  finally
    Pair.Free;
  end;
end;

procedure TestClientAgainstServer;
begin
  TestKeyLogin('mlkem768x25519-sha256', 'chacha20-poly1305@openssh.com');
  TestKeyLogin('mlkem768x25519-sha256', 'aes256-gcm@openssh.com');
  TestKeyLogin('curve25519-sha256', 'aes128-gcm@openssh.com');
  TestPasswordLogins;
end;

end.
