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
  Intel High Definition Audio controllers (PCI class 04h, subclass 03h)
  and their codecs: sound output.

  The controller is reset, and every codec it found is asked about its
  widgets through the immediate command interface (one verb at a time,
  polled). In the codec's audio function group the driver looks for an
  output pin complex fed by an audio output converter (directly, or
  through one mixer or selector), powers them up, enables the pin and
  unmutes the path.

  Sound comes from the audio framework's ring (Io.AudioOutput): the
  first output stream's buffer descriptor list has one entry per period,
  each raising an interrupt when played (by MSI; without it a timer asks
  where the stream is). The stream plays 16-bit stereo at 48 kHz (the
  framework mixes everything into that); the volume is the converter's
  output amplifier.
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
  Runtime.Memory,
  Runtime.Atomic,
  Memory.Layout,
  Memory.PhysicalPages,
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
  Debug.Output;

const
  PciClassMultimedia = $04;
  PciSubclassAudio = $03;

  RegisterCapabilities = $00;
  RegisterGlobalControl = $08;
  RegisterStateChange = $0E;
  RegisterInterruptControl = $20;
  RegisterInterruptStatus = $24;
  RegisterCommandOut = $60;
  RegisterCommandIn = $64;
  RegisterCommandStatus = $68;
  StreamDescriptorBase = $80;
  StreamDescriptorSize = $20;

  GlobalControlReset = 1;
  CommandBusy = 1;
  CommandResultValid = 2;
  InterruptGlobalEnable = LongWord(1) shl 31;

  { Stream descriptor registers. }
  StreamControl = $00;
  StreamStatus = $03;
  StreamPosition = $04;
  StreamCycleLength = $08;
  StreamLastValidIndex = $0C;
  StreamFormat = $12;
  StreamListLower = $18;
  StreamListUpper = $1C;
  StreamControlReset = 1;
  StreamControlRun = 2;
  StreamControlInterruptOnCompletion = 4;
  StreamStatusCompletion = 4;
  StreamTag = 1;

  { Verbs. }
  VerbGetParameter = $F00;
  VerbGetConnectionList = $F02;
  VerbGetConfiguration = $F1C;
  VerbSetConnectionSelect = $701;
  VerbSetPowerState = $705;
  VerbSetStream = $706;
  VerbSetPinControl = $707;
  VerbSetExternalAmplifier = $70C;
  { Four bit verbs with 16-bit payloads. }
  VerbSetFormat = $2;
  VerbSetAmplifier = $3;

  ParameterNodeCount = $04;
  ParameterFunctionType = $05;
  ParameterWidgetCapabilities = $09;
  ParameterPcmRates = $0A;
  ParameterPinCapabilities = $0C;
  ParameterConnectionListLength = $0E;
  ParameterOutputAmplifier = $12;

  FunctionTypeAudio = 1;
  WidgetTypeOutput = 0;
  WidgetTypeMixer = 2;
  WidgetTypeSelector = 3;
  WidgetTypePin = 4;
  PinCanOutput = $10;
  PinControlOutput = $40;
  RateBit48000 = $40;

  AmplifierOutput = $8000;
  AmplifierInput = $4000;
  AmplifierBothSides = $3000;
  AmplifierMute = $80;

  FormatStereo16Bit48000 = $0011;
  CommandTimeoutMilliseconds = 100;
  PollIntervalMilliseconds = 10;

type
  PHdAudioController = ^THdAudioController;
  THdAudioController = record
    Pci: PPciDevice;
    Registers: PByte;
    Codec: LongWord;
    Converter: LongWord;
    Pin: LongWord;
    { A mixer or selector between them (0 if none). }
    Between: LongWord;
    ConverterSteps: LongWord;
    SupportedRates: LongWord;
    Format: Word;
    Stream: PByte;
    StreamIndex: LongWord;
    ListPhysical: QWord;
    Output: PAudioOutput;
    PeriodCall: TDeferredCall;
    PollTimer: TTimer;
    UsesInterrupts: Boolean;
    IsRunning: Boolean;
  end;

{ --- Registers and verbs ------------------------------------------------------- }

function Read8(Base: PByte; Offset: LongWord): Byte;
begin
  Result := PByte(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write8(Base: PByte; Offset: LongWord; Value: Byte);
begin
  FullMemoryBarrier;
  PByte(Base + Offset)^ := Value;
end;

function Read16(Base: PByte; Offset: LongWord): Word;
begin
  Result := PWord(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write16(Base: PByte; Offset: LongWord; Value: Word);
begin
  FullMemoryBarrier;
  PWord(Base + Offset)^ := Value;
end;

function Read32(Base: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write32(Base: PByte; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Base + Offset)^ := Value;
end;

function WaitFor16(Base: PByte; Offset: LongWord; Mask, Expected: Word): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(CommandTimeoutMilliseconds);
  while (Read16(Base, Offset) and Mask) <> Expected do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

{ Sends a command (codec, node, verb and payload) through the immediate
  command interface and returns the codec's response. }
function SendCommand(Controller: PHdAudioController; Command: LongWord; out Response: LongWord): Boolean;
begin
  Response := 0;
  if not WaitFor16(Controller^.Registers, RegisterCommandStatus, CommandBusy, 0) then
    Exit(False);
  Write16(Controller^.Registers, RegisterCommandStatus, CommandResultValid);
  Write32(Controller^.Registers, RegisterCommandOut, Command);
  Write16(Controller^.Registers, RegisterCommandStatus, CommandBusy);
  Result := WaitFor16(Controller^.Registers, RegisterCommandStatus, CommandBusy or CommandResultValid,
    CommandResultValid);
  if Result then
    Response := Read32(Controller^.Registers, RegisterCommandIn);
end;

{ A twelve bit verb with an eight bit payload. }
function Verb(Controller: PHdAudioController; Node, VerbId, Payload: LongWord): LongWord;
begin
  SendCommand(Controller, (Controller^.Codec shl 28) or (Node shl 20) or (VerbId shl 8) or (Payload and $FF),
    Result);
end;

{ A four bit verb with a sixteen bit payload. }
function ShortVerb(Controller: PHdAudioController; Node, VerbId, Payload: LongWord): LongWord;
begin
  SendCommand(Controller, (Controller^.Codec shl 28) or (Node shl 20) or (VerbId shl 16) or (Payload and $FFFF),
    Result);
end;

function Parameter(Controller: PHdAudioController; Node, Which: LongWord): LongWord;
begin
  Result := Verb(Controller, Node, VerbGetParameter, Which);
end;

function WidgetType(Controller: PHdAudioController; Node: LongWord): LongWord;
begin
  Result := (Parameter(Controller, Node, ParameterWidgetCapabilities) shr 20) and $F;
end;

{ Entry Index of Node's connection list (short form), 0 if none. }
function Connection(Controller: PHdAudioController; Node, Index: LongWord): LongWord;
var
  Length: LongWord;
begin
  Length := Parameter(Controller, Node, ParameterConnectionListLength);
  if ((Length and $80) <> 0) or (Index >= (Length and $7F)) then
    Exit(0);
  Result := (Verb(Controller, Node, VerbGetConnectionList, Index and not 3) shr ((Index and 3) * 8)) and $FF;
end;

function ConnectionCount(Controller: PHdAudioController; Node: LongWord): LongWord;
begin
  Result := Parameter(Controller, Node, ParameterConnectionListLength) and $7F;
end;

{ --- Finding an output path ---------------------------------------------------- }

{ The input of Node (a pin, mixer or selector) that is an output
  converter, its index in Node's connections returned too; 0 if none. }
function ConverterFeeding(Controller: PHdAudioController; Node: LongWord; out Index: LongWord): LongWord;
var
  Position: LongWord;
  Candidate: LongWord;
begin
  Index := 0;
  Position := 0;
  while Position < ConnectionCount(Controller, Node) do
  begin
    Candidate := Connection(Controller, Node, Position);
    if (Candidate <> 0) and (WidgetType(Controller, Candidate) = WidgetTypeOutput) then
    begin
      Index := Position;
      Exit(Candidate);
    end;
    Inc(Position);
  end;
  Result := 0;
end;

{ Looks in the audio function group starting at Group for an output pin
  fed by a converter (directly or through one mixer or selector), and
  sets the path up. }
function SetUpOutputPath(Controller: PHdAudioController; Group: LongWord): Boolean;
var
  Nodes: LongWord;
  Node: LongWord;
  First: LongWord;
  Index: LongWord;
  Inner: LongWord;
  Middle: LongWord;
  Converter: LongWord;
begin
  Result := False;
  Nodes := Parameter(Controller, Group, ParameterNodeCount);
  First := (Nodes shr 16) and $FF;
  Verb(Controller, Group, VerbSetPowerState, 0);
  for Node := First to First + (Nodes and $FF) - 1 do
  begin
    if (WidgetType(Controller, Node) <> WidgetTypePin) or
       ((Parameter(Controller, Node, ParameterPinCapabilities) and PinCanOutput) = 0) or
       ((Verb(Controller, Node, VerbGetConfiguration, 0) shr 30) = 1) then { not connected }
      Continue;
    Middle := 0;
    Converter := ConverterFeeding(Controller, Node, Index);
    if Converter = 0 then
      for Index := 0 to ConnectionCount(Controller, Node) - 1 do
      begin
        Middle := Connection(Controller, Node, Index);
        if (Middle <> 0) and (WidgetType(Controller, Middle) in [WidgetTypeMixer, WidgetTypeSelector]) then
        begin
          Converter := ConverterFeeding(Controller, Middle, Inner);
          if Converter <> 0 then
            Break;
        end;
        Middle := 0;
      end;
    if Converter = 0 then
      Continue;

    Controller^.Pin := Node;
    Controller^.Converter := Converter;
    Controller^.Between := Middle;
    Verb(Controller, Node, VerbSetConnectionSelect, Index);
    Verb(Controller, Node, VerbSetPowerState, 0);
    Verb(Controller, Node, VerbSetPinControl, PinControlOutput);
    Verb(Controller, Node, VerbSetExternalAmplifier, 2);
    ShortVerb(Controller, Node, VerbSetAmplifier, AmplifierOutput or AmplifierBothSides or $7F);
    if Middle <> 0 then
    begin
      Verb(Controller, Middle, VerbSetPowerState, 0);
      Verb(Controller, Middle, VerbSetConnectionSelect, Inner);
      ShortVerb(Controller, Middle, VerbSetAmplifier,
        AmplifierOutput or AmplifierInput or AmplifierBothSides or (Inner shl 8) or $7F);
    end;
    Verb(Controller, Converter, VerbSetPowerState, 0);
    Verb(Controller, Converter, VerbSetStream, StreamTag shl 4);
    Controller^.ConverterSteps := (Parameter(Controller, Converter, ParameterOutputAmplifier) shr 8) and $7F;
    Controller^.SupportedRates := Parameter(Controller, Converter, ParameterPcmRates);
    if Controller^.SupportedRates = 0 then
      Controller^.SupportedRates := Parameter(Controller, Group, ParameterPcmRates);
    Exit(True);
  end;
end;

function FindOutput(Controller: PHdAudioController): Boolean;
var
  Present: Word;
  Codec: LongWord;
  Nodes: LongWord;
  Group: LongWord;
begin
  Result := False;
  Present := Read16(Controller^.Registers, RegisterStateChange);
  for Codec := 0 to 14 do
  begin
    if (Present and (1 shl Codec)) = 0 then
      Continue;
    Controller^.Codec := Codec;
    Nodes := Parameter(Controller, 0, ParameterNodeCount);
    for Group := (Nodes shr 16) and $FF to ((Nodes shr 16) and $FF) + (Nodes and $FF) - 1 do
      if ((Parameter(Controller, Group, ParameterFunctionType) and $FF) = FunctionTypeAudio) and
         SetUpOutputPath(Controller, Group) then
        Exit(True);
  end;
end;

{ --- The stream ----------------------------------------------------------------- }

procedure ApplyFormat(Controller: PHdAudioController);
begin
  Write16(Controller^.Stream, StreamFormat, Controller^.Format);
  ShortVerb(Controller, Controller^.Converter, VerbSetFormat, Controller^.Format);
end;

{ Resets the output stream and gives it the ring, the stream tag and the
  format (after a reset it starts at the beginning of the ring). }
procedure SetUpStreamRegisters(Controller: PHdAudioController);
var
  Control: LongWord;
begin
  Write8(Controller^.Stream, StreamControl, StreamControlReset);
  while (Read8(Controller^.Stream, StreamControl) and StreamControlReset) = 0 do
    CpuRelax;
  Write8(Controller^.Stream, StreamControl, 0);
  while (Read8(Controller^.Stream, StreamControl) and StreamControlReset) <> 0 do
    CpuRelax;
  Write32(Controller^.Stream, StreamCycleLength, AudioPeriodCount * AudioPeriodBytes);
  Write16(Controller^.Stream, StreamLastValidIndex, AudioPeriodCount - 1);
  Write32(Controller^.Stream, StreamListLower, LongWord(Controller^.ListPhysical));
  Write32(Controller^.Stream, StreamListUpper, LongWord(Controller^.ListPhysical shr 32));
  Control := Read32(Controller^.Stream, StreamControl) and $FFFFFF;
  Control := (Control and not ($F shl 20)) or (StreamTag shl 20) or StreamControlInterruptOnCompletion;
  Write32(Controller^.Stream, StreamControl, Control);
  ApplyFormat(Controller);
end;

function SetUpStream(Controller: PHdAudioController): Boolean;
var
  List: PQWord;
  Index: Integer;
begin
  Controller^.StreamIndex := (Read16(Controller^.Registers, RegisterCapabilities) shr 8) and $F;
  Controller^.Stream := Controller^.Registers + StreamDescriptorBase +
    Controller^.StreamIndex * StreamDescriptorSize;
  Controller^.ListPhysical := AllocateZeroedPhysicalPage(PageUsageGeneral);
  if Controller^.ListPhysical = 0 then
    Exit(False);
  List := PQWord(PhysicalToVirtual(Controller^.ListPhysical));
  { Address, then length and "interrupt on completion" in one word. }
  for Index := 0 to AudioPeriodCount - 1 do
  begin
    List[Index * 2] := Controller^.Output^.PeriodsPhysical[Index];
    List[Index * 2 + 1] := AudioPeriodBytes or (QWord(1) shl 32);
  end;
  Controller^.Format := FormatStereo16Bit48000;
  if (Controller^.SupportedRates and RateBit48000) = 0 then
    Exit(False);
  SetUpStreamRegisters(Controller);
  Result := True;
end;

procedure StartStream(Context: Pointer);
var
  Controller: PHdAudioController;
begin
  Controller := PHdAudioController(Context);
  Controller^.IsRunning := True;
  Write8(Controller^.Stream, StreamControl, Read8(Controller^.Stream, StreamControl) or StreamControlRun);
  if not Controller^.UsesInterrupts then
    SetTimer(Controller^.PollTimer, PollIntervalMilliseconds, Controller^.PeriodCall);
end;

procedure StopStream(Context: Pointer);
var
  Controller: PHdAudioController;
begin
  Controller := PHdAudioController(Context);
  Controller^.IsRunning := False;
  Write8(Controller^.Stream, StreamControl, Read8(Controller^.Stream, StreamControl) and not StreamControlRun);
  while (Read8(Controller^.Stream, StreamControl) and StreamControlRun) <> 0 do
    CpuRelax;
  { The next start begins at the start of the ring. }
  SetUpStreamRegisters(Controller);
end;

function StreamPositionOf(Context: Pointer): LongWord;
begin
  Result := Read32(PHdAudioController(Context)^.Stream, StreamPosition);
end;

procedure SetVolume(Context: Pointer; Percent: LongWord);
var
  Controller: PHdAudioController;
  Gain: LongWord;
begin
  Controller := PHdAudioController(Context);
  Gain := Controller^.ConverterSteps * Percent div 100;
  if Percent = 0 then
    Gain := AmplifierMute;
  ShortVerb(Controller, Controller^.Converter, VerbSetAmplifier, AmplifierOutput or AmplifierBothSides or Gain);
end;

{ Deferred call: after the stream's interrupt, or the poll timer. }
procedure PeriodsElapsed(Context: Pointer);
var
  Controller: PHdAudioController;
begin
  Controller := PHdAudioController(Context);
  AudioPeriodsElapsed(Controller^.Output);
  if not Controller^.UsesInterrupts and Controller^.IsRunning then
    SetTimer(Controller^.PollTimer, PollIntervalMilliseconds, Controller^.PeriodCall);
end;

procedure HandleHdAudioInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Controller: PHdAudioController;
begin
  Controller := PHdAudioController(Context);
  Write8(Controller^.Stream, StreamStatus, Read8(Controller^.Stream, StreamStatus));
  QueueDeferredCall(Controller^.PeriodCall);
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

function StartController(Pci: PPciDevice): Boolean;
var
  Controller: PHdAudioController;
  Bar: TPciBar;
  Routines: TAudioDriverRoutines;
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
  if (Controller^.Registers = nil) or not ResetController(Controller) or not FindOutput(Controller) then
    Exit;

  Routines.Start := @StartStream;
  Routines.Stop := @StopStream;
  Routines.Position := @StreamPositionOf;
  Routines.SetVolume := @SetVolume;
  Controller^.Output := RegisterAudioOutput(Routines, Controller);
  if (Controller^.Output = nil) or not SetUpStream(Controller) then
    Exit;
  InitializeDeferredCall(Controller^.PeriodCall, @PeriodsElapsed, Controller);
  InitializeTimer(Controller^.PollTimer);
  Controller^.UsesInterrupts := ConnectPciMessageInterrupt(Pci, @HandleHdAudioInterrupt, Controller);
  if Controller^.UsesInterrupts then
    Write32(Controller^.Registers, RegisterInterruptControl,
      InterruptGlobalEnable or (LongWord(1) shl Controller^.StreamIndex));

  DebugBeginMessage;
  DebugWriteTag('audio');
  DebugWrite('HD Audio ');
  DebugWriteHex(Pci^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(Pci^.DeviceId, 4);
  DebugWrite(', codec ');
  DebugWriteDecimal(Controller^.Codec);
  DebugWrite(', converter ');
  DebugWriteDecimal(Controller^.Converter);
  DebugWrite(' to pin ');
  DebugWriteDecimal(Controller^.Pin);
  if Controller^.UsesInterrupts then
    DebugWriteLine(', interrupts by MSI')
  else
    DebugWriteLine(', polled');
  DebugEndMessage;
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
