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
  curve25519-sha256 (RFC 8731): the server's half of the Diffie-Hellman
  exchange, the exchange hash H and the keys derived from it.

    H = SHA-256(string V_C, string V_S, string I_C, string I_S,
                string K_S, string Q_C, string Q_S, mpint K)

  V_C and V_S are the version lines without CR LF, I_C and I_S the
  KEXINIT payloads, K_S the host key, Q_C and Q_S the X25519 public
  keys and K the shared secret read as a big endian number. Each key is
  SHA-256(mpint K || H || letter || session id), lengthened by
  SHA-256(mpint K || H || everything so far) (RFC 4253 section 7.2).
}
unit Ssh.KeyExchange;

{$mode objfpc}{$H+}

interface

const
  Curve25519PublicKeySize = 32;
  { The letters of RFC 4253 section 7.2. }
  KeyLetterInitialValueClientToServer = 'A';
  KeyLetterInitialValueServerToClient = 'B';
  KeyLetterEncryptionClientToServer = 'C';
  KeyLetterEncryptionServerToClient = 'D';

type
  TSshEphemeralKey = record
    PrivateKey: string;
    PublicKey: string;
  end;

{ A new X25519 key pair for one exchange. }
function NewEphemeralKey: TSshEphemeralKey;
{ The X25519 shared secret (32 bytes); False when the peer's key is of
  small order (all-zero result) or not 32 bytes. }
function ComputeSharedSecret(const Ephemeral: TSshEphemeralKey; const PeerPublicKey: string;
  out SharedSecret: string): Boolean;
function ComputeExchangeHash(const ClientVersion, ServerVersion, ClientInit, ServerInit, HostKeyBlob,
  ClientPublicKey, ServerPublicKey, SharedSecret: string): string;
function DeriveKey(const SharedSecret, ExchangeHash, SessionId: string; Letter: Char; Size: Integer): string;
procedure WipeEphemeralKey(var Ephemeral: TSshEphemeralKey);

implementation

uses
  Crypto.Digests,
  Crypto.Random,
  Crypto.X25519,
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

function NewEphemeralKey: TSshEphemeralKey;
begin
  Result.PrivateKey := '';
  SetLength(Result.PrivateKey, X25519KeySize);
  RandomBytes(@Result.PrivateKey[1], X25519KeySize);
  Result.PublicKey := '';
  SetLength(Result.PublicKey, X25519KeySize);
  X25519PublicKey(@Result.PrivateKey[1], @Result.PublicKey[1]);
end;

function ComputeSharedSecret(const Ephemeral: TSshEphemeralKey; const PeerPublicKey: string;
  out SharedSecret: string): Boolean;
begin
  SharedSecret := '';
  if Length(PeerPublicKey) <> X25519KeySize then
    Exit(False);
  SetLength(SharedSecret, X25519KeySize);
  Result := X25519SharedSecret(@Ephemeral.PrivateKey[1], @PeerPublicKey[1], @SharedSecret[1]);
end;

function ComputeExchangeHash(const ClientVersion, ServerVersion, ClientInit, ServerInit, HostKeyBlob,
  ClientPublicKey, ServerPublicKey, SharedSecret: string): string;
begin
  Result := Sha256Of(SshString(ClientVersion) + SshString(ServerVersion) + SshString(ClientInit) +
    SshString(ServerInit) + SshString(HostKeyBlob) + SshString(ClientPublicKey) + SshString(ServerPublicKey) +
    SshMpint(SharedSecret));
end;

function DeriveKey(const SharedSecret, ExchangeHash, SessionId: string; Letter: Char; Size: Integer): string;
var
  Prefix: string;
begin
  Prefix := SshMpint(SharedSecret) + ExchangeHash;
  Result := Sha256Of(Prefix + Letter + SessionId);
  while Length(Result) < Size do
    Result := Result + Sha256Of(Prefix + Result);
  Result := Copy(Result, 1, Size);
  WipeString(Prefix);
end;

procedure WipeEphemeralKey(var Ephemeral: TSshEphemeralKey);
begin
  WipeString(Ephemeral.PrivateKey);
  Ephemeral.PublicKey := '';
end;

end.
