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
  The Wiener filter of loop restoration (specification sections 7.17.4
  and 7.17.5): a symmetric 7-tap filter applied horizontally then
  vertically to a block, from the block's source window.
}
unit Av1.Wiener;

{$mode objfpc}

interface

uses
  Av1.FrameContext, Av1.Picture, Av1.RestorationWindow;

{ Filters the block (its window already filled) into Target with the unit's coefficients. }
procedure WienerFilter(Scratch: TRestorationScratch; const Block: TRestorationBlock;
  const RestorationUnit: TRestorationUnit; BitDepth: Integer; Target: TPicture);

implementation

const
  FILTER_BITS = 7;

type
  TWienerTaps = array[0..6] of Integer;

{ The Wiener coefficient process. }
procedure WienerCoefficients(const RestorationUnit: TRestorationUnit; Pass: Integer; out Taps: TWienerTaps);
var
  I, C: Integer;
begin
  Taps[3] := 128;
  for I := 0 to 2 do
  begin
    C := RestorationUnit.Wiener[Pass][I];
    Taps[I] := C;
    Taps[6 - I] := C;
    Dec(Taps[3], 2 * C);
  end;
end;

procedure WienerFilter(Scratch: TRestorationScratch; const Block: TRestorationBlock;
  const RestorationUnit: TRestorationUnit; BitDepth: Integer; Target: TPicture);
var
  VerticalTaps, HorizontalTaps: TWienerTaps;
  InterRound0, InterRound1, Offset, Limit, PixelMax: Integer;
  R, C, T, Sum, Value: Integer;
  TargetRow: PWord;
begin
  InterRound0 := 3;
  InterRound1 := 11;
  if BitDepth = 12 then
  begin
    InterRound0 := 5;
    InterRound1 := 9;
  end;
  WienerCoefficients(RestorationUnit, 0, VerticalTaps);
  WienerCoefficients(RestorationUnit, 1, HorizontalTaps);
  Offset := 1 shl (BitDepth + FILTER_BITS - InterRound0 - 1);
  Limit := (1 shl (BitDepth + 1 + FILTER_BITS - InterRound0)) - 1;
  for R := 0 to Block.H + 5 do
    for C := 0 to Block.W - 1 do
    begin
      Sum := 0;
      for T := 0 to 6 do
        Inc(Sum, HorizontalTaps[T] * Scratch.Window[R][C + T]);
      Value := SarLongint(Sum + (1 shl (InterRound0 - 1)), InterRound0);
      if Value < -Offset then
        Value := -Offset
      else if Value > Limit - Offset then
        Value := Limit - Offset;
      Scratch.Intermediate[R][C] := Value;
    end;
  PixelMax := (1 shl BitDepth) - 1;
  for R := 0 to Block.H - 1 do
  begin
    TargetRow := Target.Row(Block.Plane, Block.Y + R);
    for C := 0 to Block.W - 1 do
    begin
      Sum := 0;
      for T := 0 to 6 do
        Inc(Sum, VerticalTaps[T] * Scratch.Intermediate[R + T][C]);
      Value := SarLongint(Sum + (1 shl (InterRound1 - 1)), InterRound1);
      if Value < 0 then
        Value := 0
      else if Value > PixelMax then
        Value := PixelMax;
      TargetRow[Block.X + C] := Value;
    end;
  end;
end;

end.
