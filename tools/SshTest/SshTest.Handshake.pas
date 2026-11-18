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
  The server's transport, authentication and connection layers against a
  small client made here of libssh's pieces, all in memory: the version
  lines, the key exchange (the host key's signature over H checked as a
  client checks it), the strict key exchange (sequence numbers starting
  again, a stray packet before KEXINIT refused), EXT_INFO, password and
  publickey authentication (refusals, PK_OK, the signed request), a
  session channel with a request, data both ways and its orderly end
  (EOF, exit-status, CLOSE), and a rekeying in the middle.
}
unit SshTest.Handshake;

{$mode objfpc}
{$H+}

interface

procedure TestHandshake;

implementation

uses
  SysUtils,
  TestChecks,
  SshTest.Helpers,
  Ssh.Constants,
  Ssh.Wire,
  Ssh.CipherSuites,
  Ssh.PacketLayer,
  Ssh.KeyExchange,
  Ssh.HostKeys,
  Ssh.PublicKeys,
  Ssh.ServerTransport,
  Ssh.UserAuthentication,
  Ssh.Connection;

const
  ClientVersionLine = 'SSH-2.0-SshTest_1.0';
  TestUser = 'tester';
  TestPassword = 'right horse battery';

type
  TTestPolicy = class(TSshAccountPolicy)
  public
    AuthorizedBlob: string;
    function PublicKeyAuthenticationAllowed: Boolean; override;
    function PasswordAuthenticationAllowed: Boolean; override;
    function PublicKeyIsAuthorized(const User, Blob: string): Boolean; override;
    function PasswordIsRight(const User, Password: string): Boolean; override;
  end;

  { Echoes data back, and ends with status 7 at the client's EOF. }
  TEchoChannel = class(TSshChannel)
  public
    LastRequest: string;
    LastCommand: string;
  protected
    function HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean; override;
    procedure HandleData(const Data: string); override;
    procedure HandleEof; override;
  end;

  TTestClient = class
  private
    FPackets: TSshPacketLayer;
    FServerVersion: string;
    FClientInit, FServerInit: string;
    FCipher: string;
    FSessionId: string;
    FVersionDone: Boolean;
    FVersionSent: Boolean;
    FPendingBytes: string;
  public
    Server: TSshServerTransport;
    Authenticator: TSshUserAuthenticator;
    Connection: TSshConnection;
    Policy: TTestPolicy;
    HostKeys: THostKeyArray;
    ServerDisconnected: Boolean;
    DisconnectReason: LongWord;
    constructor Create(const Cipher: string);
    destructor Destroy; override;
    procedure SendRaw(const Bytes: string);
    procedure SendVersion;
    procedure Send(const Payload: string);
    { Runs the server on what the client sent, and takes its answers. }
    procedure Pump;
    function NextPayload(out Payload: string): Boolean;
    function ExpectMessage(MessageType: Byte; out Payload: string): Boolean;
    function KeyExchange(Strict: Boolean): Boolean;
    function OpenChannel(out ServerChannel: TEchoChannel): Boolean;
    function OnChannelOpen(Owner: TSshConnection; const ChannelType: string; var Reader: TSshReader;
      out FailureReason: LongWord): TSshChannel;
    property SessionId: string read FSessionId;
  end;

function TTestPolicy.PublicKeyAuthenticationAllowed: Boolean;
begin
  Result := True;
end;

function TTestPolicy.PasswordAuthenticationAllowed: Boolean;
begin
  Result := True;
end;

function TTestPolicy.PublicKeyIsAuthorized(const User, Blob: string): Boolean;
begin
  Result := (User = TestUser) and (Blob = AuthorizedBlob);
end;

function TTestPolicy.PasswordIsRight(const User, Password: string): Boolean;
begin
  Result := (User = TestUser) and (Password = TestPassword);
end;

function TEchoChannel.HandleRequest(const RequestType: string; var Reader: TSshReader): Boolean;
begin
  LastRequest := RequestType;
  Result := RequestType = 'exec';
  if Result then
    LastCommand := Reader.ReadString;
end;

procedure TEchoChannel.HandleData(const Data: string);
begin
  SendData(UpperCase(Data));
  InputConsumed(Length(Data));
end;

procedure TEchoChannel.HandleEof;
begin
  Finish(True, 7);
end;

constructor TTestClient.Create(const Cipher: string);
begin
  inherited Create;
  FCipher := Cipher;
  FPackets := TSshPacketLayer.Create;
  Policy := TTestPolicy.Create;
  SetLength(HostKeys, 2);
  HostKeys[0] := TSshEd25519HostKey.Generate;
  HostKeys[1] := TSshEcdsaP256HostKey.Generate;
  Server := TSshServerTransport.Create(HostKeys, 'SshTestServer_1.0');
  Authenticator := TSshUserAuthenticator.Create(Server, Policy);
  Connection := TSshConnection.Create(Server);
  Connection.OnChannelOpen := @OnChannelOpen;
  Server.Start;
end;

destructor TTestClient.Destroy;
begin
  Connection.Free;
  Authenticator.Free;
  Server.Free;
  Policy.Free;
  HostKeys[0].Free;
  HostKeys[1].Free;
  FPackets.Free;
  inherited Destroy;
end;

function TTestClient.OnChannelOpen(Owner: TSshConnection; const ChannelType: string; var Reader: TSshReader;
  out FailureReason: LongWord): TSshChannel;
begin
  FailureReason := OpenUnknownChannelType;
  if ChannelType = 'session' then
    Result := TEchoChannel.Create(Owner)
  else
    Result := nil;
end;

procedure TTestClient.SendRaw(const Bytes: string);
begin
  FPendingBytes := FPendingBytes + Bytes;
end;

procedure TTestClient.SendVersion;
begin
  if FVersionSent then
    Exit;
  SendRaw(ClientVersionLine + #13#10);
  FVersionSent := True;
end;

procedure TTestClient.Send(const Payload: string);
begin
  SendRaw(FPackets.EncodePacket(Payload));
end;

procedure TTestClient.Pump;
var
  Message: TSshReceivedMessage;
  Output: string;
  LineEnd: Integer;
begin
  try
    Server.Receive(FPendingBytes);
    FPendingBytes := '';
    while Server.NextMessage(Message) do
      if not Authenticator.HandleMessage(Message) and not Connection.HandleMessage(Message) then
        Server.SendUnimplemented(Message.SequenceNumber);
    Connection.Flush;
  except
    on Error: ESshDisconnect do
    begin
      ServerDisconnected := True;
      DisconnectReason := Error.Reason;
      Server.SendDisconnect(Error.Reason, Error.Message);
    end;
  end;
  Output := Server.TakeOutput;
  if not FVersionDone then
  begin
    LineEnd := Pos(#13#10, Output);
    if LineEnd = 0 then
      Exit;
    FServerVersion := Copy(Output, 1, LineEnd - 1);
    Delete(Output, 1, LineEnd + 1);
    FVersionDone := True;
  end;
  { Packets are taken one at a time by NextPayload, since a NEWKEYS
    changes how the next ones are read. }
  FPackets.AppendInput(Output);
end;

function TTestClient.NextPayload(out Payload: string): Boolean;
var
  SequenceNumber: LongWord;
begin
  Result := FPackets.NextPayload(Payload, SequenceNumber);
end;

function TTestClient.ExpectMessage(MessageType: Byte; out Payload: string): Boolean;
begin
  Result := NextPayload(Payload) and (Payload <> '') and (Ord(Payload[1]) = MessageType);
  if not Result and (Payload <> '') then
    WriteLn('     expected message ', MessageType, ', got ', Ord(Payload[1]));
end;

function TTestClient.KeyExchange(Strict: Boolean): Boolean;
var
  KeyExchangeNames: string;
  Payload, HostKeyBlob, ServerPublic, Signature, Shared, Hash: string;
  Reader: TSshReader;
  Ephemeral: TSshEphemeralKey;
  HostKey: TSshPublicKey;
  First: Boolean;

  function Derive(Letter: Char; Size: Integer): string;
  begin
    Result := DeriveKey(Shared, Hash, FSessionId, Letter, Size);
  end;

begin
  Result := False;
  First := FSessionId = '';
  KeyExchangeNames := 'curve25519-sha256';
  if First then
  begin
    KeyExchangeNames := KeyExchangeNames + ',ext-info-c';
    if Strict then
      KeyExchangeNames := KeyExchangeNames + ',kex-strict-c-v00@openssh.com';
  end;
  FClientInit := SshByte(MessageKeyExchangeInit) + StringOfChar('c', 16) + SshString(KeyExchangeNames) +
    SshString('ssh-ed25519') + SshString(FCipher) + SshString(FCipher) + SshString('hmac-sha2-256') +
    SshString('hmac-sha2-256') + SshString('none') + SshString('none') + SshString('') + SshString('') +
    SshBoolean(False) + SshUInt32(0);
  SendVersion;
  Send(FClientInit);
  Pump;
  if not ExpectMessage(MessageKeyExchangeInit, FServerInit) then
    Exit;
  Ephemeral := NewEphemeralKey;
  Send(SshByte(MessageKeyExchangeEcdhInit) + SshString(Ephemeral.PublicKey));
  Pump;
  if not ExpectMessage(MessageKeyExchangeEcdhReply, Payload) then
    Exit;
  Reader.Start(Payload);
  Reader.ReadByte;
  HostKeyBlob := Reader.ReadString;
  ServerPublic := Reader.ReadString;
  Signature := Reader.ReadString;
  if not ComputeSharedSecret(Ephemeral, ServerPublic, Shared) then
    Exit;
  Hash := ComputeExchangeHash(ClientVersionLine, FServerVersion, FClientInit, FServerInit, HostKeyBlob,
    Ephemeral.PublicKey, ServerPublic, Shared);
  Check(ParsePublicKeyBlob(HostKeyBlob, HostKey) and VerifySshSignature(HostKey, 'ssh-ed25519', Hash, Signature),
    FCipher + ': the host key signed H');
  if First then
    FSessionId := Hash;
  if not ExpectMessage(MessageNewKeys, Payload) then
    Exit;
  FPackets.SetReceiveCipher(CreatePacketCipher(FCipher, Derive('D', CipherKeySize(FCipher)),
    Derive('B', CipherInitialValueSize(FCipher))));
  if Strict then
    FPackets.ResetReceiveSequence;
  Send(SshByte(MessageNewKeys));
  FPackets.SetSendCipher(CreatePacketCipher(FCipher, Derive('C', CipherKeySize(FCipher)),
    Derive('A', CipherInitialValueSize(FCipher))));
  if Strict then
    FPackets.ResetSendSequence;
  Result := True;
end;

function TTestClient.OpenChannel(out ServerChannel: TEchoChannel): Boolean;
var
  Payload: string;
begin
  Send(SshByte(MessageChannelOpen) + SshString('session') + SshUInt32(42) + SshUInt32(1000000) +
    SshUInt32(16384));
  Pump;
  Result := ExpectMessage(MessageChannelOpenConfirmation, Payload) and (Connection.ChannelCount = 1);
  ServerChannel := nil;
  if Result then
    ServerChannel := TEchoChannel(Connection.ChannelAt(0));
end;

function UserAuthenticationRequest(const User, Method, Rest: string): string;
begin
  Result := SshByte(MessageUserAuthenticationRequest) + SshString(User) + SshString(ServiceConnection) +
    SshString(Method) + Rest;
end;

procedure TestPasswordSession;
var
  Client: TTestClient;
  Payload: string;
  Reader: TSshReader;
begin
  Client := TTestClient.Create('chacha20-poly1305@openssh.com');
  try
    Check(Client.KeyExchange(True), 'chacha20-poly1305: key exchange (strict)');
    Check(Client.Server.StrictKeyExchange, 'strict key exchange agreed');
    Check(Client.Server.Negotiated.CipherServerToClient = 'chacha20-poly1305@openssh.com', 'cipher negotiated');
    { The EXT_INFO, under the new keys, after NEWKEYS. }
    Check(Client.ExpectMessage(MessageExtensionInformation, Payload) and
      (Pos('server-sig-algs', Payload) > 0) and (Pos('rsa-sha2-256', Payload) > 0),
      'EXT_INFO with server-sig-algs follows NEWKEYS');
    Client.Send(SshByte(MessageServiceRequest) + SshString(ServiceUserAuthentication));
    Client.Pump;
    Check(Client.ExpectMessage(MessageServiceAccept, Payload), 'ssh-userauth accepted');
    Client.Send(UserAuthenticationRequest(TestUser, 'none', ''));
    Client.Pump;
    Check(Client.ExpectMessage(MessageUserAuthenticationFailure, Payload), 'method none refused');
    Reader.Start(Payload);
    Reader.ReadByte;
    Check(Reader.ReadString = 'publickey,password', 'the methods that can continue');
    Client.Send(UserAuthenticationRequest(TestUser, 'password', SshBoolean(False) + SshString('wrong')));
    Client.Pump;
    Check(Client.ExpectMessage(MessageUserAuthenticationFailure, Payload) and not Client.Authenticator.Succeeded,
      'a wrong password refused');
    Client.Send(UserAuthenticationRequest('nobody', 'password', SshBoolean(False) + SshString(TestPassword)));
    Client.Pump;
    Check(Client.ExpectMessage(MessageUserAuthenticationFailure, Payload), 'another user''s password refused');
    Client.Send(UserAuthenticationRequest(TestUser, 'password', SshBoolean(False) + SshString(TestPassword)));
    Client.Pump;
    Check(Client.ExpectMessage(MessageUserAuthenticationSuccess, Payload) and Client.Authenticator.Succeeded and
      (Client.Authenticator.UserName = TestUser) and (Client.Authenticator.Method = 'password'),
      'the right password accepted');
    Client.Send(SshByte(MessageGlobalRequest) + SshString('keepalive@openssh.com') + SshBoolean(True));
    Client.Pump;
    Check(Client.ExpectMessage(MessageRequestFailure, Payload), 'a global request answered with a failure');
  finally
    Client.Free;
  end;
end;

procedure TestPublicKeySession;
var
  Client: TTestClient;
  ClientKey, OtherKey: TSshEd25519HostKey;
  Payload, SignedData, Rest: string;
  Channel: TEchoChannel;
  Reader: TSshReader;
  Data: string;
begin
  Client := TTestClient.Create('aes256-gcm@openssh.com');
  ClientKey := TSshEd25519HostKey.Generate;
  OtherKey := TSshEd25519HostKey.Generate;
  try
    Client.Policy.AuthorizedBlob := ClientKey.PublicBlob;
    Check(Client.KeyExchange(True), 'aes256-gcm: key exchange');
    Client.ExpectMessage(MessageExtensionInformation, Payload);
    Client.Send(SshByte(MessageServiceRequest) + SshString(ServiceUserAuthentication));
    Client.Pump;
    Client.ExpectMessage(MessageServiceAccept, Payload);

    Client.Send(UserAuthenticationRequest(TestUser, 'publickey', SshBoolean(False) + SshString('ssh-ed25519') +
      SshString(OtherKey.PublicBlob)));
    Client.Pump;
    Check(Client.ExpectMessage(MessageUserAuthenticationFailure, Payload), 'publickey: an unlisted key refused');
    Client.Send(UserAuthenticationRequest(TestUser, 'publickey', SshBoolean(False) + SshString('ssh-ed25519') +
      SshString(ClientKey.PublicBlob)));
    Client.Pump;
    Check(Client.ExpectMessage(MessageUserAuthenticationPublicKeyOk, Payload), 'publickey: PK_OK for a listed key');

    SignedData := SshString(Client.SessionId) + SshByte(MessageUserAuthenticationRequest) + SshString(TestUser) +
      SshString(ServiceConnection) + SshString('publickey') + SshBoolean(True) + SshString('ssh-ed25519') +
      SshString(ClientKey.PublicBlob);
    Rest := SshBoolean(True) + SshString('ssh-ed25519') + SshString(ClientKey.PublicBlob);
    Client.Send(UserAuthenticationRequest(TestUser, 'publickey', Rest + SshString(OtherKey.Sign(SignedData))));
    Client.Pump;
    Check(Client.ExpectMessage(MessageUserAuthenticationFailure, Payload),
      'publickey: a signature by another key refused');
    Client.Send(UserAuthenticationRequest(TestUser, 'publickey', Rest + SshString(ClientKey.Sign(SignedData))));
    Client.Pump;
    Check(Client.ExpectMessage(MessageUserAuthenticationSuccess, Payload) and
      (Client.Authenticator.Method = 'publickey'), 'publickey: the signed request accepted');

    Check(Client.OpenChannel(Channel), 'session channel opened');
    Client.Send(SshByte(MessageChannelRequest) + SshUInt32(Channel.LocalId) + SshString('exec') + SshBoolean(True) +
      SshString('uname -a'));
    Client.Pump;
    Check(Client.ExpectMessage(MessageChannelSuccess, Payload) and (Channel.LastCommand = 'uname -a'),
      'exec request answered with success');
    Client.Send(SshByte(MessageChannelRequest) + SshUInt32(Channel.LocalId) + SshString('x11-req') +
      SshBoolean(True) + SshBoolean(False));
    Client.Pump;
    Check(Client.ExpectMessage(MessageChannelFailure, Payload), 'an unknown request answered with failure');

    { A rekeying in the middle, then the channel goes on. }
    Check(Client.KeyExchange(True) and (Client.Server.KeyExchangeCount = 2), 'rekeying');
    Client.Send(SshByte(MessageChannelData) + SshUInt32(Channel.LocalId) + SshString('hello'));
    Client.Pump;
    Check(Client.ExpectMessage(MessageChannelData, Payload), 'data answered after the rekeying');
    Reader.Start(Payload);
    Reader.ReadByte;
    Check(Reader.ReadUInt32 = 42, 'data goes to the client''s channel id');
    Data := Reader.ReadString;
    Check(Data = 'HELLO', 'data echoed');

    Client.Send(SshByte(MessageChannelEof) + SshUInt32(Channel.LocalId));
    Client.Pump;
    Check(Client.ExpectMessage(MessageChannelEof, Payload), 'the channel ends: EOF');
    Check(Client.ExpectMessage(MessageChannelRequest, Payload) and (Pos('exit-status', Payload) > 0) and
      (Copy(Payload, Length(Payload) - 3, 4) = SshUInt32(7)), 'the channel ends: exit-status 7');
    Check(Client.ExpectMessage(MessageChannelClose, Payload), 'the channel ends: CLOSE');
    Client.Send(SshByte(MessageChannelClose) + SshUInt32(Channel.LocalId));
    Client.Pump;
    Check(Client.Connection.ChannelCount = 0, 'the channel is gone once closed both ways');
  finally
    OtherKey.Free;
    ClientKey.Free;
    Client.Free;
  end;
end;

procedure TestStrictRefusal;
var
  Client: TTestClient;
begin
  Client := TTestClient.Create('chacha20-poly1305@openssh.com');
  try
    Client.SendVersion;
    Client.Send(SshByte(MessageIgnore) + SshString('slipped in'));
    Client.KeyExchange(True);
    Check(Client.ServerDisconnected and (Client.DisconnectReason = DisconnectProtocolError),
      'strict key exchange: a packet before KEXINIT ends the connection');
  finally
    Client.Free;
  end;
end;

procedure TestHandshake;
begin
  TestPasswordSession;
  TestPublicKeySession;
  TestStrictRefusal;
end;

end.
