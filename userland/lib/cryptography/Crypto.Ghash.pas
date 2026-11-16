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
  GHASH, the universal hash of AES-GCM (NIST SP 800-38D, section 6.4):
  blocks are added into an accumulator that is multiplied by the hash
  key H in GF(2^128) after each one.

  The multiplication goes bit by bit with masks (SP 800-38D algorithm 1),
  with no tables and no branches on the data or the key, so it takes the
  same time whatever they are.
}
unit Crypto.Ghash;

{$mode objfpc}
{$pointermath on}

interface

type
  TGhashContext = record
    { H and the accumulator as big endian halves: High holds bits 0-63
      in GCM's numbering (bit 0 is the top bit of the first byte). }
    KeyHigh, KeyLow: QWord;
    AccumulatorHigh, AccumulatorLow: QWord;
    Pending: array[0..15] of Byte;
    PendingCount: Integer;
  end;

procedure BeginGhash(out Context: TGhashContext; HashKey: PByte);
procedure UpdateGhash(var Context: TGhashContext; Data: PByte; Count: QWord);
{ Fills a partly filled block with zeros and hashes it (GCM pads the
  additional data and the ciphertext each to a whole block). }
procedure PadGhash(var Context: TGhashContext);
{ Pads, writes the 16-byte result and wipes the context. }
procedure FinishGhash(var Context: TGhashContext; Output: PByte);

implementation

uses
  Crypto.Bits;

const
  { R = 11100001 || 0^120, the reduction of x^128 + x^7 + x^2 + x + 1
    in GCM's reflected bit order. }
  ReductionHigh = QWord($E100000000000000);

{ Accumulator := Accumulator * H. }
procedure MultiplyByKey(var Context: TGhashContext);
var
  ProductHigh, ProductLow: QWord;
  MultiplierHigh, MultiplierLow: QWord;
  BitMask: QWord;
  CarryMask: QWord;
  Bit: Integer;
begin
  ProductHigh := 0;
  ProductLow := 0;
  MultiplierHigh := Context.KeyHigh;
  MultiplierLow := Context.KeyLow;
  for Bit := 0 to 127 do
  begin
    if Bit < 64 then
      BitMask := QWord(0) - ((Context.AccumulatorHigh shr (63 - Bit)) and 1)
    else
      BitMask := QWord(0) - ((Context.AccumulatorLow shr (127 - Bit)) and 1);
    ProductHigh := ProductHigh xor (MultiplierHigh and BitMask);
    ProductLow := ProductLow xor (MultiplierLow and BitMask);
    { V := V * x: a right shift in this bit order, reduced when the bit
      shifted out was set. }
    CarryMask := QWord(0) - (MultiplierLow and 1);
    MultiplierLow := (MultiplierLow shr 1) or (MultiplierHigh shl 63);
    MultiplierHigh := (MultiplierHigh shr 1) xor (ReductionHigh and CarryMask);
  end;
  Context.AccumulatorHigh := ProductHigh;
  Context.AccumulatorLow := ProductLow;
end;

procedure HashBlock(var Context: TGhashContext; Block: PByte);
begin
  Context.AccumulatorHigh := Context.AccumulatorHigh xor LoadBigEndian64(Block);
  Context.AccumulatorLow := Context.AccumulatorLow xor LoadBigEndian64(Block + 8);
  MultiplyByKey(Context);
end;

procedure BeginGhash(out Context: TGhashContext; HashKey: PByte);
begin
  Context.KeyHigh := LoadBigEndian64(HashKey);
  Context.KeyLow := LoadBigEndian64(HashKey + 8);
  Context.AccumulatorHigh := 0;
  Context.AccumulatorLow := 0;
  Context.PendingCount := 0;
end;

procedure UpdateGhash(var Context: TGhashContext; Data: PByte; Count: QWord);
var
  Take: QWord;
begin
  if Context.PendingCount > 0 then
  begin
    Take := 16 - QWord(Context.PendingCount);
    if Take > Count then
      Take := Count;
    Move(Data^, Context.Pending[Context.PendingCount], Take);
    Context.PendingCount := Context.PendingCount + Integer(Take);
    Data := Data + Take;
    Count := Count - Take;
    if Context.PendingCount < 16 then
      Exit;
    HashBlock(Context, @Context.Pending[0]);
    Context.PendingCount := 0;
  end;
  while Count >= 16 do
  begin
    HashBlock(Context, Data);
    Data := Data + 16;
    Count := Count - 16;
  end;
  if Count > 0 then
  begin
    Move(Data^, Context.Pending[0], Count);
    Context.PendingCount := Integer(Count);
  end;
end;

procedure PadGhash(var Context: TGhashContext);
var
  Index: Integer;
begin
  if Context.PendingCount = 0 then
    Exit;
  for Index := Context.PendingCount to 15 do
    Context.Pending[Index] := 0;
  HashBlock(Context, @Context.Pending[0]);
  Context.PendingCount := 0;
end;

procedure FinishGhash(var Context: TGhashContext; Output: PByte);
begin
  PadGhash(Context);
  StoreBigEndian64(Output, Context.AccumulatorHigh);
  StoreBigEndian64(Output + 8, Context.AccumulatorLow);
  WipeMemory(@Context, SizeOf(Context));
end;

end.
