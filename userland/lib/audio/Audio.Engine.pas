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
  The audio engine: voices mixed in a graph, as XAudio2 does it.

  Voices:
    source     plays the buffers queued on it, in any sample format and
               rate, at a pitch of its own (the frequency ratio)
    submix     takes what voices send it and passes it on; submix voices
               are processed in the order of their processing stage
    mastering  the end of the graph: one per engine, sent to the audio
               device (or, offline, handed to RenderAudio's caller)

  Every voice has a volume, a volume per channel, a filter and a chain
  of effects (Audio.EffectChain), and sends its sound to one or more
  voices further down, each send with an output matrix (how its
  channels go into the destination's) and a filter of its own.

  Processing runs in passes of EngineQuantumMilliseconds on the engine's
  thread, in 32-bit float: the source voices render their buffers, then
  the submix voices in stage order, then the mastering voice, whose
  sound goes to the device as float samples (the kernel mixes it with
  other programs and converts it). Callbacks run on the engine's thread
  during a pass.

  Operation sets: a change made with a non-zero OperationSet is kept
  back until CommitChanges with that set, so several changes take
  effect in the same pass. OperationSet 0 (CommitNow) changes at once.

  Calls are safe from any thread, and from the callbacks.
}
unit Audio.Engine;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.Locks,
  Audio.Device,
  Audio.Filters,
  Audio.EffectChain,
  Audio.Voices;

const
  EngineQuantumMilliseconds = 10;
  CommitNow = 0;
  { StopVoice: the voice's effects play out their tails. }
  StopPlayTails = 1;
  MaximumPendingOperations = 256;
  MaximumParameterBytes = 256;

  EngineErrorInvalidCall = 1;
  EngineErrorDevice = 2;
  EngineErrorOutOfMemory = 3;

type
  TPendingKind = (PendingStart, PendingStop, PendingFrequencyRatio, PendingVolume, PendingChannelVolumes,
    PendingOutputMatrix, PendingFilter, PendingOutputFilter, PendingExitLoop, PendingEnableEffect,
    PendingDisableEffect, PendingEffectParameters);

  TPendingOperation = record
    OperationSet: LongWord;
    Kind: TPendingKind;
    Voice: PAudioVoice;
    Destination: PAudioVoice;
    Flags: LongWord;
    Index: Integer;
    Values: array[0..MaximumVoiceChannels * MaximumVoiceChannels - 1] of Single;
    ValueCount: Integer;
    Filter: TFilterParameters;
    Parameters: array[0..MaximumParameterBytes - 1] of Byte;
    ParameterSize: LongWord;
  end;

  TEnginePerformance = record
    ActiveSourceVoices: LongWord;
    TotalVoices: LongWord;
    Passes: QWord;
    FramesRendered: QWord;
    { Frames waiting in the device (written, not yet mixed). }
    QueuedFrames: LongWord;
  end;

  TVoiceState = record
    BuffersQueued: LongWord;
    SamplesPlayed: QWord;
    CurrentBufferContext: Pointer;
  end;

  PAudioEngine = ^TAudioEngine;
  TAudioEngine = record
    Lock: TLock;
    RenderingThread: QWord;
    Rate: LongWord;
    QuantumFrames: LongWord;
    Device: Int64;
    Thread: Int64;
    Running: LongInt;
    Quitting: LongInt;
    Voices: PAudioVoice;
    Master: PAudioVoice;
    Output: PSingle;
    { Room for one voice's samples, for filtered sends. }
    Scratch: PSingle;
    Pending: array[0..MaximumPendingOperations - 1] of TPendingOperation;
    PendingCount: Integer;
    Performance: TEnginePerformance;
  end;

{ An engine playing on the audio device DevicePath (nil: /dev/audio), or
  with Offline, one whose caller pulls the sound with RenderAudio. }
function CreateAudioEngine(DevicePath: PChar; Offline: Boolean; out Engine: PAudioEngine): LongInt;
procedure DestroyAudioEngine(Engine: PAudioEngine);
{ Starts and stops processing (an offline engine is never started). }
function StartAudioEngine(Engine: PAudioEngine): LongInt;
procedure StopAudioEngine(Engine: PAudioEngine);

function CreateMasteringVoice(Engine: PAudioEngine; Channels, Rate: LongWord; out Voice: PAudioVoice): LongInt;
{ Destinations: the voices it sends to (none: the mastering voice). }
function CreateSubmixVoice(Engine: PAudioEngine; Channels, ProcessingStage: LongWord;
  const Destinations: array of PAudioVoice; out Voice: PAudioVoice): LongInt;
function CreateSourceVoice(Engine: PAudioEngine; const Format: TAudioFormat; MaximumFrequencyRatio: Single;
  const Callbacks: TVoiceCallbacks; const Destinations: array of PAudioVoice; out Voice: PAudioVoice): LongInt;
procedure DestroyVoice(Voice: PAudioVoice);
function SetOutputVoices(Voice: PAudioVoice; const Destinations: array of PAudioVoice): LongInt;

function SubmitSourceBuffer(Voice: PAudioVoice; const Buffer: TAudioBuffer): LongInt;
procedure FlushSourceBuffers(Voice: PAudioVoice);
{ Marks the last queued buffer as the end of the stream. }
procedure Discontinuity(Voice: PAudioVoice);
procedure ExitLoop(Voice: PAudioVoice; OperationSet: LongWord);
procedure StartVoice(Voice: PAudioVoice; OperationSet: LongWord);
procedure StopVoice(Voice: PAudioVoice; Flags, OperationSet: LongWord);
procedure GetVoiceState(Voice: PAudioVoice; out State: TVoiceState);

procedure SetFrequencyRatio(Voice: PAudioVoice; Ratio: Single; OperationSet: LongWord);
function GetFrequencyRatio(Voice: PAudioVoice): Single;
procedure SetVolume(Voice: PAudioVoice; Volume: Single; OperationSet: LongWord);
function GetVolume(Voice: PAudioVoice): Single;
procedure SetChannelVolumes(Voice: PAudioVoice; const Volumes: array of Single; OperationSet: LongWord);
procedure GetChannelVolumes(Voice: PAudioVoice; Volumes: PSingle);
{ Matrix[source channel * destination channels + destination channel];
  Destination nil: the voice's first destination. }
procedure SetOutputMatrix(Voice, Destination: PAudioVoice; const Matrix: array of Single; OperationSet: LongWord);
procedure GetOutputMatrix(Voice, Destination: PAudioVoice; Matrix: PSingle);
procedure SetFilterParameters(Voice: PAudioVoice; const Parameters: TFilterParameters; OperationSet: LongWord);
procedure GetFilterParameters(Voice: PAudioVoice; out Parameters: TFilterParameters);
procedure SetOutputFilterParameters(Voice, Destination: PAudioVoice; const Parameters: TFilterParameters;
  OperationSet: LongWord);

{ Replaces the voice's effects (the old ones are released); all start
  enabled. }
function SetEffectChain(Voice: PAudioVoice; const Effects: array of PAudioEffect): LongInt;
procedure EnableEffect(Voice: PAudioVoice; Index: Integer; OperationSet: LongWord);
procedure DisableEffect(Voice: PAudioVoice; Index: Integer; OperationSet: LongWord);
procedure SetEffectParameters(Voice: PAudioVoice; Index: Integer; Parameters: Pointer; Size: LongWord;
  OperationSet: LongWord);
procedure GetEffectParameters(Voice: PAudioVoice; Index: Integer; Parameters: Pointer; Size: LongWord);

{ Applies the changes made with OperationSet. }
function CommitChanges(Engine: PAudioEngine; OperationSet: LongWord): LongInt;
procedure GetPerformanceData(Engine: PAudioEngine; out Data: TEnginePerformance);
{ Offline engines: processes passes until Frames frames are in Output,
  the mastering voice's channels interleaved. Frames are best a multiple
  of QuantumFrames: the rest of the last pass is dropped. }
procedure RenderAudio(Engine: PAudioEngine; Frames: LongWord; Output: PSingle);

implementation

uses
  Sys.Memory,
  Sys.Processes,
  Sys.Threads,
  Audio.Formats;

{ --- Locking --------------------------------------------------------------- }

{ The lock is not taken again by the engine's own thread while it
  processes (callbacks call in). }
function EnterEngine(Engine: PAudioEngine): Boolean;
begin
  Result := Engine^.RenderingThread <> GetCurrentThreadId;
  if Result then
    AcquireLock(Engine^.Lock);
end;

procedure LeaveEngine(Engine: PAudioEngine; Entered: Boolean);
begin
  if Entered then
    ReleaseLock(Engine^.Lock);
end;

function EngineOf(Voice: PAudioVoice): PAudioEngine;
begin
  Result := PAudioEngine(Voice^.Engine);
end;

{ --- Voices ------------------------------------------------------------------ }

function AllocateVoice(Engine: PAudioEngine; Kind: TVoiceKind; Channels: LongWord;
  out Voice: PAudioVoice): LongInt;
var
  Channel: LongWord;
begin
  Voice := nil;
  if (Channels < 1) or (Channels > MaximumVoiceChannels) then
    Exit(EngineErrorInvalidCall);
  Voice := PAudioVoice(AllocateMemory(SizeOf(TAudioVoice)));
  if Voice = nil then
    Exit(EngineErrorOutOfMemory);
  FillChar(Voice^, SizeOf(TAudioVoice), 0);
  Voice^.Engine := Engine;
  Voice^.Kind := Kind;
  Voice^.Channels := Channels;
  Voice^.Volume := 1;
  for Channel := 0 to MaximumVoiceChannels - 1 do
    Voice^.ChannelVolumes[Channel] := 1;
  Voice^.Filter := DefaultFilterParameters;
  Voice^.FrequencyRatio := 1;
  Voice^.Samples := PSingle(AllocateMemory(Engine^.QuantumFrames * Channels * SizeOf(Single)));
  Voice^.Input := PSingle(AllocateMemory(Engine^.QuantumFrames * Channels * SizeOf(Single)));
  if (Voice^.Samples = nil) or (Voice^.Input = nil) then
    Exit(EngineErrorOutOfMemory);
  FillChar(Voice^.Input^, Engine^.QuantumFrames * Channels * SizeOf(Single), 0);
  Result := 0;
end;

procedure LinkVoice(Engine: PAudioEngine; Voice: PAudioVoice);
begin
  Voice^.Next := Engine^.Voices;
  Engine^.Voices := Voice;
end;

{ Sets the sends of Voice (the mastering voice if Destinations is
  empty), each with the default matrix and no filter. Engine locked. }
function SetSendsLocked(Voice: PAudioVoice; const Destinations: array of PAudioVoice): LongInt;
var
  Engine: PAudioEngine;
  Index: Integer;
  Destination: PAudioVoice;
  Count: Integer;
begin
  Engine := EngineOf(Voice);
  Count := Length(Destinations);
  if Count > MaximumSends then
    Exit(EngineErrorInvalidCall);
  if Count = 0 then
  begin
    if Engine^.Master = nil then
      Exit(EngineErrorInvalidCall);
    Count := 1;
  end;
  for Index := 0 to Count - 1 do
  begin
    if Length(Destinations) = 0 then
      Destination := Engine^.Master
    else
      Destination := Destinations[Index];
    { Sound only flows down: to the mastering voice, or to a submix
      voice of a later stage. }
    if (Destination = nil) or (Destination^.Kind = VoiceSource) or (Destination = Voice) or
       ((Voice^.Kind = VoiceSubmix) and (Destination^.Kind = VoiceSubmix) and
        (Destination^.ProcessingStage <= Voice^.ProcessingStage)) then
      Exit(EngineErrorInvalidCall);
    FillChar(Voice^.Sends[Index], SizeOf(TVoiceSend), 0);
    Voice^.Sends[Index].Destination := Destination;
    Voice^.Sends[Index].Filter := DefaultFilterParameters;
    DefaultMatrix(Voice^.Channels, Destination^.Channels, @Voice^.Sends[Index].Matrix[0]);
  end;
  Voice^.SendCount := Count;
  Result := 0;
end;

function CreateMasteringVoice(Engine: PAudioEngine; Channels, Rate: LongWord; out Voice: PAudioVoice): LongInt;
var
  Entered: Boolean;
  Format: TAudioFormat;
begin
  Voice := nil;
  if (Engine^.Master <> nil) or (Rate < 8000) or (Rate > 192000) then
    Exit(EngineErrorInvalidCall);
  Entered := EnterEngine(Engine);
  Engine^.Rate := Rate;
  Engine^.QuantumFrames := Rate * EngineQuantumMilliseconds div 1000;
  Result := AllocateVoice(Engine, VoiceMastering, Channels, Voice);
  if Result = 0 then
  begin
    Engine^.Output := PSingle(AllocateMemory(Engine^.QuantumFrames * Channels * SizeOf(Single)));
    Engine^.Scratch := PSingle(AllocateMemory(Engine^.QuantumFrames * MaximumVoiceChannels * SizeOf(Single)));
    if (Engine^.Output = nil) or (Engine^.Scratch = nil) then
      Result := EngineErrorOutOfMemory;
  end;
  if (Result = 0) and (Engine^.Device >= 0) then
  begin
    Format.Rate := Rate;
    Format.Channels := Channels;
    Format.Kind := SampleFloat32;
    if SetAudioFormat(Engine^.Device, Format) <> 0 then
      Result := EngineErrorDevice;
  end;
  if Result = 0 then
  begin
    LinkVoice(Engine, Voice);
    Engine^.Master := Voice;
  end;
  LeaveEngine(Engine, Entered);
end;

function CreateSubmixVoice(Engine: PAudioEngine; Channels, ProcessingStage: LongWord;
  const Destinations: array of PAudioVoice; out Voice: PAudioVoice): LongInt;
var
  Entered: Boolean;
begin
  Voice := nil;
  if Engine^.Master = nil then
    Exit(EngineErrorInvalidCall);
  Entered := EnterEngine(Engine);
  Result := AllocateVoice(Engine, VoiceSubmix, Channels, Voice);
  if Result = 0 then
  begin
    Voice^.ProcessingStage := ProcessingStage;
    Result := SetSendsLocked(Voice, Destinations);
  end;
  if Result = 0 then
    LinkVoice(Engine, Voice);
  LeaveEngine(Engine, Entered);
end;

function CreateSourceVoice(Engine: PAudioEngine; const Format: TAudioFormat; MaximumFrequencyRatio: Single;
  const Callbacks: TVoiceCallbacks; const Destinations: array of PAudioVoice; out Voice: PAudioVoice): LongInt;
var
  Entered: Boolean;
begin
  Voice := nil;
  if (Engine^.Master = nil) or not SampleKindIsValid(Format.Kind) or (Format.Rate < 1000) or
     (Format.Rate > 200000) then
    Exit(EngineErrorInvalidCall);
  Entered := EnterEngine(Engine);
  Result := AllocateVoice(Engine, VoiceSource, Format.Channels, Voice);
  if Result = 0 then
  begin
    Voice^.SourceRate := Format.Rate;
    Voice^.SourceKind := Format.Kind;
    Voice^.BytesPerFrame := Format.Channels * BytesPerSample(Format.Kind);
    Voice^.Callbacks := Callbacks;
    Voice^.MaximumFrequencyRatio := MaximumFrequencyRatio;
    if Voice^.MaximumFrequencyRatio < 1 then
      Voice^.MaximumFrequencyRatio := 1;
    Result := SetSendsLocked(Voice, Destinations);
  end;
  if Result = 0 then
    LinkVoice(Engine, Voice);
  LeaveEngine(Engine, Entered);
end;

{ Takes away the sends to Voice and the changes waiting for it, as it
  goes. Engine locked. }
procedure ForgetVoice(Engine: PAudioEngine; Voice: PAudioVoice);
var
  Other: PAudioVoice;
  Index: Integer;
  Kept: Integer;
begin
  Other := Engine^.Voices;
  while Other <> nil do
  begin
    Kept := 0;
    for Index := 0 to Other^.SendCount - 1 do
      if Other^.Sends[Index].Destination <> Voice then
      begin
        if Kept <> Index then
          Other^.Sends[Kept] := Other^.Sends[Index];
        Inc(Kept);
      end;
    Other^.SendCount := Kept;
    Other := Other^.Next;
  end;
  Kept := 0;
  for Index := 0 to Engine^.PendingCount - 1 do
    if (Engine^.Pending[Index].Voice <> Voice) and (Engine^.Pending[Index].Destination <> Voice) then
    begin
      if Kept <> Index then
        Engine^.Pending[Kept] := Engine^.Pending[Index];
      Inc(Kept);
    end;
  Engine^.PendingCount := Kept;
end;

procedure DestroyVoice(Voice: PAudioVoice);
var
  Engine: PAudioEngine;
  Entered: Boolean;
  Link: ^PAudioVoice;
begin
  if Voice = nil then
    Exit;
  Engine := EngineOf(Voice);
  Entered := EnterEngine(Engine);
  Link := @Engine^.Voices;
  while (Link^ <> nil) and (Link^ <> Voice) do
    Link := @Link^^.Next;
  if Link^ = Voice then
    Link^ := Voice^.Next;
  ForgetVoice(Engine, Voice);
  if Engine^.Master = Voice then
    Engine^.Master := nil;
  ClearEffectChain(Voice^.Effects);
  FreeMemory(Voice^.Samples);
  FreeMemory(Voice^.Input);
  FreeMemory(Voice);
  LeaveEngine(Engine, Entered);
end;

function SetOutputVoices(Voice: PAudioVoice; const Destinations: array of PAudioVoice): LongInt;
var
  Entered: Boolean;
begin
  if Voice^.Kind = VoiceMastering then
    Exit(EngineErrorInvalidCall);
  Entered := EnterEngine(EngineOf(Voice));
  Result := SetSendsLocked(Voice, Destinations);
  LeaveEngine(EngineOf(Voice), Entered);
end;

{ --- Buffers and state ------------------------------------------------------ }

function SubmitSourceBuffer(Voice: PAudioVoice; const Buffer: TAudioBuffer): LongInt;
var
  Entered: Boolean;
begin
  if (Voice^.Kind <> VoiceSource) or (Buffer.Data = nil) or (Buffer.ByteCount < Voice^.BytesPerFrame) then
    Exit(EngineErrorInvalidCall);
  Entered := EnterEngine(EngineOf(Voice));
  if QueueBuffer(Voice, Buffer) then
    Result := 0
  else
    Result := EngineErrorInvalidCall;
  LeaveEngine(EngineOf(Voice), Entered);
end;

procedure FlushSourceBuffers(Voice: PAudioVoice);
var
  Entered: Boolean;
begin
  Entered := EnterEngine(EngineOf(Voice));
  FlushBuffers(Voice);
  LeaveEngine(EngineOf(Voice), Entered);
end;

procedure Discontinuity(Voice: PAudioVoice);
var
  Entered: Boolean;
begin
  Entered := EnterEngine(EngineOf(Voice));
  if Voice^.QueueCount > 0 then
    with Voice^.Queue[(Voice^.QueueHead + Voice^.QueueCount - 1) mod MaximumQueuedBuffers].Buffer do
      Flags := Flags or BufferEndOfStream;
  LeaveEngine(EngineOf(Voice), Entered);
end;

procedure GetVoiceState(Voice: PAudioVoice; out State: TVoiceState);
var
  Entered: Boolean;
begin
  Entered := EnterEngine(EngineOf(Voice));
  State.BuffersQueued := Voice^.QueueCount;
  State.SamplesPlayed := Voice^.SamplesPlayed;
  State.CurrentBufferContext := nil;
  if Voice^.QueueCount > 0 then
    State.CurrentBufferContext := Voice^.Queue[Voice^.QueueHead].Buffer.Context;
  LeaveEngine(EngineOf(Voice), Entered);
end;

{ --- Changes, now or in operation sets -------------------------------------- }

function SendTo(Voice, Destination: PAudioVoice): Integer;
begin
  for Result := 0 to Voice^.SendCount - 1 do
    if (Destination = nil) or (Voice^.Sends[Result].Destination = Destination) then
      Exit;
  Result := -1;
end;

{ Carries out an operation. Engine locked. }
procedure ApplyOperation(const Operation: TPendingOperation);
var
  Voice: PAudioVoice;
  Send: Integer;
  Index: Integer;
begin
  Voice := Operation.Voice;
  case Operation.Kind of
    PendingStart:
      begin
        Voice^.Started := True;
        Voice^.TailLeft := 0;
      end;
    PendingStop:
      begin
        Voice^.Started := False;
        if (Operation.Flags and StopPlayTails) <> 0 then
          Voice^.TailLeft := EffectChainTail(Voice^.Effects, EngineOf(Voice)^.Rate)
        else
          Voice^.TailLeft := 0;
      end;
    PendingFrequencyRatio:
      begin
        Voice^.FrequencyRatio := Operation.Values[0];
        if Voice^.FrequencyRatio > Voice^.MaximumFrequencyRatio then
          Voice^.FrequencyRatio := Voice^.MaximumFrequencyRatio;
        if Voice^.FrequencyRatio < 1 / 1024 then
          Voice^.FrequencyRatio := 1 / 1024;
      end;
    PendingVolume:
      Voice^.Volume := Operation.Values[0];
    PendingChannelVolumes:
      for Index := 0 to Operation.ValueCount - 1 do
        Voice^.ChannelVolumes[Index] := Operation.Values[Index];
    PendingOutputMatrix:
      begin
        Send := SendTo(Voice, Operation.Destination);
        if Send >= 0 then
          Move(Operation.Values[0], Voice^.Sends[Send].Matrix[0], Operation.ValueCount * SizeOf(Single));
      end;
    PendingFilter:
      Voice^.Filter := Operation.Filter;
    PendingOutputFilter:
      begin
        Send := SendTo(Voice, Operation.Destination);
        if Send >= 0 then
        begin
          Voice^.Sends[Send].Filter := Operation.Filter;
          Voice^.Sends[Send].UseFilter := not FilterIsTransparent(Operation.Filter);
        end;
      end;
    PendingExitLoop:
      Voice^.ExitLoopRequested := True;
    PendingEnableEffect, PendingDisableEffect:
      if (Operation.Index >= 0) and (Operation.Index < Voice^.Effects.Count) then
        Voice^.Effects.Slots[Operation.Index].Enabled := Operation.Kind = PendingEnableEffect;
    PendingEffectParameters:
      if (Operation.Index >= 0) and (Operation.Index < Voice^.Effects.Count) then
        with Voice^.Effects.Slots[Operation.Index] do
          if Assigned(Effect^.SetParameters) then
            Effect^.SetParameters(Effect, @Operation.Parameters[0], Operation.ParameterSize);
  end;
end;

{ Applies Operation now, or keeps it for its operation set. }
procedure Submit(Voice: PAudioVoice; var Operation: TPendingOperation);
var
  Engine: PAudioEngine;
  Entered: Boolean;
begin
  Engine := EngineOf(Voice);
  Operation.Voice := Voice;
  Entered := EnterEngine(Engine);
  if Operation.OperationSet = CommitNow then
    ApplyOperation(Operation)
  else if Engine^.PendingCount < MaximumPendingOperations then
  begin
    Engine^.Pending[Engine^.PendingCount] := Operation;
    Inc(Engine^.PendingCount);
  end;
  LeaveEngine(Engine, Entered);
end;

procedure NewOperation(out Operation: TPendingOperation; Kind: TPendingKind; OperationSet: LongWord);
begin
  FillChar(Operation, SizeOf(Operation), 0);
  Operation.Kind := Kind;
  Operation.OperationSet := OperationSet;
end;

function CommitChanges(Engine: PAudioEngine; OperationSet: LongWord): LongInt;
var
  Entered: Boolean;
  Index: Integer;
  Kept: Integer;
begin
  Entered := EnterEngine(Engine);
  Kept := 0;
  for Index := 0 to Engine^.PendingCount - 1 do
    if Engine^.Pending[Index].OperationSet = OperationSet then
      ApplyOperation(Engine^.Pending[Index])
    else
    begin
      Engine^.Pending[Kept] := Engine^.Pending[Index];
      Inc(Kept);
    end;
  Engine^.PendingCount := Kept;
  LeaveEngine(Engine, Entered);
  Result := 0;
end;

procedure ExitLoop(Voice: PAudioVoice; OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  NewOperation(Operation, PendingExitLoop, OperationSet);
  Submit(Voice, Operation);
end;

procedure StartVoice(Voice: PAudioVoice; OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  NewOperation(Operation, PendingStart, OperationSet);
  Submit(Voice, Operation);
end;

procedure StopVoice(Voice: PAudioVoice; Flags, OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  NewOperation(Operation, PendingStop, OperationSet);
  Operation.Flags := Flags;
  Submit(Voice, Operation);
end;

procedure SetFrequencyRatio(Voice: PAudioVoice; Ratio: Single; OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  NewOperation(Operation, PendingFrequencyRatio, OperationSet);
  Operation.Values[0] := Ratio;
  Submit(Voice, Operation);
end;

function GetFrequencyRatio(Voice: PAudioVoice): Single;
begin
  Result := Voice^.FrequencyRatio;
end;

procedure SetVolume(Voice: PAudioVoice; Volume: Single; OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  NewOperation(Operation, PendingVolume, OperationSet);
  Operation.Values[0] := Volume;
  Submit(Voice, Operation);
end;

function GetVolume(Voice: PAudioVoice): Single;
begin
  Result := Voice^.Volume;
end;

procedure SetChannelVolumes(Voice: PAudioVoice; const Volumes: array of Single; OperationSet: LongWord);
var
  Operation: TPendingOperation;
  Index: Integer;
begin
  NewOperation(Operation, PendingChannelVolumes, OperationSet);
  for Index := 0 to Length(Volumes) - 1 do
    if Index < Integer(Voice^.Channels) then
      Operation.Values[Index] := Volumes[Index];
  Operation.ValueCount := Length(Volumes);
  if Operation.ValueCount > Integer(Voice^.Channels) then
    Operation.ValueCount := Voice^.Channels;
  Submit(Voice, Operation);
end;

procedure GetChannelVolumes(Voice: PAudioVoice; Volumes: PSingle);
begin
  Move(Voice^.ChannelVolumes[0], Volumes^, Voice^.Channels * SizeOf(Single));
end;

procedure SetOutputMatrix(Voice, Destination: PAudioVoice; const Matrix: array of Single; OperationSet: LongWord);
var
  Operation: TPendingOperation;
  Index: Integer;
begin
  NewOperation(Operation, PendingOutputMatrix, OperationSet);
  Operation.Destination := Destination;
  Operation.ValueCount := Length(Matrix);
  if Operation.ValueCount > MaximumVoiceChannels * MaximumVoiceChannels then
    Operation.ValueCount := MaximumVoiceChannels * MaximumVoiceChannels;
  for Index := 0 to Operation.ValueCount - 1 do
    Operation.Values[Index] := Matrix[Index];
  Submit(Voice, Operation);
end;

procedure GetOutputMatrix(Voice, Destination: PAudioVoice; Matrix: PSingle);
var
  Send: Integer;
begin
  Send := SendTo(Voice, Destination);
  if Send >= 0 then
    Move(Voice^.Sends[Send].Matrix[0], Matrix^,
      Voice^.Channels * Voice^.Sends[Send].Destination^.Channels * SizeOf(Single));
end;

procedure SetFilterParameters(Voice: PAudioVoice; const Parameters: TFilterParameters; OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  NewOperation(Operation, PendingFilter, OperationSet);
  Operation.Filter := Parameters;
  Submit(Voice, Operation);
end;

procedure GetFilterParameters(Voice: PAudioVoice; out Parameters: TFilterParameters);
begin
  Parameters := Voice^.Filter;
end;

procedure SetOutputFilterParameters(Voice, Destination: PAudioVoice; const Parameters: TFilterParameters;
  OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  NewOperation(Operation, PendingOutputFilter, OperationSet);
  Operation.Destination := Destination;
  Operation.Filter := Parameters;
  Submit(Voice, Operation);
end;

function SetEffectChain(Voice: PAudioVoice; const Effects: array of PAudioEffect): LongInt;
var
  Entered: Boolean;
  Index: Integer;
begin
  if Length(Effects) > MaximumEffects then
    Exit(EngineErrorInvalidCall);
  Entered := EnterEngine(EngineOf(Voice));
  ClearEffectChain(Voice^.Effects);
  for Index := 0 to Length(Effects) - 1 do
  begin
    Voice^.Effects.Slots[Index].Effect := Effects[Index];
    Voice^.Effects.Slots[Index].Enabled := True;
  end;
  Voice^.Effects.Count := Length(Effects);
  LeaveEngine(EngineOf(Voice), Entered);
  Result := 0;
end;

procedure EnableEffect(Voice: PAudioVoice; Index: Integer; OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  NewOperation(Operation, PendingEnableEffect, OperationSet);
  Operation.Index := Index;
  Submit(Voice, Operation);
end;

procedure DisableEffect(Voice: PAudioVoice; Index: Integer; OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  NewOperation(Operation, PendingDisableEffect, OperationSet);
  Operation.Index := Index;
  Submit(Voice, Operation);
end;

procedure SetEffectParameters(Voice: PAudioVoice; Index: Integer; Parameters: Pointer; Size: LongWord;
  OperationSet: LongWord);
var
  Operation: TPendingOperation;
begin
  if Size > MaximumParameterBytes then
    Exit;
  NewOperation(Operation, PendingEffectParameters, OperationSet);
  Operation.Index := Index;
  Move(Parameters^, Operation.Parameters[0], Size);
  Operation.ParameterSize := Size;
  Submit(Voice, Operation);
end;

procedure GetEffectParameters(Voice: PAudioVoice; Index: Integer; Parameters: Pointer; Size: LongWord);
var
  Entered: Boolean;
begin
  Entered := EnterEngine(EngineOf(Voice));
  if (Index >= 0) and (Index < Voice^.Effects.Count) then
    with Voice^.Effects.Slots[Index] do
      if Assigned(Effect^.GetParameters) then
        Effect^.GetParameters(Effect, Parameters, Size);
  LeaveEngine(EngineOf(Voice), Entered);
end;

{ --- Processing ----------------------------------------------------------------- }

{ Adds Samples (Channels per frame), through Matrix, into Destination's
  input. }
procedure MixInto(Samples: PSingle; Frames, Channels: LongWord; Matrix: PSingle; Destination: PAudioVoice);
var
  Frame: LongWord;
  Channel: LongWord;
  Out: LongWord;
  Sum: Single;
  Width: LongWord;
begin
  Width := Destination^.Channels;
  for Frame := 0 to Frames - 1 do
    for Out := 0 to Width - 1 do
    begin
      Sum := 0;
      for Channel := 0 to Channels - 1 do
        Sum := Sum + Samples[Frame * Channels + Channel] * Matrix[Channel * Width + Out];
      Destination^.Input[Frame * Width + Out] := Destination^.Input[Frame * Width + Out] + Sum;
    end;
end;

{ Filter, volumes and effects of a voice's Samples; then its sends,
  each through its own filter if it has one. }
procedure FinishVoice(Engine: PAudioEngine; Voice: PAudioVoice);
var
  Frames: LongWord;
  Channels: LongWord;
  Channel: LongWord;
  Frame: LongWord;
  Gain: Single;
  Index: Integer;
  Sent: PSingle;
begin
  Frames := Engine^.QuantumFrames;
  Channels := Voice^.Channels;
  if not FilterIsTransparent(Voice^.Filter) then
    for Channel := 0 to Channels - 1 do
      ApplyFilter(Voice^.Filter, Voice^.FilterStates[Channel], Voice^.Samples + Channel, Frames, Channels);
  for Channel := 0 to Channels - 1 do
  begin
    Gain := Voice^.Volume * Voice^.ChannelVolumes[Channel];
    if Gain <> 1 then
      for Frame := 0 to Frames - 1 do
        Voice^.Samples[Frame * Channels + Channel] := Voice^.Samples[Frame * Channels + Channel] * Gain;
  end;
  ProcessEffectChain(Voice^.Effects, Voice^.Samples, Frames, Channels, Engine^.Rate);
  if Voice^.Kind = VoiceMastering then
    Exit;
  for Index := 0 to Voice^.SendCount - 1 do
    with Voice^.Sends[Index] do
    begin
      Sent := Voice^.Samples;
      if UseFilter then
      begin
        Move(Voice^.Samples^, Engine^.Scratch^, Frames * Channels * SizeOf(Single));
        for Channel := 0 to Channels - 1 do
          ApplyFilter(Filter, FilterStates[Channel], Engine^.Scratch + Channel, Frames, Channels);
        Sent := Engine^.Scratch;
      end;
      MixInto(Sent, Frames, Channels, @Matrix[0], Destination);
    end;
end;

procedure ProcessPass(Engine: PAudioEngine);
var
  Voice: PAudioVoice;
  Frames: LongWord;
  Stage: LongWord;
  NextStage: LongWord;
  Callbacks: ^TVoiceCallbacks;
  Active: LongWord;
begin
  Frames := Engine^.QuantumFrames;
  Active := 0;
  { Source voices. }
  Voice := Engine^.Voices;
  while Voice <> nil do
  begin
    if (Voice^.Kind = VoiceSource) and (Voice^.Started or (Voice^.TailLeft > 0)) then
    begin
      Callbacks := @Voice^.Callbacks;
      if Voice^.Started and Assigned(Callbacks^.OnPassStart) then
        Callbacks^.OnPassStart(Callbacks^.Context, LongWord(Round(Frames * Voice^.FrequencyRatio *
          Voice^.SourceRate / Engine^.Rate)) * Voice^.BytesPerFrame);
      if Voice^.Started then
      begin
        RenderSource(Voice, Frames, Engine^.Rate);
        Inc(Active);
      end
      else
      begin
        FillChar(Voice^.Samples^, Frames * Voice^.Channels * SizeOf(Single), 0);
        if Voice^.TailLeft > Frames then
          Voice^.TailLeft := Voice^.TailLeft - Frames
        else
          Voice^.TailLeft := 0;
      end;
      FinishVoice(Engine, Voice);
      if Voice^.Started and Assigned(Callbacks^.OnPassEnd) then
        Callbacks^.OnPassEnd(Callbacks^.Context);
    end;
    Voice := Voice^.Next;
  end;
  { Submix voices, stage by stage. }
  Stage := 0;
  repeat
    NextStage := High(LongWord);
    Voice := Engine^.Voices;
    while Voice <> nil do
    begin
      if Voice^.Kind = VoiceSubmix then
      begin
        if Voice^.ProcessingStage = Stage then
        begin
          Move(Voice^.Input^, Voice^.Samples^, Frames * Voice^.Channels * SizeOf(Single));
          FillChar(Voice^.Input^, Frames * Voice^.Channels * SizeOf(Single), 0);
          FinishVoice(Engine, Voice);
        end
        else if (Voice^.ProcessingStage > Stage) and (Voice^.ProcessingStage < NextStage) then
          NextStage := Voice^.ProcessingStage;
      end;
      Voice := Voice^.Next;
    end;
    Stage := NextStage;
  until NextStage = High(LongWord);
  { The mastering voice. }
  Voice := Engine^.Master;
  Move(Voice^.Input^, Voice^.Samples^, Frames * Voice^.Channels * SizeOf(Single));
  FillChar(Voice^.Input^, Frames * Voice^.Channels * SizeOf(Single), 0);
  FinishVoice(Engine, Voice);
  Move(Voice^.Samples^, Engine^.Output^, Frames * Voice^.Channels * SizeOf(Single));
  Engine^.Performance.ActiveSourceVoices := Active;
  Inc(Engine^.Performance.Passes);
  Inc(Engine^.Performance.FramesRendered, Frames);
end;

procedure RenderAudio(Engine: PAudioEngine; Frames: LongWord; Output: PSingle);
var
  Done: LongWord;
  Count: LongWord;
  Channels: LongWord;
begin
  if Engine^.Master = nil then
    Exit;
  Channels := Engine^.Master^.Channels;
  Done := 0;
  AcquireLock(Engine^.Lock);
  Engine^.RenderingThread := GetCurrentThreadId;
  while Done < Frames do
  begin
    ProcessPass(Engine);
    Count := Engine^.QuantumFrames;
    if Count > Frames - Done then
      Count := Frames - Done;
    Move(Engine^.Output^, Output[Done * Channels], Count * Channels * SizeOf(Single));
    Done := Done + Count;
  end;
  Engine^.RenderingThread := 0;
  ReleaseLock(Engine^.Lock);
end;

function EngineThread(Argument: Pointer): LongInt;
var
  Engine: PAudioEngine;
  Bytes: QWord;
begin
  Engine := PAudioEngine(Argument);
  while Engine^.Quitting = 0 do
  begin
    if (Engine^.Running = 0) or (Engine^.Master = nil) then
    begin
      SleepMilliseconds(EngineQuantumMilliseconds);
      Continue;
    end;
    AcquireLock(Engine^.Lock);
    Engine^.RenderingThread := GetCurrentThreadId;
    ProcessPass(Engine);
    Engine^.RenderingThread := 0;
    Bytes := Engine^.QuantumFrames * Engine^.Master^.Channels * SizeOf(Single);
    ReleaseLock(Engine^.Lock);
    { Waits while the device's queue is full: this paces the engine. }
    WriteAudio(Engine^.Device, Engine^.Output, Bytes);
  end;
  Result := 0;
end;

procedure GetPerformanceData(Engine: PAudioEngine; out Data: TEnginePerformance);
var
  Entered: Boolean;
  Voice: PAudioVoice;
  Queued: Int64;
begin
  Entered := EnterEngine(Engine);
  Data := Engine^.Performance;
  Data.TotalVoices := 0;
  Voice := Engine^.Voices;
  while Voice <> nil do
  begin
    Inc(Data.TotalVoices);
    Voice := Voice^.Next;
  end;
  Data.QueuedFrames := 0;
  if (Engine^.Device >= 0) and (Engine^.Master <> nil) then
  begin
    Queued := QueuedAudioBytes(Engine^.Device);
    if Queued > 0 then
      Data.QueuedFrames := LongWord(Queued div (Engine^.Master^.Channels * SizeOf(Single)));
  end;
  LeaveEngine(Engine, Entered);
end;

{ --- The engine ----------------------------------------------------------------- }

function CreateAudioEngine(DevicePath: PChar; Offline: Boolean; out Engine: PAudioEngine): LongInt;
begin
  Engine := PAudioEngine(AllocateMemory(SizeOf(TAudioEngine)));
  if Engine = nil then
    Exit(EngineErrorOutOfMemory);
  FillChar(Engine^, SizeOf(TAudioEngine), 0);
  InitializeLock(Engine^.Lock);
  Engine^.Device := -1;
  Engine^.Thread := -1;
  Result := 0;
  if Offline then
    Exit;
  Engine^.Device := OpenAudioOutput(DevicePath);
  if Engine^.Device < 0 then
  begin
    FreeMemory(Engine);
    Engine := nil;
    Exit(EngineErrorDevice);
  end;
  Engine^.Thread := CreateThread(@EngineThread, Engine);
  if Engine^.Thread < 0 then
    Result := EngineErrorOutOfMemory;
end;

function StartAudioEngine(Engine: PAudioEngine): LongInt;
begin
  if (Engine^.Device < 0) or (Engine^.Master = nil) then
    Exit(EngineErrorInvalidCall);
  AtomicExchange32(Engine^.Running, 1);
  Result := 0;
end;

procedure StopAudioEngine(Engine: PAudioEngine);
begin
  AtomicExchange32(Engine^.Running, 0);
end;

procedure DestroyAudioEngine(Engine: PAudioEngine);
var
  ExitCode: LongInt;
begin
  if Engine = nil then
    Exit;
  if Engine^.Thread >= 0 then
  begin
    AtomicExchange32(Engine^.Quitting, 1);
    WaitForThread(Engine^.Thread, -1, ExitCode);
    CloseThreadHandle(Engine^.Thread);
  end;
  while Engine^.Voices <> nil do
    DestroyVoice(Engine^.Voices);
  if Engine^.Device >= 0 then
  begin
    DrainAudio(Engine^.Device);
    CloseAudioOutput(Engine^.Device);
  end;
  FreeMemory(Engine^.Output);
  FreeMemory(Engine^.Scratch);
  FreeMemory(Engine);
end;

end.
