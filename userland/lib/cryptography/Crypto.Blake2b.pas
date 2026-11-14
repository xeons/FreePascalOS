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
  The BLAKE2b compression function (RFC 7693). Its initial vector is the
  SHA-512 initial state. Use Crypto.Digests for whole messages.
}
unit Crypto.Blake2b;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.Sha512;

type
  TBlake2bState = TSha512State;

{ The state for an unkeyed hash of OutputBytes (1..64) bytes. }
procedure Blake2bInitialize(out State: TBlake2bState; OutputBytes: Integer);

{ Mixes one 128-byte block into State. ByteCounter counts every message
  byte up to and including this block; IsLast marks the final block. }
procedure Blake2bCompress(var State: TBlake2bState; Block: PByte; ByteCounter: QWord; IsLast: Boolean);

implementation

uses
  Crypto.Bits;

const
  Blake2bSchedule: array[0..11, 0..15] of Byte = (
    (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15),
    (14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3),
    (11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4),
    (7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8),
    (9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13),
    (2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9),
    (12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11),
    (13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10),
    (6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5),
    (10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0),
    (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15),
    (14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3));

procedure Blake2bInitialize(out State: TBlake2bState; OutputBytes: Integer);
var
  Index: Integer;
begin
  for Index := 0 to 7 do
    State[Index] := Sha512InitialState[Index];
  { Parameter block word 0: digest length, key length 0, fanout 1, depth 1. }
  State[0] := State[0] xor $01010000 xor QWord(OutputBytes);
end;

procedure Mix(var Vector: array of QWord; A, B, C, D: Integer; X, Y: QWord);
begin
  Vector[A] := Vector[A] + Vector[B] + X;
  Vector[D] := RotateRight64(Vector[D] xor Vector[A], 32);
  Vector[C] := Vector[C] + Vector[D];
  Vector[B] := RotateRight64(Vector[B] xor Vector[C], 24);
  Vector[A] := Vector[A] + Vector[B] + Y;
  Vector[D] := RotateRight64(Vector[D] xor Vector[A], 16);
  Vector[C] := Vector[C] + Vector[D];
  Vector[B] := RotateRight64(Vector[B] xor Vector[C], 63);
end;

procedure Blake2bCompress(var State: TBlake2bState; Block: PByte; ByteCounter: QWord; IsLast: Boolean);
var
  Message: array[0..15] of QWord;
  Vector: array[0..15] of QWord;
  Round: Integer;
  Index: Integer;
begin
  for Index := 0 to 15 do
    Message[Index] := LoadLittleEndian64(Block + Index * 8);
  for Index := 0 to 7 do
  begin
    Vector[Index] := State[Index];
    Vector[Index + 8] := Sha512InitialState[Index];
  end;
  { The counter is 128 bits; its high half stays zero for any file
    smaller than 2^64 bytes. }
  Vector[12] := Vector[12] xor ByteCounter;
  if IsLast then
    Vector[14] := not Vector[14];

  for Round := 0 to 11 do
  begin
    Mix(Vector, 0, 4, 8, 12, Message[Blake2bSchedule[Round, 0]], Message[Blake2bSchedule[Round, 1]]);
    Mix(Vector, 1, 5, 9, 13, Message[Blake2bSchedule[Round, 2]], Message[Blake2bSchedule[Round, 3]]);
    Mix(Vector, 2, 6, 10, 14, Message[Blake2bSchedule[Round, 4]], Message[Blake2bSchedule[Round, 5]]);
    Mix(Vector, 3, 7, 11, 15, Message[Blake2bSchedule[Round, 6]], Message[Blake2bSchedule[Round, 7]]);
    Mix(Vector, 0, 5, 10, 15, Message[Blake2bSchedule[Round, 8]], Message[Blake2bSchedule[Round, 9]]);
    Mix(Vector, 1, 6, 11, 12, Message[Blake2bSchedule[Round, 10]], Message[Blake2bSchedule[Round, 11]]);
    Mix(Vector, 2, 7, 8, 13, Message[Blake2bSchedule[Round, 12]], Message[Blake2bSchedule[Round, 13]]);
    Mix(Vector, 3, 4, 9, 14, Message[Blake2bSchedule[Round, 14]], Message[Blake2bSchedule[Round, 15]]);
  end;
  for Index := 0 to 7 do
    State[Index] := State[Index] xor Vector[Index] xor Vector[Index + 8];
end;

end.
