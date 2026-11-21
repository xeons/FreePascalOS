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
  The ChaCha20 block function (RFC 8439, section 2.3): 64 bytes of key
  stream from a 256-bit key, a 32-bit block counter and a 96-bit nonce.
  Kernel.Random runs it as its generator. Plain Pascal with no kernel
  dependencies, so the host tests build it too (tools/AslrTest checks it
  against the RFC's test vector).
}
unit Kernel.ChaCha20;

{$mode objfpc}
{$rangechecks off}
{$overflowchecks off}

interface

const
  ChaChaKeyWords = 8;
  ChaChaNonceWords = 3;
  ChaChaBlockWords = 16;

type
  TChaChaKey = array[0..ChaChaKeyWords - 1] of LongWord;
  TChaChaNonce = array[0..ChaChaNonceWords - 1] of LongWord;
  TChaChaBlock = array[0..ChaChaBlockWords - 1] of LongWord;

{ The key stream block for Key, Counter and Nonce, as 16 little endian
  words (byte N of the stream is byte N mod 4 of word N div 4). }
procedure ChaChaBlock(constref Key: TChaChaKey; Counter: LongWord; constref Nonce: TChaChaNonce;
  out Block: TChaChaBlock);

implementation

const
  { "expand 32-byte k" }
  ChaChaConstant0 = $61707865;
  ChaChaConstant1 = $3320646E;
  ChaChaConstant2 = $79622D32;
  ChaChaConstant3 = $6B206574;
  DoubleRoundCount = 10;

function RotateLeft(Value: LongWord; Count: Integer): LongWord; inline;
begin
  Result := (Value shl Count) or (Value shr (32 - Count));
end;

procedure QuarterRound(var State: TChaChaBlock; A, B, C, D: Integer);
begin
  State[A] := State[A] + State[B];
  State[D] := RotateLeft(State[D] xor State[A], 16);
  State[C] := State[C] + State[D];
  State[B] := RotateLeft(State[B] xor State[C], 12);
  State[A] := State[A] + State[B];
  State[D] := RotateLeft(State[D] xor State[A], 8);
  State[C] := State[C] + State[D];
  State[B] := RotateLeft(State[B] xor State[C], 7);
end;

procedure ChaChaBlock(constref Key: TChaChaKey; Counter: LongWord; constref Nonce: TChaChaNonce;
  out Block: TChaChaBlock);
var
  Initial: TChaChaBlock;
  Index: Integer;
  Round: Integer;
begin
  Initial[0] := ChaChaConstant0;
  Initial[1] := ChaChaConstant1;
  Initial[2] := ChaChaConstant2;
  Initial[3] := ChaChaConstant3;
  for Index := 0 to ChaChaKeyWords - 1 do
    Initial[4 + Index] := Key[Index];
  Initial[12] := Counter;
  for Index := 0 to ChaChaNonceWords - 1 do
    Initial[13 + Index] := Nonce[Index];

  Block := Initial;
  for Round := 1 to DoubleRoundCount do
  begin
    QuarterRound(Block, 0, 4, 8, 12);
    QuarterRound(Block, 1, 5, 9, 13);
    QuarterRound(Block, 2, 6, 10, 14);
    QuarterRound(Block, 3, 7, 11, 15);
    QuarterRound(Block, 0, 5, 10, 15);
    QuarterRound(Block, 1, 6, 11, 12);
    QuarterRound(Block, 2, 7, 8, 13);
    QuarterRound(Block, 3, 4, 9, 14);
  end;
  for Index := 0 to ChaChaBlockWords - 1 do
    Block[Index] := Block[Index] + Initial[Index];
end;

end.
