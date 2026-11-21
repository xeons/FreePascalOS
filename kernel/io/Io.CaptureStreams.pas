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
  Capture streams: what one program records.

  Every open of an audio input is a capture stream with a format of its
  own, as playing streams have (Io.AudioStreams): 8, 16, 24 or 32-bit
  integer or 32-bit float samples, 1 to 8 channels, 8 to 192 kHz. The
  input hands over what it captured (16-bit stereo at its rate) with
  FeedCaptureStream; the stream converts the rate by linear
  interpolation, spreads stereo over its channels (mono is the average;
  with more channels, left and right go to the front pair, their
  average to the centre, and the rest is silent), applies its volume
  and keeps the samples in its queue until the program reads them. If
  the program falls behind and the queue fills up, what does not fit is
  dropped and counted.

  Everything is integer arithmetic: float samples are put together bit
  by bit.
}
unit Io.CaptureStreams;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Kernel.Events;

const
  { A quarter of a second of 96 kHz, 6 channels of float samples (28 ms
    with 64 KiB, which a reader on an emulated AArch64 machine fell
    behind by, dropping samples from its recording). }
  CaptureQueueBytes = 512 * 1024;

type
  PSmallInt = ^SmallInt;

  PCaptureStream = ^TCaptureStream;
  TCaptureStream = record
    Rate: LongWord;
    Channels: LongWord;
    Kind: LongWord;
    BytesPerFrame: LongWord;
    Volume: LongWord;
    VolumeFactor: LongWord;
    Lock: TSpinLock;
    Queue: PByte;
    Head: LongWord;
    Count: LongWord;
    { Signalled when samples arrive. }
    DataArrived: TEvent;
    { Rate conversion: the last two input frames, and how far past the
      older one the next output frame lies, in 1/2^32 of a frame. }
    Previous: array[0..1] of LongInt;
    Current: array[0..1] of LongInt;
    Position: QWord;
    Step: QWord;
    InputRate: LongWord;
    FramesDropped: QWord;
    Next: PCaptureStream;
  end;

{ A stream (16-bit stereo at InputRate), or nil if memory is short. }
function CreateCaptureStream(InputRate: LongWord): PCaptureStream;
procedure DestroyCaptureStream(Stream: PCaptureStream);
{ False if the format is not one streams take. Empties the queue. }
function SetCaptureFormat(Stream: PCaptureStream; Rate, Channels, Kind: LongWord): Boolean;
procedure SetCaptureVolume(Stream: PCaptureStream; Percent: LongWord);
{ Adds Frames frames of 16-bit stereo, as captured. }
procedure FeedCaptureStream(Stream: PCaptureStream; Samples: PSmallInt; Frames: LongWord);
{ Moves up to ByteCount bytes (whole frames) out of the queue into
  Destination; returns how many. }
function TakeCapturedData(Stream: PCaptureStream; Destination: PByte; ByteCount: QWord): QWord;
function CapturedBytes(Stream: PCaptureStream): LongWord;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.PriorityLevel,
  Memory.KernelHeap,
  Io.AudioStreams;

function CreateCaptureStream(InputRate: LongWord): PCaptureStream;
begin
  Result := PCaptureStream(AllocateZeroedKernelMemory(SizeOf(TCaptureStream)));
  if Result = nil then
    Exit;
  Result^.Queue := PByte(AllocateKernelMemory(CaptureQueueBytes));
  if Result^.Queue = nil then
  begin
    FreeKernelMemory(Result);
    Exit(nil);
  end;
  Result^.InputRate := InputRate;
  InitializeSpinLock(Result^.Lock);
  InitializeEvent(Result^.DataArrived, EventKindNotification, False);
  SetCaptureVolume(Result, 100);
  SetCaptureFormat(Result, InputRate, 2, AudioSampleSigned16);
end;

procedure DestroyCaptureStream(Stream: PCaptureStream);
begin
  FreeKernelMemory(Stream^.Queue);
  FreeKernelMemory(Stream);
end;

function SetCaptureFormat(Stream: PCaptureStream; Rate, Channels, Kind: LongWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  Result := (Rate >= MinimumAudioRate) and (Rate <= MaximumAudioRate) and (Channels >= 1) and
    (Channels <= MaximumAudioChannels) and (Kind >= AudioSampleUnsigned8) and (Kind <= AudioSampleFloat32);
  if not Result then
    Exit;
  PreviousLevel := AcquireSpinLock(Stream^.Lock);
  Stream^.Rate := Rate;
  Stream^.Channels := Channels;
  Stream^.Kind := Kind;
  Stream^.BytesPerFrame := Channels * BytesPerSample(Kind);
  { Input frames for each output frame. }
  Stream^.Step := (QWord(Stream^.InputRate) shl 32) div Rate;
  Stream^.Position := 0;
  Stream^.Head := 0;
  Stream^.Count := 0;
  ReleaseSpinLock(Stream^.Lock, PreviousLevel);
end;

procedure SetCaptureVolume(Stream: PCaptureStream; Percent: LongWord);
begin
  Stream^.Volume := Percent;
  Stream^.VolumeFactor := Percent * 65536 div 100;
end;

function CapturedBytes(Stream: PCaptureStream): LongWord;
begin
  Result := Stream^.Count;
end;

{ --- Encoding samples -------------------------------------------------------- }

{ The number of the highest bit set in Value (not 0), by halving: the
  mixer converts every sample of every recording, and a bit by bit
  search cost an emulated AArch64 machine whole periods. }
function HighestSetBit(Value: QWord): Integer;
var
  Width: Integer;
begin
  Result := 0;
  Width := 32;
  while Width > 0 do
  begin
    if (Value shr Width) <> 0 then
    begin
      Value := Value shr Width;
      Result := Result + Width;
    end;
    Width := Width div 2;
  end;
end;

{ The IEEE single for Value / 2^31. }
function SampleToFloatBits(Value: LongInt): LongWord;
var
  Magnitude: QWord;
  Sign: LongWord;
  Highest: Integer;
  Mantissa: QWord;
begin
  if Value = 0 then
    Exit(0);
  Sign := 0;
  Magnitude := QWord(Int64(Value));
  if Value < 0 then
  begin
    Sign := LongWord($80000000);
    Magnitude := QWord(-Int64(Value));
  end;
  Highest := HighestSetBit(Magnitude);
  { The leading bit is implied; 23 bits follow it. }
  if Highest >= 23 then
    Mantissa := Magnitude shr (Highest - 23)
  else
    Mantissa := Magnitude shl (23 - Highest);
  Result := Sign or (LongWord(127 + Highest - 31) shl 23) or (LongWord(Mantissa) and $7FFFFF);
end;

{ Writes Value (full scale is 2^31) as a sample of Kind. }
procedure EncodeSample(Kind: LongWord; Value: LongInt; Destination: PByte);
var
  Bits: LongWord;
begin
  case Kind of
    AudioSampleUnsigned8:
      Destination[0] := Byte((Value shr 24) + 128);
    AudioSampleSigned16:
      begin
        Destination[0] := Byte(Value shr 16);
        Destination[1] := Byte(Value shr 24);
      end;
    AudioSampleSigned24:
      begin
        Destination[0] := Byte(Value shr 8);
        Destination[1] := Byte(Value shr 16);
        Destination[2] := Byte(Value shr 24);
      end;
    AudioSampleSigned32:
      PLongInt(Destination)^ := Value;
  else
    begin
      Bits := SampleToFloatBits(Value);
      PLongWord(Destination)^ := Bits;
    end;
  end;
end;

{ --- Feeding and taking ------------------------------------------------------------ }

{ Puts one output frame (stereo, full scale 2^31) in the queue, spread
  over the stream's channels. Lock held. }
procedure QueueFrame(Stream: PCaptureStream; Left, Right: LongInt);
var
  Frame: array[0..MaximumAudioChannels * 4 - 1] of Byte;
  Channel: LongWord;
  Value: LongInt;
  SampleBytes: LongWord;
  Tail: LongWord;
  Index: LongWord;
begin
  if Stream^.Count + Stream^.BytesPerFrame > CaptureQueueBytes then
  begin
    Inc(Stream^.FramesDropped);
    Exit;
  end;
  SampleBytes := BytesPerSample(Stream^.Kind);
  for Channel := 0 to Stream^.Channels - 1 do
  begin
    if Stream^.Channels = 1 then
      Value := LongInt((Int64(Left) + Right) div 2)
    else
      case Channel of
        0: Value := Left;
        1: Value := Right;
        2: Value := LongInt((Int64(Left) + Right) div 2);
      else
        Value := 0;
      end;
    EncodeSample(Stream^.Kind, Value, @Frame[Channel * SampleBytes]);
  end;
  Tail := (Stream^.Head + Stream^.Count) mod CaptureQueueBytes;
  if Tail + Stream^.BytesPerFrame <= CaptureQueueBytes then
    Move(Frame[0], Stream^.Queue[Tail], Stream^.BytesPerFrame)
  else
    for Index := 0 to Stream^.BytesPerFrame - 1 do
      Stream^.Queue[(Tail + Index) mod CaptureQueueBytes] := Frame[Index];
  Stream^.Count := Stream^.Count + Stream^.BytesPerFrame;
end;

function Interpolate(Older, Newer: LongInt; Position: QWord): LongInt;
begin
  { Position is under 2^32: the weight is its top 16 bits. }
  Result := LongInt(Older + ((Int64(Newer) - Older) * Int64(Position shr 16)) div 65536);
end;

procedure FeedCaptureStream(Stream: PCaptureStream; Samples: PSmallInt; Frames: LongWord);
var
  PreviousLevel: TPriorityLevel;
  Frame: LongWord;
  Channel: Integer;
  Value: Int64;
begin
  PreviousLevel := AcquireSpinLock(Stream^.Lock);
  for Frame := 0 to Frames - 1 do
  begin
    Stream^.Previous := Stream^.Current;
    for Channel := 0 to 1 do
    begin
      { Full scale 2^31, with the volume, clipped. }
      Value := (Int64(Samples[Frame * 2 + LongWord(Channel)]) * 65536 * Stream^.VolumeFactor) div 65536;
      if Value > High(LongInt) then
        Value := High(LongInt);
      if Value < Low(LongInt) then
        Value := Low(LongInt);
      Stream^.Current[Channel] := LongInt(Value);
    end;
    { The output frames between the previous input frame and this one. }
    while Stream^.Position < (QWord(1) shl 32) do
    begin
      QueueFrame(Stream, Interpolate(Stream^.Previous[0], Stream^.Current[0], Stream^.Position),
        Interpolate(Stream^.Previous[1], Stream^.Current[1], Stream^.Position));
      Stream^.Position := Stream^.Position + Stream^.Step;
    end;
    Stream^.Position := Stream^.Position - (QWord(1) shl 32);
  end;
  ReleaseSpinLock(Stream^.Lock, PreviousLevel);
  SignalEvent(Stream^.DataArrived);
end;

function TakeCapturedData(Stream: PCaptureStream; Destination: PByte; ByteCount: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
  First: QWord;
begin
  PreviousLevel := AcquireSpinLock(Stream^.Lock);
  Result := ByteCount;
  if Result > Stream^.Count then
    Result := Stream^.Count;
  Result := Result - Result mod Stream^.BytesPerFrame;
  if Result > 0 then
  begin
    First := CaptureQueueBytes - Stream^.Head;
    if First > Result then
      First := Result;
    CopyMemory(Destination, Stream^.Queue + Stream^.Head, First);
    CopyMemory(Destination + First, Stream^.Queue, Result - First);
    Stream^.Head := (Stream^.Head + LongWord(Result)) mod CaptureQueueBytes;
    Stream^.Count := Stream^.Count - LongWord(Result);
  end;
  ReleaseSpinLock(Stream^.Lock, PreviousLevel);
end;

end.
