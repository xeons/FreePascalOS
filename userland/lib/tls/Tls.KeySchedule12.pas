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
  The secrets of a TLS 1.2 connection (RFC 5246 sections 5, 6.3, 7.4.9,
  8.1), always with the extended master secret (RFC 7627):

    PRF(secret, label, seed) = P_hash(secret, label + seed), P_hash the
      HMAC expansion with the suite's hash (SHA-256 or SHA-384)
    master_secret = PRF(pre_master_secret, "extended master secret",
      session_hash)[0..47], session_hash the hash of the handshake up
      to and including ClientKeyExchange
    key_block = PRF(master_secret, "key expansion", server_random +
      client_random): the client and server write keys, then their IVs
      (4 bytes for AES-GCM, 12 for ChaCha20-Poly1305; AEAD suites have
      no MAC keys)
    verify_data = PRF(master_secret, "client finished" / "server
      finished", Hash(handshake messages))[0..11]
}
unit Tls.KeySchedule12;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Crypto.Digests,
  Tls.CipherSuites;

const
  Tls12MasterSecretLength = 48;
  Tls12MaximumIvLength = 12;

type
  TTls12Keys = record
    ClientKey, ServerKey: array[0..31] of Byte;
    ClientIv, ServerIv: array[0..Tls12MaximumIvLength - 1] of Byte;
    KeyLength, IvLength: Integer;
  end;

{ P_hash(Secret, Label + Seed) into Output (any length). }
procedure Tls12Prf(Hash: TDigestAlgorithm; Secret: PByte; SecretLength: Integer; const Label_: string; Seed: PByte;
  SeedLength: Integer; Output: PByte; OutputLength: Integer);
procedure DeriveExtendedMasterSecret(Hash: TDigestAlgorithm; PreMasterSecret: PByte; PreMasterLength: Integer;
  SessionHash: PByte; MasterSecret: PByte);
{ The IV length of the suite's record protection in TLS 1.2. }
function Tls12IvLength(constref Suite: TCipherSuiteInfo): Integer;
procedure DeriveTls12Keys(constref Suite: TCipherSuiteInfo; MasterSecret: PByte; ClientRandom, ServerRandom: PByte;
  out Keys: TTls12Keys);
{ 12 bytes of verify data; FromClient picks the label. }
procedure ComputeTls12VerifyData(Hash: TDigestAlgorithm; MasterSecret: PByte; FromClient: Boolean;
  TranscriptHash: PByte; VerifyData: PByte);

implementation

uses
  Crypto.Bits,
  Crypto.Hmac,
  Tls.Constants;

procedure Tls12Prf(Hash: TDigestAlgorithm; Secret: PByte; SecretLength: Integer; const Label_: string; Seed: PByte;
  SeedLength: Integer; Output: PByte; OutputLength: Integer);
var
  LabelSeed: array of Byte;
  A, NextA, Block: TDigestOutput;
  Context: THmacContext;
  HashLength, Take, Done: Integer;
begin
  LabelSeed := nil;
  SetLength(LabelSeed, Length(Label_) + SeedLength);
  if Length(Label_) > 0 then
    Move(Label_[1], LabelSeed[0], Length(Label_));
  if SeedLength > 0 then
    Move(Seed^, LabelSeed[Length(Label_)], SeedLength);
  HashLength := DigestSize(Hash);
  { A(1) = HMAC(secret, label + seed) }
  ComputeHmac(Hash, Secret, QWord(SecretLength), @LabelSeed[0], QWord(Length(LabelSeed)), A);
  Done := 0;
  while Done < OutputLength do
  begin
    { HMAC(secret, A(i) + label + seed) }
    BeginHmac(Context, Hash, Secret, QWord(SecretLength));
    UpdateHmac(Context, @A[0], QWord(HashLength));
    UpdateHmac(Context, @LabelSeed[0], QWord(Length(LabelSeed)));
    FinishHmac(Context, Block);
    Take := OutputLength - Done;
    if Take > HashLength then
      Take := HashLength;
    Move(Block[0], Output[Done], Take);
    Done := Done + Take;
    { A(i + 1) = HMAC(secret, A(i)) }
    ComputeHmac(Hash, Secret, QWord(SecretLength), @A[0], QWord(HashLength), NextA);
    A := NextA;
  end;
  WipeMemory(@NextA[0], SizeOf(NextA));
  WipeMemory(@A[0], SizeOf(A));
  WipeMemory(@Block[0], SizeOf(Block));
  WipeMemory(@LabelSeed[0], Length(LabelSeed));
end;

procedure DeriveExtendedMasterSecret(Hash: TDigestAlgorithm; PreMasterSecret: PByte; PreMasterLength: Integer;
  SessionHash: PByte; MasterSecret: PByte);
begin
  Tls12Prf(Hash, PreMasterSecret, PreMasterLength, 'extended master secret', SessionHash, DigestSize(Hash),
    MasterSecret, Tls12MasterSecretLength);
end;

function Tls12IvLength(constref Suite: TCipherSuiteInfo): Integer;
begin
  if Suite.Aead = AeadChaCha20Poly1305 then
    Result := 12
  else
    Result := 4;
end;

procedure DeriveTls12Keys(constref Suite: TCipherSuiteInfo; MasterSecret: PByte; ClientRandom, ServerRandom: PByte;
  out Keys: TTls12Keys);
var
  Seed: array[0..63] of Byte;
  Block: array[0..2 * 32 + 2 * Tls12MaximumIvLength - 1] of Byte;
  Position: Integer;
begin
  FillChar(Keys, SizeOf(Keys), 0);
  Keys.KeyLength := Suite.KeyLength;
  Keys.IvLength := Tls12IvLength(Suite);
  Move(ServerRandom^, Seed[0], 32);
  Move(ClientRandom^, Seed[32], 32);
  Tls12Prf(Suite.Hash, MasterSecret, Tls12MasterSecretLength, 'key expansion', @Seed[0], 64, @Block[0],
    2 * Keys.KeyLength + 2 * Keys.IvLength);
  Position := 0;
  Move(Block[Position], Keys.ClientKey[0], Keys.KeyLength);
  Position := Position + Keys.KeyLength;
  Move(Block[Position], Keys.ServerKey[0], Keys.KeyLength);
  Position := Position + Keys.KeyLength;
  Move(Block[Position], Keys.ClientIv[0], Keys.IvLength);
  Position := Position + Keys.IvLength;
  Move(Block[Position], Keys.ServerIv[0], Keys.IvLength);
  WipeMemory(@Block[0], SizeOf(Block));
end;

procedure ComputeTls12VerifyData(Hash: TDigestAlgorithm; MasterSecret: PByte; FromClient: Boolean;
  TranscriptHash: PByte; VerifyData: PByte);
begin
  if FromClient then
    Tls12Prf(Hash, MasterSecret, Tls12MasterSecretLength, 'client finished', TranscriptHash, DigestSize(Hash),
      VerifyData, Tls12VerifyDataLength)
  else
    Tls12Prf(Hash, MasterSecret, Tls12MasterSecretLength, 'server finished', TranscriptHash, DigestSize(Hash),
      VerifyData, Tls12VerifyDataLength);
end;

end.
