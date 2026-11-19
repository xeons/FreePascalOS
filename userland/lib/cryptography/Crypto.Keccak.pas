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
  Keccak (FIPS 202): the Keccak-f[1600] permutation and the sponge over
  it, which make SHA3-256, SHA3-512, SHAKE128 and SHAKE256. ML-KEM
  (Crypto.MlKem) needs all four.

    BeginKeccak(State, Shake128Rate, ShakeSuffix);
    AbsorbKeccak(State, Data, Count);      (any number of times)
    SqueezeKeccak(State, Output, Count);   (any number of times: the
                                            extendable output functions)

  The rate is in bytes; the suffix is the domain separation bits with
  the first bit of the padding (06 for SHA-3, 1F for SHAKE).
}
unit Crypto.Keccak;

{$mode objfpc}
{$pointermath on}

interface

const
  Sha3_256Rate = 136;
  Sha3_512Rate = 72;
  Shake128Rate = 168;
  Shake256Rate = 136;
  Sha3Suffix = $06;
  ShakeSuffix = $1F;
  Sha3_256Size = 32;
  Sha3_512Size = 64;

type
  TKeccakLanes = array[0..24] of QWord;

  TKeccakState = record
    Lanes: TKeccakLanes;
    Rate: Integer;
    Suffix: Byte;
    { The byte of the rate the next byte is absorbed into or squeezed
      from. }
    Position: Integer;
    Squeezing: Boolean;
  end;

procedure KeccakPermute(var Lanes: TKeccakLanes);
procedure BeginKeccak(out State: TKeccakState; Rate: Integer; Suffix: Byte);
procedure AbsorbKeccak(var State: TKeccakState; Data: PByte; Count: QWord);
procedure SqueezeKeccak(var State: TKeccakState; Output: PByte; Count: QWord);
procedure WipeKeccak(var State: TKeccakState);

procedure ComputeSha3_256(Data: PByte; Count: QWord; Output: PByte);
procedure ComputeSha3_512(Data: PByte; Count: QWord; Output: PByte);
procedure ComputeShake128(Data: PByte; Count: QWord; Output: PByte; OutputCount: QWord);
procedure ComputeShake256(Data: PByte; Count: QWord; Output: PByte; OutputCount: QWord);

implementation

uses
  Crypto.Bits;

const
  RoundConstants: array[0..23] of QWord = (
    QWord($0000000000000001), QWord($0000000000008082), QWord($800000000000808A), QWord($8000000080008000),
    QWord($000000000000808B), QWord($0000000080000001), QWord($8000000080008081), QWord($8000000000008009),
    QWord($000000000000008A), QWord($0000000000000088), QWord($0000000080008009), QWord($000000008000000A),
    QWord($000000008000808B), QWord($800000000000008B), QWord($8000000000008089), QWord($8000000000008003),
    QWord($8000000000008002), QWord($8000000000000080), QWord($000000000000800A), QWord($800000008000000A),
    QWord($8000000080008081), QWord($8000000000008080), QWord($0000000080000001), QWord($8000000080008008));

  { Rho's rotation of each lane, by its index x + 5y. }
  RotationOffsets: array[0..24] of Byte = (
    0, 1, 62, 28, 27,
    36, 44, 6, 55, 20,
    3, 10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2, 61, 56, 14);

function RotateLeft64(Value: QWord; Count: Integer): QWord; inline;
begin
  if Count = 0 then
    Result := Value
  else
    Result := (Value shl Count) or (Value shr (64 - Count));
end;

procedure KeccakPermute(var Lanes: TKeccakLanes);
var
  Round, X, Y: Integer;
  Columns: array[0..4] of QWord;
  Moved: TKeccakLanes;
  Mixing: QWord;
begin
  for Round := 0 to 23 do
  begin
    { Theta. }
    for X := 0 to 4 do
      Columns[X] := Lanes[X] xor Lanes[X + 5] xor Lanes[X + 10] xor Lanes[X + 15] xor Lanes[X + 20];
    for X := 0 to 4 do
    begin
      Mixing := Columns[(X + 4) mod 5] xor RotateLeft64(Columns[(X + 1) mod 5], 1);
      for Y := 0 to 4 do
        Lanes[X + 5 * Y] := Lanes[X + 5 * Y] xor Mixing;
    end;
    { Rho and pi: lane (x, y) goes to (y, 2x + 3y). }
    for X := 0 to 4 do
      for Y := 0 to 4 do
        Moved[Y + 5 * ((2 * X + 3 * Y) mod 5)] := RotateLeft64(Lanes[X + 5 * Y], RotationOffsets[X + 5 * Y]);
    { Chi. }
    for Y := 0 to 4 do
      for X := 0 to 4 do
        Lanes[X + 5 * Y] := Moved[X + 5 * Y] xor
          ((not Moved[(X + 1) mod 5 + 5 * Y]) and Moved[(X + 2) mod 5 + 5 * Y]);
    { Iota. }
    Lanes[0] := Lanes[0] xor RoundConstants[Round];
  end;
end;

procedure XorByteIntoState(var State: TKeccakState; Index: Integer; Value: Byte); inline;
begin
  State.Lanes[Index div 8] := State.Lanes[Index div 8] xor (QWord(Value) shl (8 * (Index mod 8)));
end;

function StateByte(const State: TKeccakState; Index: Integer): Byte; inline;
begin
  Result := Byte(State.Lanes[Index div 8] shr (8 * (Index mod 8)));
end;

procedure BeginKeccak(out State: TKeccakState; Rate: Integer; Suffix: Byte);
begin
  FillChar(State, SizeOf(State), 0);
  State.Rate := Rate;
  State.Suffix := Suffix;
end;

procedure AbsorbKeccak(var State: TKeccakState; Data: PByte; Count: QWord);
var
  Index: QWord;
begin
  Index := 0;
  while Index < Count do
  begin
    XorByteIntoState(State, State.Position, Data[Index]);
    Inc(State.Position);
    if State.Position = State.Rate then
    begin
      KeccakPermute(State.Lanes);
      State.Position := 0;
    end;
    Inc(Index);
  end;
end;

{ The padding (pad10*1 after the suffix bits), then the first block of
  output. }
procedure FinishAbsorbing(var State: TKeccakState);
begin
  XorByteIntoState(State, State.Position, State.Suffix);
  XorByteIntoState(State, State.Rate - 1, $80);
  KeccakPermute(State.Lanes);
  State.Position := 0;
  State.Squeezing := True;
end;

procedure SqueezeKeccak(var State: TKeccakState; Output: PByte; Count: QWord);
var
  Index: QWord;
begin
  if not State.Squeezing then
    FinishAbsorbing(State);
  Index := 0;
  while Index < Count do
  begin
    if State.Position = State.Rate then
    begin
      KeccakPermute(State.Lanes);
      State.Position := 0;
    end;
    Output[Index] := StateByte(State, State.Position);
    Inc(State.Position);
    Inc(Index);
  end;
end;

procedure WipeKeccak(var State: TKeccakState);
begin
  WipeMemory(@State, SizeOf(State));
end;

procedure ComputeSponge(Rate: Integer; Suffix: Byte; Data: PByte; Count: QWord; Output: PByte;
  OutputCount: QWord);
var
  State: TKeccakState;
begin
  BeginKeccak(State, Rate, Suffix);
  AbsorbKeccak(State, Data, Count);
  SqueezeKeccak(State, Output, OutputCount);
  WipeKeccak(State);
end;

procedure ComputeSha3_256(Data: PByte; Count: QWord; Output: PByte);
begin
  ComputeSponge(Sha3_256Rate, Sha3Suffix, Data, Count, Output, Sha3_256Size);
end;

procedure ComputeSha3_512(Data: PByte; Count: QWord; Output: PByte);
begin
  ComputeSponge(Sha3_512Rate, Sha3Suffix, Data, Count, Output, Sha3_512Size);
end;

procedure ComputeShake128(Data: PByte; Count: QWord; Output: PByte; OutputCount: QWord);
begin
  ComputeSponge(Shake128Rate, ShakeSuffix, Data, Count, Output, OutputCount);
end;

procedure ComputeShake256(Data: PByte; Count: QWord; Output: PByte; OutputCount: QWord);
begin
  ComputeSponge(Shake256Rate, ShakeSuffix, Data, Count, Output, OutputCount);
end;

end.
