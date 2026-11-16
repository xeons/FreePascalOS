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
  VP8's loop filter (RFC 6386 section 15), smoothing the edges between
  blocks where the step across them is small enough to be an artefact.

  The simple filter changes one luma pixel each side of an edge. The
  normal filter looks at four each side and changes up to three (two
  inside a macroblock), less where the edge has high variance, on luma
  and chroma. Macroblock edges get a threshold 4 higher than the edges
  between the 4x4 blocks inside. Each routine filters edges of the
  macroblock at P in a plane of lines Stride bytes apart: its top or
  left edge, or the three inner horizontal or vertical ones.
}
unit Image.WebP.LoopFilter;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

procedure SimpleTopEdge16(P: PByte; Stride, Threshold: LongInt);
procedure SimpleLeftEdge16(P: PByte; Stride, Threshold: LongInt);
procedure SimpleInnerHorizontalEdges16(P: PByte; Stride, Threshold: LongInt);
procedure SimpleInnerVerticalEdges16(P: PByte; Stride, Threshold: LongInt);

procedure TopEdge16(P: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
procedure LeftEdge16(P: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
procedure InnerHorizontalEdges16(P: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
procedure InnerVerticalEdges16(P: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
procedure TopEdge8(U, V: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
procedure LeftEdge8(U, V: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
procedure InnerHorizontalEdge8(U, V: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
procedure InnerVerticalEdge8(U, V: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);

implementation

function Clamp(Value, Low, High: LongInt): LongInt; inline;
begin
  if Value < Low then
    Result := Low
  else if Value > High then
    Result := High
  else
    Result := Value;
end;

function SignedClip1(Value: LongInt): LongInt; inline;
begin
  Result := Clamp(Value, -128, 127);
end;

function SignedClip2(Value: LongInt): LongInt; inline;
begin
  Result := Clamp(Value, -16, 15);
end;

function ClipPixel(Value: LongInt): Byte; inline;
begin
  Result := Clamp(Value, 0, 255);
end;

{ Pixel Index steps across the edge at P (negative before it). }
function Sample(P: PByte; Index, Step: LongInt): LongInt; inline;
begin
  Result := P[Index * Step];
end;

procedure Filter2(P: PByte; Step: LongInt);
var
  P1, P0, Q0, Q1: LongInt;
  A, A1, A2: LongInt;
begin
  P1 := Sample(P, -2, Step);
  P0 := Sample(P, -1, Step);
  Q0 := Sample(P, 0, Step);
  Q1 := Sample(P, 1, Step);
  A := 3 * (Q0 - P0) + SignedClip1(P1 - Q1);
  A1 := SignedClip2(SarLongint(A + 4, 3));
  A2 := SignedClip2(SarLongint(A + 3, 3));
  P[-Step] := ClipPixel(P0 + A2);
  P[0] := ClipPixel(Q0 - A1);
end;

procedure Filter4(P: PByte; Step: LongInt);
var
  P1, P0, Q0, Q1: LongInt;
  A, A1, A2, A3: LongInt;
begin
  P1 := Sample(P, -2, Step);
  P0 := Sample(P, -1, Step);
  Q0 := Sample(P, 0, Step);
  Q1 := Sample(P, 1, Step);
  A := 3 * (Q0 - P0);
  A1 := SignedClip2(SarLongint(A + 4, 3));
  A2 := SignedClip2(SarLongint(A + 3, 3));
  A3 := SarLongint(A1 + 1, 1);
  P[-2 * Step] := ClipPixel(P1 + A3);
  P[-Step] := ClipPixel(P0 + A2);
  P[0] := ClipPixel(Q0 - A1);
  P[Step] := ClipPixel(Q1 - A3);
end;

procedure Filter6(P: PByte; Step: LongInt);
var
  P2, P1, P0, Q0, Q1, Q2: LongInt;
  A, A1, A2, A3: LongInt;
begin
  P2 := Sample(P, -3, Step);
  P1 := Sample(P, -2, Step);
  P0 := Sample(P, -1, Step);
  Q0 := Sample(P, 0, Step);
  Q1 := Sample(P, 1, Step);
  Q2 := Sample(P, 2, Step);
  A := SignedClip1(3 * (Q0 - P0) + SignedClip1(P1 - Q1));
  A1 := SarLongint(27 * A + 63, 7);
  A2 := SarLongint(18 * A + 63, 7);
  A3 := SarLongint(9 * A + 63, 7);
  P[-3 * Step] := ClipPixel(P2 + A3);
  P[-2 * Step] := ClipPixel(P1 + A2);
  P[-Step] := ClipPixel(P0 + A1);
  P[0] := ClipPixel(Q0 - A1);
  P[Step] := ClipPixel(Q1 - A2);
  P[2 * Step] := ClipPixel(Q2 - A3);
end;

function HighVariance(P: PByte; Step, Threshold: LongInt): Boolean; inline;
begin
  Result := (Abs(Sample(P, -2, Step) - Sample(P, -1, Step)) > Threshold) or
    (Abs(Sample(P, 1, Step) - Sample(P, 0, Step)) > Threshold);
end;

function NeedsSimpleFilter(P: PByte; Step, Threshold2: LongInt): Boolean; inline;
begin
  Result := 4 * Abs(Sample(P, -1, Step) - Sample(P, 0, Step)) + Abs(Sample(P, -2, Step) - Sample(P, 1, Step)) <=
    Threshold2;
end;

function NeedsNormalFilter(P: PByte; Step, Threshold2, InnerThreshold: LongInt): Boolean;
var
  P3, P2, P1, P0, Q0, Q1, Q2, Q3: LongInt;
begin
  P3 := Sample(P, -4, Step);
  P2 := Sample(P, -3, Step);
  P1 := Sample(P, -2, Step);
  P0 := Sample(P, -1, Step);
  Q0 := Sample(P, 0, Step);
  Q1 := Sample(P, 1, Step);
  Q2 := Sample(P, 2, Step);
  Q3 := Sample(P, 3, Step);
  if 4 * Abs(P0 - Q0) + Abs(P1 - Q1) > Threshold2 then
    Exit(False);
  Result := (Abs(P3 - P2) <= InnerThreshold) and (Abs(P2 - P1) <= InnerThreshold) and
    (Abs(P1 - P0) <= InnerThreshold) and (Abs(Q3 - Q2) <= InnerThreshold) and
    (Abs(Q2 - Q1) <= InnerThreshold) and (Abs(Q1 - Q0) <= InnerThreshold);
end;

{ The simple filter along 16 pixels of an edge: Step crosses it,
  Along moves along it. }
procedure SimpleEdge(P: PByte; Step, Along, Threshold: LongInt);
var
  Index: LongInt;
  Threshold2: LongInt;
begin
  Threshold2 := 2 * Threshold + 1;
  for Index := 0 to 15 do
    if NeedsSimpleFilter(P + Index * Along, Step, Threshold2) then
      Filter2(P + Index * Along, Step);
end;

procedure SimpleTopEdge16(P: PByte; Stride, Threshold: LongInt);
begin
  SimpleEdge(P, Stride, 1, Threshold);
end;

procedure SimpleLeftEdge16(P: PByte; Stride, Threshold: LongInt);
begin
  SimpleEdge(P, 1, Stride, Threshold);
end;

procedure SimpleInnerHorizontalEdges16(P: PByte; Stride, Threshold: LongInt);
var
  Edge: LongInt;
begin
  for Edge := 1 to 3 do
    SimpleEdge(P + 4 * Edge * Stride, Stride, 1, Threshold);
end;

procedure SimpleInnerVerticalEdges16(P: PByte; Stride, Threshold: LongInt);
var
  Edge: LongInt;
begin
  for Edge := 1 to 3 do
    SimpleEdge(P + 4 * Edge, 1, Stride, Threshold);
end;

{ The normal filter along Size pixels of an edge; macroblock edges
  change three pixels each side, inner edges two. }
procedure NormalEdge(P: PByte; Step, Along, Size, Threshold, InnerThreshold, HighVarianceThreshold: LongInt;
  MacroblockEdge: Boolean);
var
  Index: LongInt;
  Threshold2: LongInt;
  Q: PByte;
begin
  Threshold2 := 2 * Threshold + 1;
  for Index := 0 to Size - 1 do
  begin
    Q := P + Index * Along;
    if NeedsNormalFilter(Q, Step, Threshold2, InnerThreshold) then
    begin
      if HighVariance(Q, Step, HighVarianceThreshold) then
        Filter2(Q, Step)
      else if MacroblockEdge then
        Filter6(Q, Step)
      else
        Filter4(Q, Step);
    end;
  end;
end;

procedure TopEdge16(P: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
begin
  NormalEdge(P, Stride, 1, 16, Threshold, InnerThreshold, HighVarianceThreshold, True);
end;

procedure LeftEdge16(P: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
begin
  NormalEdge(P, 1, Stride, 16, Threshold, InnerThreshold, HighVarianceThreshold, True);
end;

procedure InnerHorizontalEdges16(P: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
var
  Edge: LongInt;
begin
  for Edge := 1 to 3 do
    NormalEdge(P + 4 * Edge * Stride, Stride, 1, 16, Threshold, InnerThreshold, HighVarianceThreshold, False);
end;

procedure InnerVerticalEdges16(P: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
var
  Edge: LongInt;
begin
  for Edge := 1 to 3 do
    NormalEdge(P + 4 * Edge, 1, Stride, 16, Threshold, InnerThreshold, HighVarianceThreshold, False);
end;

procedure TopEdge8(U, V: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
begin
  NormalEdge(U, Stride, 1, 8, Threshold, InnerThreshold, HighVarianceThreshold, True);
  NormalEdge(V, Stride, 1, 8, Threshold, InnerThreshold, HighVarianceThreshold, True);
end;

procedure LeftEdge8(U, V: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
begin
  NormalEdge(U, 1, Stride, 8, Threshold, InnerThreshold, HighVarianceThreshold, True);
  NormalEdge(V, 1, Stride, 8, Threshold, InnerThreshold, HighVarianceThreshold, True);
end;

procedure InnerHorizontalEdge8(U, V: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
begin
  NormalEdge(U + 4 * Stride, Stride, 1, 8, Threshold, InnerThreshold, HighVarianceThreshold, False);
  NormalEdge(V + 4 * Stride, Stride, 1, 8, Threshold, InnerThreshold, HighVarianceThreshold, False);
end;

procedure InnerVerticalEdge8(U, V: PByte; Stride, Threshold, InnerThreshold, HighVarianceThreshold: LongInt);
begin
  NormalEdge(U + 4, 1, Stride, 8, Threshold, InnerThreshold, HighVarianceThreshold, False);
  NormalEdge(V + 4, 1, Stride, 8, Threshold, InnerThreshold, HighVarianceThreshold, False);
end;

end.
