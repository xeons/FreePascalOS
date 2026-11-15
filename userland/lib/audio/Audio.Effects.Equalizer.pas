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
  The equalizer: four bands, each a peaking filter that raises or lowers
  the sound around its Frequency by Gain (linear: 2.0 is +6 dB, 0.5 is
  -6 dB), over Bandwidth octaves. A band with Gain 1 leaves the sound as
  it is.

  Each band is a biquad (the "peaking EQ" of Robert Bristow-Johnson's
  cookbook); the coefficients are worked out again when the parameters
  or the rate change.
}
unit Audio.Effects.Equalizer;

{$mode objfpc}
{$pointermath on}

interface

uses
  Audio.EffectChain;

const
  EqualizerBands = 4;

type
  TEqualizerBand = record
    Frequency: Single;
    Gain: Single;
    Bandwidth: Single;
  end;

  TEqualizerParameters = record
    Bands: array[0..EqualizerBands - 1] of TEqualizerBand;
  end;

{ 100, 800, 2000 and 10000 Hz, a gain of 1 and an octave wide. }
function DefaultEqualizerParameters: TEqualizerParameters;
function CreateEqualizer(const Parameters: TEqualizerParameters): PAudioEffect;

implementation

type
  TBiquad = record
    B0, B1, B2, A1, A2: Single;
  end;

  { The last two inputs and outputs of one band on one channel. }
  TBiquadHistory = record
    X1, X2, Y1, Y2: Single;
  end;

  PEqualizerState = ^TEqualizerState;
  TEqualizerState = record
    Parameters: TEqualizerParameters;
    Rate: LongWord;
    Filters: array[0..EqualizerBands - 1] of TBiquad;
    History: array[0..7, 0..EqualizerBands - 1] of TBiquadHistory;
  end;

function DefaultEqualizerParameters: TEqualizerParameters;
const
  Centres: array[0..EqualizerBands - 1] of Single = (100, 800, 2000, 10000);
var
  Band: Integer;
begin
  for Band := 0 to EqualizerBands - 1 do
  begin
    Result.Bands[Band].Frequency := Centres[Band];
    Result.Bands[Band].Gain := 1;
    Result.Bands[Band].Bandwidth := 1;
  end;
end;

function HyperbolicSine(X: Double): Double;
begin
  Result := (Exp(X) - Exp(-X)) / 2;
end;

procedure DesignPeakingFilter(const Band: TEqualizerBand; Rate: LongWord; out Filter: TBiquad);
var
  A: Double;
  Omega: Double;
  Alpha: Double;
  Cosine: Double;
  A0: Double;
begin
  { The amplitude at the centre is Gain: A is its square root. }
  A := Sqrt(Band.Gain);
  Omega := 2 * Pi * Band.Frequency / Rate;
  Alpha := Sin(Omega) * HyperbolicSine(Ln(2) / 2 * Band.Bandwidth * Omega / Sin(Omega));
  Cosine := Cos(Omega);
  A0 := 1 + Alpha / A;
  Filter.B0 := (1 + Alpha * A) / A0;
  Filter.B1 := -2 * Cosine / A0;
  Filter.B2 := (1 - Alpha * A) / A0;
  Filter.A1 := -2 * Cosine / A0;
  Filter.A2 := (1 - Alpha / A) / A0;
end;

procedure DesignFilters(State: PEqualizerState; Rate: LongWord);
var
  Band: Integer;
begin
  for Band := 0 to EqualizerBands - 1 do
    DesignPeakingFilter(State^.Parameters.Bands[Band], Rate, State^.Filters[Band]);
  State^.Rate := Rate;
end;

procedure EqualizerProcess(Effect: PAudioEffect; Samples: PSingle; Frames, Channels, Rate: LongWord);
var
  State: PEqualizerState;
  Band: Integer;
  Channel: LongWord;
  Frame: LongWord;
  Input: Single;
  Output: Single;
begin
  State := PEqualizerState(Effect^.State);
  if State^.Rate <> Rate then
    DesignFilters(State, Rate);
  if Channels > 8 then
    Channels := 8;
  for Band := 0 to EqualizerBands - 1 do
  begin
    if State^.Parameters.Bands[Band].Gain = 1 then
      Continue;
    with State^.Filters[Band] do
      for Channel := 0 to Channels - 1 do
        with State^.History[Channel][Band] do
          for Frame := 0 to Frames - 1 do
          begin
            Input := Samples[Frame * Channels + Channel];
            Output := B0 * Input + B1 * X1 + B2 * X2 - A1 * Y1 - A2 * Y2;
            X2 := X1;
            X1 := Input;
            Y2 := Y1;
            Y1 := Output;
            Samples[Frame * Channels + Channel] := Output;
          end;
  end;
end;

procedure EqualizerSetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
var
  State: PEqualizerState;
  Wanted: TEqualizerParameters;
  Band: Integer;
begin
  if Size <> SizeOf(TEqualizerParameters) then
    Exit;
  Wanted := TEqualizerParameters(Parameters^);
  for Band := 0 to EqualizerBands - 1 do
    with Wanted.Bands[Band] do
      if (Frequency < 20) or (Frequency > 20000) or (Gain < 0.126) or (Gain > 7.94) or (Bandwidth < 0.1) or
         (Bandwidth > 2) then
        Exit;
  State := PEqualizerState(Effect^.State);
  State^.Parameters := Wanted;
  if State^.Rate <> 0 then
    DesignFilters(State, State^.Rate);
end;

procedure EqualizerGetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
begin
  if Size = SizeOf(TEqualizerParameters) then
    TEqualizerParameters(Parameters^) := PEqualizerState(Effect^.State)^.Parameters;
end;

procedure EqualizerReset(Effect: PAudioEffect);
var
  State: PEqualizerState;
begin
  State := PEqualizerState(Effect^.State);
  FillChar(State^.History, SizeOf(State^.History), 0);
end;

function CreateEqualizer(const Parameters: TEqualizerParameters): PAudioEffect;
begin
  Result := CreateEffect(SizeOf(TEqualizerState));
  if Result = nil then
    Exit;
  Result^.Process := @EqualizerProcess;
  Result^.SetParameters := @EqualizerSetParameters;
  Result^.GetParameters := @EqualizerGetParameters;
  Result^.Reset := @EqualizerReset;
  PEqualizerState(Result^.State)^.Parameters := DefaultEqualizerParameters;
  EqualizerSetParameters(Result, @Parameters, SizeOf(Parameters));
end;

end.
