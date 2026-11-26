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
  The deblocking filter's sample filtering (specification section
  7.14.6): the filter masks, the narrow filter and the wide filters,
  applied across one edge position. The samples are reached as
  Samples[ Center + k * Step ], where Center is the first sample past
  the edge (q0) and Step the distance between samples across the edge
  (1 for vertical edges, the plane's stride for horizontal ones).
}
unit Av1.LoopFilterSamples;

{$mode objfpc}

interface

type
  { The strengths of one edge (section 7.14.4), already scaled to the
    bit depth, and the filter's shape. }
  TEdgeFilterStrength = record
    LimitBd, BlimitBd, ThreshBd, FlatThresholdBd: Integer;
    FilterSize: Integer;         { 4, 6 (chroma 8), 8 or 16 }
    IsChroma: Boolean;
    BitDepth: Integer;
  end;

{ The sample filtering process for the samples across the edge at Center. }
procedure FilterEdgeSample(Samples: PWord; Center, Step: Integer; const Strength: TEdgeFilterStrength);

implementation

function AbsDiff(A, B: Integer): Integer; inline;
begin
  if A > B then
    Result := A - B
  else
    Result := B - A;
end;

procedure NarrowFilter(Samples: PWord; Center, Step: Integer; HevMask: Boolean; BitDepth: Integer);
var
  Low, High, Offset: Integer;
  ps1, ps0, qs0, qs1, Filter, Filter1, Filter2: Integer;

  function Clamp4(Value: Integer): Integer; inline;
  begin
    if Value < Low then
      Result := Low
    else if Value > High then
      Result := High
    else
      Result := Value;
  end;

begin
  Low := -(1 shl (BitDepth - 1));
  High := (1 shl (BitDepth - 1)) - 1;
  Offset := $80 shl (BitDepth - 8);
  ps1 := Samples[Center - 2 * Step] - Offset;
  ps0 := Samples[Center - Step] - Offset;
  qs0 := Samples[Center] - Offset;
  qs1 := Samples[Center + Step] - Offset;
  if HevMask then
    Filter := Clamp4(ps1 - qs1)
  else
    Filter := 0;
  Filter := Clamp4(Filter + 3 * (qs0 - ps0));
  Filter1 := SarLongint(Clamp4(Filter + 4), 3);
  Filter2 := SarLongint(Clamp4(Filter + 3), 3);
  Samples[Center] := Clamp4(qs0 - Filter1) + Offset;
  Samples[Center - Step] := Clamp4(ps0 + Filter2) + Offset;
  if not HevMask then
  begin
    Filter := SarLongint(Filter1 + 1, 1);
    Samples[Center + Step] := Clamp4(qs1 - Filter) + Offset;
    Samples[Center - 2 * Step] := Clamp4(ps1 + Filter) + Offset;
  end;
end;

{ The wide filter: n taps each side (n2 taps of weight 2 around the centre). }
procedure WideFilter(Samples: PWord; Center, Step, Log2Size: Integer; IsChroma: Boolean);
var
  N, N2, I, J, P, Tap, Total: Integer;
  Source: array[-7..6] of Integer;
  Filtered: array[-6..5] of Integer;
begin
  if Log2Size = 4 then
    N := 6
  else if not IsChroma then
    N := 3
  else
    N := 2;
  if (Log2Size = 3) and not IsChroma then
    N2 := 0
  else
    N2 := 1;
  for I := -(N + 1) to N do
    Source[I] := Samples[Center + I * Step];
  for I := -N to N - 1 do
  begin
    Total := 0;
    for J := -N to N do
    begin
      P := I + J;
      if P < -(N + 1) then
        P := -(N + 1)
      else if P > N then
        P := N;
      if Abs(J) <= N2 then
        Tap := 2
      else
        Tap := 1;
      Inc(Total, Source[P] * Tap);
    end;
    Filtered[I] := (Total + (1 shl (Log2Size - 1))) shr Log2Size;
  end;
  for I := -N to N - 1 do
    Samples[Center + I * Step] := Filtered[I];
end;

procedure FilterEdgeSample(Samples: PWord; Center, Step: Integer; const Strength: TEdgeFilterStrength);
var
  q0, q1, q2, q3, p0, p1, p2, p3: Integer;
  FilterLen: Integer;
  HevMask, FlatMask, FlatMask2: Boolean;
  Threshold: Integer;
begin
  q0 := Samples[Center];
  q1 := Samples[Center + Step];
  p0 := Samples[Center - Step];
  p1 := Samples[Center - 2 * Step];
  if Strength.FilterSize = 4 then
    FilterLen := 4
  else if Strength.IsChroma then
    FilterLen := 6
  else if Strength.FilterSize = 8 then
    FilterLen := 8
  else
    FilterLen := 16;
  { filterMask }
  if (AbsDiff(p1, p0) > Strength.LimitBd) or (AbsDiff(q1, q0) > Strength.LimitBd) or
    (AbsDiff(p0, q0) * 2 + AbsDiff(p1, q1) div 2 > Strength.BlimitBd) then
    Exit;
  q2 := 0;
  q3 := 0;
  p2 := 0;
  p3 := 0;
  if FilterLen >= 6 then
  begin
    q2 := Samples[Center + 2 * Step];
    p2 := Samples[Center - 3 * Step];
    if (AbsDiff(p2, p1) > Strength.LimitBd) or (AbsDiff(q2, q1) > Strength.LimitBd) then
      Exit;
  end;
  if FilterLen >= 8 then
  begin
    q3 := Samples[Center + 3 * Step];
    p3 := Samples[Center - 4 * Step];
    if (AbsDiff(p3, p2) > Strength.LimitBd) or (AbsDiff(q3, q2) > Strength.LimitBd) then
      Exit;
  end;
  HevMask := (AbsDiff(p1, p0) > Strength.ThreshBd) or (AbsDiff(q1, q0) > Strength.ThreshBd);
  if Strength.FilterSize = 4 then
  begin
    NarrowFilter(Samples, Center, Step, HevMask, Strength.BitDepth);
    Exit;
  end;
  Threshold := Strength.FlatThresholdBd;
  FlatMask := (AbsDiff(p1, p0) <= Threshold) and (AbsDiff(q1, q0) <= Threshold) and
    (AbsDiff(p2, p0) <= Threshold) and (AbsDiff(q2, q0) <= Threshold);
  if FlatMask and (FilterLen >= 8) then
    FlatMask := (AbsDiff(p3, p0) <= Threshold) and (AbsDiff(q3, q0) <= Threshold);
  if not FlatMask then
  begin
    NarrowFilter(Samples, Center, Step, HevMask, Strength.BitDepth);
    Exit;
  end;
  FlatMask2 := False;
  if Strength.FilterSize >= 16 then
    FlatMask2 :=
      (AbsDiff(Samples[Center - 7 * Step], p0) <= Threshold) and
      (AbsDiff(Samples[Center + 6 * Step], q0) <= Threshold) and
      (AbsDiff(Samples[Center - 6 * Step], p0) <= Threshold) and
      (AbsDiff(Samples[Center + 5 * Step], q0) <= Threshold) and
      (AbsDiff(Samples[Center - 5 * Step], p0) <= Threshold) and
      (AbsDiff(Samples[Center + 4 * Step], q0) <= Threshold);
  if (Strength.FilterSize = 8) or not FlatMask2 then
    WideFilter(Samples, Center, Step, 3, Strength.IsChroma)
  else
    WideFilter(Samples, Center, Step, 4, Strength.IsChroma);
end;

end.
