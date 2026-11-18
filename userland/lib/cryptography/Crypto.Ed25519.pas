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
  Ed25519 signatures (RFC 8032, the pure variant).

  A private key is a 32-byte random seed (Crypto.KeyGeneration makes
  one); Ed25519PublicKey gives its 32-byte public key. Ed25519Sign
  signs a message with the seed into 64 bytes (R and S); Ed25519Verify
  checks such a signature with the public key.

  Points are kept in extended coordinates (X:Y:Z:T, x = X/Z, y = Y/Z,
  xy = T/Z) and multiplied by a scalar with a ladder that does the same
  additions whatever the bits, swapping by masks; the field arithmetic
  is Crypto.Curve25519Field's. Scalars mod L (the order of the base
  point) are reduced from 64 bytes by schoolbook folding of the top
  bytes.
}
unit Crypto.Ed25519;

{$mode objfpc}
{$pointermath on}

interface

const
  Ed25519SeedSize = 32;
  Ed25519PublicKeySize = 32;
  Ed25519SignatureSize = 64;

procedure Ed25519PublicKey(Seed: PByte; PublicKey: PByte);
procedure Ed25519Sign(Seed: PByte; Message: PByte; MessageLength: QWord; Signature: PByte);
{ False for a wrong signature, a public key that is no point of the
  curve, or an S that is not below L. }
function Ed25519Verify(PublicKey: PByte; Message: PByte; MessageLength: QWord; Signature: PByte): Boolean;

implementation

uses
  Crypto.Bits,
  Crypto.Digests,
  Crypto.Curve25519Field;

type
  TEdwardsPoint = array[0..3] of TCurve25519Element;
  TScalarBytes = array[0..31] of Byte;
  TWideScalar = array[0..63] of Int64;

const
  { d = -121665 / 121666 and 2d. }
  CurveD: TCurve25519Element = ($78a3, $1359, $4dca, $75eb, $d8ab, $4141, $0a4d, $0070,
    $e898, $7779, $4079, $8cc7, $fe73, $2b6f, $6cee, $5203);
  CurveDoubleD: TCurve25519Element = ($f159, $26b2, $9b94, $ebd6, $b156, $8283, $149a, $00e0,
    $d130, $eef3, $80f2, $198e, $fce7, $56df, $d9dc, $2406);
  { The base point B: y = 4/5 and its even x. }
  BaseX: TCurve25519Element = ($d51a, $8f25, $2d60, $c956, $a7b2, $9525, $c760, $692c,
    $dc5c, $fdd6, $e231, $c0a4, $53fe, $cd6e, $36d3, $2169);
  BaseY: TCurve25519Element = ($6658, $6666, $6666, $6666, $6666, $6666, $6666, $6666,
    $6666, $6666, $6666, $6666, $6666, $6666, $6666, $6666);
  { A square root of -1: 2^((p - 1) / 4). }
  SquareRootOfMinusOne: TCurve25519Element = ($a0b0, $4a0e, $1b27, $c4ee, $e478, $ad2f, $1806, $2f43,
    $d7a7, $3dfb, $0099, $2b4d, $df0b, $4fc1, $2480, $2b83);
  { L = 2^252 + 27742317777372353535851937790883648493, little endian. }
  GroupOrder: array[0..31] of Int64 = ($ed, $d3, $f5, $5c, $1a, $63, $12, $58, $d6, $9c, $f7, $a2,
    $de, $f9, $de, $14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $10);

{ First := First + Second (the unified addition, which also doubles). }
procedure AddPoint(var First: TEdwardsPoint; const Second: TEdwardsPoint);
var
  A, B, C, D, T, E, F, G, H: TCurve25519Element;
begin
  Curve25519Subtract(A, First[1], First[0]);
  Curve25519Subtract(T, Second[1], Second[0]);
  Curve25519Multiply(A, A, T);
  Curve25519Add(B, First[0], First[1]);
  Curve25519Add(T, Second[0], Second[1]);
  Curve25519Multiply(B, B, T);
  Curve25519Multiply(C, First[3], Second[3]);
  Curve25519Multiply(C, C, CurveDoubleD);
  Curve25519Multiply(D, First[2], Second[2]);
  Curve25519Add(D, D, D);
  Curve25519Subtract(E, B, A);
  Curve25519Subtract(F, D, C);
  Curve25519Add(G, D, C);
  Curve25519Add(H, B, A);
  Curve25519Multiply(First[0], E, F);
  Curve25519Multiply(First[1], H, G);
  Curve25519Multiply(First[2], G, F);
  Curve25519Multiply(First[3], E, H);
end;

procedure SwapPoints(var First, Second: TEdwardsPoint; Swap: Int64);
var
  Coordinate: Integer;
begin
  for Coordinate := 0 to 3 do
    Curve25519Swap(First[Coordinate], Second[Coordinate], Swap);
end;

{ y with the sign of x in the top bit. }
procedure EncodePoint(Bytes: PByte; const Point: TEdwardsPoint);
var
  ZInverse, X, Y: TCurve25519Element;
begin
  Curve25519Invert(ZInverse, Point[2]);
  Curve25519Multiply(X, Point[0], ZInverse);
  Curve25519Multiply(Y, Point[1], ZInverse);
  Curve25519Pack(Bytes, Y);
  Bytes[31] := Bytes[31] xor Byte(Curve25519Parity(X) shl 7);
end;

{ Product := Scalar (32 little endian bytes) times Point; Point is used
  up. }
procedure MultiplyPoint(out Product: TEdwardsPoint; var Point: TEdwardsPoint; Scalar: PByte);
var
  Bit: Integer;
  Swap: Int64;
begin
  Product[0] := Curve25519Zero;
  Product[1] := Curve25519One;
  Product[2] := Curve25519One;
  Product[3] := Curve25519Zero;
  for Bit := 255 downto 0 do
  begin
    Swap := (Scalar[Bit shr 3] shr (Bit and 7)) and 1;
    SwapPoints(Product, Point, Swap);
    AddPoint(Point, Product);
    AddPoint(Product, Product);
    SwapPoints(Product, Point, Swap);
  end;
end;

procedure MultiplyBasePoint(out Product: TEdwardsPoint; Scalar: PByte);
var
  Base: TEdwardsPoint;
begin
  Base[0] := BaseX;
  Base[1] := BaseY;
  Base[2] := Curve25519One;
  Curve25519Multiply(Base[3], BaseX, BaseY);
  MultiplyPoint(Product, Base, Scalar);
end;

{ Writes Wide mod L as 32 little endian bytes. Wide holds byte sized
  (possibly larger) limbs; it is used up. }
procedure ReduceModuloOrder(Output: PByte; var Wide: TWideScalar);
var
  CarryValue: Int64;
  Top, Index: Integer;
begin
  { Clear each byte from the top down: byte Top weighs 2^(8 Top), and
    subtracting Wide[Top] * 16 L shifted by Top - 32 bytes takes it
    away (16 L = 2^256 + 16 (L - 2^252)), leaving the small part of L
    in the bytes below, carried in signed bytes. }
  for Top := 63 downto 32 do
  begin
    CarryValue := 0;
    Index := Top - 32;
    while Index < Top - 12 do
    begin
      Wide[Index] := Wide[Index] + CarryValue - 16 * Wide[Top] * GroupOrder[Index - (Top - 32)];
      CarryValue := SarInt64(Wide[Index] + 128, 8);
      Wide[Index] := Wide[Index] - (CarryValue shl 8);
      Inc(Index);
    end;
    Wide[Index] := Wide[Index] + CarryValue;
    Wide[Top] := 0;
  end;
  CarryValue := 0;
  for Index := 0 to 31 do
  begin
    Wide[Index] := Wide[Index] + CarryValue - SarInt64(Wide[31], 4) * GroupOrder[Index];
    CarryValue := SarInt64(Wide[Index], 8);
    Wide[Index] := Wide[Index] and 255;
  end;
  for Index := 0 to 31 do
    Wide[Index] := Wide[Index] - CarryValue * GroupOrder[Index];
  for Index := 0 to 31 do
  begin
    Wide[Index + 1] := Wide[Index + 1] + SarInt64(Wide[Index], 8);
    Output[Index] := Byte(Wide[Index] and 255);
  end;
end;

{ A 64-byte hash, taken mod L, in place (the first 32 bytes). }
procedure ReduceHash(Hash: PByte);
var
  Wide: TWideScalar;
  Index: Integer;
begin
  for Index := 0 to 63 do
    Wide[Index] := Hash[Index];
  for Index := 0 to 63 do
    Hash[Index] := 0;
  ReduceModuloOrder(Hash, Wide);
end;

{ The point whose encoding is Bytes, negated (verification needs -A).
  False when Bytes is no point. }
function DecodeNegatedPoint(out Point: TEdwardsPoint; Bytes: PByte): Boolean;
var
  Numerator, Denominator, DenominatorSquared, DenominatorFourth, DenominatorSixth: TCurve25519Element;
  Candidate, Check: TCurve25519Element;
begin
  Result := False;
  Point[2] := Curve25519One;
  Curve25519Unpack(Point[1], Bytes);
  { x^2 = (y^2 - 1) / (d y^2 + 1) }
  Curve25519Square(Numerator, Point[1]);
  Curve25519Multiply(Denominator, Numerator, CurveD);
  Curve25519Subtract(Numerator, Numerator, Point[2]);
  Curve25519Add(Denominator, Point[2], Denominator);

  { Candidate = u v^3 (u v^7)^((p - 5) / 8) }
  Curve25519Square(DenominatorSquared, Denominator);
  Curve25519Square(DenominatorFourth, DenominatorSquared);
  Curve25519Multiply(DenominatorSixth, DenominatorFourth, DenominatorSquared);
  Curve25519Multiply(Candidate, DenominatorSixth, Numerator);
  Curve25519Multiply(Candidate, Candidate, Denominator);
  Curve25519PowerForRoot(Candidate, Candidate);
  Curve25519Multiply(Candidate, Candidate, Numerator);
  Curve25519Multiply(Candidate, Candidate, Denominator);
  Curve25519Multiply(Candidate, Candidate, Denominator);
  Curve25519Multiply(Point[0], Candidate, Denominator);

  Curve25519Square(Check, Point[0]);
  Curve25519Multiply(Check, Check, Denominator);
  if Curve25519Differ(Check, Numerator) then
    Curve25519Multiply(Point[0], Point[0], SquareRootOfMinusOne);
  Curve25519Square(Check, Point[0]);
  Curve25519Multiply(Check, Check, Denominator);
  if Curve25519Differ(Check, Numerator) then
    Exit;

  { The negation: the x of the other sign than the one encoded. }
  if Curve25519Parity(Point[0]) = (Bytes[31] shr 7) then
    Curve25519Subtract(Point[0], Curve25519Zero, Point[0]);
  Curve25519Multiply(Point[3], Point[0], Point[1]);
  Result := True;
end;

{ The SHA-512 of the seed, its first half clamped into the scalar a. }
procedure ExpandSeed(Seed: PByte; out Expanded: TDigestOutput);
begin
  ComputeDigest(DigestSha512, Seed, Ed25519SeedSize, Expanded);
  Expanded[0] := Expanded[0] and 248;
  Expanded[31] := Expanded[31] and 127;
  Expanded[31] := Expanded[31] or 64;
end;

procedure Ed25519PublicKey(Seed: PByte; PublicKey: PByte);
var
  Expanded: TDigestOutput;
  Point: TEdwardsPoint;
begin
  ExpandSeed(Seed, Expanded);
  MultiplyBasePoint(Point, @Expanded[0]);
  EncodePoint(PublicKey, Point);
  WipeMemory(@Expanded[0], SizeOf(Expanded));
  WipeMemory(@Point, SizeOf(Point));
end;

procedure Ed25519Sign(Seed: PByte; Message: PByte; MessageLength: QWord; Signature: PByte);
var
  Expanded: TDigestOutput;
  PublicKey: array[0..Ed25519PublicKeySize - 1] of Byte;
  Nonce, Challenge: TDigestOutput;
  Context: TDigestContext;
  Point: TEdwardsPoint;
  Wide: TWideScalar;
  Outer, Inner: Integer;
begin
  ExpandSeed(Seed, Expanded);
  MultiplyBasePoint(Point, @Expanded[0]);
  EncodePoint(@PublicKey[0], Point);

  { r = H(prefix || M) mod L; R = r B }
  BeginDigest(Context, DigestSha512);
  UpdateDigest(Context, @Expanded[32], 32);
  UpdateDigest(Context, Message, MessageLength);
  FinishDigest(Context, Nonce);
  ReduceHash(@Nonce[0]);
  MultiplyBasePoint(Point, @Nonce[0]);
  EncodePoint(Signature, Point);

  { k = H(R || A || M) mod L }
  BeginDigest(Context, DigestSha512);
  UpdateDigest(Context, Signature, 32);
  UpdateDigest(Context, @PublicKey[0], Ed25519PublicKeySize);
  UpdateDigest(Context, Message, MessageLength);
  FinishDigest(Context, Challenge);
  ReduceHash(@Challenge[0]);

  { S = (r + k a) mod L }
  for Outer := 0 to 63 do
    Wide[Outer] := 0;
  for Outer := 0 to 31 do
    Wide[Outer] := Nonce[Outer];
  for Outer := 0 to 31 do
    for Inner := 0 to 31 do
      Wide[Outer + Inner] := Wide[Outer + Inner] + Int64(Challenge[Outer]) * Int64(Expanded[Inner]);
  ReduceModuloOrder(Signature + 32, Wide);

  WipeMemory(@Expanded[0], SizeOf(Expanded));
  WipeMemory(@Nonce[0], SizeOf(Nonce));
  WipeMemory(@Wide[0], SizeOf(Wide));
  WipeMemory(@Point, SizeOf(Point));
end;

{ True when the 32 little endian bytes are below L. }
function ScalarIsCanonical(Scalar: PByte): Boolean;
var
  Index: Integer;
begin
  for Index := 31 downto 0 do
  begin
    if Scalar[Index] < GroupOrder[Index] then
      Exit(True);
    if Scalar[Index] > GroupOrder[Index] then
      Exit(False);
  end;
  { Equal to L. }
  Result := False;
end;

function Ed25519Verify(PublicKey: PByte; Message: PByte; MessageLength: QWord; Signature: PByte): Boolean;
var
  NegatedKey: TEdwardsPoint;
  Sum, SB: TEdwardsPoint;
  Challenge: TDigestOutput;
  Context: TDigestContext;
  Encoded: array[0..31] of Byte;
begin
  Result := False;
  if not ScalarIsCanonical(Signature + 32) then
    Exit;
  if not DecodeNegatedPoint(NegatedKey, PublicKey) then
    Exit;

  BeginDigest(Context, DigestSha512);
  UpdateDigest(Context, Signature, 32);
  UpdateDigest(Context, PublicKey, Ed25519PublicKeySize);
  UpdateDigest(Context, Message, MessageLength);
  FinishDigest(Context, Challenge);
  ReduceHash(@Challenge[0]);

  { S B - k A must encode as R. }
  MultiplyPoint(Sum, NegatedKey, @Challenge[0]);
  MultiplyBasePoint(SB, Signature + 32);
  AddPoint(Sum, SB);
  EncodePoint(@Encoded[0], Sum);
  Result := ConstantTimeEqual(@Encoded[0], Signature, 32);
end;

end.
