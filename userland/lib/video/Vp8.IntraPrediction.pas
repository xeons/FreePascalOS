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
  VP8 intra prediction (RFC 6386 section 12): a whole macroblock's luma
  (16x16) or chroma (8x8) from the row above and the column to the left,
  or each 4x4 luma block from its own neighbours.

  The neighbours are read straight from the picture being decoded, whose
  border holds 127 above the picture and 129 left of it.
}
unit Vp8.IntraPrediction;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

{ Predicts a Size x Size block (16 or 8) at Target with Mode (DC, V, H
  or TM); the row above is at Target - Stride, the column to the left
  at Target - 1. DC uses only the neighbours that are available. }
procedure PredictBlock(Mode: LongInt; Target: PByte; Stride, Size: LongInt;
  LeftAvailable, AboveAvailable: Boolean);
{ Predicts the 4x4 block at Target with a 4x4 mode: Above holds the
  pixel above-left (Above[-1]) and the 8 above and above-right. }
procedure PredictSubblock(Mode: LongInt; Target: PByte; Stride: LongInt;
  Above: PByte; Left: PByte);

implementation

uses
  Vp8.Tables;

function ClampPixel(Value: LongInt): Byte; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

procedure FillBlock(Target: PByte; Stride, Size: LongInt; Value: Byte);
var
  Row: LongInt;
begin
  for Row := 0 to Size - 1 do
    FillChar(Target[Row * Stride], Size, Value);
end;

procedure PredictBlock(Mode: LongInt; Target: PByte; Stride, Size: LongInt;
  LeftAvailable, AboveAvailable: Boolean);
var
  Above: PByte;
  Row, Column, Sum, Shift, TopLeft, Left: LongInt;
begin
  Above := Target - Stride;
  case Mode of
    ModeDc:
      begin
        Sum := 0;
        Shift := 0;
        if AboveAvailable then
        begin
          for Column := 0 to Size - 1 do
            Inc(Sum, Above[Column]);
          Inc(Shift);
        end;
        if LeftAvailable then
        begin
          for Row := 0 to Size - 1 do
            Inc(Sum, Target[Row * Stride - 1]);
          Inc(Shift);
        end;
        if Shift = 0 then
          FillBlock(Target, Stride, Size, 128)
        else
          FillBlock(Target, Stride, Size, (Sum + (Size * Shift) div 2) div (Size * Shift));
      end;
    ModeVertical:
      for Row := 0 to Size - 1 do
        Move(Above^, Target[Row * Stride], Size);
    ModeHorizontal:
      for Row := 0 to Size - 1 do
        FillChar(Target[Row * Stride], Size, Target[Row * Stride - 1]);
    ModeTrueMotion:
      begin
        TopLeft := Above[-1];
        for Row := 0 to Size - 1 do
        begin
          Left := Target[Row * Stride - 1] - TopLeft;
          for Column := 0 to Size - 1 do
            Target[Row * Stride + Column] := ClampPixel(Left + Above[Column]);
        end;
      end;
  end;
end;

function Average3(A, B, C: LongInt): Byte; inline;
begin
  Result := (A + 2 * B + C + 2) shr 2;
end;

function Average2(A, B: LongInt): Byte; inline;
begin
  Result := (A + B + 1) shr 1;
end;

procedure PredictSubblock(Mode: LongInt; Target: PByte; Stride: LongInt;
  Above: PByte; Left: PByte);
var
  P: array[0..15] of Byte;
  I, J, K, L, X, A, B, C, D, E, F, G, H: LongInt;
  Row, Column, Value: LongInt;

  procedure Put(Column, Row: LongInt; Value: Byte); inline;
  begin
    P[Row * 4 + Column] := Value;
  end;

begin
  I := Left[0];
  J := Left[1];
  K := Left[2];
  L := Left[3];
  X := Above[-1];
  A := Above[0];
  B := Above[1];
  C := Above[2];
  D := Above[3];
  E := Above[4];
  F := Above[5];
  G := Above[6];
  H := Above[7];
  case Mode of
    BlockModeDc:
      begin
        Value := (A + B + C + D + I + J + K + L + 4) shr 3;
        FillChar(P, 16, Value);
      end;
    BlockModeTrueMotion:
      for Row := 0 to 3 do
        for Column := 0 to 3 do
          Put(Column, Row, ClampPixel(LongInt(Left[Row]) + LongInt(Above[Column]) - X));
    BlockModeVertical:
      for Row := 0 to 3 do
      begin
        Put(0, Row, Average3(X, A, B));
        Put(1, Row, Average3(A, B, C));
        Put(2, Row, Average3(B, C, D));
        Put(3, Row, Average3(C, D, E));
      end;
    BlockModeHorizontal:
      begin
        FillChar(P[0], 4, Average3(X, I, J));
        FillChar(P[4], 4, Average3(I, J, K));
        FillChar(P[8], 4, Average3(J, K, L));
        FillChar(P[12], 4, Average3(K, L, L));
      end;
    BlockModeDownLeft:
      begin
        Put(0, 0, Average3(A, B, C));
        Value := Average3(B, C, D);
        Put(1, 0, Value); Put(0, 1, Value);
        Value := Average3(C, D, E);
        Put(2, 0, Value); Put(1, 1, Value); Put(0, 2, Value);
        Value := Average3(D, E, F);
        Put(3, 0, Value); Put(2, 1, Value); Put(1, 2, Value); Put(0, 3, Value);
        Value := Average3(E, F, G);
        Put(3, 1, Value); Put(2, 2, Value); Put(1, 3, Value);
        Value := Average3(F, G, H);
        Put(3, 2, Value); Put(2, 3, Value);
        Put(3, 3, Average3(G, H, H));
      end;
    BlockModeDownRight:
      begin
        Put(0, 3, Average3(J, K, L));
        Value := Average3(I, J, K);
        Put(1, 3, Value); Put(0, 2, Value);
        Value := Average3(X, I, J);
        Put(2, 3, Value); Put(1, 2, Value); Put(0, 1, Value);
        Value := Average3(A, X, I);
        Put(3, 3, Value); Put(2, 2, Value); Put(1, 1, Value); Put(0, 0, Value);
        Value := Average3(B, A, X);
        Put(3, 2, Value); Put(2, 1, Value); Put(1, 0, Value);
        Value := Average3(C, B, A);
        Put(3, 1, Value); Put(2, 0, Value);
        Put(3, 0, Average3(D, C, B));
      end;
    BlockModeVerticalRight:
      begin
        Value := Average2(X, A);
        Put(0, 0, Value); Put(1, 2, Value);
        Value := Average2(A, B);
        Put(1, 0, Value); Put(2, 2, Value);
        Value := Average2(B, C);
        Put(2, 0, Value); Put(3, 2, Value);
        Put(3, 0, Average2(C, D));
        Put(0, 3, Average3(K, J, I));
        Put(0, 2, Average3(J, I, X));
        Value := Average3(I, X, A);
        Put(0, 1, Value); Put(1, 3, Value);
        Value := Average3(X, A, B);
        Put(1, 1, Value); Put(2, 3, Value);
        Value := Average3(A, B, C);
        Put(2, 1, Value); Put(3, 3, Value);
        Put(3, 1, Average3(B, C, D));
      end;
    BlockModeVerticalLeft:
      begin
        Put(0, 0, Average2(A, B));
        Value := Average2(B, C);
        Put(1, 0, Value); Put(0, 2, Value);
        Value := Average2(C, D);
        Put(2, 0, Value); Put(1, 2, Value);
        Value := Average2(D, E);
        Put(3, 0, Value); Put(2, 2, Value);
        Put(3, 2, Average3(E, F, G));
        Put(0, 1, Average3(A, B, C));
        Value := Average3(B, C, D);
        Put(1, 1, Value); Put(0, 3, Value);
        Value := Average3(C, D, E);
        Put(2, 1, Value); Put(1, 3, Value);
        Value := Average3(D, E, F);
        Put(3, 1, Value); Put(2, 3, Value);
        Put(3, 3, Average3(F, G, H));
      end;
    BlockModeHorizontalDown:
      begin
        Value := Average2(I, X);
        Put(0, 0, Value); Put(2, 1, Value);
        Value := Average2(J, I);
        Put(0, 1, Value); Put(2, 2, Value);
        Value := Average2(K, J);
        Put(0, 2, Value); Put(2, 3, Value);
        Put(0, 3, Average2(L, K));
        Put(3, 0, Average3(A, B, C));
        Put(2, 0, Average3(X, A, B));
        Value := Average3(I, X, A);
        Put(1, 0, Value); Put(3, 1, Value);
        Value := Average3(J, I, X);
        Put(1, 1, Value); Put(3, 2, Value);
        Value := Average3(K, J, I);
        Put(1, 2, Value); Put(3, 3, Value);
        Put(1, 3, Average3(L, K, J));
      end;
    BlockModeHorizontalUp:
      begin
        Put(0, 0, Average2(I, J));
        Value := Average2(J, K);
        Put(2, 0, Value); Put(0, 1, Value);
        Value := Average2(K, L);
        Put(2, 1, Value); Put(0, 2, Value);
        Put(1, 0, Average3(I, J, K));
        Value := Average3(J, K, L);
        Put(3, 0, Value); Put(1, 1, Value);
        Value := Average3(K, L, L);
        Put(3, 1, Value); Put(1, 2, Value);
        Put(3, 2, L); Put(2, 2, L); Put(0, 3, L); Put(1, 3, L); Put(2, 3, L); Put(3, 3, L);
      end;
  end;
  for Row := 0 to 3 do
    Move(P[Row * 4], Target[Row * Stride], 4);
end;

end.
