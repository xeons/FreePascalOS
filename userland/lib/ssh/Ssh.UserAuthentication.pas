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
  "publickey" and "password".

  Who may log in, with which keys and passwords, is the account policy's
  to say (TSshAccountPolicy, which the server program implements over
  the system's accounts). Here is the protocol: a publickey query is
  answered with PK_OK when the key would do; a signed request is
  accepted when the key is authorized and the signature over

    string session id, byte 50, string user, string service,
    string "publickey", boolean TRUE, string algorithm, string key

  is right. A password change request is refused. After too many
  failures the client is disconnected.
}
unit Ssh.UserAuthentication;

{$mode objfpc}{$H+}

interface

uses
  Ssh.Wire,
  Ssh.ServerTransport;

type
  TSshAccountPolicy = class
  public
    function PublicKeyAuthenticationAllowed: Boolean; virtual; abstract;
    function PasswordAuthenticationAllowed: Boolean; virtual; abstract;
    { Whether Blob is among the keys User may log in with (and User may
      log in at all). }
    function PublicKeyIsAuthorized(const User, Blob: string): Boolean; virtual; abstract;
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
    FFailures: Integer;
    procedure HandleServiceRequest(const Payload: string);
    procedure HandleRequest(const Payload: string);
    function TryPublicKey(const User, Service: string; var Reader: TSshReader): Boolean;
    function TryPassword(const User: string; var Reader: TSshReader): Boolean;
    procedure SendFailure;
    procedure CountFailure;
    function MethodList: string;
  public
    constructor Create(Transport: TSshServerTransport; Policy: TSshAccountPolicy);
    { Handles SERVICE_REQUEST and USERAUTH_REQUEST; False for any other
      message (left to the caller). }
    function HandleMessage(const Message: TSshReceivedMessage): Boolean;
    property Succeeded: Boolean read FSucceeded;
    property UserName: string read FUserName;
    { "publickey" or "password", once succeeded. }
    property Method: string read FMethod;
  end;

implementation

uses
  SysUtils,
  Ssh.Constants,
  Ssh.PublicKeys;

const
  MaximumFailures = 10;
  MethodPublicKey = 'publickey';
  MethodPassword = 'password';

procedure TSshAccountPolicy.Note(const Text: string);
begin
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

function TSshUserAuthenticator.MethodList: string;
var
  Methods: string;
begin
  Methods := '';
  if FPolicy.PublicKeyAuthenticationAllowed then
    Methods := MethodPublicKey;
  if FPolicy.PasswordAuthenticationAllowed then
  begin
    if Methods <> '' then
      Methods := Methods + ',';
    Methods := Methods + MethodPassword;
  end;
  Result := SshString(Methods);
end;

procedure TSshUserAuthenticator.SendFailure;
begin
  FTransport.Send(SshByte(MessageUserAuthenticationFailure) + MethodList + SshBoolean(False));
end;

procedure TSshUserAuthenticator.CountFailure;
begin
  Inc(FFailures);
  if FFailures >= MaximumFailures then
    raise ESshDisconnect.CreateWithReason(DisconnectNoMoreAuthenticationMethods,
      'too many authentication failures');
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
  Accepted := False;
  if (RequestedMethod = MethodPublicKey) and FPolicy.PublicKeyAuthenticationAllowed then
    Accepted := TryPublicKey(User, Service, Reader)
  else if (RequestedMethod = MethodPassword) and FPolicy.PasswordAuthenticationAllowed then
    Accepted := TryPassword(User, Reader)
  else if RequestedMethod = 'none' then
  begin
    SendFailure;
    Exit;
  end
  else
  begin
    SendFailure;
    CountFailure;
    Exit;
  end;
  if Accepted then
  begin
    FSucceeded := True;
    FUserName := User;
    FMethod := RequestedMethod;
    FTransport.Send(SshByte(MessageUserAuthenticationSuccess));
  end;
end;

{ Answers the request itself (PK_OK, or a failure) unless it succeeds. }
function TSshUserAuthenticator.TryPublicKey(const User, Service: string; var Reader: TSshReader): Boolean;
var
  Signed: Boolean;
  Algorithm, Blob, Signature, SignedData: string;
  Key: TSshPublicKey;
  Usable: Boolean;
begin
  Result := False;
  Signed := Reader.ReadBoolean;
  Algorithm := Reader.ReadString;
  Blob := Reader.ReadString;
  Usable := ParsePublicKeyBlob(Blob, Key) and SignatureAlgorithmFits(Key, Algorithm) and
    FPolicy.PublicKeyIsAuthorized(User, Blob);
  if not Signed then
  begin
    if Usable then
      FTransport.Send(SshByte(MessageUserAuthenticationPublicKeyOk) + SshString(Algorithm) + SshString(Blob))
    else
    begin
      FPolicy.Note('key ' + PublicKeyFingerprint(Blob) + ' refused for ' + User);
      SendFailure;
      CountFailure;
    end;
    Exit;
  end;
  Signature := Reader.ReadString;
  if Usable then
  begin
    SignedData := SshString(FTransport.SessionId) + SshByte(MessageUserAuthenticationRequest) + SshString(User) +
      SshString(Service) + SshString(MethodPublicKey) + SshBoolean(True) + SshString(Algorithm) + SshString(Blob);
    Result := VerifySshSignature(Key, Algorithm, SignedData, Signature);
  end;
  if Result then
    FPolicy.Note('accepted key ' + PublicKeyFingerprint(Blob) + ' (' + Algorithm + ') for ' + User)
  else
  begin
    FPolicy.Note('key ' + PublicKeyFingerprint(Blob) + ' refused for ' + User);
    SendFailure;
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
    SendFailure;
    CountFailure;
  end;
end;

end.
