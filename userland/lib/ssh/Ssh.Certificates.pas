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
  OpenSSH certificates (PROTOCOL.certkeys): a public key signed by a
  certificate authority, with who it is for and when.

    string    "ssh-ed25519-cert-v01@openssh.com" (or ecdsa-sha2-nistp256-,
              ssh-rsa-)
    string    nonce
    ...       the key's own fields (ed25519: string key; ecdsa: string
              curve, string Q; rsa: mpint e, mpint n)
    uint64    serial
    uint32    type (1 user, 2 host)
    string    key id
    string    valid principals (strings packed in a string)
    uint64    valid after, uint64 valid before (Unix time)
    string    critical options, string extensions (name, data pairs)
    string    reserved
    string    signature key (the CA's public key)
    string    signature (by the CA, over everything before it)

  A user certificate logs in when its CA is trusted (TrustedUserCAKeys),
  it is a user certificate, it lists the user among its principals, now
  is within its validity, and every critical option is one understood
  here: force-command (the command that runs) and source-address (the
  addresses it may come from). Its extensions give permissions:
  permit-pty, permit-port-forwarding, permit-agent-forwarding,
  permit-X11-forwarding, permit-user-rc; without one, that is not
  allowed.
}
unit Ssh.Certificates;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Ssh.PublicKeys;

const
  CertificateEd25519 = 'ssh-ed25519-cert-v01@openssh.com';
  CertificateEcdsaP256 = 'ecdsa-sha2-nistp256-cert-v01@openssh.com';
  CertificateRsa = 'ssh-rsa-cert-v01@openssh.com';
  CertificateTypeUser = 1;
  CertificateTypeHost = 2;

type
  TSshCertificateField = record
    Name: string;
    Data: string;
  end;
  TSshCertificateFields = array of TSshCertificateField;

  TSshCertificate = record
    Blob: string;
    KeyType: string;
    { The certified key, as a plain public key (its blob rebuilt). }
    Key: TSshPublicKey;
    Serial: QWord;
    CertificateType: LongWord;
    KeyId: string;
    Principals: TStringArray;
    ValidAfter: QWord;
    ValidBefore: QWord;
    CriticalOptions: TSshCertificateFields;
    Extensions: TSshCertificateFields;
    SignatureKey: string;
    Signature: string;
    { What the CA signed. }
    SignedData: string;
  end;

  { What a valid user certificate allows. }
  TSshCertificatePermissions = record
    ForceCommand: string;
    SourceAddress: string;
    PermitPty: Boolean;
    PermitPortForwarding: Boolean;
    PermitAgentForwarding: Boolean;
    PermitX11Forwarding: Boolean;
    PermitUserRc: Boolean;
  end;

function IsCertificateKeyType(const Name: string): Boolean;
function ParseCertificate(const Blob: string; out Certificate: TSshCertificate): Boolean;
{ The CA's signature: right, by a plain key (not a certificate), with an
  algorithm that fits it. }
function CertificateSignatureIsRight(const Certificate: TSshCertificate): Boolean;
{ A user certificate for User at Now (Unix time), its critical options
  understood; Problem says why not. }
function CheckUserCertificate(const Certificate: TSshCertificate; const User: string; Now: QWord;
  out Permissions: TSshCertificatePermissions; out Problem: string): Boolean;
{ Signature algorithm names for certificate keys in a publickey request
  (rsa-sha2-512-cert-v01@openssh.com, ...) to the plain algorithm the
  signature itself carries; '' for none. }
function PlainSignatureAlgorithm(const CertificateKeyType, Algorithm: string): string;
{ The fields packed in a critical options or extensions string. }
function ParseCertificateFields(const Encoded: string; out Fields: TSshCertificateFields): Boolean;

implementation

uses
  Ssh.Constants,
  Ssh.Wire;

function IsCertificateKeyType(const Name: string): Boolean;
begin
  Result := (Name = CertificateEd25519) or (Name = CertificateEcdsaP256) or (Name = CertificateRsa);
end;

function ParseCertificateFields(const Encoded: string; out Fields: TSshCertificateFields): Boolean;
var
  Reader: TSshReader;
  Previous: string;
begin
  Fields := nil;
  Previous := '';
  try
    Reader.Start(Encoded);
    while not Reader.AtEnd do
    begin
      SetLength(Fields, Length(Fields) + 1);
      Fields[High(Fields)].Name := Reader.ReadString;
      Fields[High(Fields)].Data := Reader.ReadString;
      { Sorted, each once (PROTOCOL.certkeys). }
      if (Length(Fields) > 1) and (Fields[High(Fields)].Name <= Previous) then
        Exit(False);
      Previous := Fields[High(Fields)].Name;
    end;
    Result := True;
  except
    on ESshProtocolError do
      Result := False;
  end;
end;

function ParsePrincipals(const Encoded: string; out Principals: TStringArray): Boolean;
var
  Reader: TSshReader;
begin
  Principals := nil;
  try
    Reader.Start(Encoded);
    while not Reader.AtEnd do
    begin
      SetLength(Principals, Length(Principals) + 1);
      Principals[High(Principals)] := Reader.ReadString;
    end;
    Result := True;
  except
    on ESshProtocolError do
      Result := False;
  end;
end;

function ParseCertificate(const Blob: string; out Certificate: TSshCertificate): Boolean;
var
  Reader: TSshReader;
  PlainBlob, Curve, Point, Exponent, Modulus, KeyBytes: string;
  SignedLength: Integer;
begin
  Certificate := Default(TSshCertificate);
  Certificate.Blob := Blob;
  Result := False;
  try
    Reader.Start(Blob);
    Certificate.KeyType := Reader.ReadString;
    Reader.ReadString;
    if Certificate.KeyType = CertificateEd25519 then
    begin
      KeyBytes := Reader.ReadString;
      PlainBlob := SshString(HostKeyEd25519) + SshString(KeyBytes);
    end
    else if Certificate.KeyType = CertificateEcdsaP256 then
    begin
      Curve := Reader.ReadString;
      Point := Reader.ReadString;
      PlainBlob := SshString(HostKeyEcdsaP256) + SshString(Curve) + SshString(Point);
    end
    else if Certificate.KeyType = CertificateRsa then
    begin
      Exponent := Reader.ReadMpint;
      Modulus := Reader.ReadMpint;
      PlainBlob := SshString(PublicKeyRsa) + SshMpint(Exponent) + SshMpint(Modulus);
    end
    else
      Exit;
    if not ParsePublicKeyBlob(PlainBlob, Certificate.Key) then
      Exit;
    Certificate.Serial := Reader.ReadUInt64;
    Certificate.CertificateType := Reader.ReadUInt32;
    Certificate.KeyId := Reader.ReadString;
    if not ParsePrincipals(Reader.ReadString, Certificate.Principals) then
      Exit;
    Certificate.ValidAfter := Reader.ReadUInt64;
    Certificate.ValidBefore := Reader.ReadUInt64;
    if not ParseCertificateFields(Reader.ReadString, Certificate.CriticalOptions) or
      not ParseCertificateFields(Reader.ReadString, Certificate.Extensions) then
      Exit;
    Reader.ReadString;
    Certificate.SignatureKey := Reader.ReadString;
    SignedLength := Length(Blob) - Reader.Remaining;
    Certificate.Signature := Reader.ReadString;
    if not Reader.AtEnd then
      Exit;
    Certificate.SignedData := Copy(Blob, 1, SignedLength);
    Result := True;
  except
    on ESshProtocolError do
      Result := False;
  end;
end;

function CertificateSignatureIsRight(const Certificate: TSshCertificate): Boolean;
var
  Authority: TSshPublicKey;
  Reader: TSshReader;
  Algorithm: string;
begin
  Result := False;
  if not ParsePublicKeyBlob(Certificate.SignatureKey, Authority) then
    Exit;
  try
    Reader.Start(Certificate.Signature);
    Algorithm := Reader.ReadString;
  except
    on ESshProtocolError do
      Exit;
  end;
  Result := VerifySshSignature(Authority, Algorithm, Certificate.SignedData, Certificate.Signature);
end;

function HasField(const Fields: TSshCertificateFields; const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Fields) do
    if Fields[Index].Name = Name then
      Exit(True);
  Result := False;
end;

{ A critical option's data is a string holding a string. }
function OptionValue(const Data: string; out Value: string): Boolean;
var
  Reader: TSshReader;
begin
  Value := '';
  try
    Reader.Start(Data);
    Value := Reader.ReadString;
    Result := Reader.AtEnd;
  except
    on ESshProtocolError do
      Result := False;
  end;
end;

function CheckUserCertificate(const Certificate: TSshCertificate; const User: string; Now: QWord;
  out Permissions: TSshCertificatePermissions; out Problem: string): Boolean;
var
  Index: Integer;
  Value: string;
begin
  Permissions := Default(TSshCertificatePermissions);
  Problem := '';
  Result := False;
  if Certificate.CertificateType <> CertificateTypeUser then
  begin
    Problem := 'not a user certificate';
    Exit;
  end;
  if not NameListContains(Certificate.Principals, User) then
  begin
    Problem := 'the certificate does not list ' + User;
    Exit;
  end;
  if (Now < Certificate.ValidAfter) or (Now >= Certificate.ValidBefore) then
  begin
    Problem := 'the certificate is not valid now';
    Exit;
  end;
  for Index := 0 to High(Certificate.CriticalOptions) do
  begin
    if not OptionValue(Certificate.CriticalOptions[Index].Data, Value) then
    begin
      Problem := 'malformed critical option ' + Certificate.CriticalOptions[Index].Name;
      Exit;
    end;
    if Certificate.CriticalOptions[Index].Name = 'force-command' then
      Permissions.ForceCommand := Value
    else if Certificate.CriticalOptions[Index].Name = 'source-address' then
      Permissions.SourceAddress := Value
    else
    begin
      Problem := 'unknown critical option ' + Certificate.CriticalOptions[Index].Name;
      Exit;
    end;
  end;
  Permissions.PermitPty := HasField(Certificate.Extensions, 'permit-pty');
  Permissions.PermitPortForwarding := HasField(Certificate.Extensions, 'permit-port-forwarding');
  Permissions.PermitAgentForwarding := HasField(Certificate.Extensions, 'permit-agent-forwarding');
  Permissions.PermitX11Forwarding := HasField(Certificate.Extensions, 'permit-X11-forwarding');
  Permissions.PermitUserRc := HasField(Certificate.Extensions, 'permit-user-rc');
  Result := True;
end;

function PlainSignatureAlgorithm(const CertificateKeyType, Algorithm: string): string;
begin
  Result := '';
  if CertificateKeyType = CertificateEd25519 then
  begin
    if Algorithm = CertificateEd25519 then
      Result := HostKeyEd25519;
  end
  else if CertificateKeyType = CertificateEcdsaP256 then
  begin
    if Algorithm = CertificateEcdsaP256 then
      Result := HostKeyEcdsaP256;
  end
  else if CertificateKeyType = CertificateRsa then
  begin
    if Algorithm = 'rsa-sha2-256-cert-v01@openssh.com' then
      Result := SignatureRsaSha256
    else if Algorithm = 'rsa-sha2-512-cert-v01@openssh.com' then
      Result := SignatureRsaSha512;
  end;
end;

end.
