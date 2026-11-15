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
  Voices of the audio engine (Audio.Engine): what they hold, and how a
  source voice turns its queued buffers into frames at the engine's rate.

  A source voice walks its buffers frame by frame: from a buffer's play
  start, round its loop region as often as it says, to its play end,
  then on to the next buffer, calling the voice's callbacks as buffers
  start and end and loops come round. Frames are decoded from whatever
  sample kind the voice has; the rate is converted (together with the
  frequency ratio, the voice's pitch) by cubic Hermite interpolation
  between the four frames around each output frame.
}
unit Audio.Voices;

{$mode objfpc}
{$pointermath on}

interface

uses
  Audio.Filters,
  Audio.EffectChain;

const
  MaximumVoiceChannels = 8;
  MaximumSends = 8;
  MaximumQueuedBuffers = 64;
  { A buffer's LoopCount for looping until ExitLoop. }
  LoopInfinite = 255;
  { TAudioBuffer.Flags: no buffer follows; OnStreamEnd comes after it. }
  BufferEndOfStream = 1;

type
  TVoiceKind = (VoiceSource, VoiceSubmix, VoiceMastering);

  PAudioVoice = ^TAudioVoice;

  TAudioBuffer = record
    Flags: LongWord;
    Data: Pointer;
    ByteCount: LongWord;
    { The frames played: from PlayBegin, PlayLength of them (0: to the
      end). }
    PlayBegin: LongWord;
    PlayLength: LongWord;
    { The loop region (LoopLength 0: to the play end) and how many
      times playing jumps back to its start (0: none, LoopInfinite:
      until ExitLoop), so it sounds LoopCount + 1 times. }
    LoopBegin: LongWord;
    LoopLength: LongWord;
    LoopCount: LongWord;
    { Handed to the buffer callbacks. }
    Context: Pointer;
  end;

  { Called on the engine's thread while it processes; they may queue
    buffers and change the voice, but must not wait for long. }
  TVoiceCallbacks = record
    Context: Pointer;
    OnPassStart: procedure(Context: Pointer; BytesWanted: LongWord);
    OnPassEnd: procedure(Context: Pointer);
    OnBufferStart: procedure(Context: Pointer; BufferContext: Pointer);
    OnBufferEnd: procedure(Context: Pointer; BufferContext: Pointer);
    OnLoopEnd: procedure(Context: Pointer; BufferContext: Pointer);
    OnStreamEnd: procedure(Context: Pointer);
  end;

  { Where a voice sends its sound: a destination voice, how its channels
    go into the destination's (Matrix[source * destination channels +
    destination channel]), and a filter of its own. }
  TVoiceSend = record
    Destination: PAudioVoice;
    UseFilter: Boolean;
    Matrix: array[0..MaximumVoiceChannels * MaximumVoiceChannels - 1] of Single;
    Filter: TFilterParameters;
    FilterStates: array[0..MaximumVoiceChannels - 1] of TFilterState;
  end;

  TQueuedBuffer = record
    Buffer: TAudioBuffer;
    Started: Boolean;
    Position: LongWord;
    LoopsLeft: LongWord;
    InLoop: Boolean;
  end;

  TAudioVoice = record
    Engine: Pointer;
    Kind: TVoiceKind;
    Channels: LongWord;
    ProcessingStage: LongWord;
    Volume: Single;
    ChannelVolumes: array[0..MaximumVoiceChannels - 1] of Single;
    Filter: TFilterParameters;
    FilterStates: array[0..MaximumVoiceChannels - 1] of TFilterState;
    Sends: array[0..MaximumSends - 1] of TVoiceSend;
    SendCount: Integer;
    Effects: TEffectChain;
    { The voice's samples for the pass, and (submix and mastering) what
      others sent it. }
    Samples: PSingle;
    Input: PSingle;

    { Source voices. }
    SourceRate: LongWord;
    SourceKind: LongWord;
    BytesPerFrame: LongWord;
    Callbacks: TVoiceCallbacks;
    Started: Boolean;
    { Stopped with its tails: effects still sound for TailLeft frames. }
    TailLeft: LongWord;
    FrequencyRatio: Single;
    MaximumFrequencyRatio: Single;
    Queue: array[0..MaximumQueuedBuffers - 1] of TQueuedBuffer;
    QueueHead: Integer;
    QueueCount: Integer;
    ExitLoopRequested: Boolean;
    History: array[0..3, 0..MaximumVoiceChannels - 1] of Single;
    Fraction: Double;
    SamplesPlayed: QWord;
    { Voices are kept in the engine's list. }
    Next: PAudioVoice;
  end;

{ The default matrix from Source to Destination channels: the same
  channels where both have them, mono spread over both sides, stereo
  folded into mono, more channels folded into stereo. }
procedure DefaultMatrix(SourceChannels, DestinationChannels: LongWord; Matrix: PSingle);
{ Renders Frames frames of a source voice into its Samples at Rate
  (zeros once it runs out). Returns False if it had nothing at all. }
function RenderSource(Voice: PAudioVoice; Frames, Rate: LongWord): Boolean;
function QueueBuffer(Voice: PAudioVoice; const Buffer: TAudioBuffer): Boolean;
procedure FlushBuffers(Voice: PAudioVoice);

implementation

uses
  Audio.Formats;

const
  Fold = 0.70710678;

procedure DefaultMatrix(SourceChannels, DestinationChannels: LongWord; Matrix: PSingle);
var
  Source: LongWord;
  Destination: LongWord;
begin
  FillChar(Matrix^, SourceChannels * DestinationChannels * SizeOf(Single), 0);
  if SourceChannels = DestinationChannels then
  begin
    for Source := 0 to SourceChannels - 1 do
      Matrix[Source * DestinationChannels + Source] := 1;
    Exit;
  end;
  if SourceChannels = 1 then
  begin
    for Destination := 0 to DestinationChannels - 1 do
      Matrix[Destination] := Fold;
    Exit;
  end;
  if DestinationChannels = 1 then
  begin
    for Source := 0 to SourceChannels - 1 do
      Matrix[Source] := 1 / SourceChannels;
    Exit;
  end;
  { Into stereo (or more): left channels left, right right, the centre
    on both, the LFE left out. }
  for Source := 0 to SourceChannels - 1 do
    case Source of
      0, 4, 6: Matrix[Source * DestinationChannels + 0] := Fold;
      1, 5, 7: Matrix[Source * DestinationChannels + 1] := Fold;
      2:
        begin
          Matrix[Source * DestinationChannels + 0] := Fold * 0.5;
          Matrix[Source * DestinationChannels + 1] := Fold * 0.5;
        end;
    end;
end;

function QueueBuffer(Voice: PAudioVoice; const Buffer: TAudioBuffer): Boolean;
var
  Slot: Integer;
begin
  Result := Voice^.QueueCount < MaximumQueuedBuffers;
  if not Result then
    Exit;
  Slot := (Voice^.QueueHead + Voice^.QueueCount) mod MaximumQueuedBuffers;
  FillChar(Voice^.Queue[Slot], SizeOf(TQueuedBuffer), 0);
  Voice^.Queue[Slot].Buffer := Buffer;
  Inc(Voice^.QueueCount);
end;

procedure FlushBuffers(Voice: PAudioVoice);
begin
  { The buffer playing now finishes; the others go. }
  if Voice^.QueueCount > 1 then
    Voice^.QueueCount := 1;
  if (Voice^.QueueCount = 1) and not Voice^.Queue[Voice^.QueueHead].Started then
    Voice^.QueueCount := 0;
end;

function FrameCount(Voice: PAudioVoice; const Buffer: TAudioBuffer): LongWord;
begin
  Result := Buffer.ByteCount div Voice^.BytesPerFrame;
end;

{ Takes the next frame from the queue into Frame (0 if there is none,
  returning False). }
function NextFrame(Voice: PAudioVoice; Frame: PSingle): Boolean;
var
  Entry: ^TQueuedBuffer;
  PlayEnd: LongWord;
  LoopEnd: LongWord;
  Limit: LongWord;
  Channel: LongWord;
  SampleBytes: LongWord;
  Source: PByte;
  Callbacks: ^TVoiceCallbacks;
  Ended: TAudioBuffer;
begin
  Callbacks := @Voice^.Callbacks;
  repeat
    if Voice^.QueueCount = 0 then
    begin
      for Channel := 0 to Voice^.Channels - 1 do
        Frame[Channel] := 0;
      Exit(False);
    end;
    Entry := @Voice^.Queue[Voice^.QueueHead];
    PlayEnd := FrameCount(Voice, Entry^.Buffer);
    if (Entry^.Buffer.PlayLength > 0) and (Entry^.Buffer.PlayBegin + Entry^.Buffer.PlayLength < PlayEnd) then
      PlayEnd := Entry^.Buffer.PlayBegin + Entry^.Buffer.PlayLength;
    LoopEnd := PlayEnd;
    if Entry^.Buffer.LoopLength > 0 then
      LoopEnd := Entry^.Buffer.LoopBegin + Entry^.Buffer.LoopLength;
    if not Entry^.Started then
    begin
      Entry^.Started := True;
      Entry^.Position := Entry^.Buffer.PlayBegin;
      Entry^.LoopsLeft := Entry^.Buffer.LoopCount;
      Entry^.InLoop := (Entry^.Buffer.LoopCount > 0) and (LoopEnd > Entry^.Buffer.LoopBegin);
      Voice^.ExitLoopRequested := False;
      if Assigned(Callbacks^.OnBufferStart) then
        Callbacks^.OnBufferStart(Callbacks^.Context, Entry^.Buffer.Context);
    end;
    if Entry^.InLoop and Voice^.ExitLoopRequested then
      Entry^.InLoop := False;
    if Entry^.InLoop then
      Limit := LoopEnd
    else
      Limit := PlayEnd;
    if Entry^.Position >= Limit then
    begin
      if Entry^.InLoop then
      begin
        { Back round the loop (LoopCount times in all), or on through the
          rest of the buffer. }
        if (Entry^.Buffer.LoopCount = LoopInfinite) or (Entry^.LoopsLeft > 0) then
        begin
          if Entry^.Buffer.LoopCount <> LoopInfinite then
            Dec(Entry^.LoopsLeft);
          Entry^.Position := Entry^.Buffer.LoopBegin;
          if Assigned(Callbacks^.OnLoopEnd) then
            Callbacks^.OnLoopEnd(Callbacks^.Context, Entry^.Buffer.Context);
        end
        else
          Entry^.InLoop := False;
        Continue;
      end;
      Ended := Entry^.Buffer;
      Voice^.QueueHead := (Voice^.QueueHead + 1) mod MaximumQueuedBuffers;
      Dec(Voice^.QueueCount);
      if Assigned(Callbacks^.OnBufferEnd) then
        Callbacks^.OnBufferEnd(Callbacks^.Context, Ended.Context);
      if ((Ended.Flags and BufferEndOfStream) <> 0) and Assigned(Callbacks^.OnStreamEnd) then
        Callbacks^.OnStreamEnd(Callbacks^.Context);
      Continue;
    end;
    SampleBytes := BytesPerSample(Voice^.SourceKind);
    Source := PByte(Entry^.Buffer.Data) + QWord(Entry^.Position) * Voice^.BytesPerFrame;
    for Channel := 0 to Voice^.Channels - 1 do
      Frame[Channel] := DecodeSample(Voice^.SourceKind, Source + Channel * SampleBytes);
    Inc(Entry^.Position);
    Inc(Voice^.SamplesPlayed);
    Exit(True);
  until False;
end;

function RenderSource(Voice: PAudioVoice; Frames, Rate: LongWord): Boolean;
var
  Step: Double;
  Frame: LongWord;
  Channel: LongWord;
  T: Single;
  P0, P1, P2, P3: Single;
  A, B, C: Single;
  Row: Integer;
  HadData: Boolean;
begin
  Step := Voice^.SourceRate / Rate * Voice^.FrequencyRatio;
  HadData := False;
  for Frame := 0 to Frames - 1 do
  begin
    { Move the four-frame window on past the frames the output passed. }
    while Voice^.Fraction >= 1 do
    begin
      for Row := 0 to 2 do
        Move(Voice^.History[Row + 1], Voice^.History[Row], Voice^.Channels * SizeOf(Single));
      if NextFrame(Voice, @Voice^.History[3][0]) then
        HadData := True;
      Voice^.Fraction := Voice^.Fraction - 1;
    end;
    T := Voice^.Fraction;
    for Channel := 0 to Voice^.Channels - 1 do
    begin
      { Cubic Hermite between History[1] and History[2]. }
      P0 := Voice^.History[0][Channel];
      P1 := Voice^.History[1][Channel];
      P2 := Voice^.History[2][Channel];
      P3 := Voice^.History[3][Channel];
      C := (P2 - P0) * 0.5;
      B := P0 - 2.5 * P1 + 2 * P2 - 0.5 * P3;
      A := 0.5 * (P3 - P0) + 1.5 * (P1 - P2);
      Voice^.Samples[Frame * Voice^.Channels + Channel] := ((A * T + B) * T + C) * T + P1;
    end;
    Voice^.Fraction := Voice^.Fraction + Step;
  end;
  Result := HadData;
end;

end.
