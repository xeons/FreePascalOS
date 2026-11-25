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
  Audio input: recording, the part that does not depend on the hardware.

  A sound driver registers each input it has (RegisterAudioInput) with
  routines to start and stop capturing, report where the hardware is in
  the ring, and set the gain. The input gets a ring like an output's
  (AudioPeriodCount pages of 16-bit stereo at AudioInputRate) that the
  hardware fills round and round, and a device file: the first input is
  /dev/audioin.

  Every open of the device is a capture stream of its own
  (Io.CaptureStreams) with its own format and volume, so any number of
  programs record at once. The hardware captures while any stream is
  open. As it finishes each period (the driver calls
  AudioInputPeriodsElapsed), the capture thread (RunAudioCapture) hands
  the period to every stream. A read waits until its stream has
  something.

  Each output also has a monitor input (RegisterAudioMonitor:
  /dev/audiomonitor for /dev/audio, then audiomonitor1, ...): no
  hardware, but fed by the mixer with every period it mixes, so what is
  played can be recorded. Like loopback capture elsewhere, it only
  delivers while the output plays.
}
unit Io.AudioInput;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Manager,
  Io.Dma,
  Io.CaptureStreams;

const
  AudioInputRate = 48000;

type
  TAudioInputRoutines = record
    { Starts capturing into the ring from its beginning. }
    Start: procedure(Context: Pointer);
    Stop: procedure(Context: Pointer);
    { Bytes into the ring the hardware has filled. }
    Position: function(Context: Pointer): LongWord;
    { 0-100 percent. }
    SetGain: procedure(Context: Pointer; Percent: LongWord);
  end;

  PAudioInput = ^TAudioInput;
  TAudioInput = record
    Routines: TAudioInputRoutines;
    Context: Pointer;
    { The ring (none for a monitor). }
    Periods: array[0..15] of PByte;
    PeriodsPhysical: array[0..15] of QWord;
    { What the device that fills the ring is given (as for an output's
      ring, Io.AudioOutput). }
    PeriodsDeviceAddress: array[0..15] of QWord;
    { Private to this unit. }
    Device: PDeviceObject;
    State: Pointer;
  end;

{ Creates an input with its ring and device file. With Dma (the
  attributes of the device that fills the ring) the pages are shared DMA
  memory it can reach (uncached when it does not snoop, so what it wrote
  is read without cache maintenance), as for RegisterAudioOutput. nil if
  memory is short. }
function RegisterAudioInput(const Routines: TAudioInputRoutines; Context: Pointer;
  Dma: PDmaAttributes = nil): PAudioInput;
{ Creates the monitor input of the next output. }
function RegisterAudioMonitor: PAudioInput;
{ For the driver, at dispatch level or below: the hardware went on. }
procedure AudioInputPeriodsElapsed(Input: PAudioInput);
{ For the mixer: Frames frames of 16-bit stereo went to the output this
  monitor belongs to. }
procedure FeedAudioMonitor(Input: PAudioInput; Samples: PSmallInt; Frames: LongWord);
{ How many hardware inputs registered (they do while the system starts;
  monitors are not counted). }
function AudioInputCount: Integer;
{ The capture thread: a system thread runs this, if there are hardware
  inputs; it never returns. }
procedure RunAudioCapture(Context: Pointer);

implementation

uses
  Io.PowerManagement,
  Runtime.Memory,
  Runtime.Text,
  Abi.SystemCalls,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.Events,
  Kernel.Mutex,
  Io.AudioOutput;

const
  MaximumInputs = 8;
  DefaultGain = 80;
  CaptureIntervalMilliseconds = 50;

type
  PInputState = ^TInputState;
  TInputState = record
    StreamsLock: TMutex;
    Streams: PCaptureStream;
    StreamCount: Integer;
    IsMonitor: Boolean;
    IsCapturing: Boolean;
    { Periods handed to the streams since capturing started. }
    Consumed: QWord;
    Gain: LongWord;
  end;

var
  InputDriver: PDriverObject;
  Inputs: array[0..MaximumInputs - 1] of PAudioInput;
  InputCount: Integer;
  HardwareInputCount: Integer;
  MonitorCount: Integer;
  CaptureWake: TEvent;
  CaptureSuspended: Boolean;

function StateOf(Input: PAudioInput): PInputState;
begin
  Result := PInputState(Input^.State);
end;

{ --- Handing out what was captured ------------------------------------- }

{ Gives Frames frames to every stream. Caller holds the streams lock. }
procedure FeedStreamsLocked(State: PInputState; Samples: PSmallInt; Frames: LongWord);
var
  Stream: PCaptureStream;
begin
  Stream := State^.Streams;
  while Stream <> nil do
  begin
    FeedCaptureStream(Stream, Samples, Frames);
    Stream := Stream^.Next;
  end;
end;

procedure FeedAudioMonitor(Input: PAudioInput; Samples: PSmallInt; Frames: LongWord);
var
  State: PInputState;
begin
  State := StateOf(Input);
  if State^.StreamCount = 0 then
    Exit;
  AcquireMutex(State^.StreamsLock);
  FeedStreamsLocked(State, Samples, Frames);
  ReleaseMutex(State^.StreamsLock);
end;

procedure AudioInputPeriodsElapsed(Input: PAudioInput);
begin
  SignalEvent(CaptureWake);
end;

{ Hands every period the hardware has finished to the streams. }
procedure ServiceInput(Input: PAudioInput);
var
  State: PInputState;
  Filling: QWord;
begin
  State := StateOf(Input);
  AcquireMutex(State^.StreamsLock);
  if State^.IsCapturing then
  begin
    Filling := (Input^.Routines.Position(Input^.Context) div AudioPeriodBytes) mod AudioPeriodCount;
    while (State^.Consumed mod AudioPeriodCount) <> Filling do
    begin
      FeedStreamsLocked(State, PSmallInt(Input^.Periods[State^.Consumed mod AudioPeriodCount]),
        AudioPeriodFrames);
      Inc(State^.Consumed);
    end;
  end;
  ReleaseMutex(State^.StreamsLock);
end;

procedure RunAudioCapture(Context: Pointer);
var
  Index: Integer;
begin
  while True do
  begin
    WaitForEventWithOptions(CaptureWake, CaptureIntervalMilliseconds, False);
    if not CaptureSuspended then
      for Index := 0 to InputCount - 1 do
        if not StateOf(Inputs[Index])^.IsMonitor then
          ServiceInput(Inputs[Index]);
  end;
end;

{ --- Suspend to RAM ------------------------------------------------------- }

{ Capturing hardware stops (and starts again on resume, from the start
  of its ring, if a reader is still there). }
procedure SuspendInputs(Context: Pointer);
var
  Index: Integer;
  State: PInputState;
begin
  CaptureSuspended := True;
  for Index := 0 to InputCount - 1 do
  begin
    State := StateOf(Inputs[Index]);
    AcquireMutex(State^.StreamsLock);
    if State^.IsCapturing then
      Inputs[Index]^.Routines.Stop(Inputs[Index]^.Context);
    ReleaseMutex(State^.StreamsLock);
  end;
end;

procedure ResumeInputs(Context: Pointer);
var
  Index: Integer;
  State: PInputState;
begin
  for Index := 0 to InputCount - 1 do
  begin
    State := StateOf(Inputs[Index]);
    if State^.IsMonitor then
      Continue;
    AcquireMutex(State^.StreamsLock);
    if Assigned(Inputs[Index]^.Routines.SetGain) then
      Inputs[Index]^.Routines.SetGain(Inputs[Index]^.Context, State^.Gain);
    if State^.IsCapturing then
    begin
      State^.Consumed := 0;
      Inputs[Index]^.Routines.Start(Inputs[Index]^.Context);
    end;
    ReleaseMutex(State^.StreamsLock);
  end;
  CaptureSuspended := False;
end;

function AudioInputCount: Integer;
begin
  Result := HardwareInputCount;
end;

{ --- The device file --------------------------------------------------------- }

function InputOfDevice(Device: PDeviceObject): PAudioInput;
begin
  Result := PAudioInput(Device^.Extension);
end;

function StreamOf(var Request: TIoRequest): PCaptureStream;
begin
  Result := PCaptureStream(Request.OpenFile^.Context);
end;

function OpenInputDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Input: PAudioInput;
  State: PInputState;
  Stream: PCaptureStream;
begin
  Input := InputOfDevice(Device);
  State := StateOf(Input);
  Stream := CreateCaptureStream(AudioInputRate);
  if Stream = nil then
    Exit(ErrorOutOfMemory);
  AcquireMutex(State^.StreamsLock);
  Stream^.Next := State^.Streams;
  State^.Streams := Stream;
  Inc(State^.StreamCount);
  { The first reader starts the hardware. }
  if not State^.IsMonitor and not State^.IsCapturing then
  begin
    State^.Consumed := 0;
    State^.IsCapturing := True;
    Input^.Routines.Start(Input^.Context);
  end;
  ReleaseMutex(State^.StreamsLock);
  Request.OpenFile^.Context := Stream;
  Result := ErrorNone;
end;

function CloseInputDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Input: PAudioInput;
  State: PInputState;
  Stream: PCaptureStream;
  Link: ^PCaptureStream;
begin
  Input := InputOfDevice(Device);
  State := StateOf(Input);
  Stream := StreamOf(Request);
  Result := ErrorNone;
  if Stream = nil then
    Exit;
  AcquireMutex(State^.StreamsLock);
  Link := @State^.Streams;
  while (Link^ <> nil) and (Link^ <> Stream) do
    Link := @Link^^.Next;
  if Link^ = Stream then
  begin
    Link^ := Stream^.Next;
    Dec(State^.StreamCount);
  end;
  { The last reader stops it. }
  if (State^.StreamCount = 0) and State^.IsCapturing then
  begin
    State^.IsCapturing := False;
    Input^.Routines.Stop(Input^.Context);
  end;
  ReleaseMutex(State^.StreamsLock);
  DestroyCaptureStream(Stream);
  Request.OpenFile^.Context := nil;
end;

function ReadInputDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Stream: PCaptureStream;
  Taken: QWord;
begin
  Stream := StreamOf(Request);
  Result := ErrorNone;
  Request.Information := 0;
  if Request.Length < Stream^.BytesPerFrame then
    Exit(ErrorInvalidArgument);
  repeat
    ResetEvent(Stream^.DataArrived);
    Taken := TakeCapturedData(Stream, PByte(Request.Buffer), Request.Length);
    if Taken > 0 then
      Break;
    if WaitForEventWithOptions(Stream^.DataArrived, InfiniteTimeout, True) = WaitAlerted then
      Exit(ErrorInterrupted);
  until False;
  Request.Information := Int64(Taken);
end;

function ControlInputDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Input: PAudioInput;
  State: PInputState;
  Stream: PCaptureStream;
  Argument: QWord;
begin
  Input := InputOfDevice(Device);
  State := StateOf(Input);
  Stream := StreamOf(Request);
  Argument := Request.ControlArgument;
  Result := ErrorNone;
  case Request.ControlCode of
    ControlAudioGetFormat:
      Request.Information := (Int64(Stream^.Rate) shl 16) or (Int64(Stream^.Channels) shl 8) or Stream^.Kind;
    ControlAudioSetFormat:
      if not SetCaptureFormat(Stream, LongWord(Argument shr 16), LongWord((Argument shr 8) and $FF),
        LongWord(Argument and $FF)) then
        Result := ErrorInvalidArgument;
    ControlAudioGetVolume:
      Request.Information := Stream^.Volume;
    ControlAudioSetVolume:
      if Argument > 100 then
        Result := ErrorInvalidArgument
      else
        SetCaptureVolume(Stream, LongWord(Argument));
    ControlAudioGetMasterVolume:
      Request.Information := State^.Gain;
    ControlAudioSetMasterVolume:
      if Argument > 100 then
        Result := ErrorInvalidArgument
      else
      begin
        State^.Gain := LongWord(Argument);
        if Assigned(Input^.Routines.SetGain) then
          Input^.Routines.SetGain(Input^.Context, State^.Gain);
      end;
    ControlAudioGetQueued:
      Request.Information := CapturedBytes(Stream);
    ControlAudioGetDropped:
      Request.Information := Int64(Stream^.FramesDropped);
  else
    Result := ErrorInvalidArgument;
  end;
end;

{ --- Registering ------------------------------------------------------------------ }

{ Makes Name: Base, then Base followed by Number if it is not 0. }
procedure NumberedName(Name: PChar; Capacity: Integer; Base: PChar; Number: Integer);
var
  Length: Integer;
begin
  CopyText(Name, Base, Capacity);
  if Number = 0 then
    Exit;
  Length := TextLength(Name);
  Name[Length] := Char(Ord('0') + Number);
  Name[Length + 1] := #0;
end;

function CreateInput(Name: PChar; IsMonitor: Boolean): PAudioInput;
const
  EveryoneReadWrite = $1B6; { rw-rw-rw- }
var
  Dispatch: TDispatchTable;
  State: PInputState;
begin
  Result := nil;
  if InputCount = MaximumInputs then
    Exit;
  if InputDriver = nil then
  begin
    FillMemory(@Dispatch, SizeOf(Dispatch), 0);
    Dispatch[IoFunctionOpen] := @OpenInputDevice;
    Dispatch[IoFunctionClose] := @CloseInputDevice;
    Dispatch[IoFunctionRead] := @ReadInputDevice;
    Dispatch[IoFunctionControl] := @ControlInputDevice;
    InputDriver := CreateDriver('audioin', Dispatch);
    InitializeEvent(CaptureWake, EventKindSynchronization, False);
  end;
  State := PInputState(AllocateZeroedKernelMemory(SizeOf(TInputState)));
  Result := PAudioInput(AllocateZeroedKernelMemory(SizeOf(TAudioInput)));
  if (State = nil) or (Result = nil) then
    Exit(nil);
  InitializeMutex(State^.StreamsLock);
  State^.IsMonitor := IsMonitor;
  State^.Gain := DefaultGain;
  Result^.State := State;
  Result^.Device := CreateDevice(InputDriver, Name, DeviceKindCharacter, EveryoneReadWrite, 0);
  if Result^.Device = nil then
    Exit(nil);
  Result^.Device^.Extension := Result;
  Inputs[InputCount] := Result;
  Inc(InputCount);
end;

function RegisterAudioInput(const Routines: TAudioInputRoutines; Context: Pointer;
  Dma: PDmaAttributes): PAudioInput;
var
  Name: array[0..23] of Char;
  Index: Integer;
  Pages: array[0..AudioPeriodCount - 1] of PByte;
  Physical: array[0..AudioPeriodCount - 1] of QWord;
  DeviceAddresses: array[0..AudioPeriodCount - 1] of QWord;
begin
  Result := nil;
  for Index := 0 to AudioPeriodCount - 1 do
    if not AllocateAudioPeriod(Dma, Pages[Index], Physical[Index], DeviceAddresses[Index]) then
      Exit;
  NumberedName(@Name[0], SizeOf(Name), 'audioin', HardwareInputCount);
  Result := CreateInput(@Name[0], False);
  if Result = nil then
    Exit;
  for Index := 0 to AudioPeriodCount - 1 do
  begin
    Result^.PeriodsPhysical[Index] := Physical[Index];
    Result^.PeriodsDeviceAddress[Index] := DeviceAddresses[Index];
    Result^.Periods[Index] := Pages[Index];
  end;
  Result^.Routines := Routines;
  Result^.Context := Context;
  if Assigned(Routines.SetGain) then
    Routines.SetGain(Context, DefaultGain);
  if HardwareInputCount = 0 then
    RegisterPowerHandler('audio inputs', PowerStageServices, @SuspendInputs, @ResumeInputs, nil);
  Inc(HardwareInputCount);
end;

function RegisterAudioMonitor: PAudioInput;
var
  Name: array[0..23] of Char;
begin
  NumberedName(@Name[0], SizeOf(Name), 'audiomonitor', MonitorCount);
  Result := CreateInput(@Name[0], True);
  if Result <> nil then
    Inc(MonitorCount);
end;

end.
