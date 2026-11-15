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
  Effects on loudness: a volume meter and a limiter.

  The volume meter leaves the sound as it is and measures each pass: the
  peak and the RMS level of every channel. GetParameters with a
  TMeterLevels reads the last pass's.

  The limiter keeps the sound under Threshold (linear, 1.0 is full
  scale). Its gain drops at once to hold a peak under the threshold, and
  recovers over ReleaseMilliseconds. Channels share the gain, so the
  balance between them stays.
}
unit Audio.Effects.Dynamics;

{$mode objfpc}
{$pointermath on}

interface

uses
  Audio.EffectChain;

type
  TMeterLevels = record
    Channels: LongWord;
    Peak: array[0..7] of Single;
    Rms: array[0..7] of Single;
  end;

  TLimiterParameters = record
    Threshold: Single;
    ReleaseMilliseconds: Single;
  end;

function CreateVolumeMeter: PAudioEffect;
function DefaultLimiterParameters: TLimiterParameters;
function CreateLimiter(const Parameters: TLimiterParameters): PAudioEffect;

implementation

type
  PMeterState = ^TMeterState;
  TMeterState = record
    Levels: TMeterLevels;
  end;

  PLimiterState = ^TLimiterState;
  TLimiterState = record
    Parameters: TLimiterParameters;
    Envelope: Single;
  end;

{ --- Volume meter ------------------------------------------------------------ }

procedure MeterProcess(Effect: PAudioEffect; Samples: PSingle; Frames, Channels, Rate: LongWord);
var
  Levels: ^TMeterLevels;
  Channel: LongWord;
  Frame: LongWord;
  Value: Single;
  Peak: Single;
  Sum: Double;
begin
  Levels := @PMeterState(Effect^.State)^.Levels;
  if Channels > 8 then
    Channels := 8;
  Levels^.Channels := Channels;
  for Channel := 0 to Channels - 1 do
  begin
    Peak := 0;
    Sum := 0;
    for Frame := 0 to Frames - 1 do
    begin
      Value := Abs(Samples[Frame * Channels + Channel]);
      if Value > Peak then
        Peak := Value;
      Sum := Sum + Value * Value;
    end;
    Levels^.Peak[Channel] := Peak;
    Levels^.Rms[Channel] := Sqrt(Sum / Frames);
  end;
end;

procedure MeterGetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
begin
  if Size = SizeOf(TMeterLevels) then
    TMeterLevels(Parameters^) := PMeterState(Effect^.State)^.Levels;
end;

procedure MeterReset(Effect: PAudioEffect);
begin
  FillChar(PMeterState(Effect^.State)^.Levels, SizeOf(TMeterLevels), 0);
end;

function CreateVolumeMeter: PAudioEffect;
begin
  Result := CreateEffect(SizeOf(TMeterState));
  if Result = nil then
    Exit;
  Result^.Process := @MeterProcess;
  Result^.GetParameters := @MeterGetParameters;
  Result^.Reset := @MeterReset;
end;

{ --- Limiter ------------------------------------------------------------------ }

function DefaultLimiterParameters: TLimiterParameters;
begin
  Result.Threshold := 1;
  Result.ReleaseMilliseconds := 100;
end;

procedure LimiterProcess(Effect: PAudioEffect; Samples: PSingle; Frames, Channels, Rate: LongWord);
var
  State: PLimiterState;
  Release: Single;
  Frame: LongWord;
  Channel: LongWord;
  Peak: Single;
  Gain: Single;
begin
  State := PLimiterState(Effect^.State);
  { The envelope falls by this much a frame: to 1/e over the release. }
  Release := Exp(-1000 / (Rate * State^.Parameters.ReleaseMilliseconds));
  for Frame := 0 to Frames - 1 do
  begin
    Peak := 0;
    for Channel := 0 to Channels - 1 do
      if Abs(Samples[Frame * Channels + Channel]) > Peak then
        Peak := Abs(Samples[Frame * Channels + Channel]);
    State^.Envelope := State^.Envelope * Release;
    if Peak > State^.Envelope then
      State^.Envelope := Peak;
    if State^.Envelope > State^.Parameters.Threshold then
    begin
      Gain := State^.Parameters.Threshold / State^.Envelope;
      for Channel := 0 to Channels - 1 do
        Samples[Frame * Channels + Channel] := Samples[Frame * Channels + Channel] * Gain;
    end;
  end;
end;

procedure LimiterSetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
var
  Wanted: TLimiterParameters;
begin
  if Size <> SizeOf(TLimiterParameters) then
    Exit;
  Wanted := TLimiterParameters(Parameters^);
  if (Wanted.Threshold <= 0) or (Wanted.ReleaseMilliseconds <= 0) then
    Exit;
  PLimiterState(Effect^.State)^.Parameters := Wanted;
end;

procedure LimiterGetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
begin
  if Size = SizeOf(TLimiterParameters) then
    TLimiterParameters(Parameters^) := PLimiterState(Effect^.State)^.Parameters;
end;

procedure LimiterReset(Effect: PAudioEffect);
begin
  PLimiterState(Effect^.State)^.Envelope := 0;
end;

function CreateLimiter(const Parameters: TLimiterParameters): PAudioEffect;
begin
  Result := CreateEffect(SizeOf(TLimiterState));
  if Result = nil then
    Exit;
  Result^.Process := @LimiterProcess;
  Result^.SetParameters := @LimiterSetParameters;
  Result^.GetParameters := @LimiterGetParameters;
  Result^.Reset := @LimiterReset;
  PLimiterState(Result^.State)^.Parameters := DefaultLimiterParameters;
  LimiterSetParameters(Result, @Parameters, SizeOf(Parameters));
end;

end.
