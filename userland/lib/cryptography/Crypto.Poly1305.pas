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
  The Poly1305 one-time authenticator (RFC 8439, section 2.5): a 32-byte
  one-time key turns a message into a 16-byte tag.

    BeginPoly1305(Context, Key);
    UpdatePoly1305(Context, Data, Count);   (any number of times)
    FinishPoly1305(Context, Tag);

  The accumulator is kept in five limbs of 26 bits, so every product
  fits in 64 bits; no step branches on or indexes by secret data, so the
  time taken does not depend on the key or the message.
}
unit Crypto.Poly1305;

{$mode objfpc}
{$pointermath on}

interface

const
  Poly1305KeySize = 32;
  Poly1305TagSize = 16;

type
  TPoly1305Context = record
    { The clamped multiplier r and the accumulator h, in 26-bit limbs. }
    Multiplier: array[0..4] of LongWord;
    Accumulator: array[0..4] of LongWord;
    { s, added at the end. }
    FinalAddend: array[0..3] of LongWord;
    Pending: array[0..15] of Byte;
    PendingCount: Integer;
  end;

procedure BeginPoly1305(out Context: TPoly1305Context; Key: PByte);
procedure UpdatePoly1305(var Context: TPoly1305Context; Data: PByte; Count: QWord);
{ Writes the 16-byte tag and wipes the context. }
procedure FinishPoly1305(var Context: TPoly1305Context; Tag: PByte);
procedure ComputePoly1305(Key: PByte; Data: PByte; Count: QWord; Tag: PByte);

implementation

uses
  Crypto.Bits;

const
  LimbMask = $3FFFFFF;

procedure BeginPoly1305(out Context: TPoly1305Context; Key: PByte);
var
  Index: Integer;
begin
  { r with the bits RFC 8439 clears ("clamping"). }
  Context.Multiplier[0] := LoadLittleEndian32(Key) and $3FFFFFF;
  Context.Multiplier[1] := (LoadLittleEndian32(Key + 3) shr 2) and $3FFFF03;
  Context.Multiplier[2] := (LoadLittleEndian32(Key + 6) shr 4) and $3FFC0FF;
  Context.Multiplier[3] := (LoadLittleEndian32(Key + 9) shr 6) and $3F03FFF;
  Context.Multiplier[4] := (LoadLittleEndian32(Key + 12) shr 8) and $00FFFFF;
  for Index := 0 to 4 do
    Context.Accumulator[Index] := 0;
  for Index := 0 to 3 do
    Context.FinalAddend[Index] := LoadLittleEndian32(Key + 16 + 4 * Index);
  Context.PendingCount := 0;
end;

{ h := (h + block) * r mod 2^130 - 5. HighBit is 2^24 in the top limb
  (the 2^128 every full block gets), or 0 for the padded last block,
  which carries its own 1 byte. }
procedure ProcessBlock(var Context: TPoly1305Context; Block: PByte; HighBit: LongWord);
var
  R0, R1, R2, R3, R4: QWord;
  S1, S2, S3, S4: QWord;
  H0, H1, H2, H3, H4: QWord;
  D0, D1, D2, D3, D4: QWord;
  Carry: QWord;
begin
  R0 := Context.Multiplier[0];
  R1 := Context.Multiplier[1];
  R2 := Context.Multiplier[2];
  R3 := Context.Multiplier[3];
  R4 := Context.Multiplier[4];
  { 2^130 = 5 (mod p): limbs that pass the top come back times 5. }
  S1 := R1 * 5;
  S2 := R2 * 5;
  S3 := R3 * 5;
  S4 := R4 * 5;

  H0 := QWord(Context.Accumulator[0]) + (LoadLittleEndian32(Block) and LimbMask);
  H1 := QWord(Context.Accumulator[1]) + ((LoadLittleEndian32(Block + 3) shr 2) and LimbMask);
  H2 := QWord(Context.Accumulator[2]) + ((LoadLittleEndian32(Block + 6) shr 4) and LimbMask);
  H3 := QWord(Context.Accumulator[3]) + ((LoadLittleEndian32(Block + 9) shr 6) and LimbMask);
  H4 := QWord(Context.Accumulator[4]) + ((LoadLittleEndian32(Block + 12) shr 8) or HighBit);

  D0 := H0 * R0 + H1 * S4 + H2 * S3 + H3 * S2 + H4 * S1;
  D1 := H0 * R1 + H1 * R0 + H2 * S4 + H3 * S3 + H4 * S2;
  D2 := H0 * R2 + H1 * R1 + H2 * R0 + H3 * S4 + H4 * S3;
  D3 := H0 * R3 + H1 * R2 + H2 * R1 + H3 * R0 + H4 * S4;
  D4 := H0 * R4 + H1 * R3 + H2 * R2 + H3 * R1 + H4 * R0;

  Carry := D0 shr 26;
  H0 := D0 and LimbMask;
  D1 := D1 + Carry;
  Carry := D1 shr 26;
  H1 := D1 and LimbMask;
  D2 := D2 + Carry;
  Carry := D2 shr 26;
  H2 := D2 and LimbMask;
  D3 := D3 + Carry;
  Carry := D3 shr 26;
  H3 := D3 and LimbMask;
  D4 := D4 + Carry;
  Carry := D4 shr 26;
  H4 := D4 and LimbMask;
  H0 := H0 + Carry * 5;
  Carry := H0 shr 26;
  H0 := H0 and LimbMask;
  H1 := H1 + Carry;

  Context.Accumulator[0] := LongWord(H0);
  Context.Accumulator[1] := LongWord(H1);
  Context.Accumulator[2] := LongWord(H2);
  Context.Accumulator[3] := LongWord(H3);
  Context.Accumulator[4] := LongWord(H4);
end;

procedure UpdatePoly1305(var Context: TPoly1305Context; Data: PByte; Count: QWord);
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
    ProcessBlock(Context, @Context.Pending[0], 1 shl 24);
    Context.PendingCount := 0;
  end;
  while Count >= 16 do
  begin
    ProcessBlock(Context, Data, 1 shl 24);
    Data := Data + 16;
    Count := Count - 16;
  end;
  if Count > 0 then
  begin
    Move(Data^, Context.Pending[0], Count);
    Context.PendingCount := Integer(Count);
  end;
end;

procedure FinishPoly1305(var Context: TPoly1305Context; Tag: PByte);
var
  H0, H1, H2, H3, H4: LongWord;
  G0, G1, G2, G3, G4: LongWord;
  Carry: LongWord;
  SelectMask: LongWord;
  Sum: QWord;
  Index: Integer;
begin
  if Context.PendingCount > 0 then
  begin
    Context.Pending[Context.PendingCount] := 1;
    for Index := Context.PendingCount + 1 to 15 do
      Context.Pending[Index] := 0;
    ProcessBlock(Context, @Context.Pending[0], 0);
  end;

  { Carry fully. }
  H0 := Context.Accumulator[0];
  H1 := Context.Accumulator[1];
  H2 := Context.Accumulator[2];
  H3 := Context.Accumulator[3];
  H4 := Context.Accumulator[4];
  Carry := H1 shr 26;
  H1 := H1 and LimbMask;
  H2 := H2 + Carry;
  Carry := H2 shr 26;
  H2 := H2 and LimbMask;
  H3 := H3 + Carry;
  Carry := H3 shr 26;
  H3 := H3 and LimbMask;
  H4 := H4 + Carry;
  Carry := H4 shr 26;
  H4 := H4 and LimbMask;
  H0 := H0 + Carry * 5;
  Carry := H0 shr 26;
  H0 := H0 and LimbMask;
  H1 := H1 + Carry;

  { g := h + 5 - 2^130; if that is not negative, h was at least p and
    g is h mod p. The choice is made by masks, not by a branch. }
  G0 := H0 + 5;
  Carry := G0 shr 26;
  G0 := G0 and LimbMask;
  G1 := H1 + Carry;
  Carry := G1 shr 26;
  G1 := G1 and LimbMask;
  G2 := H2 + Carry;
  Carry := G2 shr 26;
  G2 := G2 and LimbMask;
  G3 := H3 + Carry;
  Carry := G3 shr 26;
  G3 := G3 and LimbMask;
  G4 := LongWord(H4 + Carry - LongWord(1 shl 26));

  { All ones when g did not go negative (its top bit is clear). }
  SelectMask := LongWord((G4 shr 31) - 1);
  H0 := (H0 and not SelectMask) or (G0 and SelectMask);
  H1 := (H1 and not SelectMask) or (G1 and SelectMask);
  H2 := (H2 and not SelectMask) or (G2 and SelectMask);
  H3 := (H3 and not SelectMask) or (G3 and SelectMask);
  H4 := (H4 and not SelectMask) or (G4 and SelectMask);

  { h mod 2^128 as four 32-bit words, plus s. }
  H0 := H0 or (H1 shl 26);
  H1 := (H1 shr 6) or (H2 shl 20);
  H2 := (H2 shr 12) or (H3 shl 14);
  H3 := (H3 shr 18) or (H4 shl 8);

  Sum := QWord(H0) + Context.FinalAddend[0];
  StoreLittleEndian32(Tag, LongWord(Sum));
  Sum := QWord(H1) + Context.FinalAddend[1] + (Sum shr 32);
  StoreLittleEndian32(Tag + 4, LongWord(Sum));
  Sum := QWord(H2) + Context.FinalAddend[2] + (Sum shr 32);
  StoreLittleEndian32(Tag + 8, LongWord(Sum));
  Sum := QWord(H3) + Context.FinalAddend[3] + (Sum shr 32);
  StoreLittleEndian32(Tag + 12, LongWord(Sum));

  WipeMemory(@Context, SizeOf(Context));
end;

procedure ComputePoly1305(Key: PByte; Data: PByte; Count: QWord; Tag: PByte);
var
  Context: TPoly1305Context;
begin
  BeginPoly1305(Context, Key);
  UpdatePoly1305(Context, Data, Count);
  FinishPoly1305(Context, Tag);
end;

end.
