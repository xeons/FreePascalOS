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
  3D audio: how a sound from an emitter reaches a listener, as X3DAudio
  works it out, for the voices of Audio.Engine.

  Space is left-handed, as in most games: X to the right, Y up, Z
  forward. Distances are in whatever unit the program likes; the
  velocities in that unit per second, and SpeedOfSound in the same.

  CalculateSpatial gives, for one emitter and listener:
    Matrix         the emitter's channels into the destination's
                   speakers: each channel panned by its direction from
                   the listener (equal power between the two speakers
                   around it), times the volume by distance and cone
    DopplerFactor  the frequency ratio the motion gives
    LowPassLevel   the low-pass coefficient by distance (1: no filter);
                   LowPassFilterParameters turns it into a voice filter
    ReverbLevel    how much to send to a reverb, by distance
  ApplySpatial sets them on a voice (matrix, frequency ratio and filter).

  Curves are points of (distance, value) with distances as fractions of
  the emitter's CurveDistanceScaler, values between points linear. With
  no volume curve, the volume falls as 1 / distance past the scaler; no
  low-pass or reverb curve leaves those at 1.

  Speakers: mono, stereo (at the sides), quad, 5.1 and 7.1; the LFE gets
  nothing. Other channel counts are panned as stereo on their first two.
}
unit Audio.Spatial;

{$mode objfpc}
{$pointermath on}

interface

uses
  Audio.Filters,
  Audio.Voices;

const
  MaximumCurvePoints = 16;
  DefaultSpeedOfSound = 343.5;

type
  TVector = record
    X, Y, Z: Single;
  end;

  TCurvePoint = record
    Distance: Single;
    Value: Single;
  end;

  PDistanceCurve = ^TDistanceCurve;
  TDistanceCurve = record
    Count: Integer;
    Points: array[0..MaximumCurvePoints - 1] of TCurvePoint;
  end;

  { The emitter is loud inside InnerAngle (radians, centred on its
    front) and quiet outside OuterAngle, with a fade between. }
  PSoundCone = ^TSoundCone;
  TSoundCone = record
    InnerAngle: Single;
    OuterAngle: Single;
    InnerVolume: Single;
    OuterVolume: Single;
  end;

  TListener = record
    Position: TVector;
    Velocity: TVector;
    Front: TVector;
    Top: TVector;
  end;

  TEmitter = record
    Position: TVector;
    Velocity: TVector;
    Front: TVector;
    Top: TVector;
    { Nil: the same all round. }
    Cone: PSoundCone;
    ChannelCount: LongWord;
    { Channels of a multi-channel emitter sit ChannelRadius from its
      position, at ChannelAzimuths (radians, clockwise from its front
      seen from above). }
    ChannelRadius: Single;
    ChannelAzimuths: array[0..MaximumVoiceChannels - 1] of Single;
    { Within InnerRadius the sound spreads over all the speakers. }
    InnerRadius: Single;
    CurveDistanceScaler: Single;
    DopplerScaler: Single;
    VolumeCurve: PDistanceCurve;
    LowPassCurve: PDistanceCurve;
    ReverbCurve: PDistanceCurve;
  end;

  TSpatialResult = record
    SourceChannels: LongWord;
    DestinationChannels: LongWord;
    Matrix: array[0..MaximumVoiceChannels * MaximumVoiceChannels - 1] of Single;
    DopplerFactor: Single;
    LowPassLevel: Single;
    ReverbLevel: Single;
    Distance: Single;
    { Of the emitter, from the listener: radians, clockwise from the
      front, -pi to pi. }
    Azimuth: Single;
  end;

function Vector(X, Y, Z: Single): TVector;
{ A listener at the origin facing forward, still. }
procedure InitializeListener(out Listener: TListener);
{ A still mono emitter at the origin, facing forward, all round, with
  the default curves and scalers of 1. }
procedure InitializeEmitter(out Emitter: TEmitter);
procedure CalculateSpatial(const Listener: TListener; const Emitter: TEmitter; DestinationChannels: LongWord;
  SpeedOfSound: Single; out Result: TSpatialResult);
function LowPassFilterParameters(Level: Single): TFilterParameters;
{ Sets the voice's matrix to Destination (nil: its first), frequency
  ratio (times BaseRatio) and filter. }
procedure ApplySpatial(Voice, Destination: PAudioVoice; const Spatial: TSpatialResult; BaseRatio: Single;
  OperationSet: LongWord);

implementation

uses
  Audio.Engine;

const
  { No speaker: the LFE. }
  NoAzimuth = 1000;
  StereoAzimuths: array[0..1] of Single = (-90, 90);
  QuadAzimuths: array[0..3] of Single = (-45, 45, -135, 135);
  Surround51Azimuths: array[0..5] of Single = (-30, 30, 0, NoAzimuth, -110, 110);
  Surround71Azimuths: array[0..7] of Single = (-30, 30, 0, NoAzimuth, -150, 150, -90, 90);

{ --- Vectors ------------------------------------------------------------------ }

function Vector(X, Y, Z: Single): TVector;
begin
  Result.X := X;
  Result.Y := Y;
  Result.Z := Z;
end;

function Add(const A, B: TVector): TVector;
begin
  Result := Vector(A.X + B.X, A.Y + B.Y, A.Z + B.Z);
end;

function Subtract(const A, B: TVector): TVector;
begin
  Result := Vector(A.X - B.X, A.Y - B.Y, A.Z - B.Z);
end;

function Scale(const A: TVector; Factor: Single): TVector;
begin
  Result := Vector(A.X * Factor, A.Y * Factor, A.Z * Factor);
end;

function Dot(const A, B: TVector): Single;
begin
  Result := A.X * B.X + A.Y * B.Y + A.Z * B.Z;
end;

function Cross(const A, B: TVector): TVector;
begin
  Result := Vector(A.Y * B.Z - A.Z * B.Y, A.Z * B.X - A.X * B.Z, A.X * B.Y - A.Y * B.X);
end;

function Length(const A: TVector): Single;
begin
  Result := Sqrt(Dot(A, A));
end;

function Normalize(const A: TVector): TVector;
var
  Size: Single;
begin
  Size := Length(A);
  if Size = 0 then
    Result := A
  else
    Result := Scale(A, 1 / Size);
end;

{ The angle of (X, Y) from the X axis, -pi to pi. }
function Angle(Y, X: Single): Single;
begin
  if X > 0 then
    Result := ArcTan(Y / X)
  else if X < 0 then
  begin
    if Y >= 0 then
      Result := ArcTan(Y / X) + Pi
    else
      Result := ArcTan(Y / X) - Pi;
  end
  else if Y > 0 then
    Result := Pi / 2
  else if Y < 0 then
    Result := -Pi / 2
  else
    Result := 0;
end;

{ --- Defaults -------------------------------------------------------------------- }

procedure InitializeListener(out Listener: TListener);
begin
  FillChar(Listener, SizeOf(Listener), 0);
  Listener.Front := Vector(0, 0, 1);
  Listener.Top := Vector(0, 1, 0);
end;

procedure InitializeEmitter(out Emitter: TEmitter);
begin
  FillChar(Emitter, SizeOf(Emitter), 0);
  Emitter.Front := Vector(0, 0, 1);
  Emitter.Top := Vector(0, 1, 0);
  Emitter.ChannelCount := 1;
  Emitter.CurveDistanceScaler := 1;
  Emitter.DopplerScaler := 1;
end;

{ --- Curves and cones ------------------------------------------------------------ }

function CurveValue(Curve: PDistanceCurve; Normalized: Single): Single;
var
  Index: Integer;
  Span: Single;
begin
  if Normalized <= Curve^.Points[0].Distance then
    Exit(Curve^.Points[0].Value);
  for Index := 1 to Curve^.Count - 1 do
    if Normalized <= Curve^.Points[Index].Distance then
    begin
      Span := Curve^.Points[Index].Distance - Curve^.Points[Index - 1].Distance;
      if Span <= 0 then
        Exit(Curve^.Points[Index].Value);
      Exit(Curve^.Points[Index - 1].Value + (Curve^.Points[Index].Value - Curve^.Points[Index - 1].Value) *
        (Normalized - Curve^.Points[Index - 1].Distance) / Span);
    end;
  Result := Curve^.Points[Curve^.Count - 1].Value;
end;

function DistanceVolume(const Emitter: TEmitter; Distance: Single): Single;
var
  Normalized: Single;
begin
  Normalized := Distance / Emitter.CurveDistanceScaler;
  if (Emitter.VolumeCurve <> nil) and (Emitter.VolumeCurve^.Count > 0) then
    Exit(CurveValue(Emitter.VolumeCurve, Normalized));
  if Normalized <= 1 then
    Result := 1
  else
    Result := 1 / Normalized;
end;

function OptionalCurve(Curve: PDistanceCurve; Normalized: Single): Single;
begin
  if (Curve = nil) or (Curve^.Count = 0) then
    Result := 1
  else
    Result := CurveValue(Curve, Normalized);
end;

{ The cone's volume for a listener in direction ToListener (normalized)
  from the emitter. }
function ConeVolume(const Emitter: TEmitter; const ToListener: TVector): Single;
var
  Cone: PSoundCone;
  Off: Single;
  Inner: Single;
  Outer: Single;
begin
  Cone := Emitter.Cone;
  if Cone = nil then
    Exit(1);
  Off := Angle(Length(Cross(Normalize(Emitter.Front), ToListener)), Dot(Normalize(Emitter.Front), ToListener));
  Inner := Cone^.InnerAngle / 2;
  Outer := Cone^.OuterAngle / 2;
  if Off <= Inner then
    Result := Cone^.InnerVolume
  else if (Off >= Outer) or (Outer <= Inner) then
    Result := Cone^.OuterVolume
  else
    Result := Cone^.InnerVolume + (Cone^.OuterVolume - Cone^.InnerVolume) * (Off - Inner) / (Outer - Inner);
end;

{ --- Panning ------------------------------------------------------------------------- }

function SpeakerAzimuths(Channels: LongWord; out Count: Integer): PSingle;
begin
  case Channels of
    4:
      begin
        Count := 4;
        Result := @QuadAzimuths[0];
      end;
    6:
      begin
        Count := 6;
        Result := @Surround51Azimuths[0];
      end;
    8:
      begin
        Count := 8;
        Result := @Surround71Azimuths[0];
      end;
  else
    Count := 2;
    Result := @StereoAzimuths[0];
  end;
end;

{ Clockwise distance in degrees from From to Towards, 0 to 360. }
function ClockwiseDegrees(From, Towards: Single): Single;
begin
  Result := Towards - From;
  while Result < 0 do
    Result := Result + 360;
  while Result >= 360 do
    Result := Result - 360;
end;

{ The gains of each destination speaker for a sound from Azimuth
  (degrees): equal power between the nearest speaker on either side. }
procedure PanGains(DestinationChannels: LongWord; Azimuth: Single; Gains: PSingle);
var
  Azimuths: PSingle;
  Count: Integer;
  Speaker: Integer;
  Before: Integer;
  After: Integer;
  BeforeGap: Single;
  AfterGap: Single;
  Gap: Single;
  Share: Single;
begin
  FillChar(Gains^, DestinationChannels * SizeOf(Single), 0);
  if DestinationChannels = 1 then
  begin
    Gains[0] := 1;
    Exit;
  end;
  Azimuths := SpeakerAzimuths(DestinationChannels, Count);
  Before := -1;
  After := -1;
  BeforeGap := 361;
  AfterGap := 361;
  for Speaker := 0 to Count - 1 do
  begin
    if Azimuths[Speaker] = NoAzimuth then
      Continue;
    Gap := ClockwiseDegrees(Azimuths[Speaker], Azimuth);
    if Gap < BeforeGap then
    begin
      BeforeGap := Gap;
      Before := Speaker;
    end;
    Gap := ClockwiseDegrees(Azimuth, Azimuths[Speaker]);
    if Gap < AfterGap then
    begin
      AfterGap := Gap;
      After := Speaker;
    end;
  end;
  if (Before = After) or (BeforeGap + AfterGap = 0) then
  begin
    Gains[Before] := 1;
    Exit;
  end;
  Share := BeforeGap / (BeforeGap + AfterGap);
  Gains[Before] := Cos(Share * Pi / 2);
  Gains[After] := Sin(Share * Pi / 2);
end;

{ The direction of Point from the listener: its azimuth (radians) and
  distance. }
procedure Locate(const Listener: TListener; const Point: TVector; out Azimuth, Distance: Single);
var
  Offset: TVector;
  Front: TVector;
  Right: TVector;
begin
  Offset := Subtract(Point, Listener.Position);
  Distance := Length(Offset);
  Front := Normalize(Listener.Front);
  Right := Normalize(Cross(Listener.Top, Listener.Front));
  Azimuth := Angle(Dot(Offset, Right), Dot(Offset, Front));
end;

{ Where channel Channel of the emitter is. }
function ChannelPosition(const Emitter: TEmitter; Channel: LongWord): TVector;
var
  Front: TVector;
  Right: TVector;
  Turn: Single;
begin
  if Emitter.ChannelCount <= 1 then
    Exit(Emitter.Position);
  Front := Normalize(Emitter.Front);
  Right := Normalize(Cross(Emitter.Top, Emitter.Front));
  Turn := Emitter.ChannelAzimuths[Channel];
  Result := Add(Emitter.Position, Scale(Add(Scale(Front, Cos(Turn)), Scale(Right, Sin(Turn))),
    Emitter.ChannelRadius));
end;

{ --- Doppler ------------------------------------------------------------------------ }

function DopplerFactor(const Listener: TListener; const Emitter: TEmitter; SpeedOfSound: Single): Single;
var
  ToListener: TVector;
  Speed: Single;
  ListenerPart: Single;
  EmitterPart: Single;
  Limit: Single;
begin
  ToListener := Normalize(Subtract(Listener.Position, Emitter.Position));
  if (Length(ToListener) = 0) or (Emitter.DopplerScaler <= 0) then
    Exit(1);
  Speed := SpeedOfSound / Emitter.DopplerScaler;
  { Speeds towards the other one, held under the speed of sound. }
  ListenerPart := Dot(Listener.Velocity, ToListener);
  EmitterPart := Dot(Emitter.Velocity, ToListener);
  Limit := Speed * 0.99;
  if ListenerPart > Limit then
    ListenerPart := Limit;
  if ListenerPart < -Limit then
    ListenerPart := -Limit;
  if EmitterPart > Limit then
    EmitterPart := Limit;
  if EmitterPart < -Limit then
    EmitterPart := -Limit;
  Result := (Speed - ListenerPart) / (Speed - EmitterPart);
end;

{ --- Working it out ----------------------------------------------------------------- }

procedure CalculateSpatial(const Listener: TListener; const Emitter: TEmitter; DestinationChannels: LongWord;
  SpeedOfSound: Single; out Result: TSpatialResult);
var
  Volume: Single;
  Channel: LongWord;
  Speaker: LongWord;
  Azimuth: Single;
  Distance: Single;
  Gains: array[0..MaximumVoiceChannels - 1] of Single;
  Spread: Single;
  Normalized: Single;
  Channels: LongWord;
  ToListener: TVector;
begin
  FillChar(Result, SizeOf(Result), 0);
  Channels := Emitter.ChannelCount;
  if Channels < 1 then
    Channels := 1;
  if Channels > MaximumVoiceChannels then
    Channels := MaximumVoiceChannels;
  if DestinationChannels > MaximumVoiceChannels then
    DestinationChannels := MaximumVoiceChannels;
  Result.SourceChannels := Channels;
  Result.DestinationChannels := DestinationChannels;
  Locate(Listener, Emitter.Position, Result.Azimuth, Result.Distance);
  ToListener := Normalize(Subtract(Listener.Position, Emitter.Position));
  Volume := DistanceVolume(Emitter, Result.Distance) * ConeVolume(Emitter, ToListener);
  { Within the inner radius, part of the sound comes from everywhere. }
  Spread := 0;
  if (Emitter.InnerRadius > 0) and (Result.Distance < Emitter.InnerRadius) then
    Spread := 1 - Result.Distance / Emitter.InnerRadius;
  for Channel := 0 to Channels - 1 do
  begin
    Locate(Listener, ChannelPosition(Emitter, Channel), Azimuth, Distance);
    PanGains(DestinationChannels, Azimuth * 180 / Pi, @Gains[0]);
    for Speaker := 0 to DestinationChannels - 1 do
      Result.Matrix[Channel * DestinationChannels + Speaker] :=
        Volume * (Gains[Speaker] * (1 - Spread) + Spread / Sqrt(DestinationChannels));
  end;
  Normalized := Result.Distance / Emitter.CurveDistanceScaler;
  Result.LowPassLevel := OptionalCurve(Emitter.LowPassCurve, Normalized);
  Result.ReverbLevel := OptionalCurve(Emitter.ReverbCurve, Normalized);
  Result.DopplerFactor := DopplerFactor(Listener, Emitter, SpeedOfSound);
end;

function LowPassFilterParameters(Level: Single): TFilterParameters;
begin
  Result.Kind := FilterLowPass;
  Result.OneOverQ := DefaultFilterOneOverQ;
  { As XAudio2 maps its coefficient; 1 (or more) lets everything
  through, and is set exactly so the filter is skipped. }
  if Level >= 1 then
    Result.Frequency := FilterMaximumFrequency
  else
    Result.Frequency := 2 * Sin(Pi / 6 * Level);
end;

procedure ApplySpatial(Voice, Destination: PAudioVoice; const Spatial: TSpatialResult; BaseRatio: Single;
  OperationSet: LongWord);
begin
  SetOutputMatrix(Voice, Destination, Slice(Spatial.Matrix, Spatial.SourceChannels * Spatial.DestinationChannels),
    OperationSet);
  if Voice^.Kind = VoiceSource then
    SetFrequencyRatio(Voice, BaseRatio * Spatial.DopplerFactor, OperationSet);
  SetFilterParameters(Voice, LowPassFilterParameters(Spatial.LowPassLevel), OperationSet);
end;

end.
