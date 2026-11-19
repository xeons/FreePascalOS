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
  SHA-256 (FIPS 180-4) for the network stack: the pseudo-random function
  of stable-privacy interface identifiers (RFC 7217). Self-contained (no
  other unit), so the host tests use it as it is.

  A hash is begun, fed any number of pieces and finished:
    BeginSha256(Context); AddToSha256(Context, Data, Length) ...;
    FinishSha256(Context, Digest)
}
unit Network.Sha256;

{$mode objfpc}
{$pointermath on}
{$rangechecks off}
{$overflowchecks off}

interface

const
  Sha256DigestBytes = 32;
  Sha256BlockBytes = 64;

type
  TSha256Digest = array[0..Sha256DigestBytes - 1] of Byte;

  TSha256Context = record
    State: array[0..7] of LongWord;
    Block: array[0..Sha256BlockBytes - 1] of Byte;
    BlockUsed: LongWord;
    TotalBytes: QWord;
  end;

procedure BeginSha256(out Context: TSha256Context);
procedure AddToSha256(var Context: TSha256Context; Data: PByte; Length: LongWord);
procedure FinishSha256(var Context: TSha256Context; out Digest: TSha256Digest);

implementation

const
  RoundConstants: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function RotateRight(Value: LongWord; Count: Byte): LongWord; inline;
begin
  Result := (Value shr Count) or (Value shl (32 - Count));
end;

procedure CompressBlock(var Context: TSha256Context; Block: PByte);
var
  Schedule: array[0..63] of LongWord;
  Index: Integer;
  A, B, C, D, E, F, G, H: LongWord;
  Sigma0, Sigma1, Choice, Majority, Temporary1, Temporary2: LongWord;
begin
  for Index := 0 to 15 do
    Schedule[Index] := (LongWord(Block[Index * 4]) shl 24) or (LongWord(Block[Index * 4 + 1]) shl 16) or
      (LongWord(Block[Index * 4 + 2]) shl 8) or LongWord(Block[Index * 4 + 3]);
  for Index := 16 to 63 do
  begin
    Sigma0 := RotateRight(Schedule[Index - 15], 7) xor RotateRight(Schedule[Index - 15], 18) xor
      (Schedule[Index - 15] shr 3);
    Sigma1 := RotateRight(Schedule[Index - 2], 17) xor RotateRight(Schedule[Index - 2], 19) xor
      (Schedule[Index - 2] shr 10);
    Schedule[Index] := Schedule[Index - 16] + Sigma0 + Schedule[Index - 7] + Sigma1;
  end;
  A := Context.State[0];
  B := Context.State[1];
  C := Context.State[2];
  D := Context.State[3];
  E := Context.State[4];
  F := Context.State[5];
  G := Context.State[6];
  H := Context.State[7];
  for Index := 0 to 63 do
  begin
    Sigma1 := RotateRight(E, 6) xor RotateRight(E, 11) xor RotateRight(E, 25);
    Choice := (E and F) xor ((not E) and G);
    Temporary1 := H + Sigma1 + Choice + RoundConstants[Index] + Schedule[Index];
    Sigma0 := RotateRight(A, 2) xor RotateRight(A, 13) xor RotateRight(A, 22);
    Majority := (A and B) xor (A and C) xor (B and C);
    Temporary2 := Sigma0 + Majority;
    H := G;
    G := F;
    F := E;
    E := D + Temporary1;
    D := C;
    C := B;
    B := A;
    A := Temporary1 + Temporary2;
  end;
  Context.State[0] := Context.State[0] + A;
  Context.State[1] := Context.State[1] + B;
  Context.State[2] := Context.State[2] + C;
  Context.State[3] := Context.State[3] + D;
  Context.State[4] := Context.State[4] + E;
  Context.State[5] := Context.State[5] + F;
  Context.State[6] := Context.State[6] + G;
  Context.State[7] := Context.State[7] + H;
end;

procedure BeginSha256(out Context: TSha256Context);
var
  Index: Integer;
begin
  Context.State[0] := $6a09e667;
  Context.State[1] := $bb67ae85;
  Context.State[2] := $3c6ef372;
  Context.State[3] := $a54ff53a;
  Context.State[4] := $510e527f;
  Context.State[5] := $9b05688c;
  Context.State[6] := $1f83d9ab;
  Context.State[7] := $5be0cd19;
  for Index := 0 to Sha256BlockBytes - 1 do
    Context.Block[Index] := 0;
  Context.BlockUsed := 0;
  Context.TotalBytes := 0;
end;

procedure AddToSha256(var Context: TSha256Context; Data: PByte; Length: LongWord);
var
  Position: LongWord;
begin
  Position := 0;
  while Position < Length do
  begin
    Context.Block[Context.BlockUsed] := Data[Position];
    Inc(Context.BlockUsed);
    Inc(Position);
    if Context.BlockUsed = Sha256BlockBytes then
    begin
      CompressBlock(Context, @Context.Block[0]);
      Context.BlockUsed := 0;
    end;
  end;
  Context.TotalBytes := Context.TotalBytes + Length;
end;

procedure FinishSha256(var Context: TSha256Context; out Digest: TSha256Digest);
var
  BitCount: QWord;
  Padding: array[0..Sha256BlockBytes + 8 - 1] of Byte;
  PaddingLength: LongWord;
  Index: Integer;
begin
  BitCount := Context.TotalBytes * 8;
  for Index := 0 to High(Padding) do
    Padding[Index] := 0;
  Padding[0] := $80;
  if Context.BlockUsed < 56 then
    PaddingLength := 56 - Context.BlockUsed
  else
    PaddingLength := 120 - Context.BlockUsed;
  for Index := 0 to 7 do
    Padding[PaddingLength + LongWord(Index)] := Byte(BitCount shr (56 - Index * 8));
  AddToSha256(Context, @Padding[0], PaddingLength + 8);
  for Index := 0 to 7 do
  begin
    Digest[Index * 4] := Byte(Context.State[Index] shr 24);
    Digest[Index * 4 + 1] := Byte(Context.State[Index] shr 16);
    Digest[Index * 4 + 2] := Byte(Context.State[Index] shr 8);
    Digest[Index * 4 + 3] := Byte(Context.State[Index]);
  end;
end;

end.
