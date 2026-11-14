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
  in the ring, and set the volume and sample rate. This unit gives the
  output its ring - PeriodCount pages ("periods") the hardware plays
  round and round - and a device file: the first output is /dev/audio.

  Programs write 16-bit little-endian samples (stereo, or mono, which is
  widened to stereo here) at the rate they chose with
  ControlAudioSetFormat (44100 or 48000 Hz). A write copies the samples
  into the periods after the one playing, waiting while all of them are
  full; playing starts once two periods are full. Each time the hardware
  finishes a period (it interrupts, and the driver calls
  AudioPeriodsElapsed) the period is cleared, so that if programs fall
  behind the hardware plays silence rather than old sound. Draining (on
  request, and when the file is closed) pads the last period with
  silence, waits until everything has been played and stops the
  hardware.
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
  AudioDefaultRate = 48000;

type
  TAudioDriverRoutines = record
    { Starts playing the ring from its beginning. }
    Start: procedure(Context: Pointer);
    Stop: procedure(Context: Pointer);
    { Bytes into the ring the hardware has played. }
    Position: function(Context: Pointer): LongWord;
    { 0-100 percent. }
    SetVolume: procedure(Context: Pointer; Percent: LongWord);
    { False if the hardware cannot play at Rate. Called while stopped. }
    SetRate: function(Context: Pointer; Rate: LongWord): Boolean;
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
  first, audio1, ... after that); the driver fills in nothing more. nil
  if memory is short. }
function RegisterAudioOutput(const Routines: TAudioDriverRoutines; Context: Pointer): PAudioOutput;
{ For the driver, at dispatch level or below: the hardware went on (it
  interrupted). }
procedure AudioPeriodsElapsed(Output: PAudioOutput);

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
  Debug.Output;

const
  StartAfterPeriods = 2;
  BytesPerFrame = 4; { 16-bit stereo }
  DefaultVolume = 80;

type
  POutputState = ^TOutputState;
  TOutputState = record
    Lock: TSpinLock;
    { Serializes writers, format changes and draining. }
    WriterLock: TMutex;
    Played: QWord;      { periods the hardware finished }
    Written: QWord;     { periods filled }
    WriteOffset: LongWord; { bytes in the period being filled }
    IsPlaying: Boolean;
    PeriodDone: TEvent;
    Rate: LongWord;
    Channels: LongWord;
    Volume: LongWord;
  end;

var
  AudioDriver: PDriverObject;
  OutputCount: Integer;

function StateOf(Output: PAudioOutput): POutputState;
begin
  Result := POutputState(Output^.State);
end;

function OutputOfDevice(Device: PDeviceObject): PAudioOutput;
begin
  Result := PAudioOutput(Device^.Extension);
end;

{ --- The ring ---------------------------------------------------------------- }

procedure AudioPeriodsElapsed(Output: PAudioOutput);
var
  State: POutputState;
  PreviousLevel: TPriorityLevel;
  Playing: LongWord;
  Moved: Boolean;
begin
  State := StateOf(Output);
  PreviousLevel := AcquireSpinLock(State^.Lock);
  Moved := False;
  if State^.IsPlaying then
  begin
    Playing := (Output^.Routines.Position(Output^.Context) div AudioPeriodBytes) mod AudioPeriodCount;
    { Every period before the one playing now is done: cleared, so that
      it plays silence if nothing new comes. }
    while (State^.Played mod AudioPeriodCount) <> Playing do
    begin
      ZeroMemory(Output^.Periods[State^.Played mod AudioPeriodCount], AudioPeriodBytes);
      Inc(State^.Played);
      Moved := True;
    end;
  end;
  ReleaseSpinLock(State^.Lock, PreviousLevel);
  if Moved then
    SignalEvent(State^.PeriodDone);
end;

{ Clears the ring and the counts (while not playing). }
procedure ResetRing(Output: PAudioOutput);
var
  Index: Integer;
  State: POutputState;
begin
  State := StateOf(Output);
  for Index := 0 to AudioPeriodCount - 1 do
    ZeroMemory(Output^.Periods[Index], AudioPeriodBytes);
  State^.Played := 0;
  State^.Written := 0;
  State^.WriteOffset := 0;
end;

procedure StartIfReady(Output: PAudioOutput; Force: Boolean);
var
  State: POutputState;
begin
  State := StateOf(Output);
  if State^.IsPlaying or ((State^.Written < StartAfterPeriods) and not Force) then
    Exit;
  State^.IsPlaying := True;
  Output^.Routines.Start(Output^.Context);
end;

{ Waits until a period after the one playing is free for writing; False
  if the wait was interrupted. }
function WaitForFreePeriod(Output: PAudioOutput): Boolean;
var
  State: POutputState;
  PreviousLevel: TPriorityLevel;
  Free: Boolean;
begin
  State := StateOf(Output);
  repeat
    PreviousLevel := AcquireSpinLock(State^.Lock);
    { Fell behind: the hardware played past what was written. }
    if State^.IsPlaying and (State^.Written <= State^.Played) then
    begin
      State^.Written := State^.Played + 1;
      State^.WriteOffset := 0;
    end;
    Free := State^.Written < State^.Played + AudioPeriodCount - 1;
    if not Free then
      ResetEvent(State^.PeriodDone);
    ReleaseSpinLock(State^.Lock, PreviousLevel);
    if Free then
      Exit(True);
    if not State^.IsPlaying then
      StartIfReady(Output, True);
    if WaitForEventWithOptions(State^.PeriodDone, 1000, True) = WaitAlerted then
      Exit(False);
  until False;
end;

{ Copies Count frames of stereo samples into the ring. }
function WriteFrames(Output: PAudioOutput; Source: PByte; ByteCount: QWord; Mono: Boolean): QWord;
var
  State: POutputState;
  Period: PByte;
  Room: LongWord;
  Frames: LongWord;
  Frame: LongWord;
  SourceStep: LongWord;
begin
  State := StateOf(Output);
  Result := 0;
  if Mono then
    SourceStep := 2
  else
    SourceStep := BytesPerFrame;
  while ByteCount - Result >= SourceStep do
  begin
    if not WaitForFreePeriod(Output) then
      Exit;
    Period := Output^.Periods[State^.Written mod AudioPeriodCount];
    Room := (AudioPeriodBytes - State^.WriteOffset) div BytesPerFrame;
    Frames := LongWord((ByteCount - Result) div SourceStep);
    if Frames > Room then
      Frames := Room;
    if Mono then
      for Frame := 0 to Frames - 1 do
      begin
        PWord(Period + State^.WriteOffset + Frame * BytesPerFrame)^ := PWord(Source + Result + Frame * 2)^;
        PWord(Period + State^.WriteOffset + Frame * BytesPerFrame + 2)^ := PWord(Source + Result + Frame * 2)^;
      end
    else
      CopyMemory(Period + State^.WriteOffset, Source + Result, Frames * BytesPerFrame);
    State^.WriteOffset := State^.WriteOffset + Frames * BytesPerFrame;
    Result := Result + Frames * SourceStep;
    if State^.WriteOffset = AudioPeriodBytes then
    begin
      State^.WriteOffset := 0;
      Inc(State^.Written);
      StartIfReady(Output, False);
    end;
  end;
end;

{ Plays out what was written (the last period padded with silence),
  then stops the hardware. }
procedure Drain(Output: PAudioOutput);
var
  State: POutputState;
begin
  State := StateOf(Output);
  if State^.WriteOffset > 0 then
  begin
    State^.WriteOffset := 0;
    Inc(State^.Written);
  end;
  if State^.Written > 0 then
  begin
    StartIfReady(Output, True);
    { Played counts the periods the hardware has moved past. }
    while State^.IsPlaying and (State^.Played < State^.Written) do
      if WaitForEventWithOptions(State^.PeriodDone, 1000, False) <> WaitSignaled then
        Break;
  end;
  if State^.IsPlaying then
  begin
    Output^.Routines.Stop(Output^.Context);
    State^.IsPlaying := False;
  end;
  ResetRing(Output);
end;

{ --- The device file ---------------------------------------------------------- }

function WriteAudioDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Output: PAudioOutput;
  State: POutputState;
begin
  Output := OutputOfDevice(Device);
  State := StateOf(Output);
  AcquireMutex(State^.WriterLock);
  Request.Information := Int64(WriteFrames(Output, PByte(Request.Buffer), Request.Length,
    State^.Channels = 1));
  ReleaseMutex(State^.WriterLock);
  if (Request.Information = 0) and (Request.Length >= 2) then
    Result := ErrorInterrupted
  else
    Result := ErrorNone;
end;

function SetFormat(Output: PAudioOutput; Format: QWord): LongInt;
var
  State: POutputState;
  Rate: LongWord;
  Channels: LongWord;
begin
  State := StateOf(Output);
  Rate := LongWord(Format shr 16);
  Channels := LongWord((Format shr 8) and $FF);
  if ((Format and $FF) <> 16) or not (Channels in [1, 2]) or ((Rate <> 44100) and (Rate <> 48000)) then
    Exit(ErrorInvalidArgument);
  Drain(Output);
  if not Output^.Routines.SetRate(Output^.Context, Rate) then
    Exit(ErrorUnsupported);
  State^.Rate := Rate;
  State^.Channels := Channels;
  Result := ErrorNone;
end;

function ControlAudioDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Output: PAudioOutput;
  State: POutputState;
begin
  Output := OutputOfDevice(Device);
  State := StateOf(Output);
  Result := ErrorNone;
  AcquireMutex(State^.WriterLock);
  case Request.ControlCode of
    ControlAudioGetFormat:
      Request.Information := (Int64(State^.Rate) shl 16) or (Int64(State^.Channels) shl 8) or 16;
    ControlAudioSetFormat:
      Result := SetFormat(Output, Request.ControlArgument);
    ControlAudioGetVolume:
      Request.Information := State^.Volume;
    ControlAudioSetVolume:
      if Request.ControlArgument > 100 then
        Result := ErrorInvalidArgument
      else
      begin
        State^.Volume := LongWord(Request.ControlArgument);
        Output^.Routines.SetVolume(Output^.Context, State^.Volume);
      end;
    ControlAudioDrain:
      Drain(Output);
  else
    Result := ErrorInvalidArgument;
  end;
  ReleaseMutex(State^.WriterLock);
end;

function CloseAudioDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Output: PAudioOutput;
begin
  Output := OutputOfDevice(Device);
  AcquireMutex(StateOf(Output)^.WriterLock);
  Drain(Output);
  ReleaseMutex(StateOf(Output)^.WriterLock);
  Result := ErrorNone;
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
  if AudioDriver = nil then
  begin
    FillMemory(@Dispatch, SizeOf(Dispatch), 0);
    Dispatch[IoFunctionWrite] := @WriteAudioDevice;
    Dispatch[IoFunctionControl] := @ControlAudioDevice;
    Dispatch[IoFunctionClose] := @CloseAudioDevice;
    AudioDriver := CreateDriver('audio', Dispatch);
  end;
  if OutputCount = 0 then
    CopyText(@Name[0], 'audio', SizeOf(Name))
  else
  begin
    CopyText(@Name[0], 'audio', SizeOf(Name));
    Name[5] := Char(Ord('0') + OutputCount);
    Name[6] := #0;
  end;
  State := POutputState(AllocateZeroedKernelMemory(SizeOf(TOutputState)));
  if State = nil then
    Exit;
  Result := PAudioOutput(AllocateZeroedKernelMemory(SizeOf(TAudioOutput)));
  if Result = nil then
    Exit;
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
  InitializeSpinLock(State^.Lock);
  InitializeMutex(State^.WriterLock);
  InitializeEvent(State^.PeriodDone, EventKindNotification, False);
  State^.Rate := AudioDefaultRate;
  State^.Channels := 2;
  State^.Volume := DefaultVolume;
  Result^.Device := CreateDevice(AudioDriver, @Name[0], DeviceKindCharacter, EveryoneReadWrite, 0);
  if Result^.Device = nil then
    Exit(nil);
  Result^.Device^.Extension := Result;
  Routines.SetVolume(Context, DefaultVolume);
  Inc(OutputCount);
end;

end.
