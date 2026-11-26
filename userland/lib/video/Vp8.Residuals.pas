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
  VP8 residual data (RFC 6386 section 13): the quantized coefficients of
  a macroblock's 25 blocks (16 luma, 4 + 4 chroma and, unless the luma
  is predicted 4x4 at a time, the second order block of the luma DCs),
  token by token, each block's first token in the context of whether
  the blocks above and to the left had any coefficients.
}
unit Vp8.Residuals;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Video.BoolDecoder;

const
  { Block numbers: 0..15 luma, 16..19 U, 20..23 V, 24 the second order
    block. }
  SecondOrderBlock = 24;

type
  TCoefficientProbabilities = array[0..3, 0..7, 0..2, 0..10] of Byte;

  { Whether the last blocks had coefficients: 4 luma columns or rows,
    2 U, 2 V and the second order block. }
  TEntropyContexts = array[0..8] of Byte;
  PEntropyContexts = ^TEntropyContexts;

  TMacroblockCoefficients = record
    Values: array[0..24, 0..15] of SmallInt;
    { One past the last coefficient's position in each block, and 1
      more for a luma block whose DC comes from the second order block
      (so that a value above 1 means a full transform is needed). }
    Ends: array[0..24] of Byte;
  end;

{ Reads a macroblock's coefficients into Coefficients (whose Values
  must be zero); HasSecondOrder when the luma DCs come from block 24.
  Returns the number of coefficients' positions taken (0: none at all). }
function ReadMacroblockCoefficients(var Decoder: TBoolDecoder;
  constref Probabilities: TCoefficientProbabilities; HasSecondOrder: Boolean;
  Above, Left: PEntropyContexts; var Coefficients: TMacroblockCoefficients): LongInt;

{ The contexts of a macroblock without coefficients. }
procedure ClearContexts(Above, Left: PEntropyContexts; HasSecondOrder: Boolean);

implementation

uses
  Vp8.Tables;

type
  PBandProbabilities = ^TBandProbabilities;
  TBandProbabilities = array[0..7, 0..2, 0..10] of Byte;

{ Reads one block's tokens from position First; returns one past the
  last coefficient's position, or 0 when there are none. }
function ReadBlock(var Decoder: TBoolDecoder; Bands: PBandProbabilities;
  Context, First: LongInt; Output: PSmallInt): LongInt;
var
  P: PByte;
  Position, Value, Bit1, Bit0, Category: LongInt;
  Table: PByte;
begin
  P := @Bands^[First, Context, 0];
  if Decoder.ReadBool(P[0]) = 0 then
    Exit(0);
  Position := First;
  while True do
  begin
    Inc(Position);
    if Decoder.ReadBool(P[1]) = 0 then
      P := @Bands^[CoefficientBands[Position], 0, 0]
    else
    begin
      if Decoder.ReadBool(P[2]) = 0 then
      begin
        P := @Bands^[CoefficientBands[Position], 1, 0];
        Value := 1;
      end
      else
      begin
        if Decoder.ReadBool(P[3]) = 0 then
        begin
          if Decoder.ReadBool(P[4]) = 0 then
            Value := 2
          else
            Value := 3 + Decoder.ReadBool(P[5]);
        end
        else if Decoder.ReadBool(P[6]) = 0 then
        begin
          if Decoder.ReadBool(P[7]) = 0 then
            Value := 5 + Decoder.ReadBool(159)
          else
          begin
            Value := 7 + 2 * Decoder.ReadBool(165);
            Inc(Value, Decoder.ReadBool(145));
          end;
        end
        else
        begin
          Bit1 := Decoder.ReadBool(P[8]);
          Bit0 := Decoder.ReadBool(P[9 + Bit1]);
          Category := 2 * Bit1 + Bit0;
          case Category of
            0: Table := @Category3[0];
            1: Table := @Category4[0];
            2: Table := @Category5[0];
          else
            Table := @Category6[0];
          end;
          Value := 0;
          while Table^ <> 0 do
          begin
            Value := Value + Value + Decoder.ReadBool(Table^);
            Inc(Table);
          end;
          Inc(Value, 3 + (8 shl Category));
        end;
        P := @Bands^[CoefficientBands[Position], 2, 0];
      end;
      if Decoder.ReadBit <> 0 then
        Value := -Value;
      Output[Zigzag[Position - 1]] := Value;
      if (Position = 16) or (Decoder.ReadBool(P[0]) = 0) then
        Exit(Position);
    end;
    if Position = 16 then
      Exit(16);
  end;
end;

function ReadMacroblockCoefficients(var Decoder: TBoolDecoder;
  constref Probabilities: TCoefficientProbabilities; HasSecondOrder: Boolean;
  Above, Left: PEntropyContexts; var Coefficients: TMacroblockCoefficients): LongInt;
var
  Bands: PBandProbabilities;
  Block, Count, First: LongInt;
  A, L: PByte;
begin
  Result := 0;
  if HasSecondOrder then
  begin
    A := @Above^[8];
    L := @Left^[8];
    Count := ReadBlock(Decoder, @Probabilities[BlockTypeY2], A^ + L^, 0,
      @Coefficients.Values[SecondOrderBlock, 0]);
    A^ := Ord(Count > 0);
    L^ := A^;
    Coefficients.Ends[SecondOrderBlock] := Count;
    Inc(Result, Count - 16);
    Bands := @Probabilities[BlockTypeYAfterY2];
    First := 1;
  end
  else
  begin
    Bands := @Probabilities[BlockTypeYWithDc];
    First := 0;
  end;
  for Block := 0 to 15 do
  begin
    A := @Above^[Block and 3];
    L := @Left^[Block shr 2];
    Count := ReadBlock(Decoder, Bands, A^ + L^, First, @Coefficients.Values[Block, 0]);
    A^ := Ord(Count > 0);
    L^ := A^;
    Inc(Count, First);
    Coefficients.Ends[Block] := Count;
    Inc(Result, Count);
  end;
  Bands := @Probabilities[BlockTypeChroma];
  for Block := 16 to 23 do
  begin
    A := @Above^[4 + Ord(Block > 19) * 2 + (Block and 1)];
    L := @Left^[4 + Ord(Block > 19) * 2 + Ord((Block and 3) > 1)];
    Count := ReadBlock(Decoder, Bands, A^ + L^, 0, @Coefficients.Values[Block, 0]);
    A^ := Ord(Count > 0);
    L^ := A^;
    Coefficients.Ends[Block] := Count;
    Inc(Result, Count);
  end;
end;

procedure ClearContexts(Above, Left: PEntropyContexts; HasSecondOrder: Boolean);
begin
  FillChar(Above^, 8, 0);
  FillChar(Left^, 8, 0);
  if HasSecondOrder then
  begin
    Above^[8] := 0;
    Left^[8] := 0;
  end;
end;

end.
