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
  The neighbours of a modular sample and the fourteen predictors
  (ISO/IEC 18181-1 annex H.3).

  Off the edges: on the first line the "north" neighbours are the
  west one, in the first column the west one is the north one (0 in
  the very first sample), and so on, as libjxl resolves them; the
  averages divide truncating towards zero, as C does.
}
unit Image.Jxl.Modular.Predictors;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils;

type
  TJxlNeighbours = record
    West: Int64;
    North: Int64;
    NorthWest: Int64;
    NorthEast: Int64;
    WestWest: Int64;
    NorthNorth: Int64;
    NorthEastEast: Int64;
  end;

{ The neighbours of (X, Y) in a channel Width wide whose line Y starts
  at Line (line Y - 1 at Line - Width...). }
procedure GetJxlNeighbours(Line: PLongInt; Width, X, Y: LongInt; out Neighbours: TJxlNeighbours); inline;
function JxlClampedGradient(West, North, NorthWest: Int64): Int64; inline;
{ Predictor Predictor (not the weighted one, which gives
  WeightedPrediction). }
function JxlPredict(Predictor: LongInt; const Neighbours: TJxlNeighbours; WeightedPrediction: Int64): Int64;

implementation

uses
  Image.Jxl.Modular.Tree;

procedure GetJxlNeighbours(Line: PLongInt; Width, X, Y: LongInt; out Neighbours: TJxlNeighbours);
var
  Above: PLongInt;
begin
  Above := Line - Width;
  if X > 0 then
    Neighbours.West := Line[X - 1]
  else if Y > 0 then
    Neighbours.West := Above[X]
  else
    Neighbours.West := 0;
  if Y > 0 then
    Neighbours.North := Above[X]
  else
    Neighbours.North := Neighbours.West;
  if (X > 0) and (Y > 0) then
    Neighbours.NorthWest := Above[X - 1]
  else
    Neighbours.NorthWest := Neighbours.West;
  if (X + 1 < Width) and (Y > 0) then
    Neighbours.NorthEast := Above[X + 1]
  else
    Neighbours.NorthEast := Neighbours.North;
  if X > 1 then
    Neighbours.WestWest := Line[X - 2]
  else
    Neighbours.WestWest := Neighbours.West;
  if Y > 1 then
    Neighbours.NorthNorth := (Above - Width)[X]
  else
    Neighbours.NorthNorth := Neighbours.North;
  if (X + 2 < Width) and (Y > 0) then
    Neighbours.NorthEastEast := Above[X + 2]
  else
    Neighbours.NorthEastEast := Neighbours.NorthEast;
end;

function JxlClampedGradient(West, North, NorthWest: Int64): Int64;
var
  Lowest: Int64;
  Highest: Int64;
begin
  if North < West then
  begin
    Lowest := North;
    Highest := West;
  end
  else
  begin
    Lowest := West;
    Highest := North;
  end;
  if NorthWest > Highest then
    Exit(Lowest);
  if NorthWest < Lowest then
    Exit(Highest);
  Result := North + West - NorthWest;
end;

function JxlPredict(Predictor: LongInt; const Neighbours: TJxlNeighbours; WeightedPrediction: Int64): Int64;
var
  Gradient: Int64;
begin
  case Predictor of
    JxlPredictorZero: Result := 0;
    JxlPredictorLeft: Result := Neighbours.West;
    JxlPredictorTop: Result := Neighbours.North;
    JxlPredictorAverage0: Result := (Neighbours.West + Neighbours.North) div 2;
    JxlPredictorSelect:
      begin
        Gradient := Neighbours.West + Neighbours.North - Neighbours.NorthWest;
        if Abs(Gradient - Neighbours.West) < Abs(Gradient - Neighbours.North) then
          Result := Neighbours.West
        else
          Result := Neighbours.North;
      end;
    JxlPredictorGradient: Result := JxlClampedGradient(Neighbours.West, Neighbours.North, Neighbours.NorthWest);
    JxlPredictorWeighted: Result := WeightedPrediction;
    JxlPredictorTopRight: Result := Neighbours.NorthEast;
    JxlPredictorTopLeft: Result := Neighbours.NorthWest;
    JxlPredictorLeftLeft: Result := Neighbours.WestWest;
    JxlPredictorAverage1: Result := (Neighbours.West + Neighbours.NorthWest) div 2;
    JxlPredictorAverage2: Result := (Neighbours.NorthWest + Neighbours.North) div 2;
    JxlPredictorAverage3: Result := (Neighbours.North + Neighbours.NorthEast) div 2;
    JxlPredictorAverage4:
      Result := (6 * Neighbours.North - 2 * Neighbours.NorthNorth + 7 * Neighbours.West + Neighbours.WestWest
        + Neighbours.NorthEastEast + 3 * Neighbours.NorthEast + 8) div 16;
  else
    Result := 0;
  end;
end;

end.
