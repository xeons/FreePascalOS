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
  The self guided filter of loop restoration (specification sections
  7.17.2 and 7.17.3): two box filters (radius 2 on every other row, and
  radius 1) and a projection of their outputs, from the block's source
  window.
}
unit Av1.SelfGuided;

{$mode objfpc}

interface

uses
  Av1.Constants, Av1.Tables, Av1.FrameContext, Av1.Picture, Av1.RestorationWindow;

{ Filters the block (its window already filled) into Target with the unit's parameters. }
procedure SelfGuidedFilter(Scratch: TRestorationScratch; const Block: TRestorationBlock;
  const RestorationUnit: TRestorationUnit; BitDepth: Integer; Source, Target: TPicture);

implementation

function Round2Int64(Value: Int64; Bits: Integer): Int64; inline;
begin
  if Bits = 0 then
    Result := Value
  else
    Result := SarInt64(Value + (Int64(1) shl (Bits - 1)), Bits);
end;

{ The box filter process: Scratch.Filtered[ Pass ] for the block. }
procedure BoxFilter(Scratch: TRestorationScratch; const Block: TRestorationBlock; Source: TPicture;
  BitDepth, SetIndex, Pass: Integer);
var
  Radius, Eps, N, N2e, S, OneOverN: Integer;
  I, J, DY, DX, WindowRow, WindowCol: Integer;
  A, B, D, Shift, Weight, C: Integer;
  P, Z: Int64;
  A2: Integer;
  B2: Int64;
  SourceRow: PWord;
  SumA, SumB: Integer;
begin
  Radius := Sgr_Params[SetIndex][Pass * 2];
  if Radius = 0 then
    Exit;
  Eps := Sgr_Params[SetIndex][Pass * 2 + 1];
  N := (2 * Radius + 1) * (2 * Radius + 1);
  N2e := N * N * Eps;
  S := ((1 shl SGRPROJ_MTABLE_BITS) + N2e div 2) div N2e;
  OneOverN := ((1 shl SGRPROJ_RECIP_BITS) + (N div 2)) div N;
  for I := -1 to Block.H do
    for J := -1 to Block.W do
    begin
      A := 0;
      B := 0;
      for DY := -Radius to Radius do
      begin
        WindowRow := I + DY + RestorationMargin;
        for DX := -Radius to Radius do
        begin
          WindowCol := J + DX + RestorationMargin;
          C := Scratch.Window[WindowRow][WindowCol];
          Inc(A, C * C);
          Inc(B, C);
        end;
      end;
      A := Integer(Round2Int64(A, 2 * (BitDepth - 8)));
      D := Integer(Round2Int64(B, BitDepth - 8));
      P := Int64(A) * N - Int64(D) * D;
      if P < 0 then
        P := 0;
      Z := Round2Int64(P * S, SGRPROJ_MTABLE_BITS);
      if Z >= 255 then
        A2 := 256
      else if Z = 0 then
        A2 := 1
      else
        A2 := Integer(((Z shl SGRPROJ_SGR_BITS) + (Z div 2)) div (Z + 1));
      B2 := Int64((1 shl SGRPROJ_SGR_BITS) - A2) * B * OneOverN;
      Scratch.BoxA[I + 1][J + 1] := A2;
      Scratch.BoxB[I + 1][J + 1] := Integer(Round2Int64(B2, SGRPROJ_RECIP_BITS));
    end;
  for I := 0 to Block.H - 1 do
  begin
    Shift := 5;
    if (Pass = 0) and ((I and 1) <> 0) then
      Shift := 4;
    SourceRow := Source.Row(Block.Plane, Block.Y + I);
    for J := 0 to Block.W - 1 do
    begin
      SumA := 0;
      SumB := 0;
      for DY := -1 to 1 do
        for DX := -1 to 1 do
        begin
          if Pass = 0 then
          begin
            if ((I + DY) and 1) <> 0 then
            begin
              if DX = 0 then
                Weight := 6
              else
                Weight := 5;
            end
            else
              Weight := 0;
          end
          else if (DX = 0) or (DY = 0) then
            Weight := 4
          else
            Weight := 3;
          Inc(SumA, Weight * Scratch.BoxA[I + DY + 1][J + DX + 1]);
          Inc(SumB, Weight * Scratch.BoxB[I + DY + 1][J + DX + 1]);
        end;
      Scratch.Filtered[Pass][I][J] := Integer(Round2Int64(Int64(SumA) * SourceRow[Block.X + J] + SumB,
        SGRPROJ_SGR_BITS + Shift - SGRPROJ_RST_BITS));
    end;
  end;
end;

procedure SelfGuidedFilter(Scratch: TRestorationScratch; const Block: TRestorationBlock;
  const RestorationUnit: TRestorationUnit; BitDepth: Integer; Source, Target: TPicture);
var
  SetIndex, W0, W1, W2, R0, R1, I, J, U, V, S, PixelMax: Integer;
  SourceRow, TargetRow: PWord;
begin
  SetIndex := RestorationUnit.SgrSet;
  BoxFilter(Scratch, Block, Source, BitDepth, SetIndex, 0);
  BoxFilter(Scratch, Block, Source, BitDepth, SetIndex, 1);
  W0 := RestorationUnit.SgrXqd[0];
  W1 := RestorationUnit.SgrXqd[1];
  W2 := (1 shl SGRPROJ_PRJ_BITS) - W0 - W1;
  R0 := Sgr_Params[SetIndex][0];
  R1 := Sgr_Params[SetIndex][2];
  PixelMax := (1 shl BitDepth) - 1;
  for I := 0 to Block.H - 1 do
  begin
    SourceRow := Source.Row(Block.Plane, Block.Y + I);
    TargetRow := Target.Row(Block.Plane, Block.Y + I);
    for J := 0 to Block.W - 1 do
    begin
      U := SourceRow[Block.X + J] shl SGRPROJ_RST_BITS;
      V := W1 * U;
      if R0 <> 0 then
        Inc(V, W0 * Scratch.Filtered[0][I][J])
      else
        Inc(V, W0 * U);
      if R1 <> 0 then
        Inc(V, W2 * Scratch.Filtered[1][I][J])
      else
        Inc(V, W2 * U);
      S := SarLongint(V + (1 shl (SGRPROJ_RST_BITS + SGRPROJ_PRJ_BITS - 1)), SGRPROJ_RST_BITS + SGRPROJ_PRJ_BITS);
      if S < 0 then
        S := 0
      else if S > PixelMax then
        S := PixelMax;
      TargetRow[Block.X + J] := S;
    end;
  end;
end;

end.
