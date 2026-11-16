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
  Checking RSA signatures (RFC 8017): PKCS #1 v1.5 (RSASSA-PKCS1-v1_5)
  and PSS (RSASSA-PSS with MGF1), over SHA-1, SHA-256, SHA-384 and
  SHA-512. Only the public key operation is here; nothing signs.

  Callers hash the message themselves and pass the digest. Keys from
  1024 to 8192 bits are taken; a signature must be exactly as long as
  the modulus and smaller than it.
}
unit Crypto.Rsa;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.BigNumbers,
  Crypto.Digests;

const
  RsaMinimumModulusBits = 1024;

type
  TRsaPublicKey = record
    Modulus: TMontgomeryModulus;
    Exponent: TBigNumber;
    ModulusBits: Integer;
    ModulusBytes: Integer;
  end;

{ From the big endian modulus and public exponent; False for a modulus
  that is even, too small or too large, or an exponent that is even or
  below 3. }
function PrepareRsaPublicKey(out Key: TRsaPublicKey; Modulus: PByte; ModulusLength: PtrUInt; Exponent: PByte;
  ExponentLength: PtrUInt): Boolean;

function VerifyRsaPkcs1Signature(constref Key: TRsaPublicKey; Algorithm: TDigestAlgorithm; Digest: PByte;
  Signature: PByte; SignatureLength: PtrUInt): Boolean;

{ SaltLength is what the signer used (TLS 1.3: the digest size). MGF1
  uses the same digest as the message. }
function VerifyRsaPssSignature(constref Key: TRsaPublicKey; Algorithm: TDigestAlgorithm; Digest: PByte;
  SaltLength: Integer; Signature: PByte; SignatureLength: PtrUInt): Boolean;

implementation

uses
  Crypto.Bits;

const
  { DigestInfo prefixes (RFC 8017 section 9.2, note 1), each followed
    by the digest itself. }
  Sha1DigestInfo: array[0..14] of Byte = ($30, $21, $30, $09, $06, $05, $2B, $0E, $03, $02, $1A, $05, $00,
    $04, $14);
  Sha256DigestInfo: array[0..18] of Byte = ($30, $31, $30, $0D, $06, $09, $60, $86, $48, $01, $65, $03, $04,
    $02, $01, $05, $00, $04, $20);
  Sha384DigestInfo: array[0..18] of Byte = ($30, $41, $30, $0D, $06, $09, $60, $86, $48, $01, $65, $03, $04,
    $02, $02, $05, $00, $04, $30);
  Sha512DigestInfo: array[0..18] of Byte = ($30, $51, $30, $0D, $06, $09, $60, $86, $48, $01, $65, $03, $04,
    $02, $03, $05, $00, $04, $40);

function PrepareRsaPublicKey(out Key: TRsaPublicKey; Modulus: PByte; ModulusLength: PtrUInt; Exponent: PByte;
  ExponentLength: PtrUInt): Boolean;
var
  ModulusNumber: TBigNumber;
begin
  FillChar(Key, SizeOf(Key), 0);
  if not BigNumberFromBytes(ModulusNumber, Modulus, ModulusLength) then
    Exit(False);
  if not BigNumberFromBytes(Key.Exponent, Exponent, ExponentLength) then
    Exit(False);
  Key.ModulusBits := BigNumberBitLength(ModulusNumber);
  if (Key.ModulusBits < RsaMinimumModulusBits) or (Key.ModulusBits > 8192) then
    Exit(False);
  if (BigNumberBitLength(Key.Exponent) < 2) or not BigNumberBit(Key.Exponent, 0) then
    Exit(False);
  if CompareBigNumbers(Key.Exponent, ModulusNumber) >= 0 then
    Exit(False);
  if not PrepareMontgomeryModulus(Key.Modulus, ModulusNumber) then
    Exit(False);
  Key.ModulusBytes := (Key.ModulusBits + 7) div 8;
  Result := True;
end;

{ s^e mod n as ModulusBytes big endian bytes into Output. }
function ApplyPublicKey(constref Key: TRsaPublicKey; Signature: PByte; SignatureLength: PtrUInt;
  Output: PByte): Boolean;
var
  SignatureNumber: TBigNumber;
  Message: TBigNumber;
begin
  if SignatureLength <> PtrUInt(Key.ModulusBytes) then
    Exit(False);
  if not BigNumberFromBytes(SignatureNumber, Signature, SignatureLength) then
    Exit(False);
  if CompareBigNumbers(SignatureNumber, Key.Modulus.Modulus) >= 0 then
    Exit(False);
  ModularPower(Key.Modulus, SignatureNumber, Key.Exponent, Message);
  Result := BigNumberToBytes(Message, Output, Key.ModulusBytes);
end;

function DigestInfoPrefix(Algorithm: TDigestAlgorithm; out Prefix: PByte; out PrefixLength: Integer): Boolean;
begin
  Result := True;
  case Algorithm of
    DigestSha1:
      begin
        Prefix := @Sha1DigestInfo[0];
        PrefixLength := SizeOf(Sha1DigestInfo);
      end;
    DigestSha256:
      begin
        Prefix := @Sha256DigestInfo[0];
        PrefixLength := SizeOf(Sha256DigestInfo);
      end;
    DigestSha384:
      begin
        Prefix := @Sha384DigestInfo[0];
        PrefixLength := SizeOf(Sha384DigestInfo);
      end;
    DigestSha512:
      begin
        Prefix := @Sha512DigestInfo[0];
        PrefixLength := SizeOf(Sha512DigestInfo);
      end;
  else
    Prefix := nil;
    PrefixLength := 0;
    Result := False;
  end;
end;

function VerifyRsaPkcs1Signature(constref Key: TRsaPublicKey; Algorithm: TDigestAlgorithm; Digest: PByte;
  Signature: PByte; SignatureLength: PtrUInt): Boolean;
var
  Recovered: array[0..BigNumberMaximumBytes - 1] of Byte;
  Expected: array[0..BigNumberMaximumBytes - 1] of Byte;
  Prefix: PByte;
  PrefixLength: Integer;
  HashLength: Integer;
  PaddingEnd: Integer;
  Index: Integer;
begin
  Result := False;
  if not DigestInfoPrefix(Algorithm, Prefix, PrefixLength) then
    Exit;
  HashLength := DigestSize(Algorithm);
  { EM = 00 01 FF..FF 00 DigestInfo, with at least 8 bytes of FF. }
  if Key.ModulusBytes < PrefixLength + HashLength + 11 then
    Exit;
  if not ApplyPublicKey(Key, Signature, SignatureLength, @Recovered[0]) then
    Exit;
  PaddingEnd := Key.ModulusBytes - PrefixLength - HashLength - 1;
  Expected[0] := 0;
  Expected[1] := 1;
  for Index := 2 to PaddingEnd - 1 do
    Expected[Index] := $FF;
  Expected[PaddingEnd] := 0;
  Move(Prefix^, Expected[PaddingEnd + 1], PrefixLength);
  Move(Digest^, Expected[PaddingEnd + 1 + PrefixLength], HashLength);
  Result := ConstantTimeEqual(@Recovered[0], @Expected[0], PtrUInt(Key.ModulusBytes));
end;

{ MGF1 (RFC 8017 appendix B.2.1): XORs the mask from Seed into Data. }
procedure ApplyMgf1Mask(Algorithm: TDigestAlgorithm; Seed: PByte; SeedLength: Integer; Data: PByte;
  DataLength: Integer);
var
  Context: TDigestContext;
  Block: TDigestOutput;
  CounterBytes: array[0..3] of Byte;
  Counter: LongWord;
  HashLength: Integer;
  Done: Integer;
  Index: Integer;
begin
  HashLength := DigestSize(Algorithm);
  Counter := 0;
  Done := 0;
  while Done < DataLength do
  begin
    StoreBigEndian32(@CounterBytes[0], Counter);
    BeginDigest(Context, Algorithm);
    UpdateDigest(Context, Seed, QWord(SeedLength));
    UpdateDigest(Context, @CounterBytes[0], 4);
    FinishDigest(Context, Block);
    Index := 0;
    while (Index < HashLength) and (Done < DataLength) do
    begin
      Data[Done] := Data[Done] xor Block[Index];
      Inc(Index);
      Inc(Done);
    end;
    Inc(Counter);
  end;
end;

function VerifyRsaPssSignature(constref Key: TRsaPublicKey; Algorithm: TDigestAlgorithm; Digest: PByte;
  SaltLength: Integer; Signature: PByte; SignatureLength: PtrUInt): Boolean;
var
  Recovered: array[0..BigNumberMaximumBytes - 1] of Byte;
  EncodedMessage: PByte;
  EncodedBits: Integer;
  EncodedLength: Integer;
  HashLength: Integer;
  MaskedLength: Integer;
  HashInMessage: PByte;
  UnusedBits: Integer;
  Index: Integer;
  PaddingLength: Integer;
  Context: TDigestContext;
  Zeros: array[0..7] of Byte;
  ComputedHash: TDigestOutput;
begin
  Result := False;
  if not (Algorithm in [DigestSha1, DigestSha256, DigestSha384, DigestSha512]) then
    Exit;
  if SaltLength < 0 then
    Exit;
  HashLength := DigestSize(Algorithm);
  if not ApplyPublicKey(Key, Signature, SignatureLength, @Recovered[0]) then
    Exit;

  { EM is emBits = modBits - 1 bits long; when that is a whole number of
    bytes the first byte of the k-byte result must be zero. }
  EncodedBits := Key.ModulusBits - 1;
  EncodedLength := (EncodedBits + 7) div 8;
  EncodedMessage := @Recovered[0];
  if EncodedLength < Key.ModulusBytes then
  begin
    if Recovered[0] <> 0 then
      Exit;
    EncodedMessage := @Recovered[1];
  end;
  if EncodedLength < HashLength + SaltLength + 2 then
    Exit;
  if EncodedMessage[EncodedLength - 1] <> $BC then
    Exit;
  MaskedLength := EncodedLength - HashLength - 1;
  HashInMessage := EncodedMessage + MaskedLength;
  UnusedBits := 8 * EncodedLength - EncodedBits;
  if (UnusedBits > 0) and ((EncodedMessage[0] shr (8 - UnusedBits)) <> 0) then
    Exit;

  ApplyMgf1Mask(Algorithm, HashInMessage, HashLength, EncodedMessage, MaskedLength);
  if UnusedBits > 0 then
    EncodedMessage[0] := EncodedMessage[0] and Byte($FF shr UnusedBits);

  { DB = PS (zeros) || 01 || salt. }
  PaddingLength := EncodedLength - HashLength - SaltLength - 2;
  for Index := 0 to PaddingLength - 1 do
    if EncodedMessage[Index] <> 0 then
      Exit;
  if EncodedMessage[PaddingLength] <> 1 then
    Exit;

  { H' = Hash(00 x 8 || mHash || salt). }
  for Index := 0 to 7 do
    Zeros[Index] := 0;
  BeginDigest(Context, Algorithm);
  UpdateDigest(Context, @Zeros[0], 8);
  UpdateDigest(Context, Digest, QWord(HashLength));
  if SaltLength > 0 then
    UpdateDigest(Context, EncodedMessage + MaskedLength - SaltLength, QWord(SaltLength));
  FinishDigest(Context, ComputedHash);
  Result := ConstantTimeEqual(@ComputedHash[0], HashInMessage, PtrUInt(HashLength));
end;

end.
