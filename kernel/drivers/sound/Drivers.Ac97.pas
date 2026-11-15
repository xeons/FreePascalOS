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
  AC'97 audio controllers (Intel ICH and compatibles, PCI class 04h,
  subclass 01h): sound output.

  The controller has two sets of I/O ports: the codec's mixer (BAR 0:
  volumes, rates) and the bus master (BAR 1), whose PCM out box plays a
  list of up to 32 buffer descriptors. The list here describes the
  audio framework's ring (Io.AudioOutput) twice over: entry N and entry
  N + 16 are the same period. The box stops when it reaches its last
  valid entry, so the driver keeps moving the last valid entry on to the
  one before the current entry. The codec plays at its fixed 48 kHz, as
  the framework mixes.

  Descriptors hold 32-bit addresses, so the list and the ring are kept
  below 4 GiB. The controller signals on its PCI interrupt line (routed
  by the ACPI namespace, Io.PciLineInterrupts) as each buffer completes;
  the line is level triggered and may be shared, so the handler checks
  the box's status and clears it. Without routing, a timer asks where
  the box is.
}
unit Drivers.Ac97;

{$mode objfpc}
{$pointermath on}

interface

{ Starts every AC'97 controller; returns how many. }
function InitializeAc97Controllers: Integer;

implementation

uses
  Io.PowerManagement,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.KernelHeap,
  Kernel.Arch.Cpu,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.Clock,
  Kernel.Arch.TrapFrame,
  Hal.PortIo,
  Io.Pci,
  Io.PciLineInterrupts,
  Io.AudioOutput,
  Debug.Output;

const
  PciClassMultimedia = $04;
  PciSubclassAudioController = $01;

  { The codec's mixer (BAR 0). }
  MixerReset = $00;
  MixerMasterVolume = $02;
  MixerPcmOutVolume = $18;
  { Bit 15 mutes; the attenuation of each side is in bits 8-12 and 0-4,
    1.5 dB a step. }
  VolumeMute = $8000;
  VolumeSteps = 31;
  PcmOutUnity = $0808;

  { The bus master (BAR 1). }
  PcmOutBox = $10;
  BoxDescriptorList = $00;
  BoxCurrentIndex = $04;
  BoxLastValidIndex = $05;
  BoxStatus = $06;
  BoxControl = $0B;
  BoxPositionInBuffer = $08;
  GlobalControl = $2C;
  GlobalStatus = $30;

  ControlRun = $01;
  ControlResetRegisters = $02;
  ControlInterruptOnCompletion = $10;
  GlobalControlInterruptEnable = $01;
  StatusHalted = $01;
  { Written back to clear: last valid entry, completion, FIFO error. }
  StatusClearBits = $1C;
  GlobalControlColdResetOff = $02;
  GlobalStatusPrimaryReady = $100;

  DescriptorCount = 32;
  DescriptorInterruptOnCompletion = LongWord(1) shl 31;
  { Samples, not frames: two a frame. }
  SamplesPerPeriod = AudioPeriodBytes div 2;
  FourGibibytes = QWord($100000000);
  PollIntervalMilliseconds = 10;

type
  TBufferDescriptor = packed record
    Address: LongWord;
    Control: LongWord;
  end;
  PBufferDescriptor = ^TBufferDescriptor;

  PAc97Controller = ^TAc97Controller;
  TAc97Controller = record
    Pci: PPciDevice;
    MixerPorts: Word;
    BusMasterPorts: Word;
    Descriptors: PBufferDescriptor;
    DescriptorsPhysical: QWord;
    Output: PAudioOutput;
    IsRunning: Boolean;
    UsesInterrupts: Boolean;
    PeriodCall: TDeferredCall;
    PollTimer: TTimer;
  end;

function BoxPort(Controller: PAc97Controller; Register: Word): Word;
begin
  Result := Controller^.BusMasterPorts + PcmOutBox + Register;
end;

{ --- The PCM out box ----------------------------------------------------- }

procedure ResetBox(Controller: PAc97Controller);
var
  Deadline: QWord;
begin
  WritePortByte(BoxPort(Controller, BoxControl), 0);
  Deadline := ClockTickCount + MillisecondsToTicks(100);
  while ((ReadPortWord(BoxPort(Controller, BoxStatus)) and StatusHalted) = 0) and
        (ClockTickCount < Deadline) do
    CpuRelax;
  WritePortByte(BoxPort(Controller, BoxControl), ControlResetRegisters);
  Deadline := ClockTickCount + MillisecondsToTicks(100);
  while ((ReadPortByte(BoxPort(Controller, BoxControl)) and ControlResetRegisters) <> 0) and
        (ClockTickCount < Deadline) do
    CpuRelax;
  WritePortLongWord(BoxPort(Controller, BoxDescriptorList), LongWord(Controller^.DescriptorsPhysical));
end;

{ Keeps the box from reaching its last valid entry: that is always the
  one just before the current one. }
procedure MoveLastValid(Controller: PAc97Controller);
var
  Current: Byte;
begin
  Current := ReadPortByte(BoxPort(Controller, BoxCurrentIndex)) and (DescriptorCount - 1);
  WritePortByte(BoxPort(Controller, BoxLastValidIndex), (Current + DescriptorCount - 1) and (DescriptorCount - 1));
  WritePortWord(BoxPort(Controller, BoxStatus), StatusClearBits);
end;

procedure StartPlaying(Context: Pointer);
var
  Controller: PAc97Controller;
begin
  Controller := PAc97Controller(Context);
  ResetBox(Controller);
  WritePortByte(BoxPort(Controller, BoxLastValidIndex), DescriptorCount - 1);
  Controller^.IsRunning := True;
  if Controller^.UsesInterrupts then
    WritePortByte(BoxPort(Controller, BoxControl), ControlRun or ControlInterruptOnCompletion)
  else
  begin
    WritePortByte(BoxPort(Controller, BoxControl), ControlRun);
    SetTimer(Controller^.PollTimer, PollIntervalMilliseconds, Controller^.PeriodCall);
  end;
end;

procedure StopPlaying(Context: Pointer);
var
  Controller: PAc97Controller;
begin
  Controller := PAc97Controller(Context);
  Controller^.IsRunning := False;
  { Back at the start of the ring for the next start. }
  ResetBox(Controller);
end;

function PlayingPosition(Context: Pointer): LongWord;
var
  Controller: PAc97Controller;
  Current: LongWord;
  Left: LongWord;
begin
  Controller := PAc97Controller(Context);
  Current := ReadPortByte(BoxPort(Controller, BoxCurrentIndex)) mod AudioPeriodCount;
  { Samples still to play in the current entry. }
  Left := ReadPortWord(BoxPort(Controller, BoxPositionInBuffer));
  if Left > SamplesPerPeriod then
    Left := SamplesPerPeriod;
  Result := (Current * AudioPeriodBytes + (SamplesPerPeriod - Left) * 2) mod (AudioPeriodCount * AudioPeriodBytes);
end;

procedure SetVolume(Context: Pointer; Percent: LongWord);
var
  Controller: PAc97Controller;
  Attenuation: LongWord;
begin
  Controller := PAc97Controller(Context);
  if Percent = 0 then
  begin
    WritePortWord(Controller^.MixerPorts + MixerMasterVolume, VolumeMute);
    Exit;
  end;
  Attenuation := VolumeSteps * (100 - Percent) div 100;
  WritePortWord(Controller^.MixerPorts + MixerMasterVolume, Word((Attenuation shl 8) or Attenuation));
end;

{ The line fired: if the box finished a buffer, the status is cleared
  (the line is level triggered) and the rest is deferred. }
procedure HandleAc97Interrupt(Frame: PTrapFrame; Context: Pointer);
var
  Controller: PAc97Controller;
  Status: Word;
begin
  Controller := PAc97Controller(Context);
  Status := ReadPortWord(BoxPort(Controller, BoxStatus)) and StatusClearBits;
  if Status = 0 then
    Exit;
  WritePortWord(BoxPort(Controller, BoxStatus), Status);
  QueueDeferredCall(Controller^.PeriodCall);
end;

{ Deferred call from the interrupt or the poll timer. }
procedure PeriodsElapsed(Context: Pointer);
var
  Controller: PAc97Controller;
begin
  Controller := PAc97Controller(Context);
  if not Controller^.IsRunning then
    Exit;
  MoveLastValid(Controller);
  AudioPeriodsElapsed(Controller^.Output);
  if Controller^.IsRunning and not Controller^.UsesInterrupts then
    SetTimer(Controller^.PollTimer, PollIntervalMilliseconds, Controller^.PeriodCall);
end;

{ --- Starting a controller -------------------------------------------------------- }

function ResetCodec(Controller: PAc97Controller): Boolean;
var
  Deadline: QWord;
begin
  WritePortLongWord(Controller^.BusMasterPorts + GlobalControl, GlobalControlColdResetOff);
  Deadline := ClockTickCount + MillisecondsToTicks(200);
  while (ReadPortLongWord(Controller^.BusMasterPorts + GlobalStatus) and GlobalStatusPrimaryReady) = 0 do
    if ClockTickCount > Deadline then
      Exit(False);
  WritePortWord(Controller^.MixerPorts + MixerReset, 1);
  WritePortWord(Controller^.MixerPorts + MixerPcmOutVolume, PcmOutUnity);
  Result := True;
end;

{ The list: entry N plays period N mod 16, all of it, and says so. }
procedure DescribeRing(Controller: PAc97Controller);
var
  Index: Integer;
begin
  for Index := 0 to DescriptorCount - 1 do
  begin
    Controller^.Descriptors[Index].Address := LongWord(Controller^.Output^.PeriodsPhysical[Index mod AudioPeriodCount]);
    Controller^.Descriptors[Index].Control := DescriptorInterruptOnCompletion or SamplesPerPeriod;
  end;
end;

{ --- Suspend to RAM ---------------------------------------------------------- }

{ Waking reset the controller and codec: the codec out of reset, the
  box given its list again, and the interrupts as they were. }
procedure ResumeController(Context: Pointer);
var
  Controller: PAc97Controller;
begin
  Controller := PAc97Controller(Context);
  Controller^.IsRunning := False;
  if not ResetCodec(Controller) then
    Exit;
  ResetBox(Controller);
  if Controller^.UsesInterrupts then
    WritePortLongWord(Controller^.BusMasterPorts + GlobalControl,
      ReadPortLongWord(Controller^.BusMasterPorts + GlobalControl) or GlobalControlInterruptEnable);
end;

function StartController(Pci: PPciDevice): Boolean;
var
  Controller: PAc97Controller;
  MixerBar: TPciBar;
  BusMasterBar: TPciBar;
  Routines: TAudioDriverRoutines;
begin
  Result := False;
  if not PciReadBar(Pci, 0, MixerBar) or not MixerBar.IsIoPort or not PciReadBar(Pci, 1, BusMasterBar) or
     not BusMasterBar.IsIoPort then
    Exit;
  Controller := PAc97Controller(AllocateZeroedKernelMemory(SizeOf(TAc97Controller)));
  if Controller = nil then
    Exit;
  Controller^.Pci := Pci;
  Controller^.MixerPorts := Word(MixerBar.PhysicalAddress);
  Controller^.BusMasterPorts := Word(BusMasterBar.PhysicalAddress);
  PciEnableDevice(Pci, True);
  if not ResetCodec(Controller) then
    Exit;
  Controller^.DescriptorsPhysical := AllocateZeroedPhysicalPageBelow(FourGibibytes - 1, PageUsageGeneral);
  if Controller^.DescriptorsPhysical = 0 then
    Exit;
  Controller^.Descriptors := PBufferDescriptor(PhysicalToVirtual(Controller^.DescriptorsPhysical));

  Routines.Start := @StartPlaying;
  Routines.Stop := @StopPlaying;
  Routines.Position := @PlayingPosition;
  Routines.SetVolume := @SetVolume;
  InitializeDeferredCall(Controller^.PeriodCall, @PeriodsElapsed, Controller);
  InitializeTimer(Controller^.PollTimer);
  Controller^.Output := RegisterAudioOutput(Routines, Controller, FourGibibytes - 1);
  if Controller^.Output = nil then
    Exit;
  DescribeRing(Controller);
  ResetBox(Controller);
  Controller^.UsesInterrupts := ConnectPciLineInterrupt(Pci, @HandleAc97Interrupt, Controller);
  if Controller^.UsesInterrupts then
    WritePortLongWord(Controller^.BusMasterPorts + GlobalControl,
      ReadPortLongWord(Controller^.BusMasterPorts + GlobalControl) or GlobalControlInterruptEnable);
  RegisterPowerHandler('AC''97', PowerStageDevices, nil, @ResumeController, Controller);

  DebugBeginMessage;
  DebugWriteTag('audio');
  DebugWrite('AC''97 ');
  DebugWriteHex(Pci^.VendorId, 4);
  DebugWrite(':');
  DebugWriteHex(Pci^.DeviceId, 4);
  if Controller^.UsesInterrupts then
    DebugWriteLine(', interrupts by line')
  else
    DebugWriteLine(', polled');
  DebugEndMessage;
  Result := True;
end;

function InitializeAc97Controllers: Integer;
var
  Index: Integer;
  Pci: PPciDevice;
begin
  Result := 0;
  for Index := 0 to PciDeviceCount - 1 do
  begin
    Pci := PciDeviceAt(Index);
    if (Pci^.ClassCode = PciClassMultimedia) and (Pci^.Subclass = PciSubclassAudioController) and
       StartController(Pci) then
      Inc(Result);
  end;
end;

end.
