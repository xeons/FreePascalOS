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
  SHA-3 and ML-KEM-768 checks. The answers (CryptoTest.PostQuantumVectors.inc)
  are made at build time by make-post-quantum-vectors.py: SHA3-256,
  SHA3-512, SHAKE128 and SHAKE256 by Python's hashlib, and ML-KEM-768
  encapsulation keys, ciphertexts and shared secrets by OpenSSL through
  Python's cryptography package.
}
unit CryptoTest.PostQuantum;

{$mode objfpc}
{$H+}

interface

procedure TestSha3;
procedure TestMlKem;

implementation

uses
  SysUtils,
  TestChecks,
  Crypto.Sha3,
  Crypto.MlKem;

{$i CryptoTest.PostQuantumVectors.inc}

const
  HashNames: array[THashAlgorithm] of string = ('SHA3-256', 'SHA3-512', 'SHAKE128', 'SHAKE256');
  { Piece sizes for absorbing and squeezing in several calls. }
  PieceSizes: array[0..5] of Integer = (1, 7, 64, 3, 136, 29);

{ The same bytes make-post-quantum-vectors.py's test_input makes (and
  one spare, so that an empty input still has an address). }
function TestInput(Count: Integer): TByteArray;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Count + 1);
  for Index := 0 to Count - 1 do
    Result[Index] := Byte((Index * 7 + 3) mod 251);
end;

procedure ComputeOneShot(constref Vector: TSha3Vector; Input, Output: PByte);
begin
  case Vector.Algorithm of
    HashSha3_256: Sha3_256(Input, Vector.InputLength, Output);
    HashSha3_512: Sha3_512(Input, Vector.InputLength, Output);
    HashShake128: Shake128(Input, Vector.InputLength, Output, Vector.OutputLength);
    HashShake256: Shake256(Input, Vector.InputLength, Output, Vector.OutputLength);
  end;
end;

{ The same hash, with the input absorbed and the output squeezed in pieces. }
procedure ComputeInPieces(constref Vector: TSha3Vector; Input, Output: PByte);
var
  Context: TSha3Context;
  Done, Piece, PieceIndex: Integer;
  IsShake: Boolean;
begin
  IsShake := Vector.Algorithm in [HashShake128, HashShake256];
  case Vector.Algorithm of
    HashSha3_256: BeginSha3(Context, 256);
    HashSha3_512: BeginSha3(Context, 512);
    HashShake128: BeginShake(Context, 128);
    HashShake256: BeginShake(Context, 256);
  end;
  Done := 0;
  PieceIndex := 0;
  while Done < Vector.InputLength do
  begin
    Piece := PieceSizes[PieceIndex mod Length(PieceSizes)];
    if Piece > Vector.InputLength - Done then
      Piece := Vector.InputLength - Done;
    if IsShake then
      AbsorbShake(Context, Input + Done, Piece)
    else
      AbsorbSha3(Context, Input + Done, Piece);
    Inc(Done, Piece);
    Inc(PieceIndex);
  end;
  if not IsShake then
  begin
    FinishSha3(Context, Output, 8 * Vector.OutputLength);
    Exit;
  end;
  Done := 0;
  while Done < Vector.OutputLength do
  begin
    Piece := PieceSizes[PieceIndex mod Length(PieceSizes)];
    if Piece > Vector.OutputLength - Done then
      Piece := Vector.OutputLength - Done;
    SqueezeShake(Context, Output + Done, Piece);
    Inc(Done, Piece);
    Inc(PieceIndex);
  end;
  WipeSha3(Context);
end;

procedure TestSha3;
var
  Index: Integer;
  Vector: TSha3Vector;
  Input, Output: TByteArray;
  Name: string;
begin
  for Index := 0 to High(Sha3Vectors) do
  begin
    Vector := Sha3Vectors[Index];
    Input := TestInput(Vector.InputLength);
    Output := nil;
    SetLength(Output, Vector.OutputLength);
    Name := Format('%s of %d bytes, %d out', [HashNames[Vector.Algorithm], Vector.InputLength, Vector.OutputLength]);
    ComputeOneShot(Vector, @Input[0], @Output[0]);
    CheckBytes(@Output[0], Vector.OutputLength, Vector.Output, Name);
    FillChar(Output[0], Vector.OutputLength, 0);
    ComputeInPieces(Vector, @Input[0], @Output[0]);
    CheckBytes(@Output[0], Vector.OutputLength, Vector.Output, Name + ' in pieces');
  end;
end;

procedure TestMlKem;
var
  Index: Integer;
  Vector: TMlKemVector;
  Seed, Ciphertext, Randomness: TByteArray;
  EncapsulationKey: array[0..MlKem768EncapsulationKeyLength - 1] of Byte;
  DecapsulationKey: array[0..MlKem768DecapsulationKeyLength - 1] of Byte;
  OwnCiphertext: array[0..MlKem768CiphertextLength - 1] of Byte;
  SharedSecret, OwnSecret: array[0..MlKemSharedSecretLength - 1] of Byte;
  Name: string;
begin
  Randomness := nil;
  for Index := 0 to High(MlKemVectors) do
  begin
    Vector := MlKemVectors[Index];
    Name := Format('ML-KEM-768 seed %d', [Index]);
    Seed := HexToBytes(Vector.Seed);
    MlKem768KeyPairFromSeed(@Seed[0], @EncapsulationKey[0], @DecapsulationKey[0]);
    CheckBytes(@EncapsulationKey[0], MlKem768EncapsulationKeyLength, Vector.EncapsulationKey,
      Name + ' encapsulation key');

    Ciphertext := HexToBytes(Vector.Ciphertext);
    MlKem768Decapsulate(@DecapsulationKey[0], @Ciphertext[0], @SharedSecret[0]);
    CheckBytes(@SharedSecret[0], MlKemSharedSecretLength, Vector.SharedSecret,
      Name + ' decapsulates OpenSSL''s ciphertext');

    Ciphertext[Vector.FlippedIndex] := Ciphertext[Vector.FlippedIndex] xor Vector.FlippedMask;
    MlKem768Decapsulate(@DecapsulationKey[0], @Ciphertext[0], @SharedSecret[0]);
    CheckBytes(@SharedSecret[0], MlKemSharedSecretLength, Vector.RejectionSecret, Name + ' implicit rejection');

    Randomness := TestInput(32 + Index);
    Check(MlKem768Encapsulate(@EncapsulationKey[0], @Randomness[Index], @OwnCiphertext[0], @OwnSecret[0]),
      Name + ' encapsulates');
    MlKem768Decapsulate(@DecapsulationKey[0], @OwnCiphertext[0], @SharedSecret[0]);
    Check(CompareMem(@SharedSecret[0], @OwnSecret[0], MlKemSharedSecretLength), Name + ' round trip');
  end;

  { A 12-bit value of q or more fails the modulus check. }
  EncapsulationKey[0] := $FF;
  EncapsulationKey[1] := EncapsulationKey[1] or $0F;
  Check(not MlKem768Encapsulate(@EncapsulationKey[0], @Randomness[0], @OwnCiphertext[0], @OwnSecret[0]),
    'ML-KEM-768 refuses an unreduced encapsulation key');
end;

end.
