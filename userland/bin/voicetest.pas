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
  voicetest - test the audio engine (libaudio's voices)

  voicetest          renders offline and checks what comes out
  voicetest play     plays a looped buffer through the audio device

  The offline checks build voice graphs on an engine without a device,
  render them and measure the result: frequency (by counting zero
  crossings), loudness on each side (the peak), and the order of the
  callbacks. Each failed check prints a line; at the end the number of
  checks that passed. With play, one cycle of a 600 Hz tone at 24 kHz is
  looped for half a second at twice its pitch: 1200 Hz at the device.
}
program voicetest;

{$mode objfpc}{$H+}
{$pointermath on}

uses
  SysUtils,
  Runtime.Text,
  Sys.Memory,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.CommandLine,
  Util.Output,
  Audio.Formats,
  Audio.Device,
  Audio.Filters,
  Audio.EffectChain,
  Audio.Voices,
  Audio.Engine;

const
  Usage: PChar = 'Usage: voicetest [play]'#10 +
    'Test the audio engine: offline, or with play through the audio device.'#10;
  Rate = 48000;
  { 0.2 s: the passes measured. The first pass is left out of measuring
    (filters and interpolation settle). }
  RenderFrames = 9600;
  SettleFrames = 480;
  Amplitude = 0.5;
  { Mono into stereo: 1/sqrt 2 on each side. }
  Fold = 0.70710678;

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
    PrintString(Format('voicetest: %s failed: %s'#10, [Name, Detail]));
  end;
end;

function Near(Value, Expected, Tolerance: Single): Boolean;
begin
  Result := Abs(Value - Expected) <= Tolerance;
end;

{ Thousandths, for printing. }
function Milli(Value: Single): Int64;
begin
  Result := Round(Value * 1000);
end;

function Describe(Value, Expected: Single): string;
begin
  Result := Format('%d/1000, expected %d/1000', [Milli(Value), Milli(Expected)]);
end;

{ The peak of one side of what was rendered, after it settled. }
function Peak(Channel: LongWord): Single;
var
  Frame: LongWord;
begin
  Result := 0;
  for Frame := SettleFrames to RenderFrames - 1 do
    if Abs(Rendered[Frame * 2 + Channel]) > Result then
      Result := Abs(Rendered[Frame * 2 + Channel]);
end;

{ The amplitude of one side from its RMS level (a sine's peak is
  sqrt 2 times it), which unlike the peak does not depend on where the
  samples fall in each cycle. }
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

{ The frequency of the left side, from its rising zero crossings. }
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

{ Frames frames of a sine of Hertz at SourceRate, float, every channel
  the same. }
function MakeSine(Frames: LongWord; Hertz: Single; SourceRate, Channels: LongWord): PSingle;
var
  Frame: LongWord;
  Channel: LongWord;
begin
  Result := PSingle(AllocateMemory(Frames * Channels * SizeOf(Single)));
  for Frame := 0 to Frames - 1 do
    for Channel := 0 to Channels - 1 do
      Result[Frame * Channels + Channel] := Amplitude * Sin(2 * Pi * Hertz * Frame / SourceRate);
end;

function NewEngine: PAudioEngine;
var
  Master: PAudioVoice;
begin
  if CreateAudioEngine(nil, True, Result) <> 0 then
    Fail(1, 'cannot create an engine');
  if CreateMasteringVoice(Result, 2, Rate, Master) <> 0 then
    Fail(1, 'cannot create a mastering voice');
end;

function FloatFormat(SourceRate, Channels: LongWord): TAudioFormat;
begin
  Result.Rate := SourceRate;
  Result.Channels := Channels;
  Result.Kind := SampleFloat32;
end;

function NoCallbacks: TVoiceCallbacks;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

function WholeBuffer(Data: Pointer; ByteCount: LongWord): TAudioBuffer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Data := Data;
  Result.ByteCount := ByteCount;
end;

{ A started source voice looping a second of a sine of Hertz, sent to
  Destinations (none: the mastering voice). }
function SineVoice(Engine: PAudioEngine; Hertz: Single; SourceRate, Channels: LongWord;
  const Destinations: array of PAudioVoice): PAudioVoice;
var
  Buffer: TAudioBuffer;
begin
  if CreateSourceVoice(Engine, FloatFormat(SourceRate, Channels), 4, NoCallbacks, Destinations, Result) <> 0 then
    Fail(1, 'cannot create a source voice');
  Buffer := WholeBuffer(MakeSine(SourceRate, Hertz, SourceRate, Channels), SourceRate * Channels * SizeOf(Single));
  Buffer.LoopCount := LoopInfinite;
  SubmitSourceBuffer(Result, Buffer);
  StartVoice(Result, CommitNow);
end;

procedure Render(Engine: PAudioEngine);
begin
  RenderAudio(Engine, RenderFrames, Rendered);
end;

{ --- The checks ------------------------------------------------------------------ }

procedure CheckResampling;
var
  Engine: PAudioEngine;
begin
  Engine := NewEngine;
  SineVoice(Engine, 1000, 24000, 1, []);
  Render(Engine);
  Check('resampling (frequency)', Near(Frequency, 1000, 10), Describe(Frequency, 1000));
  Check('resampling (level)', Near(Peak(0), Amplitude * Fold, 0.02), Describe(Peak(0), Amplitude * Fold));
  DestroyAudioEngine(Engine);
end;

procedure CheckPitch;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
begin
  Engine := NewEngine;
  Voice := SineVoice(Engine, 1000, Rate, 1, []);
  SetFrequencyRatio(Voice, 0.5, CommitNow);
  Render(Engine);
  Check('frequency ratio 0.5', Near(Frequency, 500, 5), Describe(Frequency, 500));
  SetFrequencyRatio(Voice, 1.5, CommitNow);
  Render(Engine);
  Check('frequency ratio 1.5', Near(Frequency, 1500, 15), Describe(Frequency, 1500));
  { Above the voice's maximum ratio (4): held at it. }
  SetFrequencyRatio(Voice, 10, CommitNow);
  Check('maximum frequency ratio', GetFrequencyRatio(Voice) = 4, 'not held at 4');
  DestroyAudioEngine(Engine);
end;

procedure CheckVolumes;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
begin
  Engine := NewEngine;
  Voice := SineVoice(Engine, 1000, Rate, 2, []);
  SetVolume(Voice, 0.5, CommitNow);
  Render(Engine);
  Check('volume', Near(Peak(0), Amplitude * 0.5, 0.01), Describe(Peak(0), Amplitude * 0.5));
  SetVolume(Voice, 1, CommitNow);
  SetChannelVolumes(Voice, [1, 0.25], CommitNow);
  Render(Engine);
  Check('channel volumes (left)', Near(Peak(0), Amplitude, 0.01), Describe(Peak(0), Amplitude));
  Check('channel volumes (right)', Near(Peak(1), Amplitude * 0.25, 0.01), Describe(Peak(1), Amplitude * 0.25));
  DestroyAudioEngine(Engine);
end;

procedure CheckMatrix;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Matrix: array[0..1] of Single;
begin
  Engine := NewEngine;
  Voice := SineVoice(Engine, 1000, Rate, 1, []);
  SetOutputMatrix(Voice, nil, [1, 0], CommitNow);
  Render(Engine);
  Check('output matrix (left)', Near(Peak(0), Amplitude, 0.01), Describe(Peak(0), Amplitude));
  Check('output matrix (right)', Peak(1) < 0.001, Describe(Peak(1), 0));
  GetOutputMatrix(Voice, nil, @Matrix[0]);
  Check('reading the output matrix', (Matrix[0] = 1) and (Matrix[1] = 0), 'not as set');
  DestroyAudioEngine(Engine);
end;

{ The level of a 1000 or 8000 Hz tone through a voice filter, against
  the level without it. }
function FilteredLevel(Kind: TFilterKind; Cutoff, Hertz: Single): Single;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Parameters: TFilterParameters;
begin
  Engine := NewEngine;
  Voice := SineVoice(Engine, Hertz, Rate, 2, []);
  Parameters.Kind := Kind;
  Parameters.OneOverQ := 1;
  if Kind in [FilterLowPassOnePole, FilterHighPassOnePole] then
    Parameters.Frequency := CutoffToOnePoleFrequency(Cutoff, Rate)
  else
    Parameters.Frequency := CutoffToFilterFrequency(Cutoff, Rate);
  SetFilterParameters(Voice, Parameters, CommitNow);
  Render(Engine);
  Result := Level(0) / Amplitude;
  DestroyAudioEngine(Engine);
end;

procedure CheckFilters;
var
  Level: Single;
begin
  Level := FilteredLevel(FilterLowPass, 500, 8000);
  Check('low-pass filter', Level < 0.02, Describe(Level, 0));
  Level := FilteredLevel(FilterHighPass, 500, 8000);
  Check('high-pass filter', Level > 0.9, Describe(Level, 1));
  Level := FilteredLevel(FilterHighPass, 8000, 500);
  Check('high-pass filter (below)', Level < 0.02, Describe(Level, 0));
  Level := FilteredLevel(FilterBandPass, 1000, 1000);
  Check('band-pass filter', Level > 0.9, Describe(Level, 1));
  Level := FilteredLevel(FilterBandPass, 1000, 8000);
  Check('band-pass filter (outside)', Level < 0.2, Describe(Level, 0));
  Level := FilteredLevel(FilterNotch, 1000, 1000);
  Check('notch filter', Level < 0.05, Describe(Level, 0));
  Level := FilteredLevel(FilterLowPassOnePole, 200, 8000);
  Check('one-pole low-pass filter', Level < 0.05, Describe(Level, 0));
  Level := FilteredLevel(FilterHighPassOnePole, 200, 8000);
  Check('one-pole high-pass filter', Level > 0.9, Describe(Level, 1));
end;

{ --- Callbacks and buffers --------------------------------------------------- }

var
  Events: array[0..1023] of Char;
  EventLength: Integer;
  StreamEnded: Boolean;

procedure NoteEvent(Text: PChar);
begin
  while (Text^ <> #0) and (EventLength < High(Events)) do
  begin
    Events[EventLength] := Text^;
    Inc(EventLength);
    Inc(Text);
  end;
  Events[EventLength] := #0;
end;

procedure NoteBufferStart(Context: Pointer; BufferContext: Pointer);
begin
  NoteEvent('start ');
  NoteEvent(PChar(BufferContext));
  NoteEvent(', ');
end;

procedure NoteBufferEnd(Context: Pointer; BufferContext: Pointer);
begin
  NoteEvent('end ');
  NoteEvent(PChar(BufferContext));
  NoteEvent(', ');
end;

procedure NoteLoopEnd(Context: Pointer; BufferContext: Pointer);
begin
  NoteEvent('loop ');
  NoteEvent(PChar(BufferContext));
  NoteEvent(', ');
end;

procedure NoteStreamEnd(Context: Pointer);
begin
  NoteEvent('stream end');
  StreamEnded := True;
end;

function NotingCallbacks: TVoiceCallbacks;
begin
  Result := NoCallbacks;
  Result.OnBufferStart := @NoteBufferStart;
  Result.OnBufferEnd := @NoteBufferEnd;
  Result.OnLoopEnd := @NoteLoopEnd;
  Result.OnStreamEnd := @NoteStreamEnd;
end;

procedure CheckCallbacks;
const
  Expected: PChar = 'start A, loop A, loop A, end A, start B, end B, stream end';
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  First: TAudioBuffer;
  Second: TAudioBuffer;
  State: TVoiceState;
  Samples: PSingle;
begin
  EventLength := 0;
  Events[0] := #0;
  Engine := NewEngine;
  CreateSourceVoice(Engine, FloatFormat(Rate, 1), 1, NotingCallbacks, [], Voice);
  Samples := MakeSine(100, 1000, Rate, 1);
  { 100 frames with frames 20-39 played three times, then 50 more. }
  First := WholeBuffer(Samples, 100 * SizeOf(Single));
  First.LoopBegin := 20;
  First.LoopLength := 20;
  First.LoopCount := 2;
  First.Context := PChar('A');
  Second := WholeBuffer(Samples, 50 * SizeOf(Single));
  Second.Flags := BufferEndOfStream;
  Second.Context := PChar('B');
  SubmitSourceBuffer(Voice, First);
  SubmitSourceBuffer(Voice, Second);
  GetVoiceState(Voice, State);
  Check('buffers queued', State.BuffersQueued = 2, 'not 2');
  StartVoice(Voice, CommitNow);
  Render(Engine);
  Check('buffer callbacks', TextIsEqual(@Events[0], Expected), PChar(@Events[0]));
  GetVoiceState(Voice, State);
  Check('samples played', State.SamplesPlayed = 190,
    Format('%u, expected 190', [State.SamplesPlayed]));
  Check('queue empty', State.BuffersQueued = 0, 'buffers left');
  DestroyAudioEngine(Engine);
end;

procedure CheckExitLoop;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Buffer: TAudioBuffer;
  State: TVoiceState;
begin
  EventLength := 0;
  Events[0] := #0;
  Engine := NewEngine;
  CreateSourceVoice(Engine, FloatFormat(Rate, 1), 1, NotingCallbacks, [], Voice);
  Buffer := WholeBuffer(MakeSine(480, 1000, Rate, 1), 480 * SizeOf(Single));
  Buffer.LoopCount := LoopInfinite;
  Buffer.Context := PChar('L');
  SubmitSourceBuffer(Voice, Buffer);
  StartVoice(Voice, CommitNow);
  Render(Engine);
  GetVoiceState(Voice, State);
  Check('infinite loop', State.BuffersQueued = 1, 'the buffer ended');
  ExitLoop(Voice, CommitNow);
  Render(Engine);
  GetVoiceState(Voice, State);
  Check('exit loop', State.BuffersQueued = 0, 'the buffer is still looping');
  Check('exit loop (callbacks)', TextEndsWith(@Events[0], 'loop L, end L, '), PChar(@Events[0]));
  DestroyAudioEngine(Engine);
end;

procedure CheckFlush;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Buffer: TAudioBuffer;
  State: TVoiceState;
  Index: Integer;
begin
  Engine := NewEngine;
  CreateSourceVoice(Engine, FloatFormat(Rate, 1), 1, NoCallbacks, [], Voice);
  Buffer := WholeBuffer(MakeSine(Rate, 1000, Rate, 1), Rate * SizeOf(Single));
  for Index := 1 to 3 do
    SubmitSourceBuffer(Voice, Buffer);
  StartVoice(Voice, CommitNow);
  Render(Engine);
  FlushSourceBuffers(Voice);
  GetVoiceState(Voice, State);
  Check('flush (the playing buffer stays)', State.BuffersQueued = 1,
    Format('%u buffers', [State.BuffersQueued]));
  DestroyAudioEngine(Engine);
end;

procedure CheckSampleKinds;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Format: TAudioFormat;
  Samples: PByte;
  Frame: LongWord;
begin
  Engine := NewEngine;
  Format.Rate := Rate;
  Format.Channels := 2;
  Format.Kind := SampleUnsigned8;
  Samples := PByte(AllocateMemory(Rate * 2));
  for Frame := 0 to Rate - 1 do
  begin
    EncodeSample(Amplitude * Sin(2 * Pi * 1000 * Frame / Rate), SampleUnsigned8, Samples + Frame * 2);
    EncodeSample(Amplitude * Sin(2 * Pi * 1000 * Frame / Rate), SampleUnsigned8, Samples + Frame * 2 + 1);
  end;
  CreateSourceVoice(Engine, Format, 1, NoCallbacks, [], Voice);
  SubmitSourceBuffer(Voice, WholeBuffer(Samples, Rate * 2));
  StartVoice(Voice, CommitNow);
  Render(Engine);
  Check('8-bit samples', Near(Peak(0), Amplitude, 0.02) and Near(Frequency, 1000, 10),
    Describe(Peak(0), Amplitude));
  DestroyAudioEngine(Engine);
end;

{ --- Graphs, operation sets, effects ----------------------------------------- }

procedure CheckSubmix;
var
  Engine: PAudioEngine;
  Early: PAudioVoice;
  Late: PAudioVoice;
  Voice: PAudioVoice;
  Parameters: TFilterParameters;
  Refused: PAudioVoice;
begin
  Engine := NewEngine;
  CreateSubmixVoice(Engine, 2, 1, [], Late);
  CreateSubmixVoice(Engine, 2, 0, [Late], Early);
  SetVolume(Early, 0.5, CommitNow);
  SetVolume(Late, 0.5, CommitNow);
  Voice := SineVoice(Engine, 1000, Rate, 2, [Early]);
  Render(Engine);
  Check('submix voices', Near(Peak(0), Amplitude * 0.25, 0.01), Describe(Peak(0), Amplitude * 0.25));
  { Two sends: through the submix voices and straight to the master. }
  SetOutputVoices(Voice, [Early, Engine^.Master]);
  Render(Engine);
  Check('two sends', Near(Peak(0), Amplitude * 1.25, 0.01), Describe(Peak(0), Amplitude * 1.25));
  { The send to the master filtered away. }
  Parameters.Kind := FilterHighPass;
  Parameters.Frequency := CutoffToFilterFrequency(8000, Rate);
  Parameters.OneOverQ := 1;
  SetOutputFilterParameters(Voice, Engine^.Master, Parameters, CommitNow);
  Render(Engine);
  Check('send filter', Near(Peak(0), Amplitude * 0.25, 0.02), Describe(Peak(0), Amplitude * 0.25));
  { Sound only flows to later stages. }
  Check('stage order', CreateSubmixVoice(Engine, 2, 1, [Early], Refused) <> 0, 'a send to an earlier stage');
  DestroyVoice(Early);
  Render(Engine);
  Check('destroying a destination', Near(Peak(0), 0, 0.02), Describe(Peak(0), 0));
  DestroyAudioEngine(Engine);
end;

procedure CheckOperationSets;
var
  Engine: PAudioEngine;
  First: PAudioVoice;
  Second: PAudioVoice;
begin
  Engine := NewEngine;
  First := SineVoice(Engine, 1000, Rate, 2, []);
  Second := SineVoice(Engine, 1000, Rate, 2, []);
  SetVolume(First, 0, 7);
  StopVoice(Second, 0, 7);
  Render(Engine);
  Check('operation set kept back', Near(Peak(0), Amplitude * 2, 0.02), Describe(Peak(0), Amplitude * 2));
  CommitChanges(Engine, 8);
  Render(Engine);
  Check('other operation set', Near(Peak(0), Amplitude * 2, 0.02), Describe(Peak(0), Amplitude * 2));
  CommitChanges(Engine, 7);
  Render(Engine);
  Check('operation set committed', Peak(0) < 0.0001, Describe(Peak(0), 0));
  StartVoice(Second, CommitNow);
  Render(Engine);
  Check('voice started again', Near(Peak(0), Amplitude, 0.02), Describe(Peak(0), Amplitude));
  DestroyAudioEngine(Engine);
end;

type
  PGainState = ^TGainState;
  TGainState = record
    Gain: Single;
    Passes: Integer;
    Released: Boolean;
  end;

procedure GainProcess(Effect: PAudioEffect; Samples: PSingle; Frames, Channels, Rate: LongWord);
var
  Index: LongWord;
  State: PGainState;
begin
  State := PGainState(Effect^.State);
  for Index := 0 to Frames * Channels - 1 do
    Samples[Index] := Samples[Index] * State^.Gain;
  Inc(State^.Passes);
end;

procedure GainSetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
begin
  if Size = SizeOf(Single) then
    PGainState(Effect^.State)^.Gain := PSingle(Parameters)^;
end;

procedure GainGetParameters(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
begin
  if Size = SizeOf(Single) then
    PSingle(Parameters)^ := PGainState(Effect^.State)^.Gain;
end;

procedure GainRelease(Effect: PAudioEffect);
begin
  PGainState(Effect^.State)^.Released := True;
end;

{ A tail of 50 ms, to see a stopped voice play out its effects. }
function GainTail(Effect: PAudioEffect; Rate: LongWord): LongWord;
begin
  Result := Rate div 20;
end;

procedure CheckEffects;
var
  Engine: PAudioEngine;
  Voice: PAudioVoice;
  Effect: TAudioEffect;
  State: TGainState;
  Gain: Single;
  PassesBefore: Integer;
begin
  FillChar(Effect, SizeOf(Effect), 0);
  Effect.Process := @GainProcess;
  Effect.SetParameters := @GainSetParameters;
  Effect.GetParameters := @GainGetParameters;
  Effect.Release := @GainRelease;
  Effect.TailFrames := @GainTail;
  Effect.State := @State;
  State.Gain := 3;
  State.Passes := 0;
  State.Released := False;
  Engine := NewEngine;
  Voice := SineVoice(Engine, 1000, Rate, 2, []);
  SetVolume(Voice, 0.25, CommitNow);
  SetEffectChain(Voice, [@Effect]);
  Render(Engine);
  Check('custom effect', Near(Peak(0), Amplitude * 0.75, 0.01), Describe(Peak(0), Amplitude * 0.75));
  Gain := 2;
  SetEffectParameters(Voice, 0, @Gain, SizeOf(Gain), CommitNow);
  Gain := 0;
  GetEffectParameters(Voice, 0, @Gain, SizeOf(Gain));
  Check('effect parameters', Gain = 2, 'not as set');
  DisableEffect(Voice, 0, CommitNow);
  Render(Engine);
  Check('disabled effect', Near(Peak(0), Amplitude * 0.25, 0.01), Describe(Peak(0), Amplitude * 0.25));
  EnableEffect(Voice, 0, CommitNow);
  { Stopped with its tails, the effect runs on for 50 ms (5 passes);
    stopped without, not at all. }
  StopVoice(Voice, StopPlayTails, CommitNow);
  PassesBefore := State.Passes;
  Render(Engine);
  Check('effect tails', State.Passes - PassesBefore = 5,
    Format('%d passes, expected 5', [State.Passes - PassesBefore]));
  StartVoice(Voice, CommitNow);
  StopVoice(Voice, 0, CommitNow);
  PassesBefore := State.Passes;
  Render(Engine);
  Check('stopped without tails', State.Passes = PassesBefore, 'the effect still ran');
  DestroyVoice(Voice);
  Check('effect released', State.Released, 'not released');
  DestroyAudioEngine(Engine);
end;

procedure CheckPerformanceData;
var
  Engine: PAudioEngine;
  Data: TEnginePerformance;
  Silent: PAudioVoice;
begin
  Engine := NewEngine;
  SineVoice(Engine, 1000, Rate, 2, []);
  CreateSourceVoice(Engine, FloatFormat(Rate, 2), 1, NoCallbacks, [], Silent);
  Render(Engine);
  GetPerformanceData(Engine, Data);
  Check('performance data', (Data.TotalVoices = 3) and (Data.ActiveSourceVoices = 1) and
    (Data.Passes = RenderFrames div 480) and (Data.FramesRendered = RenderFrames),
    Format('%u voices, %u active, %u passes', [Data.TotalVoices,
    Data.ActiveSourceVoices, Data.Passes]));
  DestroyAudioEngine(Engine);
end;

procedure RunOfflineChecks;
begin
  Rendered := PSingle(AllocateMemory(RenderFrames * 2 * SizeOf(Single)));
  CheckResampling;
  CheckPitch;
  CheckVolumes;
  CheckMatrix;
  CheckFilters;
  CheckCallbacks;
  CheckExitLoop;
  CheckFlush;
  CheckSampleKinds;
  CheckSubmix;
  CheckOperationSets;
  CheckEffects;
  CheckPerformanceData;
  PrintString(Format('voicetest: %d checks passed'#10, [Passed]));
  if Failed > 0 then
    Halt(1);
end;

{ --- Playing ------------------------------------------------------------------------ }

procedure PlayThroughDevice;
const
  CycleFrames = 40;
var
  Engine: PAudioEngine;
  Master: PAudioVoice;
  Voice: PAudioVoice;
  Format: TAudioFormat;
  Cycle: array[0..CycleFrames - 1] of SmallInt;
  Frame: Integer;
  Buffer: TAudioBuffer;
  Callbacks: TVoiceCallbacks;
  Error: LongInt;
begin
  Error := CreateAudioEngine(nil, False, Engine);
  if Error <> 0 then
    Fail(1, 'cannot open the audio device');
  CreateMasteringVoice(Engine, 2, Rate, Master);
  { One cycle of 600 Hz at 24 kHz, 16-bit mono. }
  for Frame := 0 to CycleFrames - 1 do
    Cycle[Frame] := Round(16383 * Sin(2 * Pi * Frame / CycleFrames));
  Format.Rate := 24000;
  Format.Channels := 1;
  Format.Kind := SampleSigned16;
  Callbacks := NoCallbacks;
  Callbacks.OnStreamEnd := @NoteStreamEnd;
  CreateSourceVoice(Engine, Format, 2, Callbacks, [], Voice);
  SetOutputMatrix(Voice, nil, [1, 1], CommitNow);
  { At twice the pitch, 1200 cycles a second: 600 of them. }
  Buffer := WholeBuffer(@Cycle[0], SizeOf(Cycle));
  Buffer.LoopCount := 599;
  Buffer.Flags := BufferEndOfStream;
  SubmitSourceBuffer(Voice, Buffer);
  SetFrequencyRatio(Voice, 2, 1);
  StartVoice(Voice, 1);
  CommitChanges(Engine, 1);
  StreamEnded := False;
  StartAudioEngine(Engine);
  while not StreamEnded do
    SleepMilliseconds(10);
  DestroyAudioEngine(Engine);
end;

var
  CommandLine: TCommandLine;
begin
  CommandLine := TCommandLine.Create([], Usage);
  CommandLine.ReadOperandsOnly;
  if CommandLine.OperandCount = 0 then
    RunOfflineChecks
  else if (CommandLine.OperandCount = 1) and (CommandLine.Operands[0] = 'play') then
    PlayThroughDevice
  else
    FailWithUsageHint('unknown arguments');
end.
