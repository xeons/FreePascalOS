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
  The grain templates of the film grain synthesis (specification
  sections 7.18.3.2 and 7.18.3.3): the pseudo-random number generator,
  white Gaussian noise from Gaussian_Sequence, and the auto-regressive
  filter that shapes it (LumaGrain, CbGrain, CrGrain). Everything lives
  in a TGrainTemplates record, so frames can be given grain on several
  threads at once.
}
unit Av1.FilmGrainNoise;

{$mode objfpc}

interface

uses
  Av1.Common, Av1.Tables, Av1.SequenceHeader, Av1.FrameHeader;

const
  LumaGrainWidth = 82;
  LumaGrainHeight = 73;

type
  TGrainArray = array[0..LumaGrainHeight - 1, 0..LumaGrainWidth - 1] of Integer;

  TGrainTemplates = record
    RandomRegister: Integer;
    GrainMin, GrainMax: Integer;
    LumaGrain, CbGrain, CrGrain: TGrainArray;
    ChromaWidth, ChromaHeight: Integer;
  end;
  PGrainTemplates = ^TGrainTemplates;

{ get_random_number( bits ) of the specification. }
function GetRandomNumber(var RandomRegister: Integer; Bits: Integer): Integer; inline;
{ The generate grain process: GrainMin/GrainMax and the three templates. }
procedure GenerateGrain(var Templates: TGrainTemplates; const Sequence: TSequenceHeader;
  const Params: TFilmGrainParams);

implementation

function GetRandomNumber(var RandomRegister: Integer; Bits: Integer): Integer;
var
  Register, Bit: Integer;
begin
  Register := RandomRegister;
  Bit := (Register xor (Register shr 1) xor (Register shr 3) xor (Register shr 12)) and 1;
  Register := (Register shr 1) or (Bit shl 15);
  Result := (Register shr (16 - Bits)) and ((1 shl Bits) - 1);
  RandomRegister := Register;
end;

procedure FillWhiteNoise(var Grain: TGrainArray; Width, Height: Integer; var RandomRegister: Integer;
  Enabled: Boolean; Shift: Integer);
var
  X, Y, Value: Integer;
begin
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      if Enabled then
        Value := Gaussian_Sequence[GetRandomNumber(RandomRegister, 11)]
      else
        Value := 0;
      Grain[Y, X] := Round2(Value, Shift);
    end;
end;

procedure FilterLumaGrain(var Templates: TGrainTemplates; const Params: TFilmGrainParams);
var
  X, Y, DeltaRow, DeltaCol, Sum, Position, Shift, Lag: Integer;
begin
  Shift := Params.ar_coeff_shift_minus_6 + 6;
  Lag := Params.ar_coeff_lag;
  for Y := 3 to LumaGrainHeight - 1 do
    for X := 3 to LumaGrainWidth - 3 - 1 do
    begin
      Sum := 0;
      Position := 0;
      for DeltaRow := -Lag to 0 do
        for DeltaCol := -Lag to Lag do
        begin
          if (DeltaRow = 0) and (DeltaCol = 0) then
            Break;
          Inc(Sum, Templates.LumaGrain[Y + DeltaRow, X + DeltaCol] *
            (Params.ar_coeffs_y_plus_128[Position] - 128));
          Inc(Position);
        end;
      Templates.LumaGrain[Y, X] := Clip3(Templates.GrainMin, Templates.GrainMax,
        Templates.LumaGrain[Y, X] + Round2(Sum, Shift));
    end;
end;

function AverageLumaGrain(const Templates: TGrainTemplates; X, Y, SubX, SubY: Integer): Integer;
var
  LumaX, LumaY, I, J: Integer;
begin
  Result := 0;
  LumaX := ((X - 3) shl SubX) + 3;
  LumaY := ((Y - 3) shl SubY) + 3;
  for I := 0 to SubY do
    for J := 0 to SubX do
      Inc(Result, Templates.LumaGrain[LumaY + I, LumaX + J]);
  Result := Round2(Result, SubX + SubY);
end;

procedure FilterChromaGrain(var Templates: TGrainTemplates; const Sequence: TSequenceHeader;
  const Params: TFilmGrainParams);
var
  X, Y, DeltaRow, DeltaCol, SumCb, SumCr, Position, Shift, Lag, CoefficientCb, CoefficientCr,
    Luma: Integer;
begin
  Shift := Params.ar_coeff_shift_minus_6 + 6;
  Lag := Params.ar_coeff_lag;
  for Y := 3 to Templates.ChromaHeight - 1 do
    for X := 3 to Templates.ChromaWidth - 3 - 1 do
    begin
      SumCb := 0;
      SumCr := 0;
      Position := 0;
      for DeltaRow := -Lag to 0 do
        for DeltaCol := -Lag to Lag do
        begin
          CoefficientCb := Params.ar_coeffs_cb_plus_128[Position] - 128;
          CoefficientCr := Params.ar_coeffs_cr_plus_128[Position] - 128;
          if (DeltaRow = 0) and (DeltaCol = 0) then
          begin
            if Params.num_y_points > 0 then
            begin
              Luma := AverageLumaGrain(Templates, X, Y, Sequence.subsampling_x, Sequence.subsampling_y);
              Inc(SumCb, Luma * CoefficientCb);
              Inc(SumCr, Luma * CoefficientCr);
            end;
            Break;
          end;
          Inc(SumCb, Templates.CbGrain[Y + DeltaRow, X + DeltaCol] * CoefficientCb);
          Inc(SumCr, Templates.CrGrain[Y + DeltaRow, X + DeltaCol] * CoefficientCr);
          Inc(Position);
        end;
      Templates.CbGrain[Y, X] := Clip3(Templates.GrainMin, Templates.GrainMax,
        Templates.CbGrain[Y, X] + Round2(SumCb, Shift));
      Templates.CrGrain[Y, X] := Clip3(Templates.GrainMin, Templates.GrainMax,
        Templates.CrGrain[Y, X] + Round2(SumCr, Shift));
    end;
end;

procedure GenerateGrain(var Templates: TGrainTemplates; const Sequence: TSequenceHeader;
  const Params: TFilmGrainParams);
var
  GrainCenter, Shift: Integer;
  ChromaEnabled: Boolean;
begin
  GrainCenter := 128 shl (Sequence.BitDepth - 8);
  Templates.GrainMin := -GrainCenter;
  Templates.GrainMax := (256 shl (Sequence.BitDepth - 8)) - 1 - GrainCenter;
  Shift := 12 - Sequence.BitDepth + Params.grain_scale_shift;
  Templates.RandomRegister := Params.grain_seed;
  FillWhiteNoise(Templates.LumaGrain, LumaGrainWidth, LumaGrainHeight, Templates.RandomRegister,
    Params.num_y_points > 0, Shift);
  FilterLumaGrain(Templates, Params);
  if Sequence.mono_chrome then
    Exit;
  if Sequence.subsampling_x <> 0 then
    Templates.ChromaWidth := 44
  else
    Templates.ChromaWidth := 82;
  if Sequence.subsampling_y <> 0 then
    Templates.ChromaHeight := 38
  else
    Templates.ChromaHeight := 73;
  Templates.RandomRegister := Params.grain_seed xor $B524;
  ChromaEnabled := (Params.num_cb_points > 0) or Params.chroma_scaling_from_luma;
  FillWhiteNoise(Templates.CbGrain, Templates.ChromaWidth, Templates.ChromaHeight,
    Templates.RandomRegister, ChromaEnabled, Shift);
  Templates.RandomRegister := Params.grain_seed xor $49D8;
  ChromaEnabled := (Params.num_cr_points > 0) or Params.chroma_scaling_from_luma;
  FillWhiteNoise(Templates.CrGrain, Templates.ChromaWidth, Templates.ChromaHeight,
    Templates.RandomRegister, ChromaEnabled, Shift);
  FilterChromaGrain(Templates, Sequence, Params);
end;

end.
