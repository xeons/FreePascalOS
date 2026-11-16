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
  VP8's intra prediction (RFC 6386 section 12), on a work block whose
  lines are WorkStride bytes apart: the pixels above (and above to the
  right) and to the left of a block are at negative offsets from it.

  Luma is predicted as one 16x16 block (DC, vertical, horizontal or
  TrueMotion; DC has variants for the picture's top and left edges) or
  as sixteen 4x4 blocks with ten modes each; chroma as 8x8 blocks with
  the 16x16 modes.
}
unit Image.WebP.LossyPrediction;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Image.WebP.LossyTables;

const
  WorkStride = 32;
  WorkSize = WorkStride * 17 + WorkStride * 9;
  { Where the luma and the two chroma blocks start in the work block. }
  WorkLumaOffset = WorkStride + 8;
  WorkUOffset = WorkLumaOffset + WorkStride * 16 + WorkStride;
  WorkVOffset = WorkUOffset + 16;

procedure PredictLuma4(Mode: LongInt; Target: PByte);
{ Mode is one of the four 16x16 modes or a DC edge variant. }
procedure PredictLuma16(Mode: LongInt; Target: PByte);
procedure PredictChroma8(Mode: LongInt; Target: PByte);

implementation

function ClipByte(Value: LongInt): Byte; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

function Average3(First, Second, Third: LongInt): Byte; inline;
begin
  Result := (First + 2 * Second + Third + 2) shr 2;
end;

function Average2(First, Second: LongInt): Byte; inline;
begin
  Result := (First + Second + 1) shr 1;
end;

procedure FillBlock(Target: PByte; Size: LongInt; Value: Byte);
var
  Y: LongInt;
begin
  for Y := 0 to Size - 1 do
    FillChar(Target[Y * WorkStride], Size, Value);
end;

procedure TrueMotion(Target: PByte; Size: LongInt);
var
  X: LongInt;
  Y: LongInt;
  Top: PByte;
  TopLeft: LongInt;
begin
  Top := Target - WorkStride;
  TopLeft := Top[-1];
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
      Target[Y * WorkStride + X] := ClipByte(LongInt(Top[X]) + LongInt(Target[Y * WorkStride - 1]) - TopLeft);
end;

procedure Vertical(Target: PByte; Size: LongInt);
var
  Y: LongInt;
begin
  for Y := 0 to Size - 1 do
    Move(Target[-WorkStride], Target[Y * WorkStride], Size);
end;

procedure Horizontal(Target: PByte; Size: LongInt);
var
  Y: LongInt;
begin
  for Y := 0 to Size - 1 do
    FillChar(Target[Y * WorkStride], Size, Target[Y * WorkStride - 1]);
end;

{ DC from the Size pixels above and/or to the left; Shift divides the
  sum (with rounding) by how many there are. }
procedure DcPrediction(Target: PByte; Size: LongInt; UseTop, UseLeft: Boolean; Shift: LongInt);
var
  Sum: LongInt;
  Index: LongInt;
begin
  if not (UseTop or UseLeft) then
  begin
    FillBlock(Target, Size, $80);
    Exit;
  end;
  Sum := 1 shl (Shift - 1);
  for Index := 0 to Size - 1 do
  begin
    if UseTop then
      Inc(Sum, Target[Index - WorkStride]);
    if UseLeft then
      Inc(Sum, Target[Index * WorkStride - 1]);
  end;
  FillBlock(Target, Size, Sum shr Shift);
end;

procedure PredictLuma16(Mode: LongInt; Target: PByte);
begin
  case Mode of
    ModeDc: DcPrediction(Target, 16, True, True, 5);
    ModeTrueMotion: TrueMotion(Target, 16);
    ModeVertical: Vertical(Target, 16);
    ModeHorizontal: Horizontal(Target, 16);
    ModeDcNoTop: DcPrediction(Target, 16, False, True, 4);
    ModeDcNoLeft: DcPrediction(Target, 16, True, False, 4);
  else
    DcPrediction(Target, 16, False, False, 0);
  end;
end;

procedure PredictChroma8(Mode: LongInt; Target: PByte);
begin
  case Mode of
    ModeDc: DcPrediction(Target, 8, True, True, 4);
    ModeTrueMotion: TrueMotion(Target, 8);
    ModeVertical: Vertical(Target, 8);
    ModeHorizontal: Horizontal(Target, 8);
    ModeDcNoTop: DcPrediction(Target, 8, False, True, 3);
    ModeDcNoLeft: DcPrediction(Target, 8, True, False, 3);
  else
    DcPrediction(Target, 8, False, False, 0);
  end;
end;

{ --- 4x4 ------------------------------------------------------------ }

procedure Put(Target: PByte; X, Y: LongInt; Value: Byte); inline;
begin
  Target[X + Y * WorkStride] := Value;
end;

function Above(Target: PByte; X: LongInt): LongInt; inline;
begin
  Result := Target[X - WorkStride];
end;

function LeftOf(Target: PByte; Y: LongInt): LongInt; inline;
begin
  Result := Target[Y * WorkStride - 1];
end;

procedure VerticalSmoothed4(Target: PByte);
var
  Values: array[0..3] of Byte;
  X: LongInt;
  Y: LongInt;
begin
  for X := 0 to 3 do
    Values[X] := Average3(Above(Target, X - 1), Above(Target, X), Above(Target, X + 1));
  for Y := 0 to 3 do
    for X := 0 to 3 do
      Put(Target, X, Y, Values[X]);
end;

procedure HorizontalSmoothed4(Target: PByte);
var
  A, B, C, D, E: LongInt;
begin
  A := Target[-1 - WorkStride];
  B := LeftOf(Target, 0);
  C := LeftOf(Target, 1);
  D := LeftOf(Target, 2);
  E := LeftOf(Target, 3);
  FillChar(Target[0], 4, Average3(A, B, C));
  FillChar(Target[WorkStride], 4, Average3(B, C, D));
  FillChar(Target[2 * WorkStride], 4, Average3(C, D, E));
  FillChar(Target[3 * WorkStride], 4, Average3(D, E, E));
end;

procedure Dc4(Target: PByte);
var
  Sum: LongInt;
  Index: LongInt;
begin
  Sum := 4;
  for Index := 0 to 3 do
    Inc(Sum, Above(Target, Index) + LeftOf(Target, Index));
  FillBlock(Target, 4, Sum shr 3);
end;

procedure DownRight4(Target: PByte);
var
  I, J, K, L, X, A, B, C, D: LongInt;
begin
  I := LeftOf(Target, 0);
  J := LeftOf(Target, 1);
  K := LeftOf(Target, 2);
  L := LeftOf(Target, 3);
  X := Target[-1 - WorkStride];
  A := Above(Target, 0);
  B := Above(Target, 1);
  C := Above(Target, 2);
  D := Above(Target, 3);
  Put(Target, 0, 3, Average3(J, K, L));
  Put(Target, 1, 3, Average3(I, J, K));
  Put(Target, 0, 2, Average3(I, J, K));
  Put(Target, 2, 3, Average3(X, I, J));
  Put(Target, 1, 2, Average3(X, I, J));
  Put(Target, 0, 1, Average3(X, I, J));
  Put(Target, 3, 3, Average3(A, X, I));
  Put(Target, 2, 2, Average3(A, X, I));
  Put(Target, 1, 1, Average3(A, X, I));
  Put(Target, 0, 0, Average3(A, X, I));
  Put(Target, 3, 2, Average3(B, A, X));
  Put(Target, 2, 1, Average3(B, A, X));
  Put(Target, 1, 0, Average3(B, A, X));
  Put(Target, 3, 1, Average3(C, B, A));
  Put(Target, 2, 0, Average3(C, B, A));
  Put(Target, 3, 0, Average3(D, C, B));
end;

procedure DownLeft4(Target: PByte);
var
  A, B, C, D, E, F, G, H: LongInt;
begin
  A := Above(Target, 0);
  B := Above(Target, 1);
  C := Above(Target, 2);
  D := Above(Target, 3);
  E := Above(Target, 4);
  F := Above(Target, 5);
  G := Above(Target, 6);
  H := Above(Target, 7);
  Put(Target, 0, 0, Average3(A, B, C));
  Put(Target, 1, 0, Average3(B, C, D));
  Put(Target, 0, 1, Average3(B, C, D));
  Put(Target, 2, 0, Average3(C, D, E));
  Put(Target, 1, 1, Average3(C, D, E));
  Put(Target, 0, 2, Average3(C, D, E));
  Put(Target, 3, 0, Average3(D, E, F));
  Put(Target, 2, 1, Average3(D, E, F));
  Put(Target, 1, 2, Average3(D, E, F));
  Put(Target, 0, 3, Average3(D, E, F));
  Put(Target, 3, 1, Average3(E, F, G));
  Put(Target, 2, 2, Average3(E, F, G));
  Put(Target, 1, 3, Average3(E, F, G));
  Put(Target, 3, 2, Average3(F, G, H));
  Put(Target, 2, 3, Average3(F, G, H));
  Put(Target, 3, 3, Average3(G, H, H));
end;

procedure VerticalRight4(Target: PByte);
var
  I, J, K, X, A, B, C, D: LongInt;
begin
  I := LeftOf(Target, 0);
  J := LeftOf(Target, 1);
  K := LeftOf(Target, 2);
  X := Target[-1 - WorkStride];
  A := Above(Target, 0);
  B := Above(Target, 1);
  C := Above(Target, 2);
  D := Above(Target, 3);
  Put(Target, 0, 0, Average2(X, A));
  Put(Target, 1, 2, Average2(X, A));
  Put(Target, 1, 0, Average2(A, B));
  Put(Target, 2, 2, Average2(A, B));
  Put(Target, 2, 0, Average2(B, C));
  Put(Target, 3, 2, Average2(B, C));
  Put(Target, 3, 0, Average2(C, D));
  Put(Target, 0, 3, Average3(K, J, I));
  Put(Target, 0, 2, Average3(J, I, X));
  Put(Target, 0, 1, Average3(I, X, A));
  Put(Target, 1, 3, Average3(I, X, A));
  Put(Target, 1, 1, Average3(X, A, B));
  Put(Target, 2, 3, Average3(X, A, B));
  Put(Target, 2, 1, Average3(A, B, C));
  Put(Target, 3, 3, Average3(A, B, C));
  Put(Target, 3, 1, Average3(B, C, D));
end;

procedure VerticalLeft4(Target: PByte);
var
  A, B, C, D, E, F, G, H: LongInt;
begin
  A := Above(Target, 0);
  B := Above(Target, 1);
  C := Above(Target, 2);
  D := Above(Target, 3);
  E := Above(Target, 4);
  F := Above(Target, 5);
  G := Above(Target, 6);
  H := Above(Target, 7);
  Put(Target, 0, 0, Average2(A, B));
  Put(Target, 1, 0, Average2(B, C));
  Put(Target, 0, 2, Average2(B, C));
  Put(Target, 2, 0, Average2(C, D));
  Put(Target, 1, 2, Average2(C, D));
  Put(Target, 3, 0, Average2(D, E));
  Put(Target, 2, 2, Average2(D, E));
  Put(Target, 0, 1, Average3(A, B, C));
  Put(Target, 1, 1, Average3(B, C, D));
  Put(Target, 0, 3, Average3(B, C, D));
  Put(Target, 2, 1, Average3(C, D, E));
  Put(Target, 1, 3, Average3(C, D, E));
  Put(Target, 3, 1, Average3(D, E, F));
  Put(Target, 2, 3, Average3(D, E, F));
  Put(Target, 3, 2, Average3(E, F, G));
  Put(Target, 3, 3, Average3(F, G, H));
end;

procedure HorizontalUp4(Target: PByte);
var
  I, J, K, L: LongInt;
begin
  I := LeftOf(Target, 0);
  J := LeftOf(Target, 1);
  K := LeftOf(Target, 2);
  L := LeftOf(Target, 3);
  Put(Target, 0, 0, Average2(I, J));
  Put(Target, 2, 0, Average2(J, K));
  Put(Target, 0, 1, Average2(J, K));
  Put(Target, 2, 1, Average2(K, L));
  Put(Target, 0, 2, Average2(K, L));
  Put(Target, 1, 0, Average3(I, J, K));
  Put(Target, 3, 0, Average3(J, K, L));
  Put(Target, 1, 1, Average3(J, K, L));
  Put(Target, 3, 1, Average3(K, L, L));
  Put(Target, 1, 2, Average3(K, L, L));
  Put(Target, 3, 2, L);
  Put(Target, 2, 2, L);
  Put(Target, 0, 3, L);
  Put(Target, 1, 3, L);
  Put(Target, 2, 3, L);
  Put(Target, 3, 3, L);
end;

procedure HorizontalDown4(Target: PByte);
var
  I, J, K, L, X, A, B, C: LongInt;
begin
  I := LeftOf(Target, 0);
  J := LeftOf(Target, 1);
  K := LeftOf(Target, 2);
  L := LeftOf(Target, 3);
  X := Target[-1 - WorkStride];
  A := Above(Target, 0);
  B := Above(Target, 1);
  C := Above(Target, 2);
  Put(Target, 0, 0, Average2(I, X));
  Put(Target, 2, 1, Average2(I, X));
  Put(Target, 0, 1, Average2(J, I));
  Put(Target, 2, 2, Average2(J, I));
  Put(Target, 0, 2, Average2(K, J));
  Put(Target, 2, 3, Average2(K, J));
  Put(Target, 0, 3, Average2(L, K));
  Put(Target, 3, 0, Average3(A, B, C));
  Put(Target, 2, 0, Average3(X, A, B));
  Put(Target, 1, 0, Average3(I, X, A));
  Put(Target, 3, 1, Average3(I, X, A));
  Put(Target, 1, 1, Average3(J, I, X));
  Put(Target, 3, 2, Average3(J, I, X));
  Put(Target, 1, 2, Average3(K, J, I));
  Put(Target, 3, 3, Average3(K, J, I));
  Put(Target, 1, 3, Average3(L, K, J));
end;

procedure PredictLuma4(Mode: LongInt; Target: PByte);
begin
  case Mode of
    ModeDc: Dc4(Target);
    ModeTrueMotion: TrueMotion(Target, 4);
    ModeVertical: VerticalSmoothed4(Target);
    ModeHorizontal: HorizontalSmoothed4(Target);
    ModeDownRight: DownRight4(Target);
    ModeVerticalRight: VerticalRight4(Target);
    ModeDownLeft: DownLeft4(Target);
    ModeVerticalLeft: VerticalLeft4(Target);
    ModeHorizontalDown: HorizontalDown4(Target);
  else
    HorizontalUp4(Target);
  end;
end;

end.
