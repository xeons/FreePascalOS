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
  The film grain scaling functions (specification section 7.18.3.4 and
  scale_lut of 7.18.3.5): a 256 entry table per plane, interpolated
  piecewise linearly between the signalled points, and the lookup that
  interpolates between entries for 10 and 12-bit samples.
}
unit Av1.FilmGrainScaling;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.FrameHeader;

type
  TScalingLookup = array[0..2, 0..255] of Integer;

procedure InitializeScalingLookup(out Lookup: TScalingLookup; constref Params: TFilmGrainParams;
  NumPlanes: Integer);
{ scale_lut( plane, index ) for samples of BitDepth bits. }
function ScaleLookup(const Lookup: TScalingLookup; Plane, Index, BitDepth: Integer): Integer; inline;

implementation

procedure GetPoints(constref Params: TFilmGrainParams; Plane: Integer; out Count: Integer;
  out Values, Scalings: PInteger);
begin
  if (Plane = 0) or Params.chroma_scaling_from_luma then
  begin
    Count := Params.num_y_points;
    Values := @Params.point_y_value[0];
    Scalings := @Params.point_y_scaling[0];
  end
  else if Plane = 1 then
  begin
    Count := Params.num_cb_points;
    Values := @Params.point_cb_value[0];
    Scalings := @Params.point_cb_scaling[0];
  end
  else
  begin
    Count := Params.num_cr_points;
    Values := @Params.point_cr_value[0];
    Scalings := @Params.point_cr_scaling[0];
  end;
end;

procedure InitializeScalingLookup(out Lookup: TScalingLookup; constref Params: TFilmGrainParams;
  NumPlanes: Integer);
var
  Plane, Count, Point, X, DeltaX, DeltaY, Delta: Integer;
  Values, Scalings: PInteger;
begin
  FillChar(Lookup, SizeOf(Lookup), 0);
  for Plane := 0 to NumPlanes - 1 do
  begin
    GetPoints(Params, Plane, Count, Values, Scalings);
    if Count = 0 then
      Continue;
    for X := 0 to Values[0] - 1 do
      Lookup[Plane, X] := Scalings[0];
    for Point := 0 to Count - 2 do
    begin
      DeltaY := Scalings[Point + 1] - Scalings[Point];
      DeltaX := Values[Point + 1] - Values[Point];
      if DeltaX <= 0 then
        Continue;     { not conformant; nothing to interpolate }
      Delta := DeltaY * ((65536 + (DeltaX shr 1)) div DeltaX);
      for X := 0 to DeltaX - 1 do
        Lookup[Plane, Values[Point] + X] := Scalings[Point] + ShiftRight(X * Delta + 32768, 16);
    end;
    for X := Values[Count - 1] to 255 do
      Lookup[Plane, X] := Scalings[Count - 1];
  end;
end;

function ScaleLookup(const Lookup: TScalingLookup; Plane, Index, BitDepth: Integer): Integer;
var
  Shift, X, Remainder, StartValue, EndValue: Integer;
begin
  Shift := BitDepth - 8;
  X := Index shr Shift;
  if (BitDepth = 8) or (X = 255) then
    Exit(Lookup[Plane, X]);
  Remainder := Index - (X shl Shift);
  StartValue := Lookup[Plane, X];
  EndValue := Lookup[Plane, X + 1];
  Result := StartValue + Round2((EndValue - StartValue) * Remainder, Shift);
end;

end.
