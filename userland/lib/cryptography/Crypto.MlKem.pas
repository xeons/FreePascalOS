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
  ML-KEM-768 (FIPS 203): the module lattice key encapsulation mechanism
  that SSH's mlkem768x25519-sha256 and TLS's X25519MLKEM768 combine
  with X25519 against a quantum computer recording the exchange today.

    Keys:      MlKem768GenerateKeyPair(EncapsulationKey, DecapsulationKey)
    Sender:    MlKem768Encapsulate(EncapsulationKey, Ciphertext, SharedSecret)
    Receiver:  MlKem768Decapsulate(DecapsulationKey, Ciphertext, SharedSecret)

  Both ends get the same 32-byte shared secret. A changed ciphertext
  gives the receiver an unrelated secret (implicit rejection: J(z || c))
  rather than an error, so it learns nothing it could test.

  The parameters are k = 3, eta1 = eta2 = 2, du = 10, dv = 4; G is
  SHA3-512, H SHA3-256, J and PRF SHAKE256, the matrix comes from
  SHAKE128 (Crypto.MlKemPolynomials). The deterministic forms
  (MlKem768KeyPairFromSeed with d || z, MlKem768EncapsulateWithMessage)
  are what the known answer tests use.
}
unit Crypto.MlKem;

{$mode objfpc}
{$pointermath on}

interface

const
  MlKem768EncapsulationKeySize = 1184;
  MlKem768DecapsulationKeySize = 2400;
  MlKem768CiphertextSize = 1088;
  MlKem768SharedSecretSize = 32;
  { d || z. }
  MlKem768SeedSize = 64;
  MlKem768MessageSize = 32;

procedure MlKem768KeyPairFromSeed(Seed: PByte; EncapsulationKey, DecapsulationKey: PByte);
procedure MlKem768GenerateKeyPair(EncapsulationKey, DecapsulationKey: PByte);
{ False when the encapsulation key fails the modulus check (a value of q
  or more): nothing is written then. }
function MlKem768EncapsulateWithMessage(EncapsulationKey, Message: PByte; Ciphertext, SharedSecret: PByte): Boolean;
function MlKem768Encapsulate(EncapsulationKey: PByte; Ciphertext, SharedSecret: PByte): Boolean;
procedure MlKem768Decapsulate(DecapsulationKey, Ciphertext: PByte; SharedSecret: PByte);

implementation

uses
  Crypto.Bits,
  Crypto.Keccak,
  Crypto.MlKemPolynomials,
  Crypto.Random;

const
  Rank = 3;
  Eta1 = 2;
  Eta2 = 2;
  CompressionU = 10;
  CompressionV = 4;
  NoiseBytes = 64 * Eta1;
  VectorBytes = Rank * MlKemPolynomialBytes;
  { The PKE's decryption key, then the encapsulation key, H(ek), z. }
  OffsetEncapsulationKey = VectorBytes;
  OffsetKeyHash = OffsetEncapsulationKey + MlKem768EncapsulationKeySize;
  OffsetRejectionSeed = OffsetKeyHash + 32;
  CiphertextUBytes = Rank * 32 * CompressionU;

type
  TPolynomialVector = array[0..Rank - 1] of TMlKemPolynomial;
  TPolynomialMatrix = array[0..Rank - 1, 0..Rank - 1] of TMlKemPolynomial;

{ A-hat[i, j] = SampleNTT(rho || j || i); transposed, [j, i]. }
procedure ExpandMatrix(Rho: PByte; Transposed: Boolean; out Matrix: TPolynomialMatrix);
var
  Seed: array[0..33] of Byte;
  Row, Column: Integer;
begin
  Move(Rho^, Seed[0], 32);
  for Row := 0 to Rank - 1 do
    for Column := 0 to Rank - 1 do
    begin
      if Transposed then
      begin
        Seed[32] := Byte(Row);
        Seed[33] := Byte(Column);
      end
      else
      begin
        Seed[32] := Byte(Column);
        Seed[33] := Byte(Row);
      end;
      SampleUniformNtt(@Seed[0], Matrix[Row, Column]);
    end;
end;

{ SamplePolyCBD(PRF(Seed, Counter)), the counter then counted up. }
procedure SampleNoise(Seed: PByte; Eta: Integer; var Counter: Byte; out Polynomial: TMlKemPolynomial);
var
  Input: array[0..32] of Byte;
  Bytes: array[0..NoiseBytes - 1] of Byte;
begin
  Move(Seed^, Input[0], 32);
  Input[32] := Counter;
  Inc(Counter);
  ComputeShake256(@Input[0], SizeOf(Input), @Bytes[0], 64 * Eta);
  SampleCenteredBinomial(@Bytes[0], Eta, Polynomial);
  WipeMemory(@Input[0], SizeOf(Input));
  WipeMemory(@Bytes[0], SizeOf(Bytes));
end;

procedure ClearPolynomial(out Polynomial: TMlKemPolynomial);
begin
  FillChar(Polynomial, SizeOf(Polynomial), 0);
end;

{ K-PKE.KeyGen: ek = ByteEncode12(t-hat) || rho, dk = ByteEncode12(s-hat). }
procedure PkeKeyGen(D: PByte; EncryptionKey, DecryptionKey: PByte);
var
  Input: array[0..32] of Byte;
  Expanded: array[0..63] of Byte;
  Matrix: TPolynomialMatrix;
  Secret, Error, Public_: TPolynomialVector;
  Counter: Byte;
  Row, Column: Integer;
begin
  Move(D^, Input[0], 32);
  Input[32] := Rank;
  ComputeSha3_512(@Input[0], SizeOf(Input), @Expanded[0]);
  { rho = Expanded[0..31], sigma = Expanded[32..63]. }
  ExpandMatrix(@Expanded[0], False, Matrix);
  Counter := 0;
  for Row := 0 to Rank - 1 do
    SampleNoise(@Expanded[32], Eta1, Counter, Secret[Row]);
  for Row := 0 to Rank - 1 do
    SampleNoise(@Expanded[32], Eta1, Counter, Error[Row]);
  for Row := 0 to Rank - 1 do
  begin
    ForwardNtt(Secret[Row]);
    ForwardNtt(Error[Row]);
  end;
  for Row := 0 to Rank - 1 do
  begin
    ClearPolynomial(Public_[Row]);
    for Column := 0 to Rank - 1 do
      MultiplyAccumulateNtt(Public_[Row], Matrix[Row, Column], Secret[Column]);
    AddPolynomial(Public_[Row], Error[Row]);
  end;
  for Row := 0 to Rank - 1 do
  begin
    EncodePolynomial(Public_[Row], 12, EncryptionKey + Row * MlKemPolynomialBytes);
    EncodePolynomial(Secret[Row], 12, DecryptionKey + Row * MlKemPolynomialBytes);
  end;
  Move(Expanded[0], EncryptionKey[VectorBytes], 32);
  WipeMemory(@Input[0], SizeOf(Input));
  WipeMemory(@Expanded[0], SizeOf(Expanded));
  WipeMemory(@Secret, SizeOf(Secret));
  WipeMemory(@Error, SizeOf(Error));
end;

{ K-PKE.Encrypt of the 32-byte Message with randomness R. }
procedure PkeEncrypt(EncryptionKey, Message, R: PByte; Ciphertext: PByte);
var
  Matrix: TPolynomialMatrix;
  Public_, Masking, ErrorU, U: TPolynomialVector;
  ErrorV, V, Encoded: TMlKemPolynomial;
  Counter: Byte;
  Row, Column: Integer;
begin
  for Row := 0 to Rank - 1 do
    DecodePolynomial(EncryptionKey + Row * MlKemPolynomialBytes, 12, Public_[Row]);
  ExpandMatrix(EncryptionKey + VectorBytes, True, Matrix);
  Counter := 0;
  for Row := 0 to Rank - 1 do
    SampleNoise(R, Eta1, Counter, Masking[Row]);
  for Row := 0 to Rank - 1 do
    SampleNoise(R, Eta2, Counter, ErrorU[Row]);
  SampleNoise(R, Eta2, Counter, ErrorV);
  for Row := 0 to Rank - 1 do
    ForwardNtt(Masking[Row]);
  { u = NTT^-1(A-hat^T o y-hat) + e1 }
  for Row := 0 to Rank - 1 do
  begin
    ClearPolynomial(U[Row]);
    for Column := 0 to Rank - 1 do
      MultiplyAccumulateNtt(U[Row], Matrix[Row, Column], Masking[Column]);
    InverseNtt(U[Row]);
    AddPolynomial(U[Row], ErrorU[Row]);
  end;
  { v = NTT^-1(t-hat^T o y-hat) + e2 + Decompress1(m) }
  ClearPolynomial(V);
  for Column := 0 to Rank - 1 do
    MultiplyAccumulateNtt(V, Public_[Column], Masking[Column]);
  InverseNtt(V);
  AddPolynomial(V, ErrorV);
  DecodePolynomial(Message, 1, Encoded);
  DecompressPolynomial(Encoded, 1);
  AddPolynomial(V, Encoded);
  for Row := 0 to Rank - 1 do
  begin
    CompressPolynomial(U[Row], CompressionU);
    EncodePolynomial(U[Row], CompressionU, Ciphertext + Row * 32 * CompressionU);
  end;
  CompressPolynomial(V, CompressionV);
  EncodePolynomial(V, CompressionV, Ciphertext + CiphertextUBytes);
  WipeMemory(@Masking, SizeOf(Masking));
  WipeMemory(@ErrorU, SizeOf(ErrorU));
  WipeMemory(@ErrorV, SizeOf(ErrorV));
  WipeMemory(@Encoded, SizeOf(Encoded));
end;

{ K-PKE.Decrypt: m = ByteEncode1(Compress1(v' - NTT^-1(s-hat^T o NTT(u')))). }
procedure PkeDecrypt(DecryptionKey, Ciphertext: PByte; Message: PByte);
var
  Secret, U: TPolynomialVector;
  V, Product: TMlKemPolynomial;
  Row: Integer;
begin
  for Row := 0 to Rank - 1 do
  begin
    DecodePolynomial(Ciphertext + Row * 32 * CompressionU, CompressionU, U[Row]);
    DecompressPolynomial(U[Row], CompressionU);
    ForwardNtt(U[Row]);
    DecodePolynomial(DecryptionKey + Row * MlKemPolynomialBytes, 12, Secret[Row]);
  end;
  DecodePolynomial(Ciphertext + CiphertextUBytes, CompressionV, V);
  DecompressPolynomial(V, CompressionV);
  ClearPolynomial(Product);
  for Row := 0 to Rank - 1 do
    MultiplyAccumulateNtt(Product, Secret[Row], U[Row]);
  InverseNtt(Product);
  SubtractPolynomial(V, Product);
  CompressPolynomial(V, 1);
  EncodePolynomial(V, 1, Message);
  WipeMemory(@Secret, SizeOf(Secret));
  WipeMemory(@V, SizeOf(V));
  WipeMemory(@Product, SizeOf(Product));
end;

procedure MlKem768KeyPairFromSeed(Seed: PByte; EncapsulationKey, DecapsulationKey: PByte);
begin
  PkeKeyGen(Seed, EncapsulationKey, DecapsulationKey);
  Move(EncapsulationKey^, DecapsulationKey[OffsetEncapsulationKey], MlKem768EncapsulationKeySize);
  ComputeSha3_256(EncapsulationKey, MlKem768EncapsulationKeySize, DecapsulationKey + OffsetKeyHash);
  Move(Seed[32], DecapsulationKey[OffsetRejectionSeed], 32);
end;

procedure MlKem768GenerateKeyPair(EncapsulationKey, DecapsulationKey: PByte);
var
  Seed: array[0..MlKem768SeedSize - 1] of Byte;
begin
  RandomBytes(@Seed[0], SizeOf(Seed));
  MlKem768KeyPairFromSeed(@Seed[0], EncapsulationKey, DecapsulationKey);
  WipeMemory(@Seed[0], SizeOf(Seed));
end;

function EncapsulationKeyIsValid(EncapsulationKey: PByte): Boolean;
var
  Row: Integer;
begin
  Result := True;
  for Row := 0 to Rank - 1 do
    if not PolynomialBytesAreReduced(EncapsulationKey + Row * MlKemPolynomialBytes) then
      Result := False;
end;

function MlKem768EncapsulateWithMessage(EncapsulationKey, Message: PByte; Ciphertext, SharedSecret: PByte): Boolean;
var
  Input: array[0..63] of Byte;
  Expanded: array[0..63] of Byte;
begin
  Result := EncapsulationKeyIsValid(EncapsulationKey);
  if not Result then
    Exit;
  { (K, r) = G(m || H(ek)) }
  Move(Message^, Input[0], 32);
  ComputeSha3_256(EncapsulationKey, MlKem768EncapsulationKeySize, @Input[32]);
  ComputeSha3_512(@Input[0], SizeOf(Input), @Expanded[0]);
  PkeEncrypt(EncapsulationKey, Message, @Expanded[32], Ciphertext);
  Move(Expanded[0], SharedSecret^, MlKem768SharedSecretSize);
  WipeMemory(@Input[0], SizeOf(Input));
  WipeMemory(@Expanded[0], SizeOf(Expanded));
end;

function MlKem768Encapsulate(EncapsulationKey: PByte; Ciphertext, SharedSecret: PByte): Boolean;
var
  Message: array[0..MlKem768MessageSize - 1] of Byte;
begin
  RandomBytes(@Message[0], SizeOf(Message));
  Result := MlKem768EncapsulateWithMessage(EncapsulationKey, @Message[0], Ciphertext, SharedSecret);
  WipeMemory(@Message[0], SizeOf(Message));
end;

procedure MlKem768Decapsulate(DecapsulationKey, Ciphertext: PByte; SharedSecret: PByte);
var
  Message: array[0..31] of Byte;
  Input: array[0..63] of Byte;
  Expanded: array[0..63] of Byte;
  Rejection: array[0..31] of Byte;
  RejectionInput: array[0..32 + MlKem768CiphertextSize - 1] of Byte;
  Reencrypted: array[0..MlKem768CiphertextSize - 1] of Byte;
  Difference: Byte;
  Mask: Byte;
  Index: Integer;
begin
  PkeDecrypt(DecapsulationKey, Ciphertext, @Message[0]);
  { (K', r') = G(m' || h) }
  Move(Message[0], Input[0], 32);
  Move(DecapsulationKey[OffsetKeyHash], Input[32], 32);
  ComputeSha3_512(@Input[0], SizeOf(Input), @Expanded[0]);
  { K-bar = J(z || c) }
  Move(DecapsulationKey[OffsetRejectionSeed], RejectionInput[0], 32);
  Move(Ciphertext^, RejectionInput[32], MlKem768CiphertextSize);
  ComputeShake256(@RejectionInput[0], SizeOf(RejectionInput), @Rejection[0], 32);
  PkeEncrypt(DecapsulationKey + OffsetEncapsulationKey, @Message[0], @Expanded[32], @Reencrypted[0]);
  Difference := 0;
  for Index := 0 to MlKem768CiphertextSize - 1 do
    Difference := Difference or (Ciphertext[Index] xor Reencrypted[Index]);
  { Mask is FF when the ciphertexts are the same, without a branch. }
  Mask := Byte((LongWord(Difference) - 1) shr 8);
  for Index := 0 to MlKem768SharedSecretSize - 1 do
    SharedSecret[Index] := (Expanded[Index] and Mask) or (Rejection[Index] and not Mask);
  WipeMemory(@Message[0], SizeOf(Message));
  WipeMemory(@Input[0], SizeOf(Input));
  WipeMemory(@Expanded[0], SizeOf(Expanded));
  WipeMemory(@Rejection[0], SizeOf(Rejection));
end;

end.
