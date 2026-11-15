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
  Audio output: the part of sound that does not depend on the hardware.

  A sound driver registers each output it has (RegisterAudioOutput) with
  the routines that start and stop playing, report where the hardware is
  in the ring, and set the volume. The output gets a ring of
  AudioPeriodCount pages ("periods") that the hardware plays round and
  round, 16-bit stereo at AudioOutputRate, and a device file: the first
  output is /dev/audio.

  Mixing. Every open of the device is a stream of its own
  (Io.AudioStreams), with its own format and volume, so any number of
  programs play at once. The mixer thread (RunAudioMixer) keeps
  MixAheadPeriods periods ahead of the hardware: for each it adds up
  every stream's next frames (converted to the output's format and
  rate), clips the sum to 16 bits and writes the period. The hardware
  starts when a stream has something to play and stops after a while of
  silence. Each period the hardware finishes (it interrupts, and the
  driver calls AudioPeriodsElapsed) wakes the mixer.

  A write waits while its stream's queue is full; draining (on request,
  and when the file is closed) waits until everything the stream wrote
  has been played. The output's volume (the hardware's) applies to every
  stream; each stream also has its own.
}
unit Io.AudioOutput;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Manager;

const
  AudioPeriodCount = 16;
  AudioPeriodBytes = 4096;
  AudioPeriodFrames = AudioPeriodBytes div 4;
  AudioOutputRate = 48000;

type
  TAudioDriverRoutines = record
    { Starts playing the ring from its beginning. }
    Start: procedure(Context: Pointer);
    Stop: procedure(Context: Pointer);
    { Bytes into the ring the hardware has played. }
    Position: function(Context: Pointer): LongWord;
    { 0-100 percent. }
    SetVolume: procedure(Context: Pointer; Percent: LongWord);
  end;

  PAudioOutput = ^TAudioOutput;
  TAudioOutput = record
    Routines: TAudioDriverRoutines;
    Context: Pointer;
    { The ring's pages, for the driver to describe to the hardware. }
    Periods: array[0..AudioPeriodCount - 1] of PByte;
    PeriodsPhysical: array[0..AudioPeriodCount - 1] of QWord;
    { Private to this unit. }
    Device: PDeviceObject;
    State: Pointer;
  end;

{ Creates an output with its ring and device file (/dev/audio for the
  first, audio1, ... after that). nil if memory is short. }
function RegisterAudioOutput(const Routines: TAudioDriverRoutines; Context: Pointer): PAudioOutput;
{ For the driver, at dispatch level or below: the hardware went on (it
  interrupted). }
procedure AudioPeriodsElapsed(Output: PAudioOutput);
{ The mixer: a system thread runs this; it returns at once if there are
  no outputs, else never. }
procedure RunAudioMixer(Context: Pointer);

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Threads,
  Kernel.Events,
  Kernel.Mutex,
  Io.AudioStreams,
  Debug.Output;

type
  PSmallInt = ^SmallInt;

const
  MaximumOutputs = 4;
  MixAheadPeriods = 4;
  { Silent periods after which the hardware stops. }
  StopAfterSilentPeriods = 24;
  DefaultMasterVolume = 80;
  MixerIntervalMilliseconds = 50;

type
  POutputState = ^TOutputState;
  TOutputState = record
    { The streams; taken by the mixer while it mixes. }
    StreamsLock: TMutex;
    Streams: PAudioStream;
    { Guards Played and IsPlaying against the driver's deferred call. }
    Lock: TSpinLock;
    Played: QWord;      { periods the hardware moved past }
    Mixed: QWord;       { periods written }
    IsPlaying: Boolean;
    SilentPeriods: LongWord;
    PeriodDone: TEvent;
    MasterVolume: LongWord;
    Mix: PInt64;
  end;

var
  AudioDriver: PDriverObject;
  Outputs: array[0..MaximumOutputs - 1] of PAudioOutput;
  OutputCount: Integer;
  MixerWake: TEvent;

function StateOf(Output: PAudioOutput): POutputState;
begin
  Result := POutputState(Output^.State);
end;

{ --- The hardware ring --------------------------------------------------- }

procedure AudioPeriodsElapsed(Output: PAudioOutput);
var
  State: POutputState;
  PreviousLevel: TPriorityLevel;
  Playing: LongWord;
begin
  State := StateOf(Output);
  PreviousLevel := AcquireSpinLock(State^.Lock);
  if State^.IsPlaying then
  begin
    Playing := (Output^.Routines.Position(Output^.Context) div AudioPeriodBytes) mod AudioPeriodCount;
    while (State^.Played mod AudioPeriodCount) <> Playing do
      Inc(State^.Played);
  end;
  ReleaseSpinLock(State^.Lock, PreviousLevel);
  SignalEvent(State^.PeriodDone);
  SignalEvent(MixerWake);
end;

{ Mixes every stream into period Index of the ring. Caller holds the
  streams lock. }
procedure MixPeriod(Output: PAudioOutput; Index: QWord);
var
  State: POutputState;
  Stream: PAudioStream;
  Samples: PSmallInt;
  Position: LongWord;
  Value: Int64;
  HadSound: Boolean;
begin
  State := StateOf(Output);
  FillMemory(State^.Mix, AudioPeriodFrames * 2 * SizeOf(Int64), 0);
  HadSound := False;
  Stream := State^.Streams;
  while Stream <> nil do
  begin
    if MixStream(Stream, State^.Mix, AudioPeriodFrames) then
    begin
      HadSound := True;
      Stream^.LastSoundPeriod := Index;
    end;
    SignalEvent(Stream^.SpaceFreed);
    Stream := Stream^.Next;
  end;
  Samples := PSmallInt(Output^.Periods[Index mod AudioPeriodCount]);
  for Position := 0 to AudioPeriodFrames * 2 - 1 do
  begin
    Value := State^.Mix[Position] div 65536;
    if Value > High(SmallInt) then
      Value := High(SmallInt)
    else if Value < Low(SmallInt) then
      Value := Low(SmallInt);
    Samples[Position] := SmallInt(Value);
  end;
  if HadSound then
    State^.SilentPeriods := 0
  else
    Inc(State^.SilentPeriods);
end;

function AnyStreamHasData(State: POutputState): Boolean;
var
  Stream: PAudioStream;
begin
  Stream := State^.Streams;
  while Stream <> nil do
  begin
    if StreamQueuedBytes(Stream) > 0 then
      Exit(True);
    Stream := Stream^.Next;
  end;
  Result := False;
end;

procedure SetPlaying(State: POutputState; Playing: Boolean);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(State^.Lock);
  State^.IsPlaying := Playing;
  ReleaseSpinLock(State^.Lock, PreviousLevel);
end;

{ Keeps the ring ahead of the hardware; starts and stops it. }
procedure ServiceOutput(Output: PAudioOutput);
var
  State: POutputState;
  Played: QWord;
begin
  State := StateOf(Output);
  AcquireMutex(State^.StreamsLock);
  if not State^.IsPlaying then
  begin
    if AnyStreamHasData(State) then
    begin
      State^.Played := 0;
      State^.Mixed := 0;
      State^.SilentPeriods := 0;
      while State^.Mixed < MixAheadPeriods do
      begin
        MixPeriod(Output, State^.Mixed);
        Inc(State^.Mixed);
      end;
      SetPlaying(State, True);
      Output^.Routines.Start(Output^.Context);
    end;
    ReleaseMutex(State^.StreamsLock);
    Exit;
  end;
  Played := State^.Played;
  { Fell behind: the hardware is past what was mixed. }
  if State^.Mixed <= Played then
    State^.Mixed := Played + 1;
  while State^.Mixed < Played + MixAheadPeriods do
  begin
    MixPeriod(Output, State^.Mixed);
    Inc(State^.Mixed);
  end;
  if (State^.SilentPeriods >= StopAfterSilentPeriods) and not AnyStreamHasData(State) then
  begin
    Output^.Routines.Stop(Output^.Context);
    SetPlaying(State, False);
    SignalEvent(State^.PeriodDone);
  end;
  ReleaseMutex(State^.StreamsLock);
end;

procedure RunAudioMixer(Context: Pointer);
var
  Index: Integer;
begin
  { Outputs register while the system starts, before the mixer runs;
    without any there is nothing to mix. }
  if OutputCount = 0 then
    Exit;
  while True do
  begin
    WaitForEventWithOptions(MixerWake, MixerIntervalMilliseconds, False);
    for Index := 0 to OutputCount - 1 do
      ServiceOutput(Outputs[Index]);
  end;
end;

{ --- Streams ---------------------------------------------------------------- }

{ Waits until everything Stream wrote has been played. }
procedure DrainStream(Output: PAudioOutput; Stream: PAudioStream);
var
  State: POutputState;
begin
  State := StateOf(Output);
  SignalEvent(MixerWake);
  repeat
    ResetEvent(State^.PeriodDone);
    if (StreamQueuedBytes(Stream) = 0) and
       (not State^.IsPlaying or (State^.Played > Stream^.LastSoundPeriod)) then
      Exit;
    if WaitForEventWithOptions(State^.PeriodDone, 1000, True) = WaitAlerted then
      Exit;
  until False;
end;

function StreamOf(var Request: TIoRequest): PAudioStream;
begin
  Result := PAudioStream(Request.OpenFile^.Context);
end;

function OutputOfDevice(Device: PDeviceObject): PAudioOutput;
begin
  Result := PAudioOutput(Device^.Extension);
end;

function OpenAudioDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  State: POutputState;
  Stream: PAudioStream;
begin
  State := StateOf(OutputOfDevice(Device));
  Stream := CreateAudioStream(AudioOutputRate);
  if Stream = nil then
    Exit(ErrorOutOfMemory);
  AcquireMutex(State^.StreamsLock);
  Stream^.Next := State^.Streams;
  State^.Streams := Stream;
  ReleaseMutex(State^.StreamsLock);
  Request.OpenFile^.Context := Stream;
  Result := ErrorNone;
end;

function CloseAudioDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Output: PAudioOutput;
  State: POutputState;
  Stream: PAudioStream;
  Link: ^PAudioStream;
begin
  Output := OutputOfDevice(Device);
  State := StateOf(Output);
  Stream := StreamOf(Request);
  Result := ErrorNone;
  if Stream = nil then
    Exit;
  DrainStream(Output, Stream);
  AcquireMutex(State^.StreamsLock);
  Link := @State^.Streams;
  while (Link^ <> nil) and (Link^ <> Stream) do
    Link := @Link^^.Next;
  if Link^ = Stream then
    Link^ := Stream^.Next;
  ReleaseMutex(State^.StreamsLock);
  DestroyAudioStream(Stream);
  Request.OpenFile^.Context := nil;
end;

function WriteAudioDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Stream: PAudioStream;
  Done: QWord;
  Taken: QWord;
begin
  Stream := StreamOf(Request);
  Done := 0;
  Result := ErrorNone;
  while Done + Stream^.BytesPerFrame <= Request.Length do
  begin
    ResetEvent(Stream^.SpaceFreed);
    Taken := QueueStreamData(Stream, PByte(Request.Buffer) + Done, Request.Length - Done);
    Done := Done + Taken;
    SignalEvent(MixerWake);
    if (Taken = 0) and (WaitForEventWithOptions(Stream^.SpaceFreed, 1000, True) = WaitAlerted) then
    begin
      if Done = 0 then
        Result := ErrorInterrupted;
      Break;
    end;
  end;
  Request.Information := Int64(Done);
end;

function ControlAudioDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Output: PAudioOutput;
  State: POutputState;
  Stream: PAudioStream;
  Argument: QWord;
begin
  Output := OutputOfDevice(Device);
  State := StateOf(Output);
  Stream := StreamOf(Request);
  Argument := Request.ControlArgument;
  Result := ErrorNone;
  case Request.ControlCode of
    ControlAudioGetFormat:
      Request.Information := (Int64(Stream^.Rate) shl 16) or (Int64(Stream^.Channels) shl 8) or Stream^.Kind;
    ControlAudioSetFormat:
      begin
        DrainStream(Output, Stream);
        AcquireMutex(State^.StreamsLock);
        if not SetStreamFormat(Stream, LongWord(Argument shr 16), LongWord((Argument shr 8) and $FF),
          LongWord(Argument and $FF), AudioOutputRate) then
          Result := ErrorInvalidArgument;
        ReleaseMutex(State^.StreamsLock);
      end;
    ControlAudioGetVolume:
      Request.Information := Stream^.Volume;
    ControlAudioSetVolume:
      if Argument > 100 then
        Result := ErrorInvalidArgument
      else
        SetStreamVolume(Stream, LongWord(Argument));
    ControlAudioDrain:
      DrainStream(Output, Stream);
    ControlAudioGetMasterVolume:
      Request.Information := State^.MasterVolume;
    ControlAudioSetMasterVolume:
      if Argument > 100 then
        Result := ErrorInvalidArgument
      else
      begin
        State^.MasterVolume := LongWord(Argument);
        Output^.Routines.SetVolume(Output^.Context, State^.MasterVolume);
      end;
    ControlAudioGetQueued:
      Request.Information := StreamQueuedBytes(Stream);
    ControlAudioGetPosition:
      Request.Information := Int64(Stream^.FramesTaken);
  else
    Result := ErrorInvalidArgument;
  end;
end;

function RegisterAudioOutput(const Routines: TAudioDriverRoutines; Context: Pointer): PAudioOutput;
const
  EveryoneReadWrite = $1B6; { rw-rw-rw- }
var
  Dispatch: TDispatchTable;
  State: POutputState;
  Index: Integer;
  Name: array[0..15] of Char;
begin
  Result := nil;
  if OutputCount = MaximumOutputs then
    Exit;
  if AudioDriver = nil then
  begin
    FillMemory(@Dispatch, SizeOf(Dispatch), 0);
    Dispatch[IoFunctionOpen] := @OpenAudioDevice;
    Dispatch[IoFunctionClose] := @CloseAudioDevice;
    Dispatch[IoFunctionWrite] := @WriteAudioDevice;
    Dispatch[IoFunctionControl] := @ControlAudioDevice;
    AudioDriver := CreateDriver('audio', Dispatch);
    InitializeEvent(MixerWake, EventKindSynchronization, False);
  end;
  CopyText(@Name[0], 'audio', SizeOf(Name));
  if OutputCount > 0 then
  begin
    Name[5] := Char(Ord('0') + OutputCount);
    Name[6] := #0;
  end;
  State := POutputState(AllocateZeroedKernelMemory(SizeOf(TOutputState)));
  Result := PAudioOutput(AllocateZeroedKernelMemory(SizeOf(TAudioOutput)));
  if (State = nil) or (Result = nil) then
    Exit(nil);
  State^.Mix := PInt64(AllocateKernelMemory(AudioPeriodFrames * 2 * SizeOf(Int64)));
  if State^.Mix = nil then
    Exit(nil);
  for Index := 0 to AudioPeriodCount - 1 do
  begin
    Result^.PeriodsPhysical[Index] := AllocateZeroedPhysicalPage(PageUsageGeneral);
    if Result^.PeriodsPhysical[Index] = 0 then
      Exit(nil);
    Result^.Periods[Index] := PByte(PhysicalToVirtual(Result^.PeriodsPhysical[Index]));
  end;
  Result^.Routines := Routines;
  Result^.Context := Context;
  Result^.State := State;
  InitializeMutex(State^.StreamsLock);
  InitializeSpinLock(State^.Lock);
  InitializeEvent(State^.PeriodDone, EventKindNotification, False);
  State^.MasterVolume := DefaultMasterVolume;
  Result^.Device := CreateDevice(AudioDriver, @Name[0], DeviceKindCharacter, EveryoneReadWrite, 0);
  if Result^.Device = nil then
    Exit(nil);
  Result^.Device^.Extension := Result;
  Routines.SetVolume(Context, DefaultMasterVolume);
  Outputs[OutputCount] := Result;
  Inc(OutputCount);
end;

end.
