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
  The boolean entropy decoder of VP8 (RFC 6386 section 7) and VP9
  (section 9.2 of its specification): every bit comes with the
  probability, out of 256, that it is 0, which splits the range.

  The bits wait in a 64-bit window, most significant first, filled a
  byte at a time; past the end of the data the window fills with zeros
  and a large count marks it, so that HasError can tell when more bits
  were taken than there were (as the reference decoder counts it).
}
unit Video.BoolDecoder;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}
{$pointermath on}

interface

type
  TBoolDecoder = record
  private
    FValue: QWord;
    FCount: LongInt;
    FRange: LongWord;
    FBuffer: PByte;
    FBufferEnd: PByte;
    procedure Fill;
  public
    { Starts decoding Size bytes at Data (which stay the caller's). }
    procedure Init(Data: PByte; Size: PtrInt);
    function ReadBool(Probability: LongInt): LongInt; inline;
    { A bit of probability one half. }
    function ReadBit: LongInt; inline;
    { Count bits, most significant first. }
    function ReadLiteral(Count: LongInt): LongInt;
    { A value coded by Tree with the probabilities at Probabilities
      (one per pair of entries). }
    function ReadTree(Tree: PShortInt; Probabilities: PByte): LongInt;
    { More bits were taken than the data had. }
    function HasError: Boolean;
    { The first byte not yet taken into the window. }
    function Position: PByte;
    { Where the coded data ended: the bytes still in the window beyond
      what the decoding needed are given back (VP9 frames packed without
      a superframe index). }
    function FindEnd: PByte;
  end;

const
  { The shift that brings a range back to 128..255. }
  BoolNormalize: array[0..255] of Byte = (
    0, 7, 6, 6, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

implementation

const
  ValueBits = 64;
  { Added to the count once the data has run out. }
  LotsOfBits = $4000;

procedure TBoolDecoder.Init(Data: PByte; Size: PtrInt);
begin
  FBuffer := Data;
  FBufferEnd := Data + Size;
  FValue := 0;
  FCount := -8;
  FRange := 255;
  Fill;
end;

procedure TBoolDecoder.Fill;
var
  Shift: LongInt;
  BitsLeft: PtrInt;
  BitsOver: PtrInt;
  LoopEnd: PtrInt;
begin
  Shift := ValueBits - 8 - (FCount + 8);
  BitsLeft := (FBufferEnd - FBuffer) * 8;
  BitsOver := Shift + 8 - BitsLeft;
  LoopEnd := 0;
  if BitsOver >= 0 then
  begin
    { Not enough data for the window: the rest is zeros and the count
      says so. }
    Inc(FCount, LotsOfBits);
    LoopEnd := BitsOver;
  end;
  if (BitsOver < 0) or (BitsLeft > 0) then
    while Shift >= LoopEnd do
    begin
      Inc(FCount, 8);
      FValue := FValue or (QWord(FBuffer^) shl Shift);
      Inc(FBuffer);
      Dec(Shift, 8);
    end;
end;

function TBoolDecoder.ReadBool(Probability: LongInt): LongInt; inline;
var
  Split: LongWord;
  BigSplit: QWord;
  Shift: LongInt;
begin
  Split := (FRange * LongWord(Probability) + (256 - LongWord(Probability))) shr 8;
  if FCount < 0 then
    Fill;
  BigSplit := QWord(Split) shl (ValueBits - 8);
  if FValue >= BigSplit then
  begin
    FRange := FRange - Split;
    FValue := FValue - BigSplit;
    Result := 1;
  end
  else
  begin
    FRange := Split;
    Result := 0;
  end;
  Shift := BoolNormalize[FRange];
  FRange := FRange shl Shift;
  FValue := FValue shl Shift;
  Dec(FCount, Shift);
end;

function TBoolDecoder.ReadBit: LongInt; inline;
begin
  Result := ReadBool(128);
end;

function TBoolDecoder.ReadLiteral(Count: LongInt): LongInt;
begin
  Result := 0;
  while Count > 0 do
  begin
    Dec(Count);
    Result := Result or (ReadBool(128) shl Count);
  end;
end;

function TBoolDecoder.ReadTree(Tree: PShortInt; Probabilities: PByte): LongInt;
var
  Index: LongInt;
begin
  Index := 0;
  repeat
    Index := Tree[Index + ReadBool(Probabilities[Index shr 1])];
  until Index <= 0;
  Result := -Index;
end;

function TBoolDecoder.HasError: Boolean;
begin
  { The count goes past the window's size only when bits were taken
    from beyond the data. }
  Result := (FCount > ValueBits) and (FCount < LotsOfBits);
end;

function TBoolDecoder.Position: PByte;
begin
  Result := FBuffer;
end;

function TBoolDecoder.FindEnd: PByte;
var
  Count: LongInt;
begin
  Result := FBuffer;
  Count := FCount;
  while (Count > 8) and (Count < ValueBits) do
  begin
    Dec(Count, 8);
    Dec(Result);
  end;
end;

end.
