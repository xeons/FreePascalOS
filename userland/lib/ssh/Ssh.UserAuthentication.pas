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
  User authentication, the server's side (RFC 4252): the ssh-userauth
  service and its methods "none" (always refused: it asks for the list),
  "publickey" (and OpenSSH's publickey-hostbound-v00@openssh.com),
  "password" and "keyboard-interactive" (RFC 4256, with one password
  prompt).

  Who may log in, with which keys and passwords, is the account policy's
  to say (TSshAccountPolicy, which the server program implements over
  the system's accounts and its configuration); it also gives a key's
  options (authorized_keys options, or a certificate's). Here is the
  protocol: a publickey query is answered with PK_OK when the key would
  do; a signed request is accepted when the key is authorized and the
  signature over

    string session id, byte 50, string user, string service,
    string method, boolean TRUE, string algorithm, string key
    [string server host key: publickey-hostbound only]

  is right. The key may be a certificate (Ssh.Certificates): its own key
  checks the signature, the policy its authority. A hostbound request
  names one of this server's host keys, so the signature cannot be
  replayed to another server (OpenSSH's agent restrictions build on
  this). A password change request is refused. After too many failures
  the client is disconnected.
}
unit Ssh.UserAuthentication;

{$mode objfpc}{$H+}

interface

uses
  Ssh.Wire,
  Ssh.Transport,
  Ssh.ServerTransport,
  Ssh.AuthorizedKeys;

const
  MethodPublicKey = 'publickey';
  MethodPublicKeyHostBound = 'publickey-hostbound-v00@openssh.com';
  MethodPassword = 'password';
  MethodKeyboardInteractive = 'keyboard-interactive';

type
  TSshAccountPolicy = class
  public
    function PublicKeyAuthenticationAllowed(const User: string): Boolean; virtual; abstract;
    function PasswordAuthenticationAllowed(const User: string): Boolean; virtual; abstract;
    function KeyboardInteractiveAllowed(const User: string): Boolean; virtual;
    { Whether Blob (a key or a certificate; its signature is checked
      apart) may log User in (and User may log in at all), and with
      which options. }
    function AuthorizeKey(const User, Blob: string; out Options: TSshKeyOptions): Boolean; virtual; abstract;
    { Whether Password is User's (and User may log in at all). A wrong
      one should take a while to be answered. }
    function PasswordIsRight(const User, Password: string): Boolean; virtual; abstract;
    { For the log: what happened (never a password). }
    procedure Note(const Text: string); virtual;
  end;

  TSshUserAuthenticator = class
  private
    FTransport: TSshServerTransport;
    FPolicy: TSshAccountPolicy;
    FSucceeded: Boolean;
    FUserName: string;
    FMethod: string;
    FOptions: TSshKeyOptions;
    FFailures: Integer;
    FAwaitingInfoResponse: Boolean;
    FInfoUser: string;
    procedure HandleServiceRequest(const Payload: string);
    procedure HandleRequest(const Payload: string);
    procedure HandleInfoResponse(const Payload: string);
    function TryPublicKey(const User, Service, Method: string; var Reader: TSshReader): Boolean;
    function TryPassword(const User: string; var Reader: TSshReader): Boolean;
    procedure StartKeyboardInteractive(const User: string; var Reader: TSshReader);
    procedure Succeed(const User, Method: string);
    procedure SendFailure(const User: string);
    procedure CountFailure;
    function MethodList(const User: string): string;
  public
    constructor Create(Transport: TSshServerTransport; Policy: TSshAccountPolicy);
    { Handles SERVICE_REQUEST, USERAUTH_REQUEST and USERAUTH_INFO_RESPONSE;
      False for any other message (left to the caller). }
    function HandleMessage(const Message: TSshReceivedMessage): Boolean;
    property Succeeded: Boolean read FSucceeded;
    property UserName: string read FUserName;
    { "publickey", "password" or "keyboard-interactive", once succeeded. }
    property Method: string read FMethod;
    { The key's options (none for a password). }
    property Options: TSshKeyOptions read FOptions;
  end;

{ The signature check of a publickey request: Blob a key or a
  certificate, Algorithm the request's. }
function PublicKeySignatureIsRight(const Blob, Algorithm, SignedData, Signature: string): Boolean;
{ Whether a publickey request's algorithm fits its key. }
function PublicKeyAlgorithmFits(const Blob, Algorithm: string): Boolean;

implementation

uses
  SysUtils,
  Ssh.Constants,
  Ssh.PublicKeys,
  Ssh.Certificates;

const
  MaximumFailures = 10;
  PasswordPrompt = 'Password: ';

procedure TSshAccountPolicy.Note(const Text: string);
begin
end;

function TSshAccountPolicy.KeyboardInteractiveAllowed(const User: string): Boolean;
begin
  Result := False;
end;

function KeyTypeOf(const Blob: string): string;
var
  Reader: TSshReader;
begin
  try
    Reader.Start(Blob);
    Result := Reader.ReadString;
  except
    on ESshProtocolError do
      Result := '';
  end;
end;

{ The key that checks the signature and the algorithm in the signature. }
function SigningKey(const Blob, Algorithm: string; out Key: TSshPublicKey; out PlainAlgorithm: string): Boolean;
var
  KeyType: string;
  Certificate: TSshCertificate;
begin
  KeyType := KeyTypeOf(Blob);
  if IsCertificateKeyType(KeyType) then
  begin
    Result := ParseCertificate(Blob, Certificate);
    if not Result then
      Exit;
    Key := Certificate.Key;
    PlainAlgorithm := PlainSignatureAlgorithm(KeyType, Algorithm);
    Result := PlainAlgorithm <> '';
  end
  else
  begin
    Result := ParsePublicKeyBlob(Blob, Key) and SignatureAlgorithmFits(Key, Algorithm);
    PlainAlgorithm := Algorithm;
  end;
end;

function PublicKeyAlgorithmFits(const Blob, Algorithm: string): Boolean;
var
  Key: TSshPublicKey;
  PlainAlgorithm: string;
begin
  Result := SigningKey(Blob, Algorithm, Key, PlainAlgorithm);
end;

function PublicKeySignatureIsRight(const Blob, Algorithm, SignedData, Signature: string): Boolean;
var
  Key: TSshPublicKey;
  PlainAlgorithm: string;
begin
  Result := SigningKey(Blob, Algorithm, Key, PlainAlgorithm) and
    VerifySshSignature(Key, PlainAlgorithm, SignedData, Signature);
end;

constructor TSshUserAuthenticator.Create(Transport: TSshServerTransport; Policy: TSshAccountPolicy);
begin
  inherited Create;
  FTransport := Transport;
  FPolicy := Policy;
end;

function TSshUserAuthenticator.HandleMessage(const Message: TSshReceivedMessage): Boolean;
var
  MessageType: Byte;
begin
  MessageType := Ord(Message.Payload[1]);
  Result := True;
  case MessageType of
    MessageServiceRequest: HandleServiceRequest(Message.Payload);
    MessageUserAuthenticationRequest:
      { Requests after success are ignored (RFC 4252 section 5.1). }
      if not FSucceeded then
        HandleRequest(Message.Payload);
    MessageUserAuthenticationInfoResponse:
      if not FSucceeded then
        HandleInfoResponse(Message.Payload);
  else
    Result := False;
  end;
end;

procedure TSshUserAuthenticator.HandleServiceRequest(const Payload: string);
var
  Reader: TSshReader;
  Service: string;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  Service := Reader.ReadString;
  if (Service <> ServiceUserAuthentication) or FSucceeded then
    raise ESshDisconnect.CreateWithReason(DisconnectServiceNotAvailable, 'service not available: ' + Service);
  FTransport.Send(SshByte(MessageServiceAccept) + SshString(Service));
end;

function TSshUserAuthenticator.MethodList(const User: string): string;
var
  Methods: string;

  procedure Add(const Name: string);
  begin
    if Methods <> '' then
      Methods := Methods + ',';
    Methods := Methods + Name;
  end;

begin
  Methods := '';
  if FPolicy.PublicKeyAuthenticationAllowed(User) then
    Add(MethodPublicKey);
  if FPolicy.PasswordAuthenticationAllowed(User) then
    Add(MethodPassword);
  if FPolicy.KeyboardInteractiveAllowed(User) then
    Add(MethodKeyboardInteractive);
  Result := SshString(Methods);
end;

procedure TSshUserAuthenticator.SendFailure(const User: string);
begin
  FTransport.Send(SshByte(MessageUserAuthenticationFailure) + MethodList(User) + SshBoolean(False));
end;

procedure TSshUserAuthenticator.CountFailure;
begin
  Inc(FFailures);
  if FFailures >= MaximumFailures then
    raise ESshDisconnect.CreateWithReason(DisconnectNoMoreAuthenticationMethods,
      'too many authentication failures');
end;

procedure TSshUserAuthenticator.Succeed(const User, Method: string);
begin
  FSucceeded := True;
  FUserName := User;
  FMethod := Method;
  FTransport.Send(SshByte(MessageUserAuthenticationSuccess));
end;

procedure TSshUserAuthenticator.HandleRequest(const Payload: string);
var
  Reader: TSshReader;
  User, Service, RequestedMethod: string;
  Accepted: Boolean;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  User := Reader.ReadString;
  Service := Reader.ReadString;
  RequestedMethod := Reader.ReadString;
  if Service <> ServiceConnection then
    raise ESshDisconnect.CreateWithReason(DisconnectServiceNotAvailable, 'service not available: ' + Service);
  { A new request ends a keyboard-interactive exchange under way. }
  FAwaitingInfoResponse := False;
  FOptions := Default(TSshKeyOptions);
  if ((RequestedMethod = MethodPublicKey) or (RequestedMethod = MethodPublicKeyHostBound)) and
    FPolicy.PublicKeyAuthenticationAllowed(User) then
    Accepted := TryPublicKey(User, Service, RequestedMethod, Reader)
  else if (RequestedMethod = MethodPassword) and FPolicy.PasswordAuthenticationAllowed(User) then
    Accepted := TryPassword(User, Reader)
  else if (RequestedMethod = MethodKeyboardInteractive) and FPolicy.KeyboardInteractiveAllowed(User) then
  begin
    StartKeyboardInteractive(User, Reader);
    Exit;
  end
  else if RequestedMethod = 'none' then
  begin
    SendFailure(User);
    Exit;
  end
  else
  begin
    SendFailure(User);
    CountFailure;
    Exit;
  end;
  if Accepted then
    Succeed(User, RequestedMethod);
end;

{ Answers the request itself (PK_OK, or a failure) unless it succeeds. }
function TSshUserAuthenticator.TryPublicKey(const User, Service, Method: string; var Reader: TSshReader): Boolean;
var
  Signed: Boolean;
  Algorithm, Blob, HostKeyBlob, Signature, SignedData: string;
  Usable: Boolean;
  KeyOptions: TSshKeyOptions;
begin
  Result := False;
  Signed := Reader.ReadBoolean;
  Algorithm := Reader.ReadString;
  Blob := Reader.ReadString;
  HostKeyBlob := '';
  if Method = MethodPublicKeyHostBound then
    HostKeyBlob := Reader.ReadString;
  Usable := PublicKeyAlgorithmFits(Blob, Algorithm) and
    ((Method = MethodPublicKey) or FTransport.IsOwnHostKey(HostKeyBlob)) and
    FPolicy.AuthorizeKey(User, Blob, KeyOptions);
  if not Signed then
  begin
    if Usable then
      FTransport.Send(SshByte(MessageUserAuthenticationPublicKeyOk) + SshString(Algorithm) + SshString(Blob))
    else
    begin
      FPolicy.Note('key ' + PublicKeyFingerprint(Blob) + ' refused for ' + User);
      SendFailure(User);
      CountFailure;
    end;
    Exit;
  end;
  Signature := Reader.ReadString;
  if Usable then
  begin
    SignedData := SshString(FTransport.SessionId) + SshByte(MessageUserAuthenticationRequest) + SshString(User) +
      SshString(Service) + SshString(Method) + SshBoolean(True) + SshString(Algorithm) + SshString(Blob);
    if Method = MethodPublicKeyHostBound then
      SignedData := SignedData + SshString(HostKeyBlob);
    Result := PublicKeySignatureIsRight(Blob, Algorithm, SignedData, Signature);
  end;
  if Result then
  begin
    FOptions := KeyOptions;
    FPolicy.Note('accepted key ' + PublicKeyFingerprint(Blob) + ' (' + Algorithm + ') for ' + User);
  end
  else
  begin
    FPolicy.Note('key ' + PublicKeyFingerprint(Blob) + ' refused for ' + User);
    SendFailure(User);
    CountFailure;
  end;
end;

function TSshUserAuthenticator.TryPassword(const User: string; var Reader: TSshReader): Boolean;
var
  ChangeRequested: Boolean;
  Password: string;
begin
  Result := False;
  ChangeRequested := Reader.ReadBoolean;
  Password := Reader.ReadString;
  if not ChangeRequested then
    Result := FPolicy.PasswordIsRight(User, Password);
  WipeString(Password);
  if Result then
    FPolicy.Note('accepted password for ' + User)
  else
  begin
    FPolicy.Note('password refused for ' + User);
    SendFailure(User);
    CountFailure;
  end;
end;

{ RFC 4256: one prompt, not echoed. The language and submethods are
  read and not used. }
procedure TSshUserAuthenticator.StartKeyboardInteractive(const User: string; var Reader: TSshReader);
begin
  Reader.ReadString;
  Reader.ReadString;
  FInfoUser := User;
  FAwaitingInfoResponse := True;
  FTransport.Send(SshByte(MessageUserAuthenticationInfoRequest) + SshString('') + SshString('') + SshString('') +
    SshUInt32(1) + SshString(PasswordPrompt) + SshBoolean(False));
end;

procedure TSshUserAuthenticator.HandleInfoResponse(const Payload: string);
var
  Reader: TSshReader;
  Count: LongWord;
  Password: string;
  Right: Boolean;
begin
  if not FAwaitingInfoResponse then
    raise ESshProtocolError.Create('INFO_RESPONSE without a request');
  FAwaitingInfoResponse := False;
  Reader.Start(Payload);
  Reader.ReadByte;
  Count := Reader.ReadUInt32;
  Right := False;
  if Count = 1 then
  begin
    Password := Reader.ReadString;
    Right := FPolicy.PasswordIsRight(FInfoUser, Password);
    WipeString(Password);
  end;
  if Right then
  begin
    FPolicy.Note('accepted keyboard-interactive password for ' + FInfoUser);
    Succeed(FInfoUser, MethodKeyboardInteractive);
  end
  else
  begin
    FPolicy.Note('keyboard-interactive password refused for ' + FInfoUser);
    SendFailure(FInfoUser);
    CountFailure;
  end;
end;

end.
