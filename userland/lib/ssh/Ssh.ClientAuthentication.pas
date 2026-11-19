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
  User authentication, the client's side (RFC 4252): asks for the
  ssh-userauth service, learns the methods with "none", then tries what
  the server offers in turn:

    publickey               each key (signed at once, no query first);
                            as publickey-hostbound-v00@openssh.com,
                            bound to the server's host key, when the
                            server's EXT_INFO offers it
    keyboard-interactive    the server's prompts (RFC 4256), up to three
                            rounds
    password                up to three times

  The program supplies the keys, the password and the answers to
  prompts (events), and reads Succeeded or Failed.
}
unit Ssh.ClientAuthentication;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.Transport,
  Ssh.ClientTransport,
  Ssh.ClientIdentities;

type
  TSshPasswordPrompt = function(out Password: string): Boolean of object;
  TSshInteractivePrompt = function(const Name, Instruction, Prompt: string; Echo: Boolean;
    out Response: string): Boolean of object;
  TSshAuthenticationNote = procedure(const Text: string) of object;

  TSshClientAuthenticator = class
  private
    FTransport: TSshClientTransport;
    FUser: string;
    FIdentities: TSshClientIdentityArray;
    FNextIdentity: Integer;
    FServerMethods: TStringArray;
    FPasswordAttempts: Integer;
    FInteractiveAttempts: Integer;
    FInInteractive: Boolean;
    FServiceAccepted: Boolean;
    FSucceeded: Boolean;
    FFailed: Boolean;
    FMethod: string;
    FAllowPublicKey: Boolean;
    FAllowPassword: Boolean;
    FAllowKeyboardInteractive: Boolean;
    FOnPassword: TSshPasswordPrompt;
    FOnPrompt: TSshInteractivePrompt;
    FOnBanner: TSshAuthenticationNote;
    FOnNote: TSshAuthenticationNote;
    procedure Note(const Text: string);
    procedure SendRequest(const Method, Rest: string);
    procedure TryNextMethod;
    function TryNextKey: Boolean;
    function TryPassword: Boolean;
    function TryKeyboardInteractive: Boolean;
    procedure HandleFailure(const Payload: string);
    procedure HandleInfoRequest(const Payload: string);
    function ServerOffers(const Method: string): Boolean;
  public
    constructor Create(Transport: TSshClientTransport; const User: string);
    { The keys are not owned. }
    procedure AddIdentity(Identity: TSshClientIdentity);
    { Asks for the service; call once the first key exchange is done. }
    procedure Start;
    { Handles the user authentication messages; False for others. }
    function HandleMessage(const Message: TSshReceivedMessage): Boolean;
    property Succeeded: Boolean read FSucceeded;
    property Failed: Boolean read FFailed;
    property Method: string read FMethod;
    property AllowPublicKey: Boolean read FAllowPublicKey write FAllowPublicKey;
    property AllowPassword: Boolean read FAllowPassword write FAllowPassword;
    property AllowKeyboardInteractive: Boolean read FAllowKeyboardInteractive write FAllowKeyboardInteractive;
    property OnPassword: TSshPasswordPrompt read FOnPassword write FOnPassword;
    property OnPrompt: TSshInteractivePrompt read FOnPrompt write FOnPrompt;
    property OnBanner: TSshAuthenticationNote read FOnBanner write FOnBanner;
    property OnNote: TSshAuthenticationNote read FOnNote write FOnNote;
  end;

implementation

uses
  Ssh.Constants,
  Ssh.Wire,
  Ssh.PublicKeys,
  Ssh.UserAuthentication;

const
  MaximumPasswordAttempts = 3;
  MaximumInteractiveAttempts = 3;

constructor TSshClientAuthenticator.Create(Transport: TSshClientTransport; const User: string);
begin
  inherited Create;
  FTransport := Transport;
  FUser := User;
  FAllowPublicKey := True;
  FAllowPassword := True;
  FAllowKeyboardInteractive := True;
end;

procedure TSshClientAuthenticator.AddIdentity(Identity: TSshClientIdentity);
begin
  SetLength(FIdentities, Length(FIdentities) + 1);
  FIdentities[High(FIdentities)] := Identity;
end;

procedure TSshClientAuthenticator.Note(const Text: string);
begin
  if Assigned(FOnNote) then
    FOnNote(Text);
end;

procedure TSshClientAuthenticator.Start;
begin
  FTransport.Send(SshByte(MessageServiceRequest) + SshString(ServiceUserAuthentication));
end;

procedure TSshClientAuthenticator.SendRequest(const Method, Rest: string);
begin
  FMethod := Method;
  FTransport.Send(SshByte(MessageUserAuthenticationRequest) + SshString(FUser) + SshString(ServiceConnection) +
    SshString(Method) + Rest);
end;

function TSshClientAuthenticator.ServerOffers(const Method: string): Boolean;
begin
  Result := NameListContains(FServerMethods, Method);
end;

function TSshClientAuthenticator.HandleMessage(const Message: TSshReceivedMessage): Boolean;
var
  Reader: TSshReader;
begin
  Result := True;
  case Ord(Message.Payload[1]) of
    MessageServiceAccept:
      begin
        if FServiceAccepted then
          raise ESshProtocolError.Create('SERVICE_ACCEPT twice');
        FServiceAccepted := True;
        SendRequest('none', '');
      end;
    MessageUserAuthenticationFailure:
      HandleFailure(Message.Payload);
    MessageUserAuthenticationSuccess:
      FSucceeded := True;
    MessageUserAuthenticationBanner:
      begin
        Reader.Start(Message.Payload);
        Reader.ReadByte;
        if Assigned(FOnBanner) then
          FOnBanner(Reader.ReadString);
      end;
    MessageUserAuthenticationInfoRequest:
      if FInInteractive then
        HandleInfoRequest(Message.Payload)
      else
        raise ESshProtocolError.Create('unexpected message 60');
  else
    Result := False;
  end;
end;

procedure TSshClientAuthenticator.HandleFailure(const Payload: string);
var
  Reader: TSshReader;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  FServerMethods := Reader.ReadNameList;
  FInInteractive := False;
  if FMethod <> 'none' then
    Note(FMethod + ' refused');
  TryNextMethod;
end;

procedure TSshClientAuthenticator.TryNextMethod;
begin
  if FAllowPublicKey and ServerOffers(MethodPublicKey) and TryNextKey then
    Exit;
  if FAllowKeyboardInteractive and ServerOffers(MethodKeyboardInteractive) and TryKeyboardInteractive then
    Exit;
  if FAllowPassword and ServerOffers(MethodPassword) and TryPassword then
    Exit;
  FFailed := True;
end;

function TSshClientAuthenticator.TryNextKey: Boolean;
var
  Identity: TSshClientIdentity;
  Algorithm, Blob, KeyMethod, HostKey, SignedData, Signature: string;
begin
  while FNextIdentity < Length(FIdentities) do
  begin
    Identity := FIdentities[FNextIdentity];
    Inc(FNextIdentity);
    Blob := Identity.PublicBlob;
    Algorithm := ChooseSignatureAlgorithm(Blob, FTransport.ServerSignatureAlgorithms);
    if Algorithm = '' then
      Continue;
    if FTransport.ServerTakesHostBound then
    begin
      KeyMethod := MethodPublicKeyHostBound;
      HostKey := SshString(FTransport.HostKeyBlob);
    end
    else
    begin
      KeyMethod := MethodPublicKey;
      HostKey := '';
    end;
    SignedData := SshString(FTransport.SessionId) + SshByte(MessageUserAuthenticationRequest) + SshString(FUser) +
      SshString(ServiceConnection) + SshString(KeyMethod) + SshBoolean(True) + SshString(Algorithm) +
      SshString(Blob) + HostKey;
    Signature := Identity.Sign(SignedData, Algorithm);
    if Signature = '' then
    begin
      Note('cannot sign with ' + Identity.Description);
      Continue;
    end;
    Note('offering ' + Algorithm + ' key ' + PublicKeyFingerprint(Blob) + ' (' + Identity.Description + ')');
    SendRequest(KeyMethod, SshBoolean(True) + SshString(Algorithm) + SshString(Blob) + HostKey + SshString(Signature));
    Exit(True);
  end;
  Result := False;
end;

function TSshClientAuthenticator.TryPassword: Boolean;
var
  Password: string;
begin
  Result := False;
  if (FPasswordAttempts >= MaximumPasswordAttempts) or not Assigned(FOnPassword) then
    Exit;
  Inc(FPasswordAttempts);
  if not FOnPassword(Password) then
  begin
    FPasswordAttempts := MaximumPasswordAttempts;
    Exit;
  end;
  SendRequest(MethodPassword, SshBoolean(False) + SshString(Password));
  WipeString(Password);
  Result := True;
end;

function TSshClientAuthenticator.TryKeyboardInteractive: Boolean;
begin
  Result := False;
  if (FInteractiveAttempts >= MaximumInteractiveAttempts) or not Assigned(FOnPrompt) then
    Exit;
  Inc(FInteractiveAttempts);
  FInInteractive := True;
  SendRequest(MethodKeyboardInteractive, SshString('') + SshString(''));
  Result := True;
end;

procedure TSshClientAuthenticator.HandleInfoRequest(const Payload: string);
var
  Reader: TSshReader;
  Name, Instruction, Prompt, Response, Responses: string;
  Echo: Boolean;
  Count, Index: LongWord;
begin
  Reader.Start(Payload);
  Reader.ReadByte;
  Name := Reader.ReadString;
  Instruction := Reader.ReadString;
  Reader.ReadString;
  Count := Reader.ReadUInt32;
  if Count > 32 then
    raise ESshProtocolError.Create('too many prompts');
  Responses := '';
  Index := 0;
  while Index < Count do
  begin
    Prompt := Reader.ReadString;
    Echo := Reader.ReadBoolean;
    if not FOnPrompt(Name, Instruction, Prompt, Echo, Response) then
    begin
      FInteractiveAttempts := MaximumInteractiveAttempts;
      Response := '';
    end;
    Responses := Responses + SshString(Response);
    WipeString(Response);
    Inc(Index);
  end;
  FTransport.Send(SshByte(MessageUserAuthenticationInfoResponse) + SshUInt32(Count) + Responses);
  WipeString(Responses);
end;

end.
