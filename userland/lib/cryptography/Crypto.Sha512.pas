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
  The SHA-512 compression function (FIPS 180-4), shared by SHA-384 and
  SHA-512. Use Crypto.Digests for whole messages.
}
unit Crypto.Sha512;

{$mode objfpc}
{$pointermath on}
{ The word arithmetic wraps by design (programs built with -Cr too). }
{$rangechecks off}
{$overflowchecks off}

interface

type
  TSha512State = array[0..7] of QWord;

const
  Sha512InitialState: TSha512State = (
    QWord($6a09e667f3bcc908), QWord($bb67ae8584caa73b), QWord($3c6ef372fe94f82b), QWord($a54ff53a5f1d36f1),
    QWord($510e527fade682d1), QWord($9b05688c2b3e6c1f), QWord($1f83d9abfb41bd6b), QWord($5be0cd19137e2179));
  Sha384InitialState: TSha512State = (
    QWord($cbbb9d5dc1059ed8), QWord($629a292a367cd507), QWord($9159015a3070dd17), QWord($152fecd8f70e5939),
    QWord($67332667ffc00b31), QWord($8eb44a8768581511), QWord($db0c2e0d64f98fa7), QWord($47b5481dbefa4fa4));

{ Mixes one 128-byte block into State. }
procedure Sha512Compress(var State: TSha512State; Block: PByte);

implementation

uses
  Crypto.Bits;

const
  Sha512Constants: array[0..79] of QWord = (
    QWord($428a2f98d728ae22), QWord($7137449123ef65cd), QWord($b5c0fbcfec4d3b2f), QWord($e9b5dba58189dbbc),
    QWord($3956c25bf348b538), QWord($59f111f1b605d019), QWord($923f82a4af194f9b), QWord($ab1c5ed5da6d8118),
    QWord($d807aa98a3030242), QWord($12835b0145706fbe), QWord($243185be4ee4b28c), QWord($550c7dc3d5ffb4e2),
    QWord($72be5d74f27b896f), QWord($80deb1fe3b1696b1), QWord($9bdc06a725c71235), QWord($c19bf174cf692694),
    QWord($e49b69c19ef14ad2), QWord($efbe4786384f25e3), QWord($0fc19dc68b8cd5b5), QWord($240ca1cc77ac9c65),
    QWord($2de92c6f592b0275), QWord($4a7484aa6ea6e483), QWord($5cb0a9dcbd41fbd4), QWord($76f988da831153b5),
    QWord($983e5152ee66dfab), QWord($a831c66d2db43210), QWord($b00327c898fb213f), QWord($bf597fc7beef0ee4),
    QWord($c6e00bf33da88fc2), QWord($d5a79147930aa725), QWord($06ca6351e003826f), QWord($142929670a0e6e70),
    QWord($27b70a8546d22ffc), QWord($2e1b21385c26c926), QWord($4d2c6dfc5ac42aed), QWord($53380d139d95b3df),
    QWord($650a73548baf63de), QWord($766a0abb3c77b2a8), QWord($81c2c92e47edaee6), QWord($92722c851482353b),
    QWord($a2bfe8a14cf10364), QWord($a81a664bbc423001), QWord($c24b8b70d0f89791), QWord($c76c51a30654be30),
    QWord($d192e819d6ef5218), QWord($d69906245565a910), QWord($f40e35855771202a), QWord($106aa07032bbd1b8),
    QWord($19a4c116b8d2d0c8), QWord($1e376c085141ab53), QWord($2748774cdf8eeb99), QWord($34b0bcb5e19b48a8),
    QWord($391c0cb3c5c95a63), QWord($4ed8aa4ae3418acb), QWord($5b9cca4f7763e373), QWord($682e6ff3d6b2b8a3),
    QWord($748f82ee5defb2fc), QWord($78a5636f43172f60), QWord($84c87814a1f0ab72), QWord($8cc702081a6439ec),
    QWord($90befffa23631e28), QWord($a4506cebde82bde9), QWord($bef9a3f7b2c67915), QWord($c67178f2e372532b),
    QWord($ca273eceea26619c), QWord($d186b8c721c0c207), QWord($eada7dd6cde0eb1e), QWord($f57d4f7fee6ed178),
    QWord($06f067aa72176fba), QWord($0a637dc5a2c898a6), QWord($113f9804bef90dae), QWord($1b710b35131c471b),
    QWord($28db77f523047d84), QWord($32caab7b40c72493), QWord($3c9ebe0a15c9bebc), QWord($431d67c49c100d4c),
    QWord($4cc5d4becb3e42b6), QWord($597f299cfc657e2a), QWord($5fcb6fab3ad6faec), QWord($6c44198c4a475817));

procedure Sha512Compress(var State: TSha512State; Block: PByte);
var
  Words: array[0..79] of QWord;
  Working: array[0..7] of QWord;
  Sigma0, Sigma1: QWord;
  Choice, Majority: QWord;
  First, Second: QWord;
  Round: Integer;
  Index: Integer;
begin
  for Round := 0 to 15 do
    Words[Round] := LoadBigEndian64(Block + Round * 8);
  for Round := 16 to 79 do
  begin
    Sigma0 := RotateRight64(Words[Round - 15], 1) xor RotateRight64(Words[Round - 15], 8) xor
      (Words[Round - 15] shr 7);
    Sigma1 := RotateRight64(Words[Round - 2], 19) xor RotateRight64(Words[Round - 2], 61) xor
      (Words[Round - 2] shr 6);
    Words[Round] := Words[Round - 16] + Sigma0 + Words[Round - 7] + Sigma1;
  end;
  for Index := 0 to 7 do
    Working[Index] := State[Index];
  for Round := 0 to 79 do
  begin
    Sigma1 := RotateRight64(Working[4], 14) xor RotateRight64(Working[4], 18) xor RotateRight64(Working[4], 41);
    Choice := (Working[4] and Working[5]) xor ((not Working[4]) and Working[6]);
    First := Working[7] + Sigma1 + Choice + Sha512Constants[Round] + Words[Round];
    Sigma0 := RotateRight64(Working[0], 28) xor RotateRight64(Working[0], 34) xor RotateRight64(Working[0], 39);
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
