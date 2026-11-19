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
  SHA-3 (FIPS 202): the Keccak-f[1600] permutation and the sponge built
  on it, giving SHA3-256 and SHA3-512 and the extendable output functions
  SHAKE128 and SHAKE256.

  A context absorbs any number of pieces of input; the first squeeze
  pads and ends absorbing, and successive squeezes continue the same
  output stream. Contexts hold secrets when what they absorb is secret,
  so the one-shot routines wipe theirs; callers of the incremental API
  wipe with WipeSha3.
}
unit Crypto.Sha3;

{$mode objfpc}
{$pointermath on}

interface

type
  TKeccakState = array[0..24] of QWord;

  TSha3Context = record
    State: TKeccakState;
    { Bytes of state absorbed or squeezed per permutation. }
    RateBytes: Integer;
    { Where the next byte goes in (or comes out of) the rate part. }
    Position: Integer;
    { The domain separation bits and first padding bit. }
    DomainByte: Byte;
    Squeezing: Boolean;
  end;

const
  Sha3_256DigestLength = 32;
  Sha3_512DigestLength = 64;

{ Applies the 24 rounds of Keccak-f[1600] to State. }
procedure KeccakPermute(var State: TKeccakState);

{ SHA3-224, -256, -384 or -512 by DigestBits. }
procedure BeginSha3(out Context: TSha3Context; DigestBits: Integer);
procedure AbsorbSha3(var Context: TSha3Context; Data: PByte; Count: PtrUInt);
{ Writes the DigestBits div 8 bytes of the digest and wipes Context. }
procedure FinishSha3(var Context: TSha3Context; Output: PByte; DigestBits: Integer);

{ SHAKE128 or SHAKE256 by SecurityBits (128 or 256). }
procedure BeginShake(out Context: TSha3Context; SecurityBits: Integer);
procedure AbsorbShake(var Context: TSha3Context; Data: PByte; Count: PtrUInt);
{ Writes the next OutputCount bytes of output; input can no longer be
  absorbed after the first call. }
procedure SqueezeShake(var Context: TSha3Context; Output: PByte; OutputCount: PtrUInt);

procedure WipeSha3(var Context: TSha3Context);

procedure Sha3_256(Data: PByte; Count: PtrUInt; Output: PByte);
procedure Sha3_512(Data: PByte; Count: PtrUInt; Output: PByte);
procedure Shake128(Data: PByte; Count: PtrUInt; Output: PByte; OutputCount: PtrUInt);
procedure Shake256(Data: PByte; Count: PtrUInt; Output: PByte; OutputCount: PtrUInt);

implementation

uses
  Crypto.Bits;

const
  KeccakRoundConstants: array[0..23] of QWord = (
    QWord($0000000000000001), QWord($0000000000008082), QWord($800000000000808A), QWord($8000000080008000),
    QWord($000000000000808B), QWord($0000000080000001), QWord($8000000080008081), QWord($8000000000008009),
    QWord($000000000000008A), QWord($0000000000000088), QWord($0000000080008009), QWord($000000008000000A),
    QWord($000000008000808B), QWord($800000000000008B), QWord($8000000000008089), QWord($8000000000008003),
    QWord($8000000000008002), QWord($8000000000000080), QWord($000000000000800A), QWord($800000008000000A),
    QWord($8000000080008081), QWord($8000000000008080), QWord($0000000080000001), QWord($8000000080008008));

  { The rho rotation of the lane at x + 5y. }
  KeccakRotations: array[0..24] of Byte = (
    0, 1, 62, 28, 27,
    36, 44, 6, 55, 20,
    3, 10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2, 61, 56, 14);

  Sha3DomainByte = $06;
  ShakeDomainByte = $1F;

procedure KeccakPermute(var State: TKeccakState);
var
  Columns: array[0..4] of QWord;
  Moved: TKeccakState;
  Round, X, Y: Integer;
  ColumnEffect: QWord;
begin
  for Round := 0 to 23 do
  begin
    { Theta: mix each column's parity into its neighbours. }
    for X := 0 to 4 do
      Columns[X] := State[X] xor State[X + 5] xor State[X + 10] xor State[X + 15] xor State[X + 20];
    for X := 0 to 4 do
    begin
      ColumnEffect := Columns[(X + 4) mod 5] xor RolQWord(Columns[(X + 1) mod 5], 1);
      for Y := 0 to 4 do
        State[X + 5 * Y] := State[X + 5 * Y] xor ColumnEffect;
    end;

    { Rho and pi: rotate each lane and move it to (y, 2x + 3y). }
    for Y := 0 to 4 do
      for X := 0 to 4 do
        Moved[Y + 5 * ((2 * X + 3 * Y) mod 5)] := RolQWord(State[X + 5 * Y], KeccakRotations[X + 5 * Y]);

    { Chi: the only non-linear step, along rows. }
    for Y := 0 to 4 do
      for X := 0 to 4 do
        State[X + 5 * Y] := Moved[X + 5 * Y] xor
          ((not Moved[(X + 1) mod 5 + 5 * Y]) and Moved[(X + 2) mod 5 + 5 * Y]);

    { Iota. }
    State[0] := State[0] xor KeccakRoundConstants[Round];
  end;
  WipeMemory(@Moved[0], SizeOf(Moved));
  WipeMemory(@Columns[0], SizeOf(Columns));
end;

procedure XorStateByte(var State: TKeccakState; Index: Integer; Value: Byte); inline;
begin
  State[Index shr 3] := State[Index shr 3] xor (QWord(Value) shl (8 * (Index and 7)));
end;

function StateByte(const State: TKeccakState; Index: Integer): Byte; inline;
begin
  Result := Byte(State[Index shr 3] shr (8 * (Index and 7)));
end;

procedure BeginSponge(out Context: TSha3Context; CapacityBytes: Integer; DomainByte: Byte);
begin
  FillChar(Context, SizeOf(Context), 0);
  Context.RateBytes := 200 - CapacityBytes;
  Context.DomainByte := DomainByte;
end;

procedure AbsorbSponge(var Context: TSha3Context; Data: PByte; Count: PtrUInt);
var
  Index: PtrUInt;
begin
  if Context.Squeezing then
    Exit;
  Index := 0;
  while Index < Count do
  begin
    { Whole lanes at a time when aligned. }
    if ((Context.Position and 7) = 0) and (Count - Index >= 8) then
    begin
      Context.State[Context.Position shr 3] := Context.State[Context.Position shr 3] xor
        LoadLittleEndian64(Data + Index);
      Inc(Context.Position, 8);
      Inc(Index, 8);
    end
    else
    begin
      XorStateByte(Context.State, Context.Position, Data[Index]);
      Inc(Context.Position);
      Inc(Index);
    end;
    if Context.Position = Context.RateBytes then
    begin
      KeccakPermute(Context.State);
      Context.Position := 0;
    end;
  end;
end;

procedure SqueezeSponge(var Context: TSha3Context; Output: PByte; OutputCount: PtrUInt);
var
  Index: PtrUInt;
begin
  if not Context.Squeezing then
  begin
    XorStateByte(Context.State, Context.Position, Context.DomainByte);
    XorStateByte(Context.State, Context.RateBytes - 1, $80);
    KeccakPermute(Context.State);
    Context.Position := 0;
    Context.Squeezing := True;
  end;
  Index := 0;
  while Index < OutputCount do
  begin
    if Context.Position = Context.RateBytes then
    begin
      KeccakPermute(Context.State);
      Context.Position := 0;
    end;
    Output[Index] := StateByte(Context.State, Context.Position);
    Inc(Context.Position);
    Inc(Index);
  end;
end;

procedure BeginSha3(out Context: TSha3Context; DigestBits: Integer);
begin
  BeginSponge(Context, 2 * (DigestBits div 8), Sha3DomainByte);
end;

procedure AbsorbSha3(var Context: TSha3Context; Data: PByte; Count: PtrUInt);
begin
  AbsorbSponge(Context, Data, Count);
end;

procedure FinishSha3(var Context: TSha3Context; Output: PByte; DigestBits: Integer);
begin
  SqueezeSponge(Context, Output, DigestBits div 8);
  WipeSha3(Context);
end;

procedure BeginShake(out Context: TSha3Context; SecurityBits: Integer);
begin
  BeginSponge(Context, 2 * (SecurityBits div 8), ShakeDomainByte);
end;

procedure AbsorbShake(var Context: TSha3Context; Data: PByte; Count: PtrUInt);
begin
  AbsorbSponge(Context, Data, Count);
end;

procedure SqueezeShake(var Context: TSha3Context; Output: PByte; OutputCount: PtrUInt);
begin
  SqueezeSponge(Context, Output, OutputCount);
end;

procedure WipeSha3(var Context: TSha3Context);
begin
  WipeMemory(@Context, SizeOf(Context));
end;

procedure Sha3_256(Data: PByte; Count: PtrUInt; Output: PByte);
var
  Context: TSha3Context;
begin
  BeginSha3(Context, 256);
  AbsorbSha3(Context, Data, Count);
  FinishSha3(Context, Output, 256);
end;

procedure Sha3_512(Data: PByte; Count: PtrUInt; Output: PByte);
var
  Context: TSha3Context;
begin
  BeginSha3(Context, 512);
  AbsorbSha3(Context, Data, Count);
  FinishSha3(Context, Output, 512);
end;

procedure Shake128(Data: PByte; Count: PtrUInt; Output: PByte; OutputCount: PtrUInt);
var
  Context: TSha3Context;
begin
  BeginShake(Context, 128);
  AbsorbShake(Context, Data, Count);
  SqueezeShake(Context, Output, OutputCount);
  WipeSha3(Context);
end;

procedure Shake256(Data: PByte; Count: PtrUInt; Output: PByte; OutputCount: PtrUInt);
var
  Context: TSha3Context;
begin
  BeginShake(Context, 256);
  AbsorbShake(Context, Data, Count);
  SqueezeShake(Context, Output, OutputCount);
  WipeSha3(Context);
end;

end.
