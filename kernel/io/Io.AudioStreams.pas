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
  Audio streams: what one program plays, before it is mixed.

  Every open of an audio output is a stream with a format of its own:
  8, 16, 24 or 32-bit integer or 32-bit float samples, 1 to 8 channels
  (in the WAVE order: front left, front right, centre, LFE, back left,
  back right, side left, side right) at any rate from 8 to 192 kHz.
  What the program writes waits in the stream's queue; the mixer takes
  it out frame by frame (MixStream), turning each frame into stereo
  32-bit samples (other channel counts are folded into left and right,
  the LFE left out), converting the rate by linear interpolation between
  neighbouring frames, and applying the stream's volume.

  Everything is integer arithmetic: the kernel does not use the floating
  point unit, so float samples are converted from their bits.
}
unit Io.AudioStreams;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Kernel.Events;

const
  AudioStreamQueueBytes = 65536;
  MinimumAudioRate = 8000;
  MaximumAudioRate = 192000;
  MaximumAudioChannels = 8;

type
  PAudioStream = ^TAudioStream;
  TAudioStream = record
    Rate: LongWord;
    Channels: LongWord;
    Kind: LongWord;
    BytesPerFrame: LongWord;
    { 0-100, and as a factor out of 65536. }
    Volume: LongWord;
    VolumeFactor: LongWord;
    { The queue: Count bytes from Head. }
    Lock: TSpinLock;
    Queue: PByte;
    Head: LongWord;
    Count: LongWord;
    SpaceFreed: TEvent;
    { Rate conversion: the two source frames being interpolated between
      (stereo), and how far between them the next output frame lies, in
      1/2^32 of a source frame. }
    Previous: array[0..1] of LongInt;
    Current: array[0..1] of LongInt;
    Fraction: QWord;
    Step: QWord;
    HasCurrent: Boolean;
    { Frames taken from the queue, and the hardware period (of the
      output's count) holding the last real sample mixed. }
    FramesTaken: QWord;
    LastSoundPeriod: QWord;
    { Link in the output's list of streams. }
    Next: PAudioStream;
  end;

{ Bytes in one sample of Kind (an AudioSample* kind). }
function BytesPerSample(Kind: LongWord): LongWord;
{ A stream (16-bit stereo at OutputRate), or nil if memory is short. }
function CreateAudioStream(OutputRate: LongWord): PAudioStream;
procedure DestroyAudioStream(Stream: PAudioStream);
{ False if the format is not one streams take. Only while nothing is
  queued. }
function SetStreamFormat(Stream: PAudioStream; Rate, Channels, Kind, OutputRate: LongWord): Boolean;
procedure SetStreamVolume(Stream: PAudioStream; Percent: LongWord);
{ Copies whole frames of Source into the queue as far as there is room;
  returns the bytes taken. }
function QueueStreamData(Stream: PAudioStream; Source: PByte; ByteCount: QWord): QWord;
{ Adds Frames output frames of the stream to Mix (stereo, 64-bit sums);
  returns True if the stream had sound for them (rather than running
  dry). }
function MixStream(Stream: PAudioStream; Mix: PInt64; Frames: LongWord): Boolean;
function StreamQueuedBytes(Stream: PAudioStream): LongWord;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.PriorityLevel,
  Memory.KernelHeap;

type
  PSmallInt = ^SmallInt;

const
  { 1/sqrt(2) out of 65536, for centre and surround channels folded into
    left and right. }
  Fold = 46341;

  RoleLeft = 0;
  RoleRight = 1;
  RoleCentre = 2;
  RoleNone = 3;

type
  TChannelRoles = array[0..MaximumAudioChannels - 1] of Byte;

const
  { Where each channel goes, by channel count. }
  Roles: array[1..MaximumAudioChannels] of TChannelRoles = (
    (RoleCentre, 0, 0, 0, 0, 0, 0, 0),
    (RoleLeft, RoleRight, 0, 0, 0, 0, 0, 0),
    (RoleLeft, RoleRight, RoleCentre, 0, 0, 0, 0, 0),
    (RoleLeft, RoleRight, RoleLeft, RoleRight, 0, 0, 0, 0),
    (RoleLeft, RoleRight, RoleCentre, RoleLeft, RoleRight, 0, 0, 0),
    (RoleLeft, RoleRight, RoleCentre, RoleNone, RoleLeft, RoleRight, 0, 0),
    (RoleLeft, RoleRight, RoleCentre, RoleNone, RoleLeft, RoleRight, RoleCentre, 0),
    (RoleLeft, RoleRight, RoleCentre, RoleNone, RoleLeft, RoleRight, RoleLeft, RoleRight));

function BytesPerSample(Kind: LongWord): LongWord;
begin
  case Kind of
    AudioSampleUnsigned8: Result := 1;
    AudioSampleSigned16: Result := 2;
    AudioSampleSigned24: Result := 3;
  else
    Result := 4;
  end;
end;

function CreateAudioStream(OutputRate: LongWord): PAudioStream;
begin
  Result := PAudioStream(AllocateZeroedKernelMemory(SizeOf(TAudioStream)));
  if Result = nil then
    Exit;
  Result^.Queue := PByte(AllocateKernelMemory(AudioStreamQueueBytes));
  if Result^.Queue = nil then
  begin
    FreeKernelMemory(Result);
    Exit(nil);
  end;
  InitializeSpinLock(Result^.Lock);
  InitializeEvent(Result^.SpaceFreed, EventKindNotification, False);
  SetStreamVolume(Result, 100);
  SetStreamFormat(Result, OutputRate, 2, AudioSampleSigned16, OutputRate);
end;

procedure DestroyAudioStream(Stream: PAudioStream);
begin
  FreeKernelMemory(Stream^.Queue);
  FreeKernelMemory(Stream);
end;

function SetStreamFormat(Stream: PAudioStream; Rate, Channels, Kind, OutputRate: LongWord): Boolean;
begin
  Result := (Rate >= MinimumAudioRate) and (Rate <= MaximumAudioRate) and (Channels >= 1) and
    (Channels <= MaximumAudioChannels) and (Kind >= AudioSampleUnsigned8) and (Kind <= AudioSampleFloat32);
  if not Result then
    Exit;
  Stream^.Rate := Rate;
  Stream^.Channels := Channels;
  Stream^.Kind := Kind;
  Stream^.BytesPerFrame := Channels * BytesPerSample(Kind);
  Stream^.Step := (QWord(Rate) shl 32) div OutputRate;
  Stream^.Fraction := 0;
  Stream^.HasCurrent := False;
end;

procedure SetStreamVolume(Stream: PAudioStream; Percent: LongWord);
begin
  Stream^.Volume := Percent;
  Stream^.VolumeFactor := Percent * 65536 div 100;
end;

function StreamQueuedBytes(Stream: PAudioStream): LongWord;
begin
  Result := Stream^.Count;
end;

function QueueStreamData(Stream: PAudioStream; Source: PByte; ByteCount: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
  Room: QWord;
  Tail: LongWord;
  First: QWord;
begin
  PreviousLevel := AcquireSpinLock(Stream^.Lock);
  Room := AudioStreamQueueBytes - Stream^.Count;
  Result := ByteCount;
  if Result > Room then
    Result := Room;
  Result := Result - Result mod Stream^.BytesPerFrame;
  if Result > 0 then
  begin
    Tail := (Stream^.Head + Stream^.Count) mod AudioStreamQueueBytes;
    First := AudioStreamQueueBytes - Tail;
    if First > Result then
      First := Result;
    CopyMemory(Stream^.Queue + Tail, Source, First);
    CopyMemory(Stream^.Queue, Source + First, Result - First);
    Stream^.Count := Stream^.Count + LongWord(Result);
  end;
  ReleaseSpinLock(Stream^.Lock, PreviousLevel);
end;

{ --- Decoding samples ------------------------------------------------------- }

{ An IEEE single as a 32-bit sample (1.0 is full scale), from its bits. }
function FloatToSample(Bits: LongWord): LongInt;
var
  Exponent: LongInt;
  Mantissa: QWord;
  Shift: LongInt;
  Magnitude: QWord;
begin
  Exponent := LongInt((Bits shr 23) and $FF);
  if Exponent = 0 then
    Exit(0);
  Mantissa := (Bits and $7FFFFF) or $800000;
  { Value = Mantissa * 2^(Exponent - 150); full scale is 2^31. }
  Shift := Exponent - 119;
  if Shift >= 8 then
    Magnitude := $7FFFFFFF
  else if Shift >= 0 then
    Magnitude := Mantissa shl Shift
  else if Shift > -32 then
    Magnitude := Mantissa shr (-Shift)
  else
    Magnitude := 0;
  if Magnitude > $7FFFFFFF then
    Magnitude := $7FFFFFFF;
  if (Bits and $80000000) <> 0 then
    Result := -LongInt(Magnitude)
  else
    Result := LongInt(Magnitude);
end;

{ Sample Channel of the frame at Frame, as a 32-bit sample. }
function DecodeSample(Stream: PAudioStream; Frame: PByte): LongInt;
begin
  case Stream^.Kind of
    AudioSampleUnsigned8: Result := (LongInt(Frame[0]) - 128) shl 24;
    AudioSampleSigned16: Result := LongInt(PSmallInt(Frame)^) shl 16;
    AudioSampleSigned24: Result := LongInt((LongWord(Frame[0]) shl 8) or (LongWord(Frame[1]) shl 16) or
      (LongWord(Frame[2]) shl 24));
    AudioSampleSigned32: Result := PLongInt(Frame)^;
  else
    Result := FloatToSample(PLongWord(Frame)^);
  end;
end;

{ Takes the next frame from the queue (wrapping around it), folded into
  stereo. False if the queue is empty. Caller holds the lock. }
function TakeFrame(Stream: PAudioStream; out Left, Right: LongInt): Boolean;
var
  Frame: array[0..MaximumAudioChannels * 4 - 1] of Byte;
  First: LongWord;
  Channel: LongWord;
  SampleSize: LongWord;
  Sample: Int64;
  LeftSum: Int64;
  RightSum: Int64;
begin
  if Stream^.Count < Stream^.BytesPerFrame then
    Exit(False);
  First := AudioStreamQueueBytes - Stream^.Head;
  if First >= Stream^.BytesPerFrame then
    CopyMemory(@Frame[0], Stream^.Queue + Stream^.Head, Stream^.BytesPerFrame)
  else
  begin
    CopyMemory(@Frame[0], Stream^.Queue + Stream^.Head, First);
    CopyMemory(@Frame[First], Stream^.Queue, Stream^.BytesPerFrame - First);
  end;
  Stream^.Head := (Stream^.Head + Stream^.BytesPerFrame) mod AudioStreamQueueBytes;
  Stream^.Count := Stream^.Count - Stream^.BytesPerFrame;
  Inc(Stream^.FramesTaken);

  SampleSize := BytesPerSample(Stream^.Kind);
  LeftSum := 0;
  RightSum := 0;
  for Channel := 0 to Stream^.Channels - 1 do
  begin
    Sample := DecodeSample(Stream, @Frame[Channel * SampleSize]);
    case Roles[Stream^.Channels][Channel] of
      RoleLeft:
        if Stream^.Channels <= 2 then
          LeftSum := LeftSum + Sample
        else
          LeftSum := LeftSum + Sample * Fold div 65536;
      RoleRight:
        if Stream^.Channels <= 2 then
          RightSum := RightSum + Sample
        else
          RightSum := RightSum + Sample * Fold div 65536;
      RoleCentre:
        if Stream^.Channels = 1 then
        begin
          LeftSum := Sample;
          RightSum := Sample;
        end
        else
        begin
          LeftSum := LeftSum + Sample * Fold div 65536 div 2;
          RightSum := RightSum + Sample * Fold div 65536 div 2;
        end;
    end;
  end;
  if LeftSum > High(LongInt) then
    LeftSum := High(LongInt)
  else if LeftSum < Low(LongInt) then
    LeftSum := Low(LongInt);
  if RightSum > High(LongInt) then
    RightSum := High(LongInt)
  else if RightSum < Low(LongInt) then
    RightSum := Low(LongInt);
  Left := LongInt(LeftSum);
  Right := LongInt(RightSum);
  Result := True;
end;

function MixStream(Stream: PAudioStream; Mix: PInt64; Frames: LongWord): Boolean;
var
  PreviousLevel: TPriorityLevel;
  Frame: LongWord;
  Left: LongInt;
  Right: LongInt;
  Weight: Int64;
  Channel: Integer;
  Value: Int64;
begin
  Result := False;
  PreviousLevel := AcquireSpinLock(Stream^.Lock);
  for Frame := 0 to Frames - 1 do
  begin
    if not Stream^.HasCurrent then
    begin
      { Interpolating needs two frames. }
      if Stream^.Count < 2 * Stream^.BytesPerFrame then
        Break;
      TakeFrame(Stream, Stream^.Previous[0], Stream^.Previous[1]);
      TakeFrame(Stream, Stream^.Current[0], Stream^.Current[1]);
      Stream^.Fraction := 0;
      Stream^.HasCurrent := True;
    end;
    { Move on through the source frames the output frame has passed. }
    while Stream^.Fraction >= (QWord(1) shl 32) do
    begin
      if not TakeFrame(Stream, Left, Right) then
        Break;
      Stream^.Previous := Stream^.Current;
      Stream^.Current[0] := Left;
      Stream^.Current[1] := Right;
      Stream^.Fraction := Stream^.Fraction - (QWord(1) shl 32);
    end;
    if Stream^.Fraction >= (QWord(1) shl 32) then
    begin
      { Ran dry: the next data starts afresh. }
      Stream^.HasCurrent := False;
      Break;
    end;
    Weight := Int64(Stream^.Fraction shr 16);
    for Channel := 0 to 1 do
    begin
      Value := Stream^.Previous[Channel] +
        ((Int64(Stream^.Current[Channel]) - Stream^.Previous[Channel]) * Weight) div 65536;
      Mix[Frame * 2 + LongWord(Channel)] := Mix[Frame * 2 + LongWord(Channel)] +
        (Value * Stream^.VolumeFactor) div 65536;
    end;
    Stream^.Fraction := Stream^.Fraction + Stream^.Step;
    Result := True;
  end;
  ReleaseSpinLock(Stream^.Lock, PreviousLevel);
end;

end.
