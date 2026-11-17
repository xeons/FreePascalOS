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
  Bezier curves as points: a quadratic curve (one control point) or a
  cubic one (two) from one end to the other, cut into enough straight
  pieces that none strays more than a fiftieth of a pixel from the
  curve, for a stroke along it (Drawing.SmoothStrokes) or an outline
  of it. The first point is the start and the last the end, exactly.
}
unit Drawing.Curves;

{$mode objfpc}

interface

uses
  Drawing.Rasterizer;

type
  TPrecisePoints = array of TPrecisePoint;

function FlattenQuadraticCurve(const From, Control, Target: TPrecisePoint): TPrecisePoints;
function FlattenCubicCurve(const From, FirstControl, SecondControl, Target: TPrecisePoint): TPrecisePoints;

implementation

uses
  Math;

const
  Tolerance = 0.02;
  MaximumPieces = 256;

{ Pieces enough for a curve whose second differences reach Deviation:
  a piece of a curve strays at most an eighth of its bend. }
function PiecesFor(Deviation: Double): LongInt;
begin
  Result := Ceil(Sqrt(Deviation / (8 * Tolerance)));
  if Result < 1 then
    Result := 1;
  if Result > MaximumPieces then
    Result := MaximumPieces;
end;

function FlattenQuadraticCurve(const From, Control, Target: TPrecisePoint): TPrecisePoints;
var
  Deviation: Double;
  Pieces: LongInt;
  Piece: LongInt;
  T: Double;
  U: Double;
begin
  Result := nil;
  Deviation := 2 * Sqrt(Sqr(From.X - 2 * Control.X + Target.X) + Sqr(From.Y - 2 * Control.Y + Target.Y));
  Pieces := PiecesFor(Deviation);
  SetLength(Result, Pieces + 1);
  for Piece := 0 to Pieces do
  begin
    T := Piece / Pieces;
    U := 1 - T;
    Result[Piece].X := U * U * From.X + 2 * U * T * Control.X + T * T * Target.X;
    Result[Piece].Y := U * U * From.Y + 2 * U * T * Control.Y + T * T * Target.Y;
  end;
  Result[0] := From;
  Result[Pieces] := Target;
end;

function FlattenCubicCurve(const From, FirstControl, SecondControl, Target: TPrecisePoint): TPrecisePoints;
var
  Deviation: Double;
  Pieces: LongInt;
  Piece: LongInt;
  T: Double;
  U: Double;
begin
  Result := nil;
  Deviation := 6 * Max(Sqrt(Sqr(From.X - 2 * FirstControl.X + SecondControl.X) +
    Sqr(From.Y - 2 * FirstControl.Y + SecondControl.Y)),
    Sqrt(Sqr(FirstControl.X - 2 * SecondControl.X + Target.X) + Sqr(FirstControl.Y - 2 * SecondControl.Y + Target.Y)));
  Pieces := PiecesFor(Deviation);
  SetLength(Result, Pieces + 1);
  for Piece := 0 to Pieces do
  begin
    T := Piece / Pieces;
    U := 1 - T;
    Result[Piece].X := U * U * U * From.X + 3 * U * U * T * FirstControl.X + 3 * U * T * T * SecondControl.X +
      T * T * T * Target.X;
    Result[Piece].Y := U * U * U * From.Y + 3 * U * U * T * FirstControl.Y + 3 * U * T * T * SecondControl.Y +
      T * T * T * Target.Y;
  end;
  Result[0] := From;
  Result[Pieces] := Target;
end;

end.
