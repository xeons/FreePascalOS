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
  Intel High Definition Audio controllers (PCI class 04h, subclass 03h):
  sound output and input.

  The controller is reset, and its codecs are searched for an output
  path and an input path (Drivers.HdAudio.Codecs). The output plays the
  audio framework's ring (Io.AudioOutput) through the first output
  stream; the input, if there is one, captures into its ring
  (Io.AudioInput) through the first input stream
  (Drivers.HdAudio.Streams). Both carry 16-bit stereo at 48 kHz. Each
  period done raises an interrupt (by MSI; without it a timer asks where
  the streams are). The output's volume and the input's gain are their
  converters' amplifiers.
}
unit Drivers.HdAudio;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every HD Audio controller with a usable output; returns how
  many. }
function InitializeHdAudioControllers: Integer;

implementation

uses
  Abi.SystemCalls,
  Io.PowerManagement,
  Memory.KernelHeap,
  Memory.DeviceMapping,
  Kernel.Arch.TrapFrame,
  Kernel.Arch.Cpu,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.Clock,
  Io.Pci,
  Io.PciMessageInterrupts,
  Io.AudioOutput,
  Io.AudioInput,
  Drivers.HdAudio.Codecs,
  Drivers.HdAudio.Streams,
  Debug.Output;

const
  PciClassMultimedia = $04;
  PciSubclassAudio = $03;

  GlobalControlReset = 1;
  InterruptGlobalEnable = LongWord(1) shl 31;
  OutputTag = 1;
  InputTag = 2;
  PollIntervalMilliseconds = 10;

type
  PHdAudioController = ^THdAudioController;

  { Playing or capturing: the codec path, the stream, and what wakes the
    framework when periods are done. }
  PDirection = ^TDirection;
  TDirection = record
    Controller: PHdAudioController;
    IsInput: Boolean;
    Path: TCodecPath;
    Stream: THdAudioStream;
    Output: PAudioOutput;
    Input: PAudioInput;
    IsRunning: Boolean;
    PeriodCall: TDeferredCall;
    PollTimer: TTimer;
  end;

  THdAudioController = record
    Pci: PPciDevice;
    Registers: PByte;
    UsesInterrupts: Boolean;
    Playback: TDirection;
    Capture: TDirection;
    HasCapture: Boolean;
  end;

{ --- The framework's routines --------------------------------------------- }

procedure StartDirection(Context: Pointer);
var
  Direction: PDirection;
begin
  Direction := PDirection(Context);
  Direction^.IsRunning := True;
  RunStream(Direction^.Stream);
  if not Direction^.Controller^.UsesInterrupts then
    SetTimer(Direction^.PollTimer, PollIntervalMilliseconds, Direction^.PeriodCall);
end;

procedure StopDirection(Context: Pointer);
var
  Direction: PDirection;
begin
  Direction := PDirection(Context);
  Direction^.IsRunning := False;
  { Halting resets it: the next start begins at the start of the ring. }
  HaltStream(Direction^.Stream);
end;

function DirectionPosition(Context: Pointer): LongWord;
begin
  Result := StreamPosition(PDirection(Context)^.Stream);
end;

{ The converter's amplifier at Percent of its steps (muted at 0). }
function AmplifierGain(const Path: TCodecPath; Percent: LongWord): LongWord;
begin
  if Percent = 0 then
    Result := AmplifierMute
  else
    Result := Path.AmplifierSteps * Percent div 100;
end;

procedure SetPlaybackVolume(Context: Pointer; Percent: LongWord);
var
  Direction: PDirection;
begin
  Direction := PDirection(Context);
  with Direction^.Path do
    ShortVerb(Direction^.Controller^.Registers, Codec, Converter, VerbSetAmplifier,
      AmplifierOutput or AmplifierBothSides or AmplifierGain(Direction^.Path, Percent));
end;

procedure SetCaptureGain(Context: Pointer; Percent: LongWord);
var
  Direction: PDirection;
begin
  Direction := PDirection(Context);
  with Direction^.Path do
    ShortVerb(Direction^.Controller^.Registers, Codec, Converter, VerbSetAmplifier,
      AmplifierInput or AmplifierBothSides or (ConnectionIndex shl 8) or AmplifierGain(Direction^.Path, Percent));
end;

{ --- Periods done ----------------------------------------------------------------- }

{ Deferred call: after the stream's interrupt, or the poll timer. }
procedure PeriodsElapsed(Context: Pointer);
var
  Direction: PDirection;
begin
  Direction := PDirection(Context);
  if Direction^.IsInput then
    AudioInputPeriodsElapsed(Direction^.Input)
  else
    AudioPeriodsElapsed(Direction^.Output);
  if not Direction^.Controller^.UsesInterrupts and Direction^.IsRunning then
    SetTimer(Direction^.PollTimer, PollIntervalMilliseconds, Direction^.PeriodCall);
end;

procedure ServiceDirection(var Direction: TDirection; Status: LongWord);
begin
  if (Status and (LongWord(1) shl Direction.Stream.Index)) = 0 then
    Exit;
  AcknowledgeStream(Direction.Stream);
  QueueDeferredCall(Direction.PeriodCall);
end;

procedure HandleHdAudioInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Controller: PHdAudioController;
  Status: LongWord;
begin
  Controller := PHdAudioController(Context);
  Status := Read32(Controller^.Registers, RegisterInterruptStatus);
  ServiceDirection(Controller^.Playback, Status);
  if Controller^.HasCapture then
    ServiceDirection(Controller^.Capture, Status);
end;

{ --- Starting a controller -------------------------------------------------------- }

function ResetController(Controller: PHdAudioController): Boolean;
var
  Deadline: QWord;
begin
  Write32(Controller^.Registers, RegisterGlobalControl,
    Read32(Controller^.Registers, RegisterGlobalControl) and not GlobalControlReset);
  Deadline := ClockTickCount + MillisecondsToTicks(100);
  while (Read32(Controller^.Registers, RegisterGlobalControl) and GlobalControlReset) <> 0 do
    if ClockTickCount > Deadline then
      Exit(False);
  Write32(Controller^.Registers, RegisterGlobalControl, GlobalControlReset);
  Deadline := ClockTickCount + MillisecondsToTicks(100);
  while (Read32(Controller^.Registers, RegisterGlobalControl) and GlobalControlReset) = 0 do
    if ClockTickCount > Deadline then
      Exit(False);
  { Codecs announce themselves within about a millisecond. }
  Deadline := ClockTickCount + MillisecondsToTicks(20);
  while ClockTickCount < Deadline do
    CpuRelax;
  Result := Read16(Controller^.Registers, RegisterStateChange) <> 0;
end;

procedure InitializeDirection(Controller: PHdAudioController; var Direction: TDirection; IsInput: Boolean);
begin
  Direction.Controller := Controller;
  Direction.IsInput := IsInput;
  InitializeDeferredCall(Direction.PeriodCall, @PeriodsElapsed, @Direction);
  InitializeTimer(Direction.PollTimer);
end;

{ Tells the converter the stream's format. }
procedure ApplyFormat(Controller: PHdAudioController; const Path: TCodecPath);
begin
  ShortVerb(Controller^.Registers, Path.Codec, Path.Converter, VerbSetFormat, FormatStereo16Bit48000);
end;

function StartPlayback(Controller: PHdAudioController): Boolean;
var
  Routines: TAudioDriverRoutines;
  Direction: PDirection;
begin
  Result := False;
  Direction := @Controller^.Playback;
  InitializeDirection(Controller, Direction^, False);
  if not FindOutputPath(Controller^.Registers, OutputTag, Direction^.Path) or
     ((Direction^.Path.SupportedRates and RateBit48000) = 0) then
    Exit;
  Routines.Start := @StartDirection;
  Routines.Stop := @StopDirection;
  Routines.Position := @DirectionPosition;
  Routines.SetVolume := @SetPlaybackVolume;
  Routines.Kind := AudioOutputKindHdAudio;
  Routines.PeriodWritten := nil;
  Direction^.Output := RegisterAudioOutput(Routines, Direction);
  if (Direction^.Output = nil) or not PrepareStream(Direction^.Stream, Controller^.Registers,
    FirstOutputStream(Controller^.Registers), OutputTag, Direction^.Output^.PeriodsPhysical) then
    Exit;
  ApplyFormat(Controller, Direction^.Path);
  Result := True;
end;

{ An input, if a codec has an input path and the controller input
  streams. }
function StartCapture(Controller: PHdAudioController): Boolean;
var
  Routines: TAudioInputRoutines;
  Direction: PDirection;
begin
  Result := False;
  Direction := @Controller^.Capture;
  InitializeDirection(Controller, Direction^, True);
  if (FirstOutputStream(Controller^.Registers) = 0) or
     not FindInputPath(Controller^.Registers, InputTag, Direction^.Path) or
     ((Direction^.Path.SupportedRates and RateBit48000) = 0) then
    Exit;
  Routines.Start := @StartDirection;
  Routines.Stop := @StopDirection;
  Routines.Position := @DirectionPosition;
  Routines.SetGain := @SetCaptureGain;
  Direction^.Input := RegisterAudioInput(Routines, Direction);
  if (Direction^.Input = nil) or not PrepareStream(Direction^.Stream, Controller^.Registers,
    FirstInputStream(Controller^.Registers), InputTag, Direction^.Input^.PeriodsPhysical) then
    Exit;
  ApplyFormat(Controller, Direction^.Path);
  Result := True;
end;

procedure DescribeController(Controller: PHdAudioController);
begin
  DebugBeginMessage;
  DebugWriteTag('audio');
  DebugWrite('HD Audio ');
  DebugWriteHex(Controller^.Pci^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(Controller^.Pci^.DeviceId, 4);
  with Controller^.Playback.Path do
  begin
    DebugWrite(', codec ');
    DebugWriteDecimal(Codec);
    DebugWrite(', converter ');
    DebugWriteDecimal(Converter);
    DebugWrite(' to pin ');
    DebugWriteDecimal(Pin);
  end;
  if Controller^.HasCapture then
    with Controller^.Capture.Path do
    begin
      DebugWrite(', input from pin ');
      DebugWriteDecimal(Pin);
      DebugWrite(' of codec ');
      DebugWriteDecimal(Codec);
    end;
  if Controller^.UsesInterrupts then
    DebugWriteLine(', interrupts by MSI')
  else
    DebugWriteLine(', polled');
  DebugEndMessage;
end;

{ The interrupt enables for the streams in use. }
procedure EnableStreamInterrupts(Controller: PHdAudioController);
var
  Enabled: LongWord;
begin
  if not Controller^.UsesInterrupts then
    Exit;
  Enabled := InterruptGlobalEnable or (LongWord(1) shl Controller^.Playback.Stream.Index);
  if Controller^.HasCapture then
    Enabled := Enabled or (LongWord(1) shl Controller^.Capture.Stream.Index);
  Write32(Controller^.Registers, RegisterInterruptControl, Enabled);
end;

{ --- Suspend to RAM --------------------------------------------------------- }

{ Waking reset the controller and the codecs (the framework stopped the
  streams before): the controller is reset again, the codec paths set
  up again, the streams given their lists, and the interrupts enabled.
  The framework sets the volume and starts the streams again. }
procedure ResumeController(Context: Pointer);
var
  Controller: PHdAudioController;
begin
  Controller := PHdAudioController(Context);
  if not ResetController(Controller) then
    Exit;
  if FindOutputPath(Controller^.Registers, OutputTag, Controller^.Playback.Path) then
    ApplyFormat(Controller, Controller^.Playback.Path);
  ResetStream(Controller^.Playback.Stream);
  if Controller^.HasCapture then
  begin
    if FindInputPath(Controller^.Registers, InputTag, Controller^.Capture.Path) then
      ApplyFormat(Controller, Controller^.Capture.Path);
    ResetStream(Controller^.Capture.Stream);
  end;
  EnableStreamInterrupts(Controller);
end;

function StartController(Pci: PPciDevice): Boolean;
var
  Controller: PHdAudioController;
  Bar: TPciBar;
begin
  Result := False;
  if not PciReadBar(Pci, 0, Bar) or Bar.IsIoPort then
    Exit;
  Controller := PHdAudioController(AllocateZeroedKernelMemory(SizeOf(THdAudioController)));
  if Controller = nil then
    Exit;
  Controller^.Pci := Pci;
  PciEnableDevice(Pci, True);
  Controller^.Registers := PByte(MapDeviceMemory(Bar.PhysicalAddress, Bar.SizeInBytes));
  if (Controller^.Registers = nil) or not ResetController(Controller) or not StartPlayback(Controller) then
    Exit;
  Controller^.HasCapture := StartCapture(Controller);

  Controller^.UsesInterrupts := ConnectPciMessageInterrupt(Pci, @HandleHdAudioInterrupt, Controller);
  EnableStreamInterrupts(Controller);
  RegisterPowerHandler('HD Audio', PowerStageDevices, nil, @ResumeController, Controller);
  DescribeController(Controller);
  Result := True;
end;

function InitializeHdAudioControllers: Integer;
var
  Index: Integer;
  Pci: PPciDevice;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Pci := PciDeviceAt(Index);
    if (Pci^.ClassCode = PciClassMultimedia) and (Pci^.Subclass = PciSubclassAudio) and StartController(Pci) then
      Inc(Result);
  end;
end;

end.
