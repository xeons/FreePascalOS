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
  ML-KEM-768 (FIPS 203), the module lattice key encapsulation mechanism:
  the public key encryption scheme K-PKE inside it, and the deterministic
  "internal" key generation, encapsulation and decapsulation, which take
  their randomness as arguments. Crypto.MlKemRandom adds the versions
  that draw it from Crypto.Random.

  Decapsulation uses implicit rejection: a ciphertext that does not
  re-encrypt to itself gives a pseudorandom secret derived from z and the
  ciphertext, chosen without branching on the comparison.
}
unit Crypto.MlKem;

{$mode objfpc}
{$pointermath on}

interface

const
  MlKem768EncapsulationKeyLength = 1184;
  MlKem768DecapsulationKeyLength = 2400;
  MlKem768CiphertextLength = 1088;
  MlKemSharedSecretLength = 32;
  { d || z for key generation. }
  MlKemKeySeedLength = 64;
  { m for encapsulation. }
  MlKemEncapsulationRandomnessLength = 32;

{ ML-KEM.KeyGen_internal: Seed is the 64 bytes d || z. }
procedure MlKem768KeyPairFromSeed(Seed: PByte; EncapsulationKey, DecapsulationKey: PByte);

{ ML-KEM.Encaps_internal with the 32 random bytes m. False (with zeroed
  outputs) when EncapsulationKey fails the modulus check of FIPS 203
  section 7.2. }
function MlKem768Encapsulate(EncapsulationKey: PByte; Randomness: PByte; Ciphertext, SharedSecret: PByte): Boolean;

{ ML-KEM.Decaps_internal, with implicit rejection. }
procedure MlKem768Decapsulate(DecapsulationKey, Ciphertext, SharedSecret: PByte);

implementation

uses
  Crypto.Bits,
  Crypto.Sha3,
  Crypto.MlKemPolynomials;

const
  Rank = 3;
  { Bits per coefficient of the compressed u and v. }
  VectorCompressionBits = 10;
  ScalarCompressionBits = 4;
  CompressedPolynomialBytes = MlKemDegree * VectorCompressionBits div 8;
  VectorBytes = Rank * MlKemPolynomialBytes;
  CompressedVectorBytes = Rank * CompressedPolynomialBytes;

  { Where the parts of a decapsulation key start. }
  EncapsulationKeyOffset = VectorBytes;
  KeyHashOffset = EncapsulationKeyOffset + MlKem768EncapsulationKeyLength;
  RejectionSeedOffset = KeyHashOffset + 32;

type
  TMlKemVector = array[0..Rank - 1] of TMlKemPolynomial;

procedure WipeVector(var Vector: TMlKemVector);
begin
  WipeMemory(@Vector[0], SizeOf(Vector));
end;

procedure WipePolynomial(var Polynomial: TMlKemPolynomial);
begin
  WipeMemory(@Polynomial[0], SizeOf(Polynomial));
end;

{ Sum = the inner product of First and Second (in NTT form) times R^-1, reduced. }
procedure InnerProduct(out Sum: TMlKemPolynomial; constref First, Second: TMlKemVector);
var
  Product: TMlKemPolynomial;
  Index: Integer;
begin
  PolynomialMultiplyNtt(Sum, First[0], Second[0]);
  for Index := 1 to Rank - 1 do
  begin
    PolynomialMultiplyNtt(Product, First[Index], Second[Index]);
    PolynomialAdd(Sum, Product);
  end;
  PolynomialReduce(Sum);
  WipePolynomial(Product);
end;

{ Row Row of the matrix A in NTT form (or of its transpose). }
procedure SampleMatrixRow(out MatrixRow: TMlKemVector; Rho: PByte; Row: Integer; Transposed: Boolean);
var
  Column: Integer;
begin
  for Column := 0 to Rank - 1 do
    if Transposed then
      SampleNttPolynomial(MatrixRow[Column], Rho, Row, Column)
    else
      SampleNttPolynomial(MatrixRow[Column], Rho, Column, Row);
end;

{ K-PKE.KeyGen: writes the 1184 byte encryption key and the 1152 byte
  decryption key. }
procedure KPkeGenerateKeys(Seed: PByte; EncryptionKey, DecryptionKey: PByte);
var
  SeedInput: array[0..32] of Byte;
  Seeds: array[0..63] of Byte;
  Secret, Error, MatrixRow: TMlKemVector;
  PublicPolynomial: TMlKemPolynomial;
  Index: Integer;
begin
  Move(Seed^, SeedInput[0], 32);
  SeedInput[32] := Rank;
  { Rho (public) and sigma (secret). }
  Sha3_512(@SeedInput[0], SizeOf(SeedInput), @Seeds[0]);
  for Index := 0 to Rank - 1 do
  begin
    SampleNoisePolynomial(Secret[Index], @Seeds[32], Index);
    SampleNoisePolynomial(Error[Index], @Seeds[32], Rank + Index);
  end;
  for Index := 0 to Rank - 1 do
  begin
    PolynomialNtt(Secret[Index]);
    PolynomialNtt(Error[Index]);
  end;
  for Index := 0 to Rank - 1 do
  begin
    SampleMatrixRow(MatrixRow, @Seeds[0], Index, False);
    InnerProduct(PublicPolynomial, MatrixRow, Secret);
    PolynomialToMontgomery(PublicPolynomial);
    PolynomialAdd(PublicPolynomial, Error[Index]);
    PolynomialReduce(PublicPolynomial);
    PolynomialToBytes(PublicPolynomial, EncryptionKey + Index * MlKemPolynomialBytes);
    PolynomialToBytes(Secret[Index], DecryptionKey + Index * MlKemPolynomialBytes);
  end;
  Move(Seeds[0], EncryptionKey[VectorBytes], 32);
  WipeMemory(@SeedInput[0], SizeOf(SeedInput));
  WipeMemory(@Seeds[0], SizeOf(Seeds));
  WipeVector(Secret);
  WipeVector(Error);
  WipePolynomial(PublicPolynomial);
end;

{ K-PKE.Encrypt of the 32 byte Message with the 32 byte Randomness. }
procedure KPkeEncrypt(EncryptionKey, Message, Randomness, Ciphertext: PByte);
var
  PublicVector, Ephemeral, MatrixRow: TMlKemVector;
  Error, Combined, MessagePolynomial: TMlKemPolynomial;
  Rho: PByte;
  Index: Integer;
begin
  for Index := 0 to Rank - 1 do
    PolynomialFromBytes(PublicVector[Index], EncryptionKey + Index * MlKemPolynomialBytes);
  Rho := EncryptionKey + VectorBytes;
  for Index := 0 to Rank - 1 do
  begin
    SampleNoisePolynomial(Ephemeral[Index], Randomness, Index);
    PolynomialNtt(Ephemeral[Index]);
  end;

  { u = InverseNtt(A^T y) + e1 }
  for Index := 0 to Rank - 1 do
  begin
    SampleMatrixRow(MatrixRow, Rho, Index, True);
    InnerProduct(Combined, MatrixRow, Ephemeral);
    PolynomialInverseNtt(Combined);
    SampleNoisePolynomial(Error, Randomness, Rank + Index);
    PolynomialAdd(Combined, Error);
    PolynomialReduce(Combined);
    CompressPolynomial(Combined, VectorCompressionBits, Ciphertext + Index * CompressedPolynomialBytes);
  end;

  { v = InverseNtt(t^T y) + e2 + Decompress1(m) }
  InnerProduct(Combined, PublicVector, Ephemeral);
  PolynomialInverseNtt(Combined);
  SampleNoisePolynomial(Error, Randomness, 2 * Rank);
  PolynomialAdd(Combined, Error);
  PolynomialFromMessage(MessagePolynomial, Message);
  PolynomialAdd(Combined, MessagePolynomial);
  PolynomialReduce(Combined);
  CompressPolynomial(Combined, ScalarCompressionBits, Ciphertext + CompressedVectorBytes);

  WipeVector(Ephemeral);
  WipePolynomial(Error);
  WipePolynomial(Combined);
  WipePolynomial(MessagePolynomial);
end;

{ K-PKE.Decrypt into the 32 byte Message. }
procedure KPkeDecrypt(DecryptionKey, Ciphertext, Message: PByte);
var
  Secret, CiphertextVector: TMlKemVector;
  Scalar, Product, Difference: TMlKemPolynomial;
  Index: Integer;
begin
  for Index := 0 to Rank - 1 do
  begin
    DecompressPolynomial(CiphertextVector[Index], VectorCompressionBits,
      Ciphertext + Index * CompressedPolynomialBytes);
    PolynomialNtt(CiphertextVector[Index]);
    PolynomialFromBytes(Secret[Index], DecryptionKey + Index * MlKemPolynomialBytes);
  end;
  DecompressPolynomial(Scalar, ScalarCompressionBits, Ciphertext + CompressedVectorBytes);
  InnerProduct(Product, Secret, CiphertextVector);
  PolynomialInverseNtt(Product);
  PolynomialSubtract(Difference, Scalar, Product);
  PolynomialReduce(Difference);
  PolynomialToMessage(Difference, Message);
  WipeVector(Secret);
  WipeVector(CiphertextVector);
  WipePolynomial(Product);
  WipePolynomial(Difference);
end;

function EncapsulationKeyIsValid(EncapsulationKey: PByte): Boolean;
var
  Index: Integer;
begin
  Result := True;
  for Index := 0 to Rank - 1 do
    if not PolynomialBytesAreReduced(EncapsulationKey + Index * MlKemPolynomialBytes) then
      Result := False;
end;

procedure MlKem768KeyPairFromSeed(Seed: PByte; EncapsulationKey, DecapsulationKey: PByte);
begin
  KPkeGenerateKeys(Seed, EncapsulationKey, DecapsulationKey);
  Move(EncapsulationKey^, DecapsulationKey[EncapsulationKeyOffset], MlKem768EncapsulationKeyLength);
  Sha3_256(EncapsulationKey, MlKem768EncapsulationKeyLength, DecapsulationKey + KeyHashOffset);
  Move(Seed[32], DecapsulationKey[RejectionSeedOffset], 32);
end;

function MlKem768Encapsulate(EncapsulationKey: PByte; Randomness: PByte; Ciphertext, SharedSecret: PByte): Boolean;
var
  HashInput: array[0..63] of Byte;
  SecretAndCoins: array[0..63] of Byte;
begin
  if not EncapsulationKeyIsValid(EncapsulationKey) then
  begin
    FillChar(Ciphertext^, MlKem768CiphertextLength, 0);
    FillChar(SharedSecret^, MlKemSharedSecretLength, 0);
    Exit(False);
  end;
  { (K, r) = G(m || H(ek)) }
  Move(Randomness^, HashInput[0], 32);
  Sha3_256(EncapsulationKey, MlKem768EncapsulationKeyLength, @HashInput[32]);
  Sha3_512(@HashInput[0], SizeOf(HashInput), @SecretAndCoins[0]);
  KPkeEncrypt(EncapsulationKey, Randomness, @SecretAndCoins[32], Ciphertext);
  Move(SecretAndCoins[0], SharedSecret^, MlKemSharedSecretLength);
  WipeMemory(@HashInput[0], SizeOf(HashInput));
  WipeMemory(@SecretAndCoins[0], SizeOf(SecretAndCoins));
  Result := True;
end;

procedure MlKem768Decapsulate(DecapsulationKey, Ciphertext, SharedSecret: PByte);
var
  HashInput: array[0..63] of Byte;
  SecretAndCoins: array[0..63] of Byte;
  RejectionSecret: array[0..MlKemSharedSecretLength - 1] of Byte;
  Reencrypted: array[0..MlKem768CiphertextLength - 1] of Byte;
  Context: TSha3Context;
  Difference, KeepMask: Byte;
  Index: Integer;
begin
  { m' = Decrypt(c); (K', r') = G(m' || h) }
  KPkeDecrypt(DecapsulationKey, Ciphertext, @HashInput[0]);
  Move(DecapsulationKey[KeyHashOffset], HashInput[32], 32);
  Sha3_512(@HashInput[0], SizeOf(HashInput), @SecretAndCoins[0]);

  { K-bar = J(z || c) = SHAKE256(z || c, 32) }
  BeginShake(Context, 256);
  AbsorbShake(Context, DecapsulationKey + RejectionSeedOffset, 32);
  AbsorbShake(Context, Ciphertext, MlKem768CiphertextLength);
  SqueezeShake(Context, @RejectionSecret[0], SizeOf(RejectionSecret));
  WipeSha3(Context);

  KPkeEncrypt(DecapsulationKey + EncapsulationKeyOffset, @HashInput[0], @SecretAndCoins[32], @Reencrypted[0]);

  { All ones when c' = c, zero otherwise, without branching. }
  Difference := 0;
  for Index := 0 to MlKem768CiphertextLength - 1 do
    Difference := Difference or (Ciphertext[Index] xor Reencrypted[Index]);
  KeepMask := Byte(SarLongint(LongInt(Difference) - 1, 8) and $FF);
  for Index := 0 to MlKemSharedSecretLength - 1 do
    SharedSecret[Index] := RejectionSecret[Index] xor
      (KeepMask and (SecretAndCoins[Index] xor RejectionSecret[Index]));

  Difference := 0;
  KeepMask := 0;
  WipeMemory(@HashInput[0], SizeOf(HashInput));
  WipeMemory(@SecretAndCoins[0], SizeOf(SecretAndCoins));
  WipeMemory(@RejectionSecret[0], SizeOf(RejectionSecret));
  WipeMemory(@Reencrypted[0], SizeOf(Reencrypted));
end;

end.
