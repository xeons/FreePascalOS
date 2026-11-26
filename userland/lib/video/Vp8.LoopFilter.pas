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
  VP8's loop filter (RFC 6386 section 15): after a frame is decoded,
  the edges between macroblocks and between their 4x4 blocks are
  smoothed where the difference across them is small enough to be a
  coding artefact. The normal filter changes up to three pixels each
  side of a macroblock edge and two of a block edge, in all planes; the
  simple filter only one each side, in luma.

  For each macroblock: its left edge, its inner vertical edges, its top
  edge, its inner horizontal edges, in that order, macroblocks in raster
  order (each filter reads what the ones before it wrote).
}
unit Vp8.LoopFilter;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

type
  { The limits of one filter level at the frame's sharpness. }
  TVp8FilterLimits = record
    MacroblockEdgeLimit: LongInt;
    BlockEdgeLimit: LongInt;
    InteriorLimit: LongInt;
    HighEdgeVarianceThreshold: LongInt;
  end;

{ The limits of Level (1..63) at Sharpness (0..7) in a key frame or
  not. }
function ComputeFilterLimits(Level, Sharpness: LongInt; KeyFrame: Boolean): TVp8FilterLimits;

{ Filters one macroblock with the normal filter; Y, U and V point at
  its top left pixels. The left and top edges are filtered only when
  FilterLeft and FilterTop (not at the picture's edges), the inner
  edges only when FilterInner. }
procedure FilterMacroblockNormal(Y, U, V: PByte; YStride, UvStride: LongInt;
  constref Limits: TVp8FilterLimits; FilterLeft, FilterTop, FilterInner: Boolean);
{ The same with the simple filter (luma only). }
procedure FilterMacroblockSimple(Y: PByte; YStride: LongInt;
  constref Limits: TVp8FilterLimits; FilterLeft, FilterTop, FilterInner: Boolean);

implementation

function ComputeFilterLimits(Level, Sharpness: LongInt; KeyFrame: Boolean): TVp8FilterLimits;
var
  Interior: LongInt;
begin
  Interior := Level;
  if Sharpness > 0 then
    Interior := Interior shr 1;
  if Sharpness > 4 then
    Interior := Interior shr 1;
  if Sharpness > 0 then
    if Interior > 9 - Sharpness then
      Interior := 9 - Sharpness;
  if Interior < 1 then
    Interior := 1;
  Result.InteriorLimit := Interior;
  Result.BlockEdgeLimit := 2 * Level + Interior;
  Result.MacroblockEdgeLimit := 2 * (Level + 2) + Interior;
  if KeyFrame then
  begin
    if Level >= 40 then
      Result.HighEdgeVarianceThreshold := 2
    else if Level >= 15 then
      Result.HighEdgeVarianceThreshold := 1
    else
      Result.HighEdgeVarianceThreshold := 0;
  end
  else
  begin
    if Level >= 40 then
      Result.HighEdgeVarianceThreshold := 3
    else if Level >= 20 then
      Result.HighEdgeVarianceThreshold := 2
    else if Level >= 15 then
      Result.HighEdgeVarianceThreshold := 1
    else
      Result.HighEdgeVarianceThreshold := 0;
  end;
end;

function ClampSigned(Value: LongInt): LongInt; inline;
begin
  if Value < -128 then
    Result := -128
  else if Value > 127 then
    Result := 127
  else
    Result := Value;
end;

{ Whether to filter across the edge between P0 and Q0 at all. }
function FilterMask(Interior, Edge: LongInt; P: PByte; Step: LongInt): Boolean; inline;
var
  P3, P2, P1, P0, Q0, Q1, Q2, Q3: LongInt;
begin
  P3 := P[-4 * Step];
  P2 := P[-3 * Step];
  P1 := P[-2 * Step];
  P0 := P[-Step];
  Q0 := P[0];
  Q1 := P[Step];
  Q2 := P[2 * Step];
  Q3 := P[3 * Step];
  Result := (Abs(P3 - P2) <= Interior) and (Abs(P2 - P1) <= Interior) and
    (Abs(P1 - P0) <= Interior) and (Abs(Q1 - Q0) <= Interior) and
    (Abs(Q2 - Q1) <= Interior) and (Abs(Q3 - Q2) <= Interior) and
    (Abs(P0 - Q0) * 2 + Abs(P1 - Q1) div 2 <= Edge);
end;

function HighEdgeVariance(Threshold: LongInt; P: PByte; Step: LongInt): Boolean; inline;
begin
  Result := (Abs(LongInt(P[-2 * Step]) - LongInt(P[-Step])) > Threshold) or
    (Abs(LongInt(P[Step]) - LongInt(P[0])) > Threshold);
end;

{ The block edge filter at one position. }
procedure FilterCommon(P: PByte; Step: LongInt; HighVariance: Boolean);
var
  Ps1, Ps0, Qs0, Qs1, Value, Filter1, Filter2: LongInt;
begin
  Ps1 := LongInt(P[-2 * Step]) - 128;
  Ps0 := LongInt(P[-Step]) - 128;
  Qs0 := LongInt(P[0]) - 128;
  Qs1 := LongInt(P[Step]) - 128;
  if HighVariance then
    Value := ClampSigned(Ps1 - Qs1)
  else
    Value := 0;
  Value := ClampSigned(Value + 3 * (Qs0 - Ps0));
  Filter1 := SarLongint(ClampSigned(Value + 4), 3);
  Filter2 := SarLongint(ClampSigned(Value + 3), 3);
  P[0] := ClampSigned(Qs0 - Filter1) + 128;
  P[-Step] := ClampSigned(Ps0 + Filter2) + 128;
  if not HighVariance then
  begin
    Value := SarLongint(Filter1 + 1, 1);
    P[Step] := ClampSigned(Qs1 - Value) + 128;
    P[-2 * Step] := ClampSigned(Ps1 + Value) + 128;
  end;
end;

{ The macroblock edge filter at one position. }
procedure FilterMacroblockEdge(P: PByte; Step: LongInt; HighVariance: Boolean);
var
  Ps2, Ps1, Ps0, Qs0, Qs1, Qs2, Value, Filter1, Filter2, U: LongInt;
begin
  Ps2 := LongInt(P[-3 * Step]) - 128;
  Ps1 := LongInt(P[-2 * Step]) - 128;
  Ps0 := LongInt(P[-Step]) - 128;
  Qs0 := LongInt(P[0]) - 128;
  Qs1 := LongInt(P[Step]) - 128;
  Qs2 := LongInt(P[2 * Step]) - 128;
  Value := ClampSigned(Ps1 - Qs1);
  Value := ClampSigned(Value + 3 * (Qs0 - Ps0));
  if HighVariance then
  begin
    Filter1 := SarLongint(ClampSigned(Value + 4), 3);
    Filter2 := SarLongint(ClampSigned(Value + 3), 3);
    P[0] := ClampSigned(Qs0 - Filter1) + 128;
    P[-Step] := ClampSigned(Ps0 + Filter2) + 128;
  end
  else
  begin
    U := ClampSigned(SarLongint(63 + Value * 27, 7));
    P[0] := ClampSigned(Qs0 - U) + 128;
    P[-Step] := ClampSigned(Ps0 + U) + 128;
    U := ClampSigned(SarLongint(63 + Value * 18, 7));
    P[Step] := ClampSigned(Qs1 - U) + 128;
    P[-2 * Step] := ClampSigned(Ps1 + U) + 128;
    U := ClampSigned(SarLongint(63 + Value * 9, 7));
    P[2 * Step] := ClampSigned(Qs2 - U) + 128;
    P[-3 * Step] := ClampSigned(Ps2 + U) + 128;
  end;
end;

{ Filters Count pixels along an edge: Step crosses the edge, Along
  moves along it. }
procedure FilterEdge(P: PByte; Step, Along, Count: LongInt;
  constref Limits: TVp8FilterLimits; Macroblock: Boolean);
var
  Index, Edge: LongInt;
begin
  if Macroblock then
    Edge := Limits.MacroblockEdgeLimit
  else
    Edge := Limits.BlockEdgeLimit;
  for Index := 0 to Count - 1 do
  begin
    if FilterMask(Limits.InteriorLimit, Edge, P, Step) then
    begin
      if Macroblock then
        FilterMacroblockEdge(P, Step, HighEdgeVariance(Limits.HighEdgeVarianceThreshold, P, Step))
      else
        FilterCommon(P, Step, HighEdgeVariance(Limits.HighEdgeVarianceThreshold, P, Step));
    end;
    Inc(P, Along);
  end;
end;

procedure FilterMacroblockNormal(Y, U, V: PByte; YStride, UvStride: LongInt;
  constref Limits: TVp8FilterLimits; FilterLeft, FilterTop, FilterInner: Boolean);
begin
  if FilterLeft then
  begin
    FilterEdge(Y, 1, YStride, 16, Limits, True);
    FilterEdge(U, 1, UvStride, 8, Limits, True);
    FilterEdge(V, 1, UvStride, 8, Limits, True);
  end;
  if FilterInner then
  begin
    FilterEdge(Y + 4, 1, YStride, 16, Limits, False);
    FilterEdge(Y + 8, 1, YStride, 16, Limits, False);
    FilterEdge(Y + 12, 1, YStride, 16, Limits, False);
    FilterEdge(U + 4, 1, UvStride, 8, Limits, False);
    FilterEdge(V + 4, 1, UvStride, 8, Limits, False);
  end;
  if FilterTop then
  begin
    FilterEdge(Y, YStride, 1, 16, Limits, True);
    FilterEdge(U, UvStride, 1, 8, Limits, True);
    FilterEdge(V, UvStride, 1, 8, Limits, True);
  end;
  if FilterInner then
  begin
    FilterEdge(Y + 4 * YStride, YStride, 1, 16, Limits, False);
    FilterEdge(Y + 8 * YStride, YStride, 1, 16, Limits, False);
    FilterEdge(Y + 12 * YStride, YStride, 1, 16, Limits, False);
    FilterEdge(U + 4 * UvStride, UvStride, 1, 8, Limits, False);
    FilterEdge(V + 4 * UvStride, UvStride, 1, 8, Limits, False);
  end;
end;

procedure FilterSimpleEdge(P: PByte; Step, Along: LongInt; Edge: LongInt);
var
  Index, P1, P0, Q0, Q1, Value, Filter1, Filter2: LongInt;
begin
  for Index := 0 to 15 do
  begin
    P1 := P[-2 * Step];
    P0 := P[-Step];
    Q0 := P[0];
    Q1 := P[Step];
    if Abs(P0 - Q0) * 2 + Abs(P1 - Q1) div 2 <= Edge then
    begin
      Value := ClampSigned((P1 - 128) - (Q1 - 128));
      Value := ClampSigned(Value + 3 * ((Q0 - 128) - (P0 - 128)));
      Filter1 := SarLongint(ClampSigned(Value + 4), 3);
      P[0] := ClampSigned(Q0 - 128 - Filter1) + 128;
      Filter2 := SarLongint(ClampSigned(Value + 3), 3);
      P[-Step] := ClampSigned(P0 - 128 + Filter2) + 128;
    end;
    Inc(P, Along);
  end;
end;

procedure FilterMacroblockSimple(Y: PByte; YStride: LongInt;
  constref Limits: TVp8FilterLimits; FilterLeft, FilterTop, FilterInner: Boolean);
begin
  if FilterLeft then
    FilterSimpleEdge(Y, 1, YStride, Limits.MacroblockEdgeLimit);
  if FilterInner then
  begin
    FilterSimpleEdge(Y + 4, 1, YStride, Limits.BlockEdgeLimit);
    FilterSimpleEdge(Y + 8, 1, YStride, Limits.BlockEdgeLimit);
    FilterSimpleEdge(Y + 12, 1, YStride, Limits.BlockEdgeLimit);
  end;
  if FilterTop then
    FilterSimpleEdge(Y, YStride, 1, Limits.MacroblockEdgeLimit);
  if FilterInner then
  begin
    FilterSimpleEdge(Y + 4 * YStride, YStride, 1, Limits.BlockEdgeLimit);
    FilterSimpleEdge(Y + 8 * YStride, YStride, 1, Limits.BlockEdgeLimit);
    FilterSimpleEdge(Y + 12 * YStride, YStride, 1, Limits.BlockEdgeLimit);
  end;
end;

end.
