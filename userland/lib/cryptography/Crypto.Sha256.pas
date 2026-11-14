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
  The SHA-256 compression function (FIPS 180-4), shared by SHA-224 and
  SHA-256, which differ only in the initial state and output length.
  Use Crypto.Digests for whole messages.
}
unit Crypto.Sha256;

{$mode objfpc}
{$pointermath on}

interface

type
  TSha256State = array[0..7] of LongWord;

const
  Sha256InitialState: TSha256State = (
    $6a09e667, $bb67ae85, $3c6ef372, $a54ff53a, $510e527f, $9b05688c, $1f83d9ab, $5be0cd19);
  Sha224InitialState: TSha256State = (
    $c1059ed8, $367cd507, $3070dd17, $f70e5939, $ffc00b31, $68581511, $64f98fa7, $befa4fa4);

{ Mixes one 64-byte block into State. }
procedure Sha256Compress(var State: TSha256State; Block: PByte);

implementation

uses
  Crypto.Bits;

const
  Sha256Constants: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

procedure Sha256Compress(var State: TSha256State; Block: PByte);
var
  Words: array[0..63] of LongWord;
  Working: array[0..7] of LongWord;
  Sigma0, Sigma1: LongWord;
  Choice, Majority: LongWord;
  First, Second: LongWord;
  Round: Integer;
  Index: Integer;
begin
  for Round := 0 to 15 do
    Words[Round] := LoadBigEndian32(Block + Round * 4);
  for Round := 16 to 63 do
  begin
    Sigma0 := RotateRight32(Words[Round - 15], 7) xor RotateRight32(Words[Round - 15], 18) xor
      (Words[Round - 15] shr 3);
    Sigma1 := RotateRight32(Words[Round - 2], 17) xor RotateRight32(Words[Round - 2], 19) xor
      (Words[Round - 2] shr 10);
    Words[Round] := Words[Round - 16] + Sigma0 + Words[Round - 7] + Sigma1;
  end;
  for Index := 0 to 7 do
    Working[Index] := State[Index];
  for Round := 0 to 63 do
  begin
    Sigma1 := RotateRight32(Working[4], 6) xor RotateRight32(Working[4], 11) xor RotateRight32(Working[4], 25);
    Choice := (Working[4] and Working[5]) xor ((not Working[4]) and Working[6]);
    First := Working[7] + Sigma1 + Choice + Sha256Constants[Round] + Words[Round];
    Sigma0 := RotateRight32(Working[0], 2) xor RotateRight32(Working[0], 13) xor RotateRight32(Working[0], 22);
    Majority := (Working[0] and Working[1]) xor (Working[0] and Working[2]) xor (Working[1] and Working[2]);
    Second := Sigma0 + Majority;
    Working[7] := Working[6];
    Working[6] := Working[5];
    Working[5] := Working[4];
    Working[4] := Working[3] + First;
    Working[3] := Working[2];
    Working[2] := Working[1];
    Working[1] := Working[0];
    Working[0] := First + Second;
  end;
  for Index := 0 to 7 do
    State[Index] := State[Index] + Working[Index];
end;

end.
