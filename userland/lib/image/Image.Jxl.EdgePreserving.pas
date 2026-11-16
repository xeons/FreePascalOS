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
  JPEG XL's edge preserving filter (ISO/IEC 18181-1 annex J.3): each
  sample becomes a weighted average of itself and its neighbours, a
  neighbour's weight falling with how different the patch around it is
  from the patch around the sample (summed over the three channels
  with per-channel scales), against a sigma per 8 x 8 block that comes
  from the block's quantization and sharpness (constant in modular
  frames). Up to three passes: the first (only with three iterations)
  compares 12 neighbours by 3 x 3 cross patches, the second 4
  neighbours by cross patches, the third 4 neighbours by the samples
  alone; samples on a block's edge compare more gently.

  Off the planes' edges samples are mirrored, as libjxl's render
  pipeline does.
}
unit Image.Jxl.EdgePreserving;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Jxl.Planes,
  Image.Jxl.FrameHeader;

const
  { The numerator of the inverse sigma (sigma for modular frames is this
    over the header's sigma). }
  JxlInverseSigmaNumerator = -1.1715728752538099024;

type
  TJxlEpfSigma = record
    BlockColumns: LongInt;
    BlockRows: LongInt;
    { Inverse sigma of each 8 x 8 block, line after line. }
    InverseSigma: array of Single;
  end;

{ A sigma of InverseSigma for every block of a Width x Height plane. }
function JxlConstantEpfSigma(Width, Height: LongInt; InverseSigma: Single): TJxlEpfSigma;
{ Filters planes 0 to 2 (of one size) in place. }
procedure ApplyJxlEdgePreservingFilter(const Planes: TJxlPlaneSet; const Filter: TJxlLoopFilter;
  const Sigma: TJxlEpfSigma);

implementation

const
  MinimumSigma = -3.90524291751269967465540850526868;

type
  { A plane with Border mirrored samples around it. }
  TPaddedPlane = record
    Stride: LongInt;
    Border: LongInt;
    Samples: array of Single;
  end;

function JxlConstantEpfSigma(Width, Height: LongInt; InverseSigma: Single): TJxlEpfSigma;
var
  Index: PtrInt;
begin
  Result.BlockColumns := (Width + 7) div 8;
  Result.BlockRows := (Height + 7) div 8;
  SetLength(Result.InverseSigma, PtrInt(Result.BlockColumns) * Result.BlockRows);
  for Index := 0 to High(Result.InverseSigma) do
    Result.InverseSigma[Index] := InverseSigma;
end;

function PadPlane(Plane: TJxlPlane; Border: LongInt): TPaddedPlane;
var
  X: LongInt;
  Y: LongInt;
  Line: PSingle;
  Source: PSingle;
begin
  Result.Border := Border;
  Result.Stride := Plane.Width + 2 * Border;
  SetLength(Result.Samples, PtrInt(Result.Stride) * (Plane.Height + 2 * Border));
  for Y := -Border to Plane.Height + Border - 1 do
  begin
    Line := PSingle(@Result.Samples[0]) + PtrInt(Y + Border) * Result.Stride + Border;
    Source := Plane.Row(JxlMirror(Y, Plane.Height));
    for X := -Border to Plane.Width + Border - 1 do
      Line[X] := Source[JxlMirror(X, Plane.Width)];
  end;
end;

{ The sample at (X, Y) of a padded plane. }
function At(const Padded: TPaddedPlane; X, Y: LongInt): Single; inline;
begin
  Result := Padded.Samples[PtrInt(Y + Padded.Border) * Padded.Stride + X + Padded.Border];
end;

function Weight(Sad, InverseSigma: Single): Single; inline;
begin
  Result := Sad * InverseSigma + 1.0;
  if Result < 0 then
    Result := 0;
end;

function SadMultiplier(X, Y: LongInt; Center, BorderValue: Single): Single; inline;
begin
  if ((Y and 7) = 0) or ((Y and 7) = 7) or ((X and 7) = 0) or ((X and 7) = 7) then
    Result := BorderValue
  else
    Result := Center;
end;

procedure RunPass(const Planes: TJxlPlaneSet; const Filter: TJxlLoopFilter; const Sigma: TJxlEpfSigma;
  Stage: LongInt);
const
  Neighbours12: array[0..11, 0..1] of LongInt = (
    (-2, 0), (-1, -1), (-1, 0), (-1, 1), (0, -2), (0, -1), (0, 1), (0, 2), (1, -1), (1, 0), (1, 1), (2, 0));
  Neighbours4: array[0..3, 0..1] of LongInt = ((-1, 0), (0, -1), (0, 1), (1, 0));
  Cross: array[0..4, 0..1] of LongInt = ((0, 0), (-1, 0), (0, -1), (1, 0), (0, 1));
var
  Padded: array[0..2] of TPaddedPlane;
  Border: LongInt;
  Width: LongInt;
  Height: LongInt;
  Channel: LongInt;
  X: LongInt;
  Y: LongInt;
  BlockSigma: Single;
  CenterMultiplier: Single;
  BorderMultiplier: Single;
  InverseSigma: Single;
  Count: LongInt;
  Index: LongInt;
  Part: LongInt;
  RowOffset: LongInt;
  ColumnOffset: LongInt;
  Sad: Single;
  ChannelSad: Single;
  Total: array[0..2] of Single;
  WeightSum: Single;
  NeighbourWeight: Single;
  Center: array[0..2] of Single;
begin
  case Stage of
    0:
      begin
        Border := 3;
        CenterMultiplier := Filter.EpfPass0SigmaScale * 1.65;
      end;
    1:
      begin
        Border := 2;
        CenterMultiplier := 1.65;
      end;
  else
    begin
      Border := 1;
      CenterMultiplier := Filter.EpfPass2SigmaScale * 1.65;
    end;
  end;
  BorderMultiplier := CenterMultiplier * Filter.EpfBorderSadMultiplier;
  Width := Planes[0].Width;
  Height := Planes[0].Height;
  for Channel := 0 to 2 do
    Padded[Channel] := PadPlane(Planes[Channel], Border);
  if Stage = 0 then
    Count := 12
  else
    Count := 4;
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      BlockSigma := Sigma.InverseSigma[PtrInt(Y div 8) * Sigma.BlockColumns + X div 8];
      if BlockSigma < MinimumSigma then
        Continue;
      if ((Y and 7) = 0) or ((Y and 7) = 7) then
        InverseSigma := BlockSigma * BorderMultiplier
      else
        InverseSigma := BlockSigma * SadMultiplier(X, Y, CenterMultiplier, BorderMultiplier);
      for Channel := 0 to 2 do
      begin
        Center[Channel] := At(Padded[Channel], X, Y);
        Total[Channel] := Center[Channel];
      end;
      WeightSum := 1;
      for Index := 0 to Count - 1 do
      begin
        if Stage = 0 then
        begin
          RowOffset := Neighbours12[Index, 0];
          ColumnOffset := Neighbours12[Index, 1];
        end
        else
        begin
          RowOffset := Neighbours4[Index, 0];
          ColumnOffset := Neighbours4[Index, 1];
        end;
        Sad := 0;
        for Channel := 0 to 2 do
        begin
          ChannelSad := 0;
          if Stage = 2 then
            ChannelSad := Abs(At(Padded[Channel], X + ColumnOffset, Y + RowOffset) - Center[Channel])
          else
            for Part := 0 to 4 do
              ChannelSad := ChannelSad + Abs(At(Padded[Channel], X + Cross[Part, 1], Y + Cross[Part, 0]) -
                At(Padded[Channel], X + ColumnOffset + Cross[Part, 1], Y + RowOffset + Cross[Part, 0]));
          Sad := Sad + ChannelSad * Filter.EpfChannelScale[Channel];
        end;
        NeighbourWeight := Weight(Sad, InverseSigma);
        WeightSum := WeightSum + NeighbourWeight;
        for Channel := 0 to 2 do
          Total[Channel] := Total[Channel] + NeighbourWeight * At(Padded[Channel], X + ColumnOffset, Y + RowOffset);
      end;
      for Channel := 0 to 2 do
        Planes[Channel].Row(Y)[X] := Total[Channel] / WeightSum;
    end;
end;

procedure ApplyJxlEdgePreservingFilter(const Planes: TJxlPlaneSet; const Filter: TJxlLoopFilter;
  const Sigma: TJxlEpfSigma);
begin
  if (Filter.EpfIterations = 0) or (Length(Planes) < 3) then
    Exit;
  if (Sigma.BlockColumns * 8 < Planes[0].Width) or (Sigma.BlockRows * 8 < Planes[0].Height) then
    Exit;
  if Filter.EpfIterations >= 3 then
    RunPass(Planes, Filter, Sigma, 0);
  RunPass(Planes, Filter, Sigma, 1);
  if Filter.EpfIterations >= 2 then
    RunPass(Planes, Filter, Sigma, 2);
end;

end.
