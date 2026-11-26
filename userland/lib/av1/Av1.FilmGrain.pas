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
  The film grain synthesis process (specification section 7.18.3): the
  grain templates (Av1.FilmGrainNoise) are cut into 32x32 blocks at
  pseudo-random offsets, laid out in stripes 32 luma rows high (blended
  across block and stripe edges when overlap_flag is set), scaled by
  the piecewise linear functions of the samples (Av1.FilmGrainScaling)
  and added to the picture.

  The specification builds every stripe and the whole noise image
  before adding it; here a stripe is built, its rows are added, and it
  is kept only for blending with the next stripe, which gives the same
  samples with two stripes of memory.
}
unit Av1.FilmGrain;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Constants, Av1.SequenceHeader, Av1.FrameHeader, Av1.Picture,
  Av1.FilmGrainNoise, Av1.FilmGrainScaling;

{ Adds the grain of Params to the Width by Height (luma) picture Source,
  writing the result to Target, an allocated picture of the same format
  (OutY, OutU and OutV of the specification). }
procedure ApplyFilmGrain(Source: TPicture; Width, Height: Integer; const Sequence: TSequenceHeader;
  const Params: TFilmGrainParams; Target: TPicture);

implementation

const
  StripeRows = 34;

type
  { noiseStripe[ lumaNum ][ plane ] for one stripe: StripeRows rows of Stride. }
  TNoiseStripe = array[0..2] of array of Integer;

  TGrainJob = record
    Templates: PGrainTemplates;
    Scaling: TScalingLookup;
    Width, Height, SubX, SubY, NumPlanes, BitDepth: Integer;
    Stride: Integer;
    Overlap: Boolean;
    MinValue, MaxLuma, MaxChroma, ScalingShift: Integer;
  end;

function PlaneSubsampling(Plane, Subsampling: Integer): Integer; inline;
begin
  if Plane > 0 then
    Result := Subsampling
  else
    Result := 0;
end;

function GrainSample(const Templates: TGrainTemplates; Plane, Y, X: Integer): Integer; inline;
begin
  if Plane = 0 then
    Result := Templates.LumaGrain[Y, X]
  else if Plane = 1 then
    Result := Templates.CbGrain[Y, X]
  else
    Result := Templates.CrGrain[Y, X];
end;

procedure BuildNoiseStripe(const Job: TGrainJob; var Stripe: TNoiseStripe; LumaNum, GrainSeed: Integer);
var
  RandomRegister, X, Plane, PlaneSubX, PlaneSubY, PlaneOffsetX, PlaneOffsetY, OffsetX, OffsetY,
    RandomValue, I, J, Grain, Old, Column: Integer;
  Templates: PGrainTemplates;
begin
  Templates := Job.Templates;
  RandomRegister := GrainSeed;
  RandomRegister := RandomRegister xor (((LumaNum * 37 + 178) and 255) shl 8);
  RandomRegister := RandomRegister xor ((LumaNum * 173 + 105) and 255);
  X := 0;
  while X < (Job.Width + 1) div 2 do
  begin
    RandomValue := GetRandomNumber(RandomRegister, 8);
    OffsetX := RandomValue shr 4;
    OffsetY := RandomValue and 15;
    for Plane := 0 to Job.NumPlanes - 1 do
    begin
      PlaneSubX := PlaneSubsampling(Plane, Job.SubX);
      PlaneSubY := PlaneSubsampling(Plane, Job.SubY);
      if PlaneSubX <> 0 then
        PlaneOffsetX := 6 + OffsetX
      else
        PlaneOffsetX := 9 + OffsetX * 2;
      if PlaneSubY <> 0 then
        PlaneOffsetY := 6 + OffsetY
      else
        PlaneOffsetY := 9 + OffsetY * 2;
      for I := 0 to (StripeRows shr PlaneSubY) - 1 do
        for J := 0 to (StripeRows shr PlaneSubX) - 1 do
        begin
          Grain := GrainSample(Templates^, Plane, PlaneOffsetY + I, PlaneOffsetX + J);
          if PlaneSubX = 0 then
          begin
            Column := X * 2 + J;
            if (J < 2) and Job.Overlap and (X > 0) then
            begin
              Old := Stripe[Plane][I * Job.Stride + Column];
              if J = 0 then
                Grain := Old * 27 + Grain * 17
              else
                Grain := Old * 17 + Grain * 27;
              Grain := Clip3(Templates^.GrainMin, Templates^.GrainMax, Round2(Grain, 5));
            end;
          end
          else
          begin
            Column := X + J;
            if (J = 0) and Job.Overlap and (X > 0) then
            begin
              Old := Stripe[Plane][I * Job.Stride + Column];
              Grain := Old * 23 + Grain * 22;
              Grain := Clip3(Templates^.GrainMin, Templates^.GrainMax, Round2(Grain, 5));
            end;
          end;
          Stripe[Plane][I * Job.Stride + Column] := Grain;
        end;
    end;
    Inc(X, 16);
  end;
end;

{ One row of noiseImage[ plane ]: row I of stripe LumaNum, blended with the
  previous stripe's last rows. }
procedure BuildNoiseRow(const Job: TGrainJob; const Current, Previous: TNoiseStripe; Plane, LumaNum,
  I, Count: Integer; Row: PInteger);
var
  X, Grain, Old: Integer;
  PlaneSubY: Integer;
  Blend: Boolean;
  CurrentRow, PreviousRow: PInteger;
begin
  PlaneSubY := PlaneSubsampling(Plane, Job.SubY);
  CurrentRow := @Current[Plane][I * Job.Stride];
  if PlaneSubY = 0 then
    Blend := (I < 2) and (LumaNum > 0) and Job.Overlap
  else
    Blend := (I < 1) and (LumaNum > 0) and Job.Overlap;
  if not Blend then
  begin
    Move(CurrentRow^, Row^, Count * SizeOf(Integer));
    Exit;
  end;
  if PlaneSubY = 0 then
    PreviousRow := @Previous[Plane][(I + 32) * Job.Stride]
  else
    PreviousRow := @Previous[Plane][(I + 16) * Job.Stride];
  for X := 0 to Count - 1 do
  begin
    Old := PreviousRow[X];
    Grain := CurrentRow[X];
    if PlaneSubY = 0 then
    begin
      if I = 0 then
        Grain := Old * 27 + Grain * 17
      else
        Grain := Old * 17 + Grain * 27;
    end
    else
      Grain := Old * 23 + Grain * 22;
    Row[X] := Clip3(Job.Templates^.GrainMin, Job.Templates^.GrainMax, Round2(Grain, 5));
  end;
end;

procedure AddLumaNoise(const Job: TGrainJob; Source, Target: TPicture; Y: Integer; Noise: PInteger);
var
  X, Original, Scaled: Integer;
  SourceRow, TargetRow: PWord;
begin
  SourceRow := Source.Row(0, Y);
  TargetRow := Target.Row(0, Y);
  for X := 0 to Job.Width - 1 do
  begin
    Original := SourceRow[X];
    Scaled := Round2(ScaleLookup(Job.Scaling, 0, Original, Job.BitDepth) * Noise[X], Job.ScalingShift);
    TargetRow[X] := Clip3(Job.MinValue, Job.MaxLuma, Original + Scaled);
  end;
end;

function MergeChroma(const Job: TGrainJob; AverageLuma, Original, LumaMultiplier, Multiplier,
  Offset: Integer): Integer; inline;
var
  Combined: Integer;
begin
  Combined := AverageLuma * (LumaMultiplier - 128) + Original * (Multiplier - 128);
  Result := Clip3(0, (1 shl Job.BitDepth) - 1,
    ShiftRight(Combined, 6) + ((Offset - 256) shl (Job.BitDepth - 8)));
end;

procedure AddChromaNoise(const Job: TGrainJob; const Params: TFilmGrainParams; Source, Target: TPicture;
  Y: Integer; NoiseU, NoiseV: PInteger);
var
  X, ChromaWidth, LumaX, LumaY, LumaNextX, AverageLuma, Original, Merged, Scaled: Integer;
  LumaRow, SourceU, SourceV, TargetU, TargetV: PWord;
  ApplyU, ApplyV: Boolean;
begin
  ApplyU := (Params.num_cb_points > 0) or Params.chroma_scaling_from_luma;
  ApplyV := (Params.num_cr_points > 0) or Params.chroma_scaling_from_luma;
  if not (ApplyU or ApplyV) then
    Exit;
  ChromaWidth := (Job.Width + Job.SubX) shr Job.SubX;
  LumaY := Y shl Job.SubY;
  LumaRow := Source.Row(0, LumaY);
  SourceU := Source.Row(1, Y);
  SourceV := Source.Row(2, Y);
  TargetU := Target.Row(1, Y);
  TargetV := Target.Row(2, Y);
  for X := 0 to ChromaWidth - 1 do
  begin
    LumaX := X shl Job.SubX;
    if Job.SubX <> 0 then
    begin
      LumaNextX := Min(LumaX + 1, Job.Width - 1);
      AverageLuma := Round2(LumaRow[LumaX] + LumaRow[LumaNextX], 1);
    end
    else
      AverageLuma := LumaRow[LumaX];
    if ApplyU then
    begin
      Original := SourceU[X];
      if Params.chroma_scaling_from_luma then
        Merged := AverageLuma
      else
        Merged := MergeChroma(Job, AverageLuma, Original, Params.cb_luma_mult, Params.cb_mult, Params.cb_offset);
      Scaled := Round2(ScaleLookup(Job.Scaling, 1, Merged, Job.BitDepth) * NoiseU[X], Job.ScalingShift);
      TargetU[X] := Clip3(Job.MinValue, Job.MaxChroma, Original + Scaled);
    end;
    if ApplyV then
    begin
      Original := SourceV[X];
      if Params.chroma_scaling_from_luma then
        Merged := AverageLuma
      else
        Merged := MergeChroma(Job, AverageLuma, Original, Params.cr_luma_mult, Params.cr_mult, Params.cr_offset);
      Scaled := Round2(ScaleLookup(Job.Scaling, 2, Merged, Job.BitDepth) * NoiseV[X], Job.ScalingShift);
      TargetV[X] := Clip3(Job.MinValue, Job.MaxChroma, Original + Scaled);
    end;
  end;
end;

procedure CopyVisibleSamples(Source, Target: TPicture; Width, Height, NumPlanes, SubX, SubY: Integer);
var
  Plane, Y, PlaneWidth, PlaneHeight: Integer;
begin
  for Plane := 0 to NumPlanes - 1 do
  begin
    PlaneWidth := (Width + PlaneSubsampling(Plane, SubX)) shr PlaneSubsampling(Plane, SubX);
    PlaneHeight := (Height + PlaneSubsampling(Plane, SubY)) shr PlaneSubsampling(Plane, SubY);
    for Y := 0 to PlaneHeight - 1 do
      Move(Source.Row(Plane, Y)^, Target.Row(Plane, Y)^, PlaneWidth * SizeOf(Word));
  end;
end;

procedure SetUpJob(var Job: TGrainJob; Width, Height: Integer; const Sequence: TSequenceHeader;
  const Params: TFilmGrainParams);
var
  Shift: Integer;
begin
  Job.Width := Width;
  Job.Height := Height;
  Job.SubX := Sequence.subsampling_x;
  Job.SubY := Sequence.subsampling_y;
  Job.NumPlanes := Sequence.NumPlanes;
  Job.BitDepth := Sequence.BitDepth;
  Job.Overlap := Params.overlap_flag;
  Job.Stride := AlignUp(Width, 32) + 64;
  Shift := Sequence.BitDepth - 8;
  if Params.clip_to_restricted_range then
  begin
    Job.MinValue := 16 shl Shift;
    Job.MaxLuma := 235 shl Shift;
    if Sequence.matrix_coefficients = MC_IDENTITY then
      Job.MaxChroma := Job.MaxLuma
    else
      Job.MaxChroma := 240 shl Shift;
  end
  else
  begin
    Job.MinValue := 0;
    Job.MaxLuma := (256 shl Shift) - 1;
    Job.MaxChroma := Job.MaxLuma;
  end;
  Job.ScalingShift := Params.grain_scaling_minus_8 + 8;
  InitializeScalingLookup(Job.Scaling, Params, Job.NumPlanes);
end;

procedure ApplyFilmGrain(Source: TPicture; Width, Height: Integer; const Sequence: TSequenceHeader;
  const Params: TFilmGrainParams; Target: TPicture);
var
  Job: TGrainJob;
  Current, Previous, Swap: TNoiseStripe;
  NoiseRows: array[0..2] of array of Integer;
  Plane, LumaNum, StripeCount, ChromaRowsPerStripe, I, Y, ChromaHeight, ChromaWidth: Integer;
begin
  CopyVisibleSamples(Source, Target, Width, Height, Sequence.NumPlanes, Sequence.subsampling_x,
    Sequence.subsampling_y);
  New(Job.Templates);
  try
    GenerateGrain(Job.Templates^, Sequence, Params);
    SetUpJob(Job, Width, Height, Sequence, Params);
    for Plane := 0 to Job.NumPlanes - 1 do
    begin
      SetLength(Current[Plane], StripeRows * Job.Stride);
      SetLength(Previous[Plane], StripeRows * Job.Stride);
      SetLength(NoiseRows[Plane], Job.Stride);
    end;
    StripeCount := ((Height + 1) div 2 + 15) div 16;
    ChromaRowsPerStripe := 32 shr Job.SubY;
    ChromaHeight := (Height + Job.SubY) shr Job.SubY;
    ChromaWidth := (Width + Job.SubX) shr Job.SubX;
    for LumaNum := 0 to StripeCount - 1 do
    begin
      BuildNoiseStripe(Job, Current, LumaNum, Params.grain_seed);
      if Job.NumPlanes > 1 then
        for I := 0 to ChromaRowsPerStripe - 1 do
        begin
          Y := LumaNum * ChromaRowsPerStripe + I;
          if Y >= ChromaHeight then
            Break;
          BuildNoiseRow(Job, Current, Previous, 1, LumaNum, I, ChromaWidth, @NoiseRows[1][0]);
          BuildNoiseRow(Job, Current, Previous, 2, LumaNum, I, ChromaWidth, @NoiseRows[2][0]);
          AddChromaNoise(Job, Params, Source, Target, Y, @NoiseRows[1][0], @NoiseRows[2][0]);
        end;
      if Params.num_y_points > 0 then
        for I := 0 to 31 do
        begin
          Y := LumaNum * 32 + I;
          if Y >= Height then
            Break;
          BuildNoiseRow(Job, Current, Previous, 0, LumaNum, I, Width, @NoiseRows[0][0]);
          AddLumaNoise(Job, Source, Target, Y, @NoiseRows[0][0]);
        end;
      Swap := Previous;
      Previous := Current;
      Current := Swap;
    end;
  finally
    Dispose(Job.Templates);
  end;
end;

end.
