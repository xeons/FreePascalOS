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
  VP9 intra prediction (section 8.5.1 of the VP9 specification): a
  transform block predicted from the row above (and above-right) and
  the column to the left, in one of 10 modes.

  The edges come from the picture being decoded. Missing ones are made
  up: no row above gives (half the range) - 1, no column to the left
  (half the range) + 1, and past the right or bottom edge of the frame
  (rounded up to 8 pixels) the last pixel repeats. The block's own
  above-right pixels are used only by 4x4 blocks that are not on the
  right of their block, as the reference decoder (libvpx) does.
}
unit Vp9.IntraPrediction;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  TVp9IntraEdges = record
    { Where the block is and what is around it. }
    X, Y: LongInt;
    FrameWidth, FrameHeight: LongInt;
    HaveAbove, HaveLeft, HaveRight: Boolean;
    { The block reaches past the right or bottom edge of the frame
      (its macroblock does): the edges may need repeating. }
    PastRight, PastBottom: Boolean;
    BitDepth: LongInt;
  end;

{ Predicts the (4 << TransformSize) square block at Target (whose
  neighbours are read around it) with Mode. }
procedure PredictIntra(Mode, TransformSize: LongInt; Target: PWord; Stride: LongInt;
  constref Edges: TVp9IntraEdges);

implementation

uses
  Vp9.Tables;

const
  NeedLeft = 2;
  NeedAbove = 4;
  NeedAboveRight = 8;
  ExtendModes: array[0..9] of Byte = (
    NeedAbove or NeedLeft, NeedAbove, NeedLeft, NeedAboveRight, NeedLeft or NeedAbove,
    NeedLeft or NeedAbove, NeedLeft or NeedAbove, NeedLeft, NeedAboveRight, NeedLeft or NeedAbove);

function Avg2(A, B: LongInt): Word; inline;
begin
  Result := (A + B + 1) shr 1;
end;

function Avg3(A, B, C: LongInt): Word; inline;
begin
  Result := (A + 2 * B + C + 2) shr 2;
end;

procedure FillWords(Target: PWord; Count: LongInt; Value: Word); inline;
var
  Index: LongInt;
begin
  for Index := 0 to Count - 1 do
    Target[Index] := Value;
end;

procedure PredictDcValue(Target: PWord; Stride, Size: LongInt; Value: Word);
var
  Row: LongInt;
begin
  for Row := 0 to Size - 1 do
    FillWords(Target + Row * Stride, Size, Value);
end;

procedure PredictDc(Target: PWord; Stride, Size: LongInt; Above, Left: PWord; HaveAbove, HaveLeft: Boolean;
  BitDepth: LongInt);
var
  Sum, Index, Count: LongInt;
begin
  Sum := 0;
  Count := 0;
  if HaveAbove then
  begin
    for Index := 0 to Size - 1 do
      Inc(Sum, Above[Index]);
    Inc(Count, Size);
  end;
  if HaveLeft then
  begin
    for Index := 0 to Size - 1 do
      Inc(Sum, Left[Index]);
    Inc(Count, Size);
  end;
  if Count = 0 then
    PredictDcValue(Target, Stride, Size, 128 shl (BitDepth - 8))
  else
    PredictDcValue(Target, Stride, Size, (Sum + (Count shr 1)) div Count);
end;

procedure PredictVertical(Target: PWord; Stride, Size: LongInt; Above: PWord);
var
  Row: LongInt;
begin
  for Row := 0 to Size - 1 do
    Move(Above^, (Target + Row * Stride)^, Size * 2);
end;

procedure PredictHorizontal(Target: PWord; Stride, Size: LongInt; Left: PWord);
var
  Row: LongInt;
begin
  for Row := 0 to Size - 1 do
    FillWords(Target + Row * Stride, Size, Left[Row]);
end;

procedure PredictTrueMotion(Target: PWord; Stride, Size: LongInt; Above, Left: PWord; BitDepth: LongInt);
var
  Row, Column, Value, Maximum, TopLeft: LongInt;
begin
  Maximum := (1 shl BitDepth) - 1;
  TopLeft := Above[-1];
  for Row := 0 to Size - 1 do
    for Column := 0 to Size - 1 do
    begin
      Value := LongInt(Left[Row]) + LongInt(Above[Column]) - TopLeft;
      if Value < 0 then
        Value := 0
      else if Value > Maximum then
        Value := Maximum;
      Target[Row * Stride + Column] := Value;
    end;
end;

procedure PredictD207(Target: PWord; Stride, Size: LongInt; Left: PWord);
var
  Row, Column: LongInt;
  D: PWord;
begin
  D := Target;
  for Row := 0 to Size - 2 do
    D[Row * Stride] := Avg2(Left[Row], Left[Row + 1]);
  D[(Size - 1) * Stride] := Left[Size - 1];
  Inc(D);
  for Row := 0 to Size - 3 do
    D[Row * Stride] := Avg3(Left[Row], Left[Row + 1], Left[Row + 2]);
  D[(Size - 2) * Stride] := Avg3(Left[Size - 2], Left[Size - 1], Left[Size - 1]);
  D[(Size - 1) * Stride] := Left[Size - 1];
  Inc(D);
  for Column := 0 to Size - 3 do
    D[(Size - 1) * Stride + Column] := Left[Size - 1];
  for Row := Size - 2 downto 0 do
    for Column := 0 to Size - 3 do
      D[Row * Stride + Column] := D[(Row + 1) * Stride + Column - 2];
end;

procedure PredictD63(Target: PWord; Stride, Size: LongInt; Above: PWord);
var
  Row, Column, Count: LongInt;
begin
  for Column := 0 to Size - 1 do
  begin
    Target[Column] := Avg2(Above[Column], Above[Column + 1]);
    Target[Stride + Column] := Avg3(Above[Column], Above[Column + 1], Above[Column + 2]);
  end;
  Row := 2;
  Count := Size - 2;
  while Row < Size do
  begin
    Move(Target[Row shr 1], Target[Row * Stride], Count * 2);
    FillWords(Target + Row * Stride + Count, Size - Count, Above[Size - 1]);
    Move(Target[Stride + (Row shr 1)], Target[(Row + 1) * Stride], Count * 2);
    FillWords(Target + (Row + 1) * Stride + Count, Size - Count, Above[Size - 1]);
    Inc(Row, 2);
    Dec(Count);
  end;
end;

procedure PredictD45(Target: PWord; Stride, Size: LongInt; Above: PWord);
var
  X, Count: LongInt;
  AboveRight: Word;
  Row: PWord;
begin
  AboveRight := Above[Size - 1];
  for X := 0 to Size - 2 do
    Target[X] := Avg3(Above[X], Above[X + 1], Above[X + 2]);
  Target[Size - 1] := AboveRight;
  Row := Target + Stride;
  Count := Size - 2;
  for X := 1 to Size - 1 do
  begin
    Move(Target[X], Row^, Count * 2);
    FillWords(Row + Count, X + 1, AboveRight);
    Inc(Row, Stride);
    Dec(Count);
  end;
end;

procedure PredictD117(Target: PWord; Stride, Size: LongInt; Above, Left: PWord);
var
  Row, Column: LongInt;
  D: PWord;
begin
  D := Target;
  for Column := 0 to Size - 1 do
    D[Column] := Avg2(Above[Column - 1], Above[Column]);
  Inc(D, Stride);
  D[0] := Avg3(Left[0], Above[-1], Above[0]);
  for Column := 1 to Size - 1 do
    D[Column] := Avg3(Above[Column - 2], Above[Column - 1], Above[Column]);
  Inc(D, Stride);
  D[0] := Avg3(Above[-1], Left[0], Left[1]);
  for Row := 3 to Size - 1 do
    D[(Row - 2) * Stride] := Avg3(Left[Row - 3], Left[Row - 2], Left[Row - 1]);
  for Row := 2 to Size - 1 do
  begin
    for Column := 1 to Size - 1 do
      D[Column] := D[-2 * Stride + Column - 1];
    Inc(D, Stride);
  end;
end;

procedure PredictD135(Target: PWord; Stride, Size: LongInt; Above, Left: PWord);
var
  Border: array[0..63] of Word;
  Index: LongInt;
begin
  for Index := 0 to Size - 3 do
    Border[Index] := Avg3(Left[Size - 3 - Index], Left[Size - 2 - Index], Left[Size - 1 - Index]);
  Border[Size - 2] := Avg3(Above[-1], Left[0], Left[1]);
  Border[Size - 1] := Avg3(Left[0], Above[-1], Above[0]);
  Border[Size] := Avg3(Above[-1], Above[0], Above[1]);
  for Index := 0 to Size - 3 do
    Border[Size + 1 + Index] := Avg3(Above[Index], Above[Index + 1], Above[Index + 2]);
  for Index := 0 to Size - 1 do
    Move(Border[Size - 1 - Index], Target[Index * Stride], Size * 2);
end;

procedure PredictD153(Target: PWord; Stride, Size: LongInt; Above, Left: PWord);
var
  Row, Column: LongInt;
  D: PWord;
begin
  D := Target;
  D[0] := Avg2(Above[-1], Left[0]);
  for Row := 1 to Size - 1 do
    D[Row * Stride] := Avg2(Left[Row - 1], Left[Row]);
  Inc(D);
  D[0] := Avg3(Left[0], Above[-1], Above[0]);
  D[Stride] := Avg3(Above[-1], Left[0], Left[1]);
  for Row := 2 to Size - 1 do
    D[Row * Stride] := Avg3(Left[Row - 2], Left[Row - 1], Left[Row]);
  Inc(D);
  for Column := 0 to Size - 3 do
    D[Column] := Avg3(Above[Column - 1], Above[Column], Above[Column + 1]);
  Inc(D, Stride);
  for Row := 1 to Size - 1 do
  begin
    for Column := 0 to Size - 3 do
      D[Column] := D[-Stride + Column - 2];
    Inc(D, Stride);
  end;
end;

{ The 4x4 versions of the directional modes, which differ from the
  larger ones at the edges. }
procedure Put(Target: PWord; Stride, X, Y: LongInt; Value: Word); inline;
begin
  Target[Y * Stride + X] := Value;
end;

procedure PredictD207Small(T: PWord; S: LongInt; Left: PWord);
var
  I, J, K, L: LongInt;
begin
  I := Left[0]; J := Left[1]; K := Left[2]; L := Left[3];
  Put(T, S, 0, 0, Avg2(I, J));
  Put(T, S, 2, 0, Avg2(J, K)); Put(T, S, 0, 1, Avg2(J, K));
  Put(T, S, 2, 1, Avg2(K, L)); Put(T, S, 0, 2, Avg2(K, L));
  Put(T, S, 1, 0, Avg3(I, J, K));
  Put(T, S, 3, 0, Avg3(J, K, L)); Put(T, S, 1, 1, Avg3(J, K, L));
  Put(T, S, 3, 1, Avg3(K, L, L)); Put(T, S, 1, 2, Avg3(K, L, L));
  Put(T, S, 3, 2, L); Put(T, S, 2, 2, L); Put(T, S, 0, 3, L);
  Put(T, S, 1, 3, L); Put(T, S, 2, 3, L); Put(T, S, 3, 3, L);
end;

procedure PredictD63Small(T: PWord; S: LongInt; Above: PWord);
var
  A, B, C, D, E, F, G: LongInt;
begin
  A := Above[0]; B := Above[1]; C := Above[2]; D := Above[3];
  E := Above[4]; F := Above[5]; G := Above[6];
  Put(T, S, 0, 0, Avg2(A, B));
  Put(T, S, 1, 0, Avg2(B, C)); Put(T, S, 0, 2, Avg2(B, C));
  Put(T, S, 2, 0, Avg2(C, D)); Put(T, S, 1, 2, Avg2(C, D));
  Put(T, S, 3, 0, Avg2(D, E)); Put(T, S, 2, 2, Avg2(D, E));
  Put(T, S, 3, 2, Avg2(E, F));
  Put(T, S, 0, 1, Avg3(A, B, C));
  Put(T, S, 1, 1, Avg3(B, C, D)); Put(T, S, 0, 3, Avg3(B, C, D));
  Put(T, S, 2, 1, Avg3(C, D, E)); Put(T, S, 1, 3, Avg3(C, D, E));
  Put(T, S, 3, 1, Avg3(D, E, F)); Put(T, S, 2, 3, Avg3(D, E, F));
  Put(T, S, 3, 3, Avg3(E, F, G));
end;

procedure PredictD45Small(T: PWord; S: LongInt; Above: PWord);
var
  A, B, C, D, E, F, G, H: LongInt;
begin
  A := Above[0]; B := Above[1]; C := Above[2]; D := Above[3];
  E := Above[4]; F := Above[5]; G := Above[6]; H := Above[7];
  Put(T, S, 0, 0, Avg3(A, B, C));
  Put(T, S, 1, 0, Avg3(B, C, D)); Put(T, S, 0, 1, Avg3(B, C, D));
  Put(T, S, 2, 0, Avg3(C, D, E)); Put(T, S, 1, 1, Avg3(C, D, E)); Put(T, S, 0, 2, Avg3(C, D, E));
  Put(T, S, 3, 0, Avg3(D, E, F)); Put(T, S, 2, 1, Avg3(D, E, F));
  Put(T, S, 1, 2, Avg3(D, E, F)); Put(T, S, 0, 3, Avg3(D, E, F));
  Put(T, S, 3, 1, Avg3(E, F, G)); Put(T, S, 2, 2, Avg3(E, F, G)); Put(T, S, 1, 3, Avg3(E, F, G));
  Put(T, S, 3, 2, Avg3(F, G, H)); Put(T, S, 2, 3, Avg3(F, G, H));
  Put(T, S, 3, 3, H);
end;

procedure PredictD117Small(T: PWord; S: LongInt; Above, Left: PWord);
var
  I, J, K, X, A, B, C, D: LongInt;
begin
  I := Left[0]; J := Left[1]; K := Left[2];
  X := Above[-1]; A := Above[0]; B := Above[1]; C := Above[2]; D := Above[3];
  Put(T, S, 0, 0, Avg2(X, A)); Put(T, S, 1, 2, Avg2(X, A));
  Put(T, S, 1, 0, Avg2(A, B)); Put(T, S, 2, 2, Avg2(A, B));
  Put(T, S, 2, 0, Avg2(B, C)); Put(T, S, 3, 2, Avg2(B, C));
  Put(T, S, 3, 0, Avg2(C, D));
  Put(T, S, 0, 3, Avg3(K, J, I));
  Put(T, S, 0, 2, Avg3(J, I, X));
  Put(T, S, 0, 1, Avg3(I, X, A)); Put(T, S, 1, 3, Avg3(I, X, A));
  Put(T, S, 1, 1, Avg3(X, A, B)); Put(T, S, 2, 3, Avg3(X, A, B));
  Put(T, S, 2, 1, Avg3(A, B, C)); Put(T, S, 3, 3, Avg3(A, B, C));
  Put(T, S, 3, 1, Avg3(B, C, D));
end;

procedure PredictD135Small(T: PWord; S: LongInt; Above, Left: PWord);
var
  I, J, K, L, X, A, B, C, D: LongInt;
begin
  I := Left[0]; J := Left[1]; K := Left[2]; L := Left[3];
  X := Above[-1]; A := Above[0]; B := Above[1]; C := Above[2]; D := Above[3];
  Put(T, S, 0, 3, Avg3(J, K, L));
  Put(T, S, 1, 3, Avg3(I, J, K)); Put(T, S, 0, 2, Avg3(I, J, K));
  Put(T, S, 2, 3, Avg3(X, I, J)); Put(T, S, 1, 2, Avg3(X, I, J)); Put(T, S, 0, 1, Avg3(X, I, J));
  Put(T, S, 3, 3, Avg3(A, X, I)); Put(T, S, 2, 2, Avg3(A, X, I));
  Put(T, S, 1, 1, Avg3(A, X, I)); Put(T, S, 0, 0, Avg3(A, X, I));
  Put(T, S, 3, 2, Avg3(B, A, X)); Put(T, S, 2, 1, Avg3(B, A, X)); Put(T, S, 1, 0, Avg3(B, A, X));
  Put(T, S, 3, 1, Avg3(C, B, A)); Put(T, S, 2, 0, Avg3(C, B, A));
  Put(T, S, 3, 0, Avg3(D, C, B));
end;

procedure PredictD153Small(T: PWord; S: LongInt; Above, Left: PWord);
var
  I, J, K, L, X, A, B, C: LongInt;
begin
  I := Left[0]; J := Left[1]; K := Left[2]; L := Left[3];
  X := Above[-1]; A := Above[0]; B := Above[1]; C := Above[2];
  Put(T, S, 0, 0, Avg2(I, X)); Put(T, S, 2, 1, Avg2(I, X));
  Put(T, S, 0, 1, Avg2(J, I)); Put(T, S, 2, 2, Avg2(J, I));
  Put(T, S, 0, 2, Avg2(K, J)); Put(T, S, 2, 3, Avg2(K, J));
  Put(T, S, 0, 3, Avg2(L, K));
  Put(T, S, 3, 0, Avg3(A, B, C));
  Put(T, S, 2, 0, Avg3(X, A, B));
  Put(T, S, 1, 0, Avg3(I, X, A)); Put(T, S, 3, 1, Avg3(I, X, A));
  Put(T, S, 1, 1, Avg3(J, I, X)); Put(T, S, 3, 2, Avg3(J, I, X));
  Put(T, S, 1, 2, Avg3(K, J, I)); Put(T, S, 3, 3, Avg3(K, J, I));
  Put(T, S, 1, 3, Avg3(L, K, J));
end;

procedure PredictIntra(Mode, TransformSize: LongInt; Target: PWord; Stride: LongInt;
  constref Edges: TVp9IntraEdges);
var
  Size, Index, Base, Remaining, ExtendBottom: LongInt;
  LeftColumn: array[0..31] of Word;
  AboveData: array[0..63 + 16] of Word;
  AboveRow, AboveSource: PWord;
  Needs: Byte;
begin
  Size := 4 shl TransformSize;
  Base := 128 shl (Edges.BitDepth - 8);
  AboveRow := @AboveData[16];
  Needs := ExtendModes[Mode];
  if (Needs and NeedLeft) <> 0 then
  begin
    if Edges.HaveLeft then
    begin
      if Edges.PastBottom and (Edges.Y + Size > Edges.FrameHeight) then
      begin
        ExtendBottom := Edges.FrameHeight - Edges.Y;
        for Index := 0 to ExtendBottom - 1 do
          LeftColumn[Index] := Target[Index * Stride - 1];
        for Index := ExtendBottom to Size - 1 do
          LeftColumn[Index] := Target[(ExtendBottom - 1) * Stride - 1];
      end
      else
        for Index := 0 to Size - 1 do
          LeftColumn[Index] := Target[Index * Stride - 1];
    end
    else
      FillWords(@LeftColumn[0], Size, Base + 1);
  end;
  if (Needs and NeedAbove) <> 0 then
  begin
    if Edges.HaveAbove then
    begin
      AboveSource := Target - Stride;
      if Edges.PastRight and (Edges.X + Size > Edges.FrameWidth) then
      begin
        Remaining := Edges.FrameWidth - Edges.X;
        Move(AboveSource^, AboveRow^, Remaining * 2);
        FillWords(AboveRow + Remaining, Edges.X + Size - Edges.FrameWidth, AboveRow[Remaining - 1]);
      end
      else
        Move(AboveSource^, AboveRow^, Size * 2);
      if Edges.HaveLeft then
        AboveRow[-1] := AboveSource[-1]
      else
        AboveRow[-1] := Base + 1;
    end
    else
    begin
      FillWords(AboveRow, Size, Base - 1);
      AboveRow[-1] := Base - 1;
    end;
  end;
  if (Needs and NeedAboveRight) <> 0 then
  begin
    if Edges.HaveAbove then
    begin
      AboveSource := Target - Stride;
      if Edges.PastRight then
      begin
        if Edges.X + 2 * Size <= Edges.FrameWidth then
        begin
          if Edges.HaveRight and (Size = 4) then
            Move(AboveSource^, AboveRow^, 2 * Size * 2)
          else
          begin
            Move(AboveSource^, AboveRow^, Size * 2);
            FillWords(AboveRow + Size, Size, AboveRow[Size - 1]);
          end;
        end
        else if Edges.X + Size <= Edges.FrameWidth then
        begin
          Remaining := Edges.FrameWidth - Edges.X;
          if Edges.HaveRight and (Size = 4) then
          begin
            Move(AboveSource^, AboveRow^, Remaining * 2);
            FillWords(AboveRow + Remaining, Edges.X + 2 * Size - Edges.FrameWidth, AboveRow[Remaining - 1]);
          end
          else
          begin
            Move(AboveSource^, AboveRow^, Size * 2);
            FillWords(AboveRow + Size, Size, AboveRow[Size - 1]);
          end;
        end
        else
        begin
          Remaining := Edges.FrameWidth - Edges.X;
          Move(AboveSource^, AboveRow^, Remaining * 2);
          FillWords(AboveRow + Remaining, Edges.X + 2 * Size - Edges.FrameWidth, AboveRow[Remaining - 1]);
        end;
      end
      else
      begin
        Move(AboveSource^, AboveRow^, Size * 2);
        if (Size = 4) and Edges.HaveRight then
          Move(AboveSource[Size], AboveRow[Size], Size * 2)
        else
          FillWords(AboveRow + Size, Size, AboveRow[Size - 1]);
      end;
      if Edges.HaveLeft then
        AboveRow[-1] := AboveSource[-1]
      else
        AboveRow[-1] := Base + 1;
    end
    else
    begin
      FillWords(AboveRow, Size * 2, Base - 1);
      AboveRow[-1] := Base - 1;
    end;
  end;
  case Mode of
    ModeDc:
      PredictDc(Target, Stride, Size, AboveRow, @LeftColumn[0], Edges.HaveAbove, Edges.HaveLeft, Edges.BitDepth);
    ModeVertical:
      PredictVertical(Target, Stride, Size, AboveRow);
    ModeHorizontal:
      PredictHorizontal(Target, Stride, Size, @LeftColumn[0]);
    ModeTrueMotion:
      PredictTrueMotion(Target, Stride, Size, AboveRow, @LeftColumn[0], Edges.BitDepth);
    ModeD45:
      if Size = 4 then
        PredictD45Small(Target, Stride, AboveRow)
      else
        PredictD45(Target, Stride, Size, AboveRow);
    ModeD63:
      if Size = 4 then
        PredictD63Small(Target, Stride, AboveRow)
      else
        PredictD63(Target, Stride, Size, AboveRow);
    ModeD207:
      if Size = 4 then
        PredictD207Small(Target, Stride, @LeftColumn[0])
      else
        PredictD207(Target, Stride, Size, @LeftColumn[0]);
    ModeD117:
      if Size = 4 then
        PredictD117Small(Target, Stride, AboveRow, @LeftColumn[0])
      else
        PredictD117(Target, Stride, Size, AboveRow, @LeftColumn[0]);
    ModeD135:
      if Size = 4 then
        PredictD135Small(Target, Stride, AboveRow, @LeftColumn[0])
      else
        PredictD135(Target, Stride, Size, AboveRow, @LeftColumn[0]);
    ModeD153:
      if Size = 4 then
        PredictD153Small(Target, Stride, AboveRow, @LeftColumn[0])
      else
        PredictD153(Target, Stride, Size, AboveRow, @LeftColumn[0]);
  end;
end;

end.
