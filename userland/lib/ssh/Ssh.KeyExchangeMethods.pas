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
  The key exchange methods, both sides:

    curve25519-sha256 (and @libssh.org)   RFC 8731
      Q_C, Q_S: X25519 public keys; K = the X25519 secret as an mpint;
      SHA-256.
    mlkem768x25519-sha256                 draft-ietf-sshm-mlkem-hybrid-kex
      C_INIT = ML-KEM-768 encapsulation key || X25519 public key
      S_REPLY = ML-KEM-768 ciphertext || X25519 public key
      K = SHA-256(ML-KEM secret || X25519 secret) as a string; SHA-256.

  Both use the ECDH messages 30 and 31 for the client's and server's
  values. The exchange hash is

    H = HASH(string V_C, string V_S, string I_C, string I_S,
             string K_S, string C_INIT, string S_REPLY, K)

  with K already encoded (mpint or string), and every key is
  HASH(K || H || letter || session id), lengthened by
  HASH(K || H || everything so far) (RFC 4253 section 7.2).

  The hybrid method keeps the exchange secret even from someone who
  records it now and has a quantum computer later, as long as ML-KEM
  holds, and from anyone today as long as X25519 does.
}
unit Ssh.KeyExchangeMethods;

{$mode objfpc}{$H+}

interface

uses
  Ssh.KeyExchange;

const
  KeyExchangeMlKem768X25519 = 'mlkem768x25519-sha256';

type
  TSshKeyExchangeMethod = (KeyExchangeMethodCurve25519, KeyExchangeMethodMlKem768X25519);

  { What the client keeps between its value and the server's. }
  TSshClientExchangeSecret = record
    Method: TSshKeyExchangeMethod;
    X25519: TSshEphemeralKey;
    MlKemDecapsulationKey: string;
  end;

function FindKeyExchangeMethod(const Name: string; out Method: TSshKeyExchangeMethod): Boolean;
{ The client's value (Q_C or C_INIT). }
function StartClientExchange(Method: TSshKeyExchangeMethod; out Secret: TSshClientExchangeSecret): string;
{ The server's answer to the client's value: its own value and K,
  encoded. False for a client value of the wrong size or a degenerate
  one. }
function AnswerClientExchange(Method: TSshKeyExchangeMethod; const ClientValue: string;
  out ServerValue, EncodedSecret: string): Boolean;
{ K from the server's value. False for a bad value. }
function FinishClientExchange(var Secret: TSshClientExchangeSecret; const ServerValue: string;
  out EncodedSecret: string): Boolean;
procedure WipeClientExchangeSecret(var Secret: TSshClientExchangeSecret);

function ExchangeHashOf(Method: TSshKeyExchangeMethod; const ClientVersion, ServerVersion, ClientInit,
  ServerInit, HostKeyBlob, ClientValue, ServerValue, EncodedSecret: string): string;
function DeriveExchangeKey(Method: TSshKeyExchangeMethod; const EncodedSecret, ExchangeHash, SessionId: string;
  Letter: Char; Size: Integer): string;

implementation

uses
  Crypto.Digests,
  Crypto.MlKem,
  Crypto.X25519,
  Ssh.Constants,
  Ssh.Wire;

function Sha256Of(const Data: string): string;
var
  Output: TDigestOutput;
begin
  if Data = '' then
    ComputeDigest(DigestSha256, nil, 0, Output)
  else
    ComputeDigest(DigestSha256, @Data[1], Length(Data), Output);
  Result := BytesToString(@Output[0], DigestSize(DigestSha256));
end;

function FindKeyExchangeMethod(const Name: string; out Method: TSshKeyExchangeMethod): Boolean;
begin
  Result := True;
  if (Name = KeyExchangeCurve25519) or (Name = KeyExchangeCurve25519LibSsh) then
    Method := KeyExchangeMethodCurve25519
  else if Name = KeyExchangeMlKem768X25519 then
    Method := KeyExchangeMethodMlKem768X25519
  else
  begin
    Method := KeyExchangeMethodCurve25519;
    Result := False;
  end;
end;

function StartClientExchange(Method: TSshKeyExchangeMethod; out Secret: TSshClientExchangeSecret): string;
var
  EncapsulationKey: string;
begin
  Secret := Default(TSshClientExchangeSecret);
  Secret.Method := Method;
  Secret.X25519 := NewEphemeralKey;
  if Method = KeyExchangeMethodCurve25519 then
    Exit(Secret.X25519.PublicKey);
  EncapsulationKey := '';
  SetLength(EncapsulationKey, MlKem768EncapsulationKeySize);
  SetLength(Secret.MlKemDecapsulationKey, MlKem768DecapsulationKeySize);
  MlKem768GenerateKeyPair(@EncapsulationKey[1], @Secret.MlKemDecapsulationKey[1]);
  Result := EncapsulationKey + Secret.X25519.PublicKey;
end;

{ SHA-256(ML-KEM secret || X25519 secret) as a string. }
function HybridSecret(var MlKemSecret, X25519Secret: string): string;
var
  Combined: string;
begin
  Combined := MlKemSecret + X25519Secret;
  Result := SshString(Sha256Of(Combined));
  WipeString(Combined);
  WipeString(MlKemSecret);
  WipeString(X25519Secret);
end;

function AnswerClientExchange(Method: TSshKeyExchangeMethod; const ClientValue: string;
  out ServerValue, EncodedSecret: string): Boolean;
var
  Ephemeral: TSshEphemeralKey;
  X25519Secret, MlKemSecret, Ciphertext, ClientX25519: string;
begin
  ServerValue := '';
  EncodedSecret := '';
  Result := False;
  Ephemeral := NewEphemeralKey;
  try
    if Method = KeyExchangeMethodCurve25519 then
    begin
      if not ComputeSharedSecret(Ephemeral, ClientValue, X25519Secret) then
        Exit;
      ServerValue := Ephemeral.PublicKey;
      EncodedSecret := SshMpint(X25519Secret);
      WipeString(X25519Secret);
      Exit(True);
    end;
    if Length(ClientValue) <> MlKem768EncapsulationKeySize + X25519KeySize then
      Exit;
    ClientX25519 := Copy(ClientValue, MlKem768EncapsulationKeySize + 1, X25519KeySize);
    if not ComputeSharedSecret(Ephemeral, ClientX25519, X25519Secret) then
      Exit;
    Ciphertext := '';
    MlKemSecret := '';
    SetLength(Ciphertext, MlKem768CiphertextSize);
    SetLength(MlKemSecret, MlKem768SharedSecretSize);
    if not MlKem768Encapsulate(@ClientValue[1], @Ciphertext[1], @MlKemSecret[1]) then
    begin
      WipeString(X25519Secret);
      Exit;
    end;
    ServerValue := Ciphertext + Ephemeral.PublicKey;
    EncodedSecret := HybridSecret(MlKemSecret, X25519Secret);
    Result := True;
  finally
    WipeEphemeralKey(Ephemeral);
  end;
end;

function FinishClientExchange(var Secret: TSshClientExchangeSecret; const ServerValue: string;
  out EncodedSecret: string): Boolean;
var
  X25519Secret, MlKemSecret, ServerX25519: string;
begin
  EncodedSecret := '';
  Result := False;
  if Secret.Method = KeyExchangeMethodCurve25519 then
  begin
    if not ComputeSharedSecret(Secret.X25519, ServerValue, X25519Secret) then
      Exit;
    EncodedSecret := SshMpint(X25519Secret);
    WipeString(X25519Secret);
    Exit(True);
  end;
  if Length(ServerValue) <> MlKem768CiphertextSize + X25519KeySize then
    Exit;
  ServerX25519 := Copy(ServerValue, MlKem768CiphertextSize + 1, X25519KeySize);
  if not ComputeSharedSecret(Secret.X25519, ServerX25519, X25519Secret) then
    Exit;
  MlKemSecret := '';
  SetLength(MlKemSecret, MlKem768SharedSecretSize);
  MlKem768Decapsulate(@Secret.MlKemDecapsulationKey[1], @ServerValue[1], @MlKemSecret[1]);
  EncodedSecret := HybridSecret(MlKemSecret, X25519Secret);
  Result := True;
end;

procedure WipeClientExchangeSecret(var Secret: TSshClientExchangeSecret);
begin
  WipeEphemeralKey(Secret.X25519);
  WipeString(Secret.MlKemDecapsulationKey);
end;

function ExchangeHashOf(Method: TSshKeyExchangeMethod; const ClientVersion, ServerVersion, ClientInit,
  ServerInit, HostKeyBlob, ClientValue, ServerValue, EncodedSecret: string): string;
begin
  { Both methods hash with SHA-256. }
  Result := Sha256Of(SshString(ClientVersion) + SshString(ServerVersion) + SshString(ClientInit) +
    SshString(ServerInit) + SshString(HostKeyBlob) + SshString(ClientValue) + SshString(ServerValue) +
    EncodedSecret);
end;

function DeriveExchangeKey(Method: TSshKeyExchangeMethod; const EncodedSecret, ExchangeHash, SessionId: string;
  Letter: Char; Size: Integer): string;
var
  Prefix: string;
begin
  Prefix := EncodedSecret + ExchangeHash;
  Result := Sha256Of(Prefix + Letter + SessionId);
  while Length(Result) < Size do
    Result := Result + Sha256Of(Prefix + Result);
  Result := Copy(Result, 1, Size);
  WipeString(Prefix);
end;

end.
