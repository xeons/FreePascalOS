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
  VP8's DCT coefficient tokens (RFC 6386 section 13): per 4x4 block,
  the coefficients in zigzag order, each "end of block", zero or a
  value (1, 2, 3, 4, then categories with extra bits), coded with
  probabilities chosen by the block type, the coefficient's band and
  a context (how big the previous coefficient was, or for the first,
  whether the blocks above and to the left had any). Values come out
  multiplied by the quantiser step (DC or AC).
}
unit Image.WebP.LossyResiduals;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Image.WebP.BoolDecoder,
  Image.WebP.LossyTables,
  Image.WebP.LossyTransforms;

const
  { The block types of the coefficient probabilities. }
  BlockTypeLumaAc = 0;
  BlockTypeLumaDc = 1;
  BlockTypeChroma = 2;
  BlockTypeLumaWhole = 3;

{ Reads one block's coefficients from position First on into Output
  (16 coefficients, already zero), multiplied by Steps (DC, AC);
  Probabilities is the frame's coefficient table. The result is the
  position after the last coefficient read (First when there were
  none). }
function ReadCoefficients(Reader: TBoolDecoder; Probabilities: PByte; BlockType, Context: LongInt;
  constref Steps: TQuantSteps; First: LongInt; Output: PCoefficient): LongInt;

implementation

function ProbabilityOffset(BlockType, Position, Context: LongInt): LongInt; inline;
begin
  Result := ((BlockType * CoefficientBands + CoefficientBandOf[Position]) * CoefficientContexts + Context) *
    CoefficientProbabilityCount;
end;

function ReadCategoryBits(Reader: TBoolDecoder; const Probabilities: array of Byte): LongInt;
var
  Index: LongInt;
begin
  Result := 0;
  Index := 0;
  while Probabilities[Index] <> 0 do
  begin
    Result := Result + Result + Reader.ReadBit(Probabilities[Index]);
    Inc(Index);
  end;
end;

{ A coefficient of 2 or more; P are its probabilities. }
function ReadLargeValue(Reader: TBoolDecoder; P: PByte): LongInt;
var
  HighBit: LongInt;
  LowBit: LongInt;
  Category: LongInt;
begin
  if Reader.ReadBit(P[3]) = 0 then
  begin
    if Reader.ReadBit(P[4]) = 0 then
      Result := 2
    else
      Result := 3 + Reader.ReadBit(P[5]);
  end
  else if Reader.ReadBit(P[6]) = 0 then
  begin
    if Reader.ReadBit(P[7]) = 0 then
      Result := 5 + Reader.ReadBit(159)
    else
    begin
      Result := 7 + 2 * Reader.ReadBit(165);
      Result := Result + Reader.ReadBit(145);
    end;
  end
  else
  begin
    HighBit := Reader.ReadBit(P[8]);
    LowBit := Reader.ReadBit(P[9 + HighBit]);
    Category := 2 * HighBit + LowBit;
    case Category of
      0: Result := ReadCategoryBits(Reader, Category3Probabilities);
      1: Result := ReadCategoryBits(Reader, Category4Probabilities);
      2: Result := ReadCategoryBits(Reader, Category5Probabilities);
    else
      Result := ReadCategoryBits(Reader, Category6Probabilities);
    end;
    Result := Result + 3 + (8 shl Category);
  end;
end;

function ReadCoefficients(Reader: TBoolDecoder; Probabilities: PByte; BlockType, Context: LongInt;
  constref Steps: TQuantSteps; First: LongInt; Output: PCoefficient): LongInt;
var
  Position: LongInt;
  P: PByte;
  Value: LongInt;
  NextContext: LongInt;
  StepIndex: LongInt;
begin
  Position := First;
  P := Probabilities + ProbabilityOffset(BlockType, Position, Context);
  while Position < 16 do
  begin
    if Reader.ReadBit(P[0]) = 0 then
      Exit(Position);
    while Reader.ReadBit(P[1]) = 0 do
    begin
      Inc(Position);
      if Position = 16 then
        Exit(16);
      P := Probabilities + ProbabilityOffset(BlockType, Position, 0);
    end;
    if Reader.ReadBit(P[2]) = 0 then
    begin
      Value := 1;
      NextContext := 1;
    end
    else
    begin
      Value := ReadLargeValue(Reader, P);
      NextContext := 2;
    end;
    if Position > 0 then
      StepIndex := 1
    else
      StepIndex := 0;
    Output[ZigzagOrder[Position]] := SmallInt(Reader.ReadSigned(Value) * Steps[StepIndex]);
    Inc(Position);
    P := Probabilities + ProbabilityOffset(BlockType, Position, NextContext);
  end;
  Result := 16;
end;

end.
