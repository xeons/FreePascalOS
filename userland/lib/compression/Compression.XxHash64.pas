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
  XXH64 (github.com/Cyan4973/xxHash, the hash RFC 8878 checks a zstd
  frame's content with), fed in pieces of any size:

    XxHash64Start(State, 0);
    XxHash64Update(State, Data, Count);   ... as often as needed
    Hash := XxHash64Finish(State);

  The arithmetic wraps modulo 2^64 by design, so range and overflow
  checks are off in this unit.
}
unit Compression.XxHash64;

{$mode objfpc}
{$H+}
{$pointermath on}
{$rangechecks off}
{$overflowchecks off}

interface

type
  TXxHash64State = record
    Accumulators: array[0..3] of QWord;
    Seed: QWord;
    TotalLength: QWord;
    Buffer: array[0..31] of Byte;
    BufferCount: Integer;
  end;

procedure XxHash64Start(out State: TXxHash64State; Seed: QWord);
procedure XxHash64Update(var State: TXxHash64State; Data: PByte; Count: SizeUInt);
function XxHash64Finish(const State: TXxHash64State): QWord;
{ The hash of one buffer. }
function XxHash64(Data: PByte; Count: SizeUInt; Seed: QWord = 0): QWord;

implementation

const
  Prime1 = QWord($9E3779B185EBCA87);
  Prime2 = QWord($C2B2AE3D27D4EB4F);
  Prime3 = QWord($165667B19E3779F9);
  Prime4 = QWord($85EBCA77C2B2AE63);
  Prime5 = QWord($27D4EB2F165667C5);
  StripeSize = 32;

function ReadLittleEndian64(Data: PByte): QWord; inline;
begin
  Result := LEtoN(PQWord(Data)^);
end;

function ReadLittleEndian32(Data: PByte): LongWord; inline;
begin
  Result := LEtoN(PLongWord(Data)^);
end;

function AccumulateRound(Accumulator: QWord; Input: QWord): QWord; inline;
begin
  Accumulator := Accumulator + Input * Prime2;
  Accumulator := RolQWord(Accumulator, 31);
  Result := Accumulator * Prime1;
end;

function MergeRound(Accumulator: QWord; Value: QWord): QWord; inline;
begin
  Accumulator := Accumulator xor AccumulateRound(0, Value);
  Result := Accumulator * Prime1 + Prime4;
end;

procedure ConsumeStripes(var State: TXxHash64State; Data: PByte; Count: SizeUInt);
var
  Accumulator0, Accumulator1, Accumulator2, Accumulator3: QWord;
begin
  Accumulator0 := State.Accumulators[0];
  Accumulator1 := State.Accumulators[1];
  Accumulator2 := State.Accumulators[2];
  Accumulator3 := State.Accumulators[3];
  while Count >= StripeSize do
  begin
    Accumulator0 := AccumulateRound(Accumulator0, ReadLittleEndian64(Data));
    Accumulator1 := AccumulateRound(Accumulator1, ReadLittleEndian64(Data + 8));
    Accumulator2 := AccumulateRound(Accumulator2, ReadLittleEndian64(Data + 16));
    Accumulator3 := AccumulateRound(Accumulator3, ReadLittleEndian64(Data + 24));
    Inc(Data, StripeSize);
    Dec(Count, StripeSize);
  end;
  State.Accumulators[0] := Accumulator0;
  State.Accumulators[1] := Accumulator1;
  State.Accumulators[2] := Accumulator2;
  State.Accumulators[3] := Accumulator3;
end;

procedure XxHash64Start(out State: TXxHash64State; Seed: QWord);
begin
  State.Seed := Seed;
  State.Accumulators[0] := Seed + Prime1 + Prime2;
  State.Accumulators[1] := Seed + Prime2;
  State.Accumulators[2] := Seed;
  State.Accumulators[3] := Seed - Prime1;
  State.TotalLength := 0;
  State.BufferCount := 0;
end;

procedure XxHash64Update(var State: TXxHash64State; Data: PByte; Count: SizeUInt);
var
  Taken: SizeUInt;
  Whole: SizeUInt;
begin
  Inc(State.TotalLength, Count);
  if State.BufferCount > 0 then
  begin
    Taken := StripeSize - State.BufferCount;
    if Taken > Count then
      Taken := Count;
    Move(Data^, State.Buffer[State.BufferCount], Taken);
    Inc(State.BufferCount, Taken);
    Inc(Data, Taken);
    Dec(Count, Taken);
    if State.BufferCount < StripeSize then
      Exit;
    ConsumeStripes(State, @State.Buffer[0], StripeSize);
    State.BufferCount := 0;
  end;
  Whole := Count - Count mod StripeSize;
  if Whole > 0 then
  begin
    ConsumeStripes(State, Data, Whole);
    Inc(Data, Whole);
    Dec(Count, Whole);
  end;
  if Count > 0 then
  begin
    Move(Data^, State.Buffer[0], Count);
    State.BufferCount := Count;
  end;
end;

function XxHash64Finish(const State: TXxHash64State): QWord;
var
  Hash: QWord;
  Data: PByte;
  Remaining: Integer;
begin
  if State.TotalLength >= StripeSize then
  begin
    Hash := RolQWord(State.Accumulators[0], 1) + RolQWord(State.Accumulators[1], 7) +
      RolQWord(State.Accumulators[2], 12) + RolQWord(State.Accumulators[3], 18);
    Hash := MergeRound(Hash, State.Accumulators[0]);
    Hash := MergeRound(Hash, State.Accumulators[1]);
    Hash := MergeRound(Hash, State.Accumulators[2]);
    Hash := MergeRound(Hash, State.Accumulators[3]);
  end
  else
    Hash := State.Seed + Prime5;
  Hash := Hash + State.TotalLength;

  Data := @State.Buffer[0];
  Remaining := State.BufferCount;
  while Remaining >= 8 do
  begin
    Hash := Hash xor AccumulateRound(0, ReadLittleEndian64(Data));
    Hash := RolQWord(Hash, 27) * Prime1 + Prime4;
    Inc(Data, 8);
    Dec(Remaining, 8);
  end;
  if Remaining >= 4 then
  begin
    Hash := Hash xor (QWord(ReadLittleEndian32(Data)) * Prime1);
    Hash := RolQWord(Hash, 23) * Prime2 + Prime3;
    Inc(Data, 4);
    Dec(Remaining, 4);
  end;
  while Remaining > 0 do
  begin
    Hash := Hash xor (QWord(Data^) * Prime5);
    Hash := RolQWord(Hash, 11) * Prime1;
    Inc(Data);
    Dec(Remaining);
  end;

  Hash := Hash xor (Hash shr 33);
  Hash := Hash * Prime2;
  Hash := Hash xor (Hash shr 29);
  Hash := Hash * Prime3;
  Hash := Hash xor (Hash shr 32);
  Result := Hash;
end;

function XxHash64(Data: PByte; Count: SizeUInt; Seed: QWord): QWord;
var
  State: TXxHash64State;
begin
  XxHash64Start(State, Seed);
  XxHash64Update(State, Data, Count);
  Result := XxHash64Finish(State);
end;

end.
