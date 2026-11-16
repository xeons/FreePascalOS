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
  effecttest - test libaudio's built-in effects and 3D audio

  Renders voices offline through each effect (the volume meter, the
  limiter, echo, the equalizer and reverb) and measures what comes out,
  then works out emitters around a listener with Audio.Spatial and
  checks the panning, distance curves, cones, Doppler factor and a
  voice playing with the result. Each failed check prints a line; at
  the end the number of checks that passed.
}
program effecttest;

{$mode objfpc}{$H+}
{$pointermath on}

uses
  SysUtils,
  Sys.Memory,
  Util.Messages,
  Util.CommandLine,
  Util.Output,
  Audio.Formats,
  Audio.Device,
  Audio.EffectChain,
  Audio.Voices,
  Audio.Engine,
  Audio.Effects.Dynamics,
  Audio.Effects.Echo,
  Audio.Effects.Equalizer,
  Audio.Effects.Reverb,
  Audio.Spatial;

const
  Usage: PChar = 'Usage: effecttest'#10 +
    'Test the built-in audio effects and 3D audio.'#10;
  Rate = 48000;
  RenderFrames = 9600;
  SettleFrames = 480;
  Amplitude = 0.5;

var
  Passed: Integer = 0;
  Failed: Integer = 0;
  Rendered: PSingle;

{ --- Checking and measuring --------------------------------------------- }

procedure Check(const Name: string; Condition: Boolean; const Detail: string);
begin
  if Condition then
    Inc(Passed)
  else
  begin
    Inc(Failed);
    PrintString(Format('effecttest: %s failed: %s'#10, [Name, Detail]));
  end;
end;

function Near(Value, Expected, Tolerance: Single): Boolean;
begin
  Result := Abs(Value - Expected) <= Tolerance;
end;

function Describe(Value, Expected: Single): string;
begin
  Result := Format('%d/1000, expected %d/1000', [Round(Value * 1000),
    Round(Expected * 1000)]);
end;

function Peak(Channel: LongWord): Single;
var
  Frame: LongWord;
begin
  Result := 0;
  for Frame := SettleFrames to RenderFrames - 1 do
    if Abs(Rendered[Frame * 2 + Channel]) > Result then
      Result := Abs(Rendered[Frame * 2 + Channel]);
end;

{ A sine's amplitude from its RMS level. }
function Level(Channel: LongWord): Single;
var
  Frame: LongWord;
  Sum: Double;
begin
  Sum := 0;
  for Frame := SettleFrames to RenderFrames - 1 do
    Sum := Sum + Sqr(Rendered[Frame * 2 + Channel]);
  Result := Sqrt(2 * Sum / (RenderFrames - SettleFrames));
end;

function Frequency: Single;
var
  Frame: LongWord;
  Crossings: LongWord;
  First: LongWord;
  Last: LongWord;
begin
  Crossings := 0;
  First := 0;
  Last := 0;
  for Frame := SettleFrames + 1 to RenderFrames - 1 do
    if (Rendered[(Frame - 1) * 2] < 0) and (Rendered[Frame * 2] >= 0) then
    begin
      if Crossings = 0 then
        First := Frame;
      Last := Frame;
      Inc(Crossings);
    end;
  if Crossings < 2 then
    Exit(0);
  Result := (Crossings - 1) * Rate / (Last - First);
end;

{ --- Building voices --------------------------------------------------------- }

function NewEngine: PAudioEngine;
var
  Master: PAudioVoice;
begin
  if (CreateAudioEngine('', True, Result) <> 0) or (CreateMasteringVoice(Result, 2, Rate, Master) <> 0) then
    Fail(1, 'cannot create an engine');
end;

function StereoFloat: TAudioFormat;
begin
  Result.Rate := Rate;
  Result.Channels := 2;
  Result.Kind := SampleFloat32;
end;

function NoCallbacks: TVoiceCallbacks;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function NewBuffer(Data: Pointer; Frames: LongWord): TAudioBuffer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Data := Data;
  Result.ByteCount := Frames * 2 * SizeOf(Single);
end;

{ A started stereo voice looping a sine of Hertz. }
function SineVoice(Engine: PAudioEngine; Hertz: Single): PAudioVoice;
var
  Samples: PSingle;
  Frame: LongWord;
  Buffer: TAudioBuffer;
begin
  Samples := PSingle(AllocateMemory(Rate * 2 * SizeOf(Single)));
  for Frame := 0 to Rate - 1 do
  begin
    Samples[Frame * 2] := Amplitude * Sin(2 * Pi * Hertz * Frame / Rate);
    Samples[Frame * 2 + 1] := Samples[Frame * 2];
  end;
  CreateSourceVoice(Engine, StereoFloat, 2, NoCallbacks, [], Result);
  Buffer := NewBuffer(Samples, Rate);
  Buffer.LoopCount := LoopInfinite;
  SubmitSourceBuffer(Result, Buffer);
  StartVoice(Result, CommitNow);
end;

var
  Impulse: array[0..1] of Single = (1, 1);

{ A started voice playing one frame at full scale, then silence. }
function ImpulseVoice(Engine: PAudioEngine): PAudioVoice;
begin
  CreateSourceVoice(Engine, StereoFloat, 1, NoCallbacks, [], Result);
  SubmitSourceBuffer(Result, NewBuffer(@Impulse[0], 1));
  StartVoice(Result, CommitNow);
end;

procedure Render(Engine: PAudioEngine);
begin
  RenderAudio(Engine, RenderFrames, Rendered);
end;

{ The first frame of the left side that is not silent. }
function FirstSound: LongWord;
begin
  Result := 0;
  while (Result < RenderFrames - 1) and (Abs(Rendered[Result * 2]) < 0.01) do
    Inc(Result);
end;

{ --- Effects ------------------------------------------------------------------- }

procedure CheckVolumeMeter;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Levels: TMeterLevels;
begin
  Engine := NewEngine;
  Voice := SineVoice(Engine, 1000);
  SetEffectChain(Voice, [CreateVolumeMeter]);
  Render(Engine);
  GetEffectParameters(Voice, 0, @Levels, SizeOf(Levels));
  Check('volume meter (peak)', (Levels.Channels = 2) and Near(Levels.Peak[0], Amplitude, 0.01),
    Describe(Levels.Peak[0], Amplitude));
  Check('volume meter (RMS)', Near(Levels.Rms[1], Amplitude / Sqrt(2), 0.01),
    Describe(Levels.Rms[1], Amplitude / Sqrt(2)));
  Check('volume meter (passes through)', Near(Peak(0), Amplitude, 0.01), Describe(Peak(0), Amplitude));
  DestroyAudioEngine(Engine);
end;

procedure CheckLimiter;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Parameters: TLimiterParameters;
begin
  Engine := NewEngine;
  Voice := SineVoice(Engine, 1000);
  Parameters := DefaultLimiterParameters;
  SetEffectChain(Voice, [CreateLimiter(Parameters)]);
  Render(Engine);
  Check('limiter (under the threshold)', Near(Peak(0), Amplitude, 0.01), Describe(Peak(0), Amplitude));
  Parameters.Threshold := 0.25;
  SetEffectParameters(Voice, 0, @Parameters, SizeOf(Parameters), CommitNow);
  Render(Engine);
  Check('limiter (held under)', Peak(0) <= 0.2501, Describe(Peak(0), 0.25));
  Check('limiter (still sounding)', Peak(0) > 0.2, Describe(Peak(0), 0.25));
  DestroyAudioEngine(Engine);
end;

procedure CheckEcho;
const
  DelayFrames = Rate div 20;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Parameters: TEchoParameters;
  Start: LongWord;
begin
  Engine := NewEngine;
  Voice := ImpulseVoice(Engine);
  Parameters.WetDryMix := 0.5;
  Parameters.Feedback := 0.5;
  Parameters.DelayMilliseconds := 50;
  SetEffectChain(Voice, [CreateEcho(Parameters)]);
  Render(Engine);
  Start := FirstSound;
  Check('echo (dry)', Near(Rendered[Start * 2], 0.5, 0.01), Describe(Rendered[Start * 2], 0.5));
  Check('echo (between)', Abs(Rendered[(Start + DelayFrames div 2) * 2]) < 0.001,
    Describe(Rendered[(Start + DelayFrames div 2) * 2], 0));
  Check('echo (first)', Near(Rendered[(Start + DelayFrames) * 2], 0.5, 0.01),
    Describe(Rendered[(Start + DelayFrames) * 2], 0.5));
  Check('echo (second)', Near(Rendered[(Start + 2 * DelayFrames) * 2], 0.25, 0.01),
    Describe(Rendered[(Start + 2 * DelayFrames) * 2], 0.25));
  DestroyAudioEngine(Engine);
end;

function EqualizedLevel(Hertz: Single): Single;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Parameters: TEqualizerParameters;
begin
  Engine := NewEngine;
  Voice := SineVoice(Engine, Hertz);
  Parameters := DefaultEqualizerParameters;
  Parameters.Bands[1].Frequency := 1000;
  Parameters.Bands[1].Gain := 2;
  SetEffectChain(Voice, [CreateEqualizer(Parameters)]);
  Render(Engine);
  Result := Level(0) / Amplitude;
  DestroyAudioEngine(Engine);
end;

procedure CheckEqualizer;
var
  Gain: Single;
begin
  Gain := EqualizedLevel(1000);
  Check('equalizer (in the band)', Near(Gain, 2, 0.05), Describe(Gain, 2));
  Gain := EqualizedLevel(8000);
  Check('equalizer (outside)', Near(Gain, 1, 0.05), Describe(Gain, 1));
end;

{ The energy of the left side from frame First to Last. }
function Energy(First, Last: LongWord): Single;
var
  Frame: LongWord;
begin
  Result := 0;
  for Frame := First to Last - 1 do
    Result := Result + Sqr(Rendered[Frame * 2]);
end;

procedure CheckReverb;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Parameters: TReverbParameters;
  Effect: PAudioEffect;
  Start: LongWord;
  Early: Single;
  Late: Single;
  Difference: Single;
  Frame: LongWord;
begin
  Engine := NewEngine;
  Voice := SineVoice(Engine, 1000);
  Parameters := DefaultReverbParameters;
  Parameters.WetLevel := 0;
  SetEffectChain(Voice, [CreateReverb(Parameters)]);
  Render(Engine);
  Check('reverb (dry only)', Near(Peak(0), Amplitude, 0.01), Describe(Peak(0), Amplitude));
  DestroyAudioEngine(Engine);

  Engine := NewEngine;
  Voice := ImpulseVoice(Engine);
  Parameters := DefaultReverbParameters;
  Parameters.DryLevel := 0;
  Effect := CreateReverb(Parameters);
  SetEffectChain(Voice, [Effect]);
  Render(Engine);
  Start := FirstSound;
  Early := Energy(Start, Start + 2400);
  Late := Energy(Start + 4800, Start + 7200);
  Check('reverb (the room answers)', (Start > 0) and (Start < 2400) and (Early > 0.0001),
    Format('first sound at frame %u', [Start]));
  Check('reverb (dies away)', (Late > 0) and (Late < Early), 'not decaying');
  Difference := 0;
  for Frame := 0 to RenderFrames - 1 do
    Difference := Difference + Abs(Rendered[Frame * 2] - Rendered[Frame * 2 + 1]);
  Check('reverb (the sides differ)', Difference > 0.01, 'the same on both sides');
  Check('reverb (tail)', (Effect^.TailFrames(Effect, Rate) > Rate div 2) and
    (Effect^.TailFrames(Effect, Rate) < Rate * 10),
    Format('%u frames', [Effect^.TailFrames(Effect, Rate)]));
  DestroyAudioEngine(Engine);
end;

{ A voice stopped with its tails still sounds through its reverb; one
  stopped without does not. }
procedure CheckTails;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Parameters: TReverbParameters;
  Flags: LongWord;
begin
  for Flags := 0 to 1 do
  begin
    Engine := NewEngine;
    Voice := SineVoice(Engine, 1000);
    Parameters := DefaultReverbParameters;
    SetEffectChain(Voice, [CreateReverb(Parameters)]);
    Render(Engine);
    StopVoice(Voice, Flags * StopPlayTails, CommitNow);
    Render(Engine);
    if Flags = StopPlayTails then
      Check('stopped with tails', Peak(0) > 0.001, Describe(Peak(0), 0.1))
    else
      Check('stopped without tails', Peak(0) = 0, Describe(Peak(0), 0));
    DestroyAudioEngine(Engine);
  end;
end;

{ --- 3D audio --------------------------------------------------------------------- }

function DescribeGains(const Spatial: TSpatialResult): string;
begin
  Result := Format('left %d/1000, right %d/1000', [Round(Spatial.Matrix[0] * 1000),
    Round(Spatial.Matrix[1] * 1000)]);
end;

procedure CheckPanning;
var
  Listener: TListener;
  Emitter: TEmitter;
  Spatial: TSpatialResult;
begin
  InitializeListener(Listener);
  InitializeEmitter(Emitter);
  Emitter.Position := Vector(0, 0, 1);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('in front', Near(Spatial.Matrix[0], Sqrt(0.5), 0.001) and Near(Spatial.Matrix[1], Sqrt(0.5), 0.001),
    DescribeGains(Spatial));
  Emitter.Position := Vector(5, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('to the right, 5 away', Near(Spatial.Matrix[0], 0, 0.001) and Near(Spatial.Matrix[1], 0.2, 0.001),
    DescribeGains(Spatial));
  Check('azimuth and distance', Near(Spatial.Azimuth, Pi / 2, 0.001) and Near(Spatial.Distance, 5, 0.001),
    Describe(Spatial.Azimuth, Pi / 2));
  Emitter.Position := Vector(-1, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('to the left', Near(Spatial.Matrix[0], 1, 0.001) and Near(Spatial.Matrix[1], 0, 0.001),
    DescribeGains(Spatial));
  { The listener turned to face +X: the emitter at -X is behind. }
  Listener.Front := Vector(1, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('behind', Near(Spatial.Matrix[0], Sqrt(0.5), 0.001) and Near(Spatial.Matrix[1], Sqrt(0.5), 0.001),
    DescribeGains(Spatial));
end;

procedure CheckSurround;
var
  Listener: TListener;
  Emitter: TEmitter;
  Spatial: TSpatialResult;
begin
  InitializeListener(Listener);
  InitializeEmitter(Emitter);
  Emitter.Position := Vector(0, 0, 1);
  CalculateSpatial(Listener, Emitter, 6, DefaultSpeedOfSound, Spatial);
  Check('5.1 in front: the centre', Near(Spatial.Matrix[2], 1, 0.001) and (Spatial.Matrix[0] < 0.001) and
    (Spatial.Matrix[3] = 0), Describe(Spatial.Matrix[2], 1));
  { 30 degrees to the right: the front right speaker. }
  Emitter.Position := Vector(Sin(Pi / 6), 0, Cos(Pi / 6));
  CalculateSpatial(Listener, Emitter, 6, DefaultSpeedOfSound, Spatial);
  Check('5.1 at 30 degrees', Near(Spatial.Matrix[1], 1, 0.001), Describe(Spatial.Matrix[1], 1));
  { Straight behind in 7.1: between the back speakers. }
  Emitter.Position := Vector(0, 0, -1);
  CalculateSpatial(Listener, Emitter, 8, DefaultSpeedOfSound, Spatial);
  Check('7.1 behind', Near(Spatial.Matrix[4], Sqrt(0.5), 0.001) and Near(Spatial.Matrix[5], Sqrt(0.5), 0.001),
    Describe(Spatial.Matrix[4], Sqrt(0.5)));
end;

procedure CheckDoppler;
var
  Listener: TListener;
  Emitter: TEmitter;
  Spatial: TSpatialResult;
  Expected: Single;
begin
  InitializeListener(Listener);
  InitializeEmitter(Emitter);
  Emitter.Position := Vector(0, 0, 10);
  Emitter.Velocity := Vector(0, 0, -DefaultSpeedOfSound / 10);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Expected := 1 / 0.9;
  Check('Doppler (coming)', Near(Spatial.DopplerFactor, Expected, 0.001), Describe(Spatial.DopplerFactor, Expected));
  Emitter.Velocity := Vector(0, 0, DefaultSpeedOfSound / 10);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Expected := 1 / 1.1;
  Check('Doppler (going)', Near(Spatial.DopplerFactor, Expected, 0.001), Describe(Spatial.DopplerFactor, Expected));
  Emitter.Velocity := Vector(0, 0, 0);
  Listener.Velocity := Vector(0, 0, DefaultSpeedOfSound / 10);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('Doppler (listener moving)', Near(Spatial.DopplerFactor, 1.1, 0.001), Describe(Spatial.DopplerFactor, 1.1));
  { Sideways motion changes nothing. }
  Listener.Velocity := Vector(30, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('Doppler (sideways)', Near(Spatial.DopplerFactor, 1, 0.001), Describe(Spatial.DopplerFactor, 1));
end;

procedure CheckCurvesAndCones;
var
  Listener: TListener;
  Emitter: TEmitter;
  Spatial: TSpatialResult;
  Curve: TDistanceCurve;
  Cone: TSoundCone;
begin
  InitializeListener(Listener);
  InitializeEmitter(Emitter);
  Curve.Count := 2;
  Curve.Points[0].Distance := 0;
  Curve.Points[0].Value := 1;
  Curve.Points[1].Distance := 1;
  Curve.Points[1].Value := 0.5;
  Emitter.CurveDistanceScaler := 10;
  Emitter.VolumeCurve := @Curve;
  Emitter.LowPassCurve := @Curve;
  Emitter.ReverbCurve := @Curve;
  Emitter.Position := Vector(-5, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('volume curve', Near(Spatial.Matrix[0], 0.75, 0.001), DescribeGains(Spatial));
  Check('low-pass and reverb curves', Near(Spatial.LowPassLevel, 0.75, 0.001) and
    Near(Spatial.ReverbLevel, 0.75, 0.001), Describe(Spatial.LowPassLevel, 0.75));
  Emitter.Position := Vector(-50, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('past the curve', Near(Spatial.Matrix[0], 0.5, 0.001), DescribeGains(Spatial));

  { An emitter to the left facing away: the listener is outside its
    cone. Turned towards the listener: inside. }
  InitializeEmitter(Emitter);
  Cone.InnerAngle := Pi / 2;
  Cone.OuterAngle := 3 * Pi / 2;
  Cone.InnerVolume := 1;
  Cone.OuterVolume := 0.25;
  Emitter.Cone := @Cone;
  Emitter.Position := Vector(-1, 0, 0);
  Emitter.Front := Vector(-1, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('cone (behind it)', Near(Spatial.Matrix[0], 0.25, 0.001), DescribeGains(Spatial));
  Emitter.Front := Vector(1, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('cone (in front of it)', Near(Spatial.Matrix[0], 1, 0.001), DescribeGains(Spatial));
  { Side on: half way between the inner and outer angles. }
  Emitter.Front := Vector(0, 0, 1);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('cone (side on)', Near(Spatial.Matrix[0], 0.625, 0.001), DescribeGains(Spatial));
end;

procedure CheckEmitterChannels;
var
  Listener: TListener;
  Emitter: TEmitter;
  Spatial: TSpatialResult;
begin
  InitializeListener(Listener);
  InitializeEmitter(Emitter);
  { A stereo emitter right in front: its channels 1 to the left and
    right of it. }
  Emitter.ChannelCount := 2;
  Emitter.ChannelRadius := 1;
  Emitter.ChannelAzimuths[0] := -Pi / 2;
  Emitter.ChannelAzimuths[1] := Pi / 2;
  Emitter.Position := Vector(0, 0, 1);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('emitter channels', (Spatial.SourceChannels = 2) and Near(Spatial.Matrix[0], Cos(Pi / 8), 0.001) and
    Near(Spatial.Matrix[3], Cos(Pi / 8), 0.001) and Near(Spatial.Matrix[1], Sin(Pi / 8), 0.001),
    Format('%d %d %d %d', [Round(Spatial.Matrix[0] * 1000),
    Round(Spatial.Matrix[1] * 1000), Round(Spatial.Matrix[2] * 1000),
    Round(Spatial.Matrix[3] * 1000)]));
  { At the emitter, inside its inner radius: everywhere at once. }
  InitializeEmitter(Emitter);
  Emitter.InnerRadius := 2;
  Emitter.Position := Vector(1, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  Check('inner radius', Near(Spatial.Matrix[0], 0.5 * Sqrt(0.5), 0.001) and
    Near(Spatial.Matrix[1], 0.5 + 0.5 * Sqrt(0.5), 0.001), DescribeGains(Spatial));
end;

{ A voice placed to the right and coming closer: louder on the right,
  higher in pitch. }
procedure CheckSpatialVoice;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Listener: TListener;
  Emitter: TEmitter;
  Spatial: TSpatialResult;
  Samples: PSingle;
  Frame: LongWord;
  Buffer: TAudioBuffer;
  Format: TAudioFormat;
begin
  Engine := NewEngine;
  Samples := PSingle(AllocateMemory(Rate * SizeOf(Single)));
  for Frame := 0 to Rate - 1 do
    Samples[Frame] := Amplitude * Sin(2 * Pi * 1000 * Frame / Rate);
  Format.Rate := Rate;
  Format.Channels := 1;
  Format.Kind := SampleFloat32;
  CreateSourceVoice(Engine, Format, 2, NoCallbacks, [], Voice);
  Buffer := NewBuffer(Samples, Rate);
  Buffer.ByteCount := Rate * SizeOf(Single);
  Buffer.LoopCount := LoopInfinite;
  SubmitSourceBuffer(Voice, Buffer);
  StartVoice(Voice, CommitNow);
  InitializeListener(Listener);
  InitializeEmitter(Emitter);
  Emitter.Position := Vector(1, 0, 0);
  Emitter.Velocity := Vector(-DefaultSpeedOfSound / 10, 0, 0);
  CalculateSpatial(Listener, Emitter, 2, DefaultSpeedOfSound, Spatial);
  ApplySpatial(Voice, nil, Spatial, 1, CommitNow);
  { The left side is silent: measure the pitch on the right. }
  Render(Engine);
  for Frame := 0 to RenderFrames - 1 do
    Rendered[Frame * 2] := Rendered[Frame * 2 + 1];
  Check('placed voice (sides)', Near(Peak(1), Amplitude, 0.01), Describe(Peak(1), Amplitude));
  Check('placed voice (pitch)', Near(Frequency, 1000 / 0.9, 10), Describe(Frequency / 1000, 1 / 0.9));
  DestroyAudioEngine(Engine);
end;

var
  CommandLine: TCommandLine;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount <> 0 then
    FailWithUsageHint('no arguments are taken');
  Rendered := PSingle(AllocateMemory(RenderFrames * 2 * SizeOf(Single)));
  CheckVolumeMeter;
  CheckLimiter;
  CheckEcho;
  CheckEqualizer;
  CheckReverb;
  CheckTails;
  CheckPanning;
  CheckSurround;
  CheckDoppler;
  CheckCurvesAndCones;
  CheckEmitterChannels;
  CheckSpatialVoice;
  PrintString(Format('effecttest: %d checks passed'#10, [Passed]));
  if Failed > 0 then
    Halt(1);
end.
