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
  has been played. The output's volume (the hardware's, or the mixer's
  own scaling for hardware without one) applies to every stream; each
  stream also has its own. A muted output plays silence
  (the mixer writes zeros, so it is silent whatever the hardware's
  amplifier can do) and keeps its volume for when it is unmuted.

  One output is the default (the first, until someone chooses another):
  where programs play that name no output. The kernel only keeps the
  number (ControlAudioGetDefaultOutput and ...Set on any output);
  libaudio opens that output for them. Everyone may change the volumes,
  the mute and the default, as anyone at the machine could turn its
  knobs; the system settings service gives the remembered ones at
  start.
}
unit Io.AudioOutput;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Manager,
  Io.Dma;

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
    { 0-100 percent; nil for hardware without a volume control (HDMI):
      the mixer then scales the samples itself. }
    SetVolume: procedure(Context: Pointer; Percent: LongWord);
    { What the output is (AudioOutputKind*), for programs to name it. }
    Kind: LongWord;
    { nil, or called after the mixer wrote period Index mod
      AudioPeriodCount (Index counts the periods since Start; the first
      MixAheadPeriods come before Start): for hardware that plays its
      own copy of the ring or needs the period cleaned out of the
      caches. On the mixer's thread. }
    PeriodWritten: procedure(Context: Pointer; Index: QWord);
  end;

  PAudioOutput = ^TAudioOutput;
  TAudioOutput = record
    Routines: TAudioDriverRoutines;
    Context: Pointer;
    { The ring's pages, for the driver to describe to the hardware. }
    Periods: array[0..AudioPeriodCount - 1] of PByte;
    PeriodsPhysical: array[0..AudioPeriodCount - 1] of QWord;
    { What the device that plays the ring is given for each page: its
      bus address (Io.Dma) when the output was registered with the
      device's DMA attributes, else the physical address. }
    PeriodsDeviceAddress: array[0..AudioPeriodCount - 1] of QWord;
    { Private to this unit. }
    Device: PDeviceObject;
    State: Pointer;
  end;

{ Creates an output with its ring and device file (/dev/audio for the
  first, audio1, ... after that). With Dma (the attributes of the device
  that reads the ring itself) the pages are shared DMA memory that
  device can reach (mapped uncached when it does not snoop, so the
  mixer's writes need no cache maintenance) and PeriodsDeviceAddress
  holds its bus addresses. Without (nil: a driver that copies the ring,
  or translates and cleans it itself) they are ordinary cached pages.
  nil if memory is short. }
function RegisterAudioOutput(const Routines: TAudioDriverRoutines; Context: Pointer;
  Dma: PDmaAttributes = nil): PAudioOutput;
{ One zeroed page of a ring, with or without Dma as RegisterAudioOutput
  says (Io.AudioInput's rings too). False if memory is short. }
function AllocateAudioPeriod(Dma: PDmaAttributes; out Address: PByte; out Physical: QWord;
  out DeviceAddress: QWord): Boolean;
{ For the driver, at dispatch level or below: the hardware went on (it
  interrupted). }
procedure AudioPeriodsElapsed(Output: PAudioOutput);
{ How many outputs registered (they do while the system starts). }
function AudioOutputCount: Integer;
{ The mixer: a system thread runs this, if there are outputs; it never
  returns. }
procedure RunAudioMixer(Context: Pointer);

implementation

uses
  Io.PowerManagement,
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
  Kernel.PriorityBoosts,
  Kernel.Mutex,
  Io.AudioStreams,
  Io.AudioInput,
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
    Muted: Boolean;
    Mix: PInt64;
    { Recording what is played (/dev/audiomonitor). }
    Monitor: PAudioInput;
  end;

var
  AudioDriver: PDriverObject;
  Outputs: array[0..MaximumOutputs - 1] of PAudioOutput;
  OutputCount: Integer;
  MixerWake: TEvent;
  { Suspend to RAM: the mixer leaves the hardware alone meanwhile. }
  MixingSuspended: Boolean;
  DefaultOutput: Integer;

function StateOf(Output: PAudioOutput): POutputState;
begin
  Result := POutputState(Output^.State);
end;

{ --- The hardware ring --------------------------------------------------- }

function AllocateAudioPeriod(Dma: PDmaAttributes; out Address: PByte; out Physical: QWord;
  out DeviceAddress: QWord): Boolean;
var
  Buffer: TDmaBuffer;
begin
  Result := False;
  Address := nil;
  Physical := 0;
  DeviceAddress := 0;
  if Dma = nil then
  begin
    Physical := AllocateZeroedPhysicalPage(PageUsageGeneral);
    if Physical = 0 then
      Exit;
    Address := PByte(PhysicalToVirtual(Physical));
    DeviceAddress := Physical;
    Exit(True);
  end;
  if not AllocateDmaBuffer(Dma^, AudioPeriodBytes, DmaShared, Buffer) then
    Exit;
  Address := Buffer.Address;
  Physical := Buffer.Physical;
  DeviceAddress := Buffer.DeviceAddress;
  Result := True;
end;

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
  SoftwareGain: Int64;
  UsesSoftwareVolume: Boolean;
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
    { A program feeding a stream must be in time: the sound boost. }
    SignalEventWithBoost(Stream^.SpaceFreed, BoostSound);
    Stream := Stream^.Next;
  end;
  Samples := PSmallInt(Output^.Periods[Index mod AudioPeriodCount]);
  { Hardware without a volume control: the master volume scales the
    sum, by the square of the fraction (closer to how loud it sounds). }
  UsesSoftwareVolume := Output^.Routines.SetVolume = nil;
  SoftwareGain := Int64(State^.MasterVolume) * State^.MasterVolume;
  for Position := 0 to AudioPeriodFrames * 2 - 1 do
  begin
    Value := State^.Mix[Position] div 65536;
    if UsesSoftwareVolume then
      Value := Value * SoftwareGain div (100 * 100);
    if State^.Muted then
      Value := 0;
    if Value > High(SmallInt) then
      Value := High(SmallInt)
    else if Value < Low(SmallInt) then
      Value := Low(SmallInt);
    Samples[Position] := SmallInt(Value);
  end;
  if State^.Monitor <> nil then
    FeedAudioMonitor(State^.Monitor, Samples, AudioPeriodFrames);
  if Assigned(Output^.Routines.PeriodWritten) then
    Output^.Routines.PeriodWritten(Output^.Context, Index);
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
  begin
    DebugBeginMessage;
    DebugWriteTag('audio');
    DebugWrite('the mixer fell behind by ');
    DebugWriteDecimal(Played + 1 - State^.Mixed);
    DebugWriteLine(' periods (they played what the ring held)');
    DebugEndMessage;
    State^.Mixed := Played + 1;
  end;
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
  while True do
  begin
    WaitForEventWithOptions(MixerWake, MixerIntervalMilliseconds, False);
    if not MixingSuspended then
      for Index := 0 to OutputCount - 1 do
        ServiceOutput(Outputs[Index]);
  end;
end;

{ --- Suspend to RAM ------------------------------------------------------- }

{ Every output stops (each takes the streams lock, so the mixer is not
  in the middle of one); the mixer stays away until resume. }
procedure SuspendOutputs(Context: Pointer);
var
  Index: Integer;
  State: POutputState;
begin
  for Index := 0 to OutputCount - 1 do
  begin
    State := StateOf(Outputs[Index]);
    AcquireMutex(State^.StreamsLock);
    if Index = 0 then
      MixingSuspended := True;
    if State^.IsPlaying then
    begin
      Outputs[Index]^.Routines.Stop(Outputs[Index]^.Context);
      SetPlaying(State, False);
      SignalEvent(State^.PeriodDone);
    end;
    ReleaseMutex(State^.StreamsLock);
  end;
end;

{ The drivers set their hardware up again: the volumes go back, and the
  mixer starts each output again when a stream has something. }
procedure ResumeOutputs(Context: Pointer);
var
  Index: Integer;
begin
  for Index := 0 to OutputCount - 1 do
    if Assigned(Outputs[Index]^.Routines.SetVolume) then
      Outputs[Index]^.Routines.SetVolume(Outputs[Index]^.Context, StateOf(Outputs[Index])^.MasterVolume);
  MixingSuspended := False;
  SignalEvent(MixerWake);
end;

function AudioOutputCount: Integer;
begin
  Result := OutputCount;
end;

{ --- Streams ---------------------------------------------------------------- }

{ Waits until everything Stream wrote has been played. }
procedure DrainStream(Output: PAudioOutput; Stream: PAudioStream);
const
  { A device that plays nothing for this many waits of a second has
    stopped: closing does not wait for it any longer. }
  StalledWaitLimit = 3;
var
  State: POutputState;
  PlayedBefore: QWord;
  StalledWaits: Integer;
begin
  State := StateOf(Output);
  SignalEvent(MixerWake);
  StalledWaits := 0;
  repeat
    ResetEvent(State^.PeriodDone);
    if (StreamQueuedBytes(Stream) = 0) and
       (not State^.IsPlaying or (State^.Played > Stream^.LastSoundPeriod)) then
      Exit;
    PlayedBefore := State^.Played;
    if WaitForEventWithOptions(State^.PeriodDone, 1000, True) = WaitAlerted then
      Exit;
    if State^.Played = PlayedBefore then
      Inc(StalledWaits)
    else
      StalledWaits := 0;
  until StalledWaits >= StalledWaitLimit;
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
        if Assigned(Output^.Routines.SetVolume) then
          Output^.Routines.SetVolume(Output^.Context, State^.MasterVolume);
      end;
    ControlAudioGetMute:
      Request.Information := Ord(State^.Muted);
    ControlAudioSetMute:
      if Argument > 1 then
        Result := ErrorInvalidArgument
      else
        State^.Muted := Argument = 1;
    ControlAudioGetDefaultOutput:
      Request.Information := DefaultOutput;
    ControlAudioSetDefaultOutput:
      if Argument >= QWord(OutputCount) then
        Result := ErrorNotFound
      else
        DefaultOutput := Integer(Argument);
    ControlAudioGetKind:
      Request.Information := Output^.Routines.Kind;
    ControlAudioGetQueued:
      Request.Information := StreamQueuedBytes(Stream);
    ControlAudioGetPosition:
      Request.Information := Int64(Stream^.FramesTaken);
  else
    Result := ErrorInvalidArgument;
  end;
end;

function RegisterAudioOutput(const Routines: TAudioDriverRoutines; Context: Pointer;
  Dma: PDmaAttributes): PAudioOutput;
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
    if not AllocateAudioPeriod(Dma, Result^.Periods[Index], Result^.PeriodsPhysical[Index],
         Result^.PeriodsDeviceAddress[Index]) then
      Exit(nil);
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
  if Assigned(Routines.SetVolume) then
    Routines.SetVolume(Context, DefaultMasterVolume);
  State^.Monitor := RegisterAudioMonitor;
  if OutputCount = 0 then
    RegisterPowerHandler('audio outputs', PowerStageServices, @SuspendOutputs, @ResumeOutputs, nil);
  Outputs[OutputCount] := Result;
  Inc(OutputCount);
end;

end.
