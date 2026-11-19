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
  SHA-3 and SHAKE against hashlib, and ML-KEM-768 against OpenSSL
  (CryptoTest.PostQuantumVectors.inc, made by
  make-post-quantum-vectors.py when the test is built): keys from seeds,
  OpenSSL's ciphertexts decapsulated, implicit rejection of a changed
  ciphertext, round trips of the library's own encapsulations, and the
  modulus check of encapsulation keys. Compression by multiplication is
  checked against division for every coefficient.
}
unit CryptoTest.PostQuantum;

{$mode objfpc}
{$H+}

interface

procedure TestKeccak;
procedure TestMlKem;

implementation

uses
  TestChecks,
  Crypto.Keccak,
  Crypto.MlKemPolynomials,
  Crypto.MlKem;

{$I CryptoTest.PostQuantumVectors.inc}

procedure TestKeccak;
var
  Input, Output: TByteArray;
  State: TKeccakState;
  Index: Integer;
begin
  Output := nil;
  SetLength(Output, 400);
  Input := TextBytes('abc');
  ComputeSha3_256(nil, 0, @Output[0]);
  CheckBytes(@Output[0], 32, Sha3_256Empty, 'SHA3-256 ""');
  ComputeSha3_256(@Input[0], 3, @Output[0]);
  CheckBytes(@Output[0], 32, Sha3_256Abc, 'SHA3-256 "abc"');
  ComputeSha3_512(@Input[0], 3, @Output[0]);
  CheckBytes(@Output[0], 64, Sha3_512Abc, 'SHA3-512 "abc"');
  ComputeShake256(@Input[0], 3, @Output[0], 64);
  CheckBytes(@Output[0], 64, Shake256Abc, 'SHAKE256 "abc", 64 bytes');
  ComputeShake128(nil, 0, @Output[0], 32);
  CheckBytes(@Output[0], 32, Shake128Empty, 'SHAKE128 "", 32 bytes');
  Input := HexToBytes(KeccakLongInput);
  ComputeSha3_256(@Input[0], Length(Input), @Output[0]);
  CheckBytes(@Output[0], 32, Sha3_256Long, 'SHA3-256 of 500 bytes');
  ComputeSha3_512(@Input[0], Length(Input), @Output[0]);
  CheckBytes(@Output[0], 64, Sha3_512Long, 'SHA3-512 of 500 bytes');
  ComputeShake256(@Input[0], Length(Input), @Output[0], 300);
  CheckBytes(@Output[0], 300, Shake256Long, 'SHAKE256 of 500 bytes, 300 out');
  { Absorbed and squeezed a few bytes at a time. }
  BeginKeccak(State, Shake128Rate, ShakeSuffix);
  Index := 0;
  while Index < Length(Input) do
  begin
    if Length(Input) - Index >= 7 then
      AbsorbKeccak(State, @Input[Index], 7)
    else
      AbsorbKeccak(State, @Input[Index], Length(Input) - Index);
    Inc(Index, 7);
  end;
  Index := 0;
  while Index < 400 do
  begin
    SqueezeKeccak(State, @Output[Index], 5);
    Inc(Index, 5);
  end;
  CheckBytes(@Output[0], 400, Shake128Long, 'SHAKE128 of 500 bytes in pieces, 400 out in pieces');
end;

procedure TestCompression;
var
  Value: Word;
  Bits: Integer;
  Wrong: Integer;
  Expected: LongWord;
begin
  Wrong := 0;
  for Bits := 1 to 11 do
    for Value := 0 to MlKemQ - 1 do
    begin
      Expected := ((LongWord(Value) shl (Bits + 1)) + MlKemQ) div (2 * MlKemQ) mod (LongWord(1) shl Bits);
      if CompressCoefficient(Value, Bits) <> Expected then
        Inc(Wrong);
    end;
  Check(Wrong = 0, 'ML-KEM: Compress_d by multiplication equals round(2^d x / q) for every x and d');
end;

procedure CheckVector(const Name, SeedHex, KeyHex, CiphertextHex, SecretHex, ChangedHex, RejectionHex: string);
var
  Seed, Ciphertext, Changed: TByteArray;
  EncapsulationKey, DecapsulationKey: TByteArray;
  Secret, OwnCiphertext, OwnSecret: TByteArray;
begin
  Seed := HexToBytes(SeedHex);
  EncapsulationKey := nil;
  DecapsulationKey := nil;
  Secret := nil;
  OwnCiphertext := nil;
  OwnSecret := nil;
  SetLength(EncapsulationKey, MlKem768EncapsulationKeySize);
  SetLength(DecapsulationKey, MlKem768DecapsulationKeySize);
  SetLength(Secret, MlKem768SharedSecretSize);
  SetLength(OwnCiphertext, MlKem768CiphertextSize);
  SetLength(OwnSecret, MlKem768SharedSecretSize);
  MlKem768KeyPairFromSeed(@Seed[0], @EncapsulationKey[0], @DecapsulationKey[0]);
  CheckBytes(@EncapsulationKey[0], MlKem768EncapsulationKeySize, KeyHex, Name + ': encapsulation key from d || z');
  Ciphertext := HexToBytes(CiphertextHex);
  MlKem768Decapsulate(@DecapsulationKey[0], @Ciphertext[0], @Secret[0]);
  CheckBytes(@Secret[0], 32, SecretHex, Name + ': OpenSSL''s ciphertext decapsulated');
  Changed := HexToBytes(ChangedHex);
  MlKem768Decapsulate(@DecapsulationKey[0], @Changed[0], @Secret[0]);
  CheckBytes(@Secret[0], 32, RejectionHex, Name + ': a changed ciphertext gives the implicit rejection secret');
  Check(MlKem768Encapsulate(@EncapsulationKey[0], @OwnCiphertext[0], @OwnSecret[0]),
    Name + ': encapsulation takes the key');
  MlKem768Decapsulate(@DecapsulationKey[0], @OwnCiphertext[0], @Secret[0]);
  Check(CompareByte(Secret[0], OwnSecret[0], 32) = 0, Name + ': own encapsulation decapsulates to the same secret');
end;

procedure TestMlKem;
var
  EncapsulationKey, DecapsulationKey, Ciphertext, Secret, Message: TByteArray;
begin
  TestCompression;
  CheckVector('ML-KEM-768 vector 1', MlKemSeed1, MlKemEncapsulationKey1, MlKemCiphertext1, MlKemSharedSecret1,
    MlKemChangedCiphertext1, MlKemRejectionSecret1);
  CheckVector('ML-KEM-768 vector 2', MlKemSeed2, MlKemEncapsulationKey2, MlKemCiphertext2, MlKemSharedSecret2,
    MlKemChangedCiphertext2, MlKemRejectionSecret2);
  CheckVector('ML-KEM-768 vector 3', MlKemSeed3, MlKemEncapsulationKey3, MlKemCiphertext3, MlKemSharedSecret3,
    MlKemChangedCiphertext3, MlKemRejectionSecret3);

  { A key with a coefficient of q or more fails the modulus check. }
  EncapsulationKey := HexToBytes(MlKemEncapsulationKey1);
  Ciphertext := nil;
  Secret := nil;
  Message := nil;
  DecapsulationKey := nil;
  SetLength(Ciphertext, MlKem768CiphertextSize);
  SetLength(Secret, MlKem768SharedSecretSize);
  SetLength(Message, MlKem768MessageSize);
  SetLength(DecapsulationKey, MlKem768DecapsulationKeySize);
  EncapsulationKey[0] := $FF;
  EncapsulationKey[1] := EncapsulationKey[1] or $0F;
  Check(not MlKem768EncapsulateWithMessage(@EncapsulationKey[0], @Message[0], @Ciphertext[0], @Secret[0]),
    'ML-KEM-768: an encapsulation key with a coefficient of 4095 is refused');
  { A fresh random pair. }
  MlKem768GenerateKeyPair(@EncapsulationKey[0], @DecapsulationKey[0]);
  Check(MlKem768Encapsulate(@EncapsulationKey[0], @Ciphertext[0], @Message[0]), 'ML-KEM-768: random key pair');
  MlKem768Decapsulate(@DecapsulationKey[0], @Ciphertext[0], @Secret[0]);
  Check(CompareByte(Secret[0], Message[0], 32) = 0, 'ML-KEM-768: random key pair round trip');
end;

end.
