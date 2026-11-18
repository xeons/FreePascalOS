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
  Other parties' public keys: reading SSH public key blobs, checking
  signatures made with them, the lines of an authorized_keys file and
  key fingerprints.

  Keys: ssh-ed25519, ecdsa-sha2-nistp256 and ssh-rsa. Signatures:
  ssh-ed25519, ecdsa-sha2-nistp256 (SHA-256) and, for RSA keys,
  rsa-sha2-256 and rsa-sha2-512 (RFC 8332); the old ssh-rsa signature
  (SHA-1) is refused, as OpenSSH 8.8 and later refuse it.
}
unit Ssh.PublicKeys;

{$mode objfpc}{$H+}

interface

type
  TSshPublicKeyKind = (PublicKeyKindEd25519, PublicKeyKindEcdsaP256, PublicKeyKindRsa);

  TSshPublicKey = record
    Kind: TSshPublicKeyKind;
    Blob: string;
    { Ed25519: the 32 bytes; ECDSA: the point Q; RSA: n. }
    KeyData: string;
    { RSA: e. }
    RsaExponent: string;
  end;

{ False for a malformed blob or a kind of key not handled here. }
function ParsePublicKeyBlob(const Blob: string; out Key: TSshPublicKey): Boolean;
{ True when signatures named Algorithm can be made with keys of Key's
  kind (rsa-sha2-256 and rsa-sha2-512 for ssh-rsa keys). }
function SignatureAlgorithmFits(const Key: TSshPublicKey; const Algorithm: string): Boolean;
{ Checks Signature (algorithm name and signature, in SSH form) of Data;
  the name in it must be Algorithm. }
function VerifySshSignature(const Key: TSshPublicKey; const Algorithm, Data, Signature: string): Boolean;
{ A line of authorized_keys: the key's blob. False for blank lines,
  comments, unknown key types and malformed keys. HasOptions tells
  whether options came before the key (command=, from=, ...). }
function ParseAuthorizedKeyLine(const Line: string; out Blob: string; out HasOptions: Boolean): Boolean;
{ "SHA256:" and the unpadded base64 of the blob's SHA-256, as
  ssh-keygen -l prints it. }
function PublicKeyFingerprint(const Blob: string): string;
{ The OpenSSH one line form: "TYPE BASE64 COMMENT". }
function PublicKeyLine(const Blob, Comment: string): string;

implementation

uses
  SysUtils,
  Crypto.Digests,
  Crypto.Rsa,
  Crypto.EllipticCurves,
  Crypto.Ecdsa,
  Crypto.Ed25519,
  Ssh.Constants,
  Ssh.Wire,
  Ssh.Base64;

function ParsePublicKeyBlob(const Blob: string; out Key: TSshPublicKey): Boolean;
var
  Reader: TSshReader;
  KeyType: string;
begin
  Key := Default(TSshPublicKey);
  Key.Blob := Blob;
  Result := False;
  try
    Reader.Start(Blob);
    KeyType := Reader.ReadString;
    if KeyType = HostKeyEd25519 then
    begin
      Key.Kind := PublicKeyKindEd25519;
      Key.KeyData := Reader.ReadString;
      Result := Length(Key.KeyData) = Ed25519PublicKeySize;
    end
    else if KeyType = HostKeyEcdsaP256 then
    begin
      Key.Kind := PublicKeyKindEcdsaP256;
      if Reader.ReadString <> CurveNameP256 then
        Exit;
      Key.KeyData := Reader.ReadString;
      Result := (Length(Key.KeyData) = 65) and (Key.KeyData[1] = #4);
    end
    else if KeyType = PublicKeyRsa then
    begin
      Key.Kind := PublicKeyKindRsa;
      Key.RsaExponent := Reader.ReadMpint;
      Key.KeyData := Reader.ReadMpint;
      Result := (Key.RsaExponent <> '') and (Key.KeyData <> '');
    end;
    if Result and not Reader.AtEnd then
      Result := False;
  except
    on ESshProtocolError do
      Result := False;
  end;
end;

function SignatureAlgorithmFits(const Key: TSshPublicKey; const Algorithm: string): Boolean;
begin
  case Key.Kind of
    PublicKeyKindEd25519: Result := Algorithm = HostKeyEd25519;
    PublicKeyKindEcdsaP256: Result := Algorithm = HostKeyEcdsaP256;
    PublicKeyKindRsa: Result := (Algorithm = SignatureRsaSha256) or (Algorithm = SignatureRsaSha512);
  else
    Result := False;
  end;
end;

function DigestOf(Algorithm: TDigestAlgorithm; const Data: string): TDigestOutput;
begin
  if Data = '' then
    ComputeDigest(Algorithm, nil, 0, Result)
  else
    ComputeDigest(Algorithm, @Data[1], Length(Data), Result);
end;

function DataPointer(const Data: string): PByte;
begin
  if Data = '' then
    Result := nil
  else
    Result := @Data[1];
end;

function VerifyEd25519(const Key: TSshPublicKey; const Data, SignatureBytes: string): Boolean;
begin
  Result := (Length(SignatureBytes) = Ed25519SignatureSize) and
    Ed25519Verify(@Key.KeyData[1], DataPointer(Data), Length(Data), @SignatureBytes[1]);
end;

function VerifyEcdsa(const Key: TSshPublicKey; const Data, SignatureBytes: string): Boolean;
var
  Reader: TSshReader;
  R, S: string;
  Digest: TDigestOutput;
begin
  Reader.Start(SignatureBytes);
  R := Reader.ReadMpint;
  S := Reader.ReadMpint;
  if (R = '') or (S = '') or not Reader.AtEnd then
    Exit(False);
  Digest := DigestOf(DigestSha256, Data);
  Result := VerifyEcdsaSignature(CurveP256, @Key.KeyData[1], Length(Key.KeyData), @Digest[0],
    DigestSize(DigestSha256), @R[1], Length(R), @S[1], Length(S));
end;

function VerifyRsa(const Key: TSshPublicKey; Algorithm: TDigestAlgorithm; const Data, SignatureBytes: string): Boolean;
var
  RsaKey: TRsaPublicKey;
  Digest: TDigestOutput;
  Padded: string;
begin
  Result := False;
  if not PrepareRsaPublicKey(RsaKey, @Key.KeyData[1], Length(Key.KeyData), @Key.RsaExponent[1],
    Length(Key.RsaExponent)) then
    Exit;
  { Some signers leave out leading zero bytes. }
  if (SignatureBytes = '') or (Length(SignatureBytes) > RsaKey.ModulusBytes) then
    Exit;
  Padded := StringOfChar(#0, RsaKey.ModulusBytes - Length(SignatureBytes)) + SignatureBytes;
  Digest := DigestOf(Algorithm, Data);
  Result := VerifyRsaPkcs1Signature(RsaKey, Algorithm, @Digest[0], @Padded[1], Length(Padded));
end;

function VerifySshSignature(const Key: TSshPublicKey; const Algorithm, Data, Signature: string): Boolean;
var
  Reader: TSshReader;
  SignatureAlgorithm: string;
  SignatureBytes: string;
begin
  Result := False;
  if not SignatureAlgorithmFits(Key, Algorithm) then
    Exit;
  try
    Reader.Start(Signature);
    SignatureAlgorithm := Reader.ReadString;
    SignatureBytes := Reader.ReadString;
    if (SignatureAlgorithm <> Algorithm) or not Reader.AtEnd then
      Exit;
    case Key.Kind of
      PublicKeyKindEd25519: Result := VerifyEd25519(Key, Data, SignatureBytes);
      PublicKeyKindEcdsaP256: Result := VerifyEcdsa(Key, Data, SignatureBytes);
      PublicKeyKindRsa:
        if Algorithm = SignatureRsaSha512 then
          Result := VerifyRsa(Key, DigestSha512, Data, SignatureBytes)
        else
          Result := VerifyRsa(Key, DigestSha256, Data, SignatureBytes);
    end;
  except
    on ESshProtocolError do
      Result := False;
  end;
end;

function IsKnownKeyType(const Name: string): Boolean;
begin
  Result := (Name = HostKeyEd25519) or (Name = HostKeyEcdsaP256) or (Name = PublicKeyRsa);
end;

{ The next field of Line from Position: runs of anything but blanks,
  where double quotes keep blanks (option values). }
function NextField(const Line: string; var Position: Integer): string;
var
  Start: Integer;
  Quoted: Boolean;
begin
  while (Position <= Length(Line)) and (Line[Position] in [' ', #9]) do
    Inc(Position);
  Start := Position;
  Quoted := False;
  while Position <= Length(Line) do
  begin
    if Line[Position] = '"' then
      Quoted := not Quoted
    else if (Line[Position] in [' ', #9]) and not Quoted then
      Break;
    Inc(Position);
  end;
  Result := Copy(Line, Start, Position - Start);
end;

function ParseAuthorizedKeyLine(const Line: string; out Blob: string; out HasOptions: Boolean): Boolean;
var
  Position: Integer;
  First, KeyType, Encoded: string;
  Key: TSshPublicKey;
begin
  Blob := '';
  HasOptions := False;
  Result := False;
  Position := 1;
  First := NextField(Line, Position);
  if (First = '') or (First[1] = '#') then
    Exit;
  if IsKnownKeyType(First) then
    KeyType := First
  else
  begin
    { Options first, then the key. }
    HasOptions := True;
    KeyType := NextField(Line, Position);
    if not IsKnownKeyType(KeyType) then
      Exit;
  end;
  Encoded := NextField(Line, Position);
  if not DecodeBase64(Encoded, Blob) then
    Exit;
  if not ParsePublicKeyBlob(Blob, Key) then
    Exit;
  { The type written must be the blob's own. }
  Result := Copy(Blob, 5, Length(KeyType)) = KeyType;
end;

function PublicKeyFingerprint(const Blob: string): string;
var
  Digest: TDigestOutput;
  Encoded: string;
begin
  Digest := DigestOf(DigestSha256, Blob);
  Encoded := EncodeBase64(BytesToString(@Digest[0], DigestSize(DigestSha256)));
  while (Encoded <> '') and (Encoded[Length(Encoded)] = '=') do
    Delete(Encoded, Length(Encoded), 1);
  Result := 'SHA256:' + Encoded;
end;

function PublicKeyLine(const Blob, Comment: string): string;
var
  Reader: TSshReader;
begin
  Reader.Start(Blob);
  Result := Reader.ReadString + ' ' + EncodeBase64(Blob);
  if Comment <> '' then
    Result := Result + ' ' + Comment;
end;

end.
