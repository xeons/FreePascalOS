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
  HDMI audio on the Raspberry Pi 5 (BCM2712), written from Linux's
  vc4_hdmi.c and untested on the board. The Pi 5 has no analogue output:
  HDMI is its only built-in sound.

  The firmware brought the HDMI link up for its framebuffer, and it is
  left exactly as it is: no mode, PHY or clock is changed. Each port
  ("brcm,bcm2712-hdmi0", "-hdmi1", enabled by vc4-kms-v3d-pi5) gets,
  in steps that each say what failed and with which registers:

    1. resources: its register blocks, the tree's "dmas" (empty with the
       overlay's "noaudio": no audio then);
    2. clocks: the HDMI state machine clock from the firmware (VideoCore
       mailbox). If it is off nothing of the controller is read (Linux
       found that reading it then stalls the processor); the audio clock
       (108 MHz) from the tree;
    3. the DVP: the port's reset line (held: the firmware did not use
       the port) and its audio clock gate (turned on if off);
    4. hot plug: a display connected;
    5. the link: HDMI mode, not DVI (the firmware read the sink's EDID
       and chose; a DVI sink takes no audio), and the packet RAM on;
    6. the mode and the TMDS clock (Drivers.HdmiAudio.Link);
    7. N and CTS for 48 kHz (Drivers.HdmiAudio.Format);
    8. a 40-bit DMA channel (Drivers.Bcm2712Dma) and its buffer;
    9. the MAI (audio FIFO): sample clock, format, thresholds, channel
       map; the audio packets, clock regeneration and the audio
       InfoFrame;
   10. the DMA started, and checked to be moving at the sample rate.
  Then the port registers an output (/dev/audio, ...).

  The EDID is not read (the DDC needs an I2C driver this kernel lacks):
  the firmware's choice of HDMI over DVI stands for it, and the sink is
  assumed to take two-channel PCM, which every HDMI sink with audio
  does.

  The ring. The MAI takes IEC 60958 subframes, two 32-bit words a
  frame, so the driver plays its own copy of the mixer's ring: 48 slots
  of 1024 frames (8 KiB each, a period of the mixer's ring), a whole
  number of 192-frame channel status blocks (48 x 1024 = 256 x 192), so
  a slot's place says which frame of a block it starts with. The DMA
  runs round the slots from start-up on, playing silence when nothing
  plays: the sink keeps its audio locked and sounds start at once. When
  the mixer starts, its period 0 goes into the slot two ahead of the
  DMA, and period N into the Nth slot after that; when it writes a
  period (PeriodWritten) the driver converts it into its slot and
  cleans the slot out of the caches. A 10 ms timer follows the DMA: it
  tells the mixer where it is (AudioPeriodsElapsed) and silences each
  slot that played, so a mixer that falls behind leaves silence rather
  than old sound. The output has no volume control of its own: the mixer
  scales the samples.

  Kernel option hdmiaudio=off leaves HDMI audio alone; hdmiaudio=force
  goes on without the firmware's word that the HDMI clocks run (no
  mailbox, or it says 0), at the risk of a stall the watchdog ends.
}
unit Drivers.HdmiAudio;

{$mode objfpc}
{$pointermath on}

interface

{ Finds the HDMI ports and starts audio on each with a display; how many
  outputs it registered. }
function InitializeHdmiAudio: Integer;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Memory.KernelHeap,
  Kernel.Clock,
  Kernel.Scheduler,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.DeferredCalls,
  Kernel.Timers,
  Kernel.Options,
  Kernel.Arch.Cpu,
  DeviceTree.Blob,
  Firmware.DeviceTree,
  Io.Dma,
  Io.PlatformDevices,
  Io.AudioOutput,
  Drivers.VideoCoreMailbox,
  Drivers.Bcm2712Dma,
  Drivers.HdmiAudio.Format,
  Drivers.HdmiAudio.Port,
  Drivers.HdmiAudio.Link,
  Debug.Output;

const
  OptionHdmiAudio = 'hdmiaudio';
  MaximumPorts = 2;
  Channels = 2;
  ChannelMask = $3;
  SampleRate = AudioOutputRate;

  SlotCount = 48;
  SlotFrames = AudioPeriodFrames;
  SlotBytes = SlotFrames * 2 * 4;
  RingBytes = SlotCount * SlotBytes;
  { How far ahead of the DMA the mixer's first period goes. }
  StartAheadSlots = 2;
  TimerMilliseconds = 10;
  CheckMilliseconds = 100;
  PacketWaitNanoseconds = 100000000;

  { The MAI's FIFO thresholds (DREQ and panic, high and low), whose
    fields moved on the D0 stepping. }
  ThresholdPanic = $10;
  ThresholdDreq = $1C;

type
  PAudioPort = ^TAudioPort;
  TAudioPort = record
    Hdmi: THdmiPort;
    Link: THdmiLink;
    Regeneration: TAudioClockRegeneration;
    AudioClockHertz: QWord;
    Status: TChannelStatus;
    Channel: PDmaChannel;
    Buffer: TDmaBuffer;
    FifoBus: QWord;
    Output: PAudioOutput;
    { The slots, the timer and the mixer's place in them. }
    Lock: TSpinLock;
    Timer: TTimer;
    TimerCall: TDeferredCall;
    TimerArmed: Boolean;
    Running: Boolean;
    NeedBase: Boolean;
    Entered: Boolean;
    BaseSlot: LongWord;
    LastSlot: LongWord;
    LastOffset: LongWord;
    Dirty: array[0..SlotCount - 1] of Boolean;
    PeriodsWritten: QWord;
  end;

var
  Ports: array[0..MaximumPorts - 1] of PAudioPort;
  PortCount: Integer;
  SteppingD0: Boolean;
  { hdmiaudio=force: on without the firmware's word for the clocks. }
  ForcedOn: Boolean;

{ --- The slots ----------------------------------------------------------- }

function SlotAddress(Port: PAudioPort; Slot: LongWord): PLongWord;
begin
  Result := PLongWord(Port^.Buffer.Address + QWord(Slot) * SlotBytes);
end;

{ Slot Slot from Source (nil: silence), cleaned out of the caches. }
procedure FillSlot(Port: PAudioPort; Slot: LongWord; Source: PSmallInt);
begin
  PackSubframes(Source, SlotAddress(Port, Slot), SlotFrames, (Slot * SlotFrames) mod FramesPerBlock, Port^.Status);
  PrepareDmaToDevice(DmaChannelAttributes(Port^.Channel)^, SlotAddress(Port, Slot), SlotBytes);
end;

{ Where in the slots the DMA reads (bytes from the start). }
function DmaOffset(Port: PAudioPort): LongWord;
var
  Source: QWord;
begin
  Source := DmaChannelSourceAddress(Port^.Channel);
  if (Source >= Port^.Buffer.DeviceAddress) and (Source <= Port^.Buffer.DeviceAddress + RingBytes) then
  begin
    Port^.LastOffset := LongWord(Source - Port^.Buffer.DeviceAddress) mod RingBytes;
  end;
  Result := Port^.LastOffset;
end;

{ --- The output's routines ---------------------------------------------- }

procedure ArmTimer(Port: PAudioPort);
var
  PreviousLevel: TPriorityLevel;
  Arm: Boolean;
begin
  PreviousLevel := AcquireSpinLock(Port^.Lock);
  Arm := not Port^.TimerArmed;
  Port^.TimerArmed := True;
  { A timer that stopped left no slot holding sound behind the DMA: it
    starts following from where the DMA is now, not from where it was
    (which could lie past the slots just written). }
  if Arm then
    Port^.LastSlot := DmaOffset(Port) div SlotBytes;
  ReleaseSpinLock(Port^.Lock, PreviousLevel);
  if Arm then
    SetTimer(Port^.Timer, TimerMilliseconds, Port^.TimerCall);
end;

procedure ChooseBase(Port: PAudioPort);
begin
  Port^.BaseSlot := (DmaOffset(Port) div SlotBytes + StartAheadSlots) mod SlotCount;
  Port^.NeedBase := False;
end;

procedure StartPlaying(Context: Pointer);
var
  Port: PAudioPort;
begin
  Port := PAudioPort(Context);
  if Port^.NeedBase then
    ChooseBase(Port);
  Port^.Entered := False;
  Port^.Running := True;
  ArmTimer(Port);
  BeginPortLine(@Port^.Hdmi);
  DebugWrite('playing from slot ');
  DebugWriteDecimal(Port^.BaseSlot);
  DebugWrite(', DMA in slot ');
  DebugWriteDecimal(DmaOffset(Port) div SlotBytes);
  DebugWrite(', MAI_CTL 0x');
  DebugWriteHex(ReadHd(@Port^.Hdmi, Port^.Hdmi.Mai.Control), 8);
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure StopPlaying(Context: Pointer);
var
  Port: PAudioPort;
begin
  Port := PAudioPort(Context);
  Port^.Running := False;
  Port^.NeedBase := True;
  BeginPortLine(@Port^.Hdmi);
  DebugWrite('stopped after ');
  DebugWriteDecimal(Port^.PeriodsWritten);
  DebugWrite(' periods in all, MAI_CTL 0x');
  DebugWriteHex(ReadHd(@Port^.Hdmi, Port^.Hdmi.Mai.Control), 8);
  DebugWriteLine('');
  DebugEndMessage;
end;

{ Bytes of the mixer's ring played: the DMA's place from the base slot,
  as periods of the mixer's 16 (a slot holds one, at twice the bytes).
  0 until the DMA reaches the base slot. }
function PlayingPosition(Context: Pointer): LongWord;
var
  Port: PAudioPort;
  Relative: LongWord;
begin
  Port := PAudioPort(Context);
  Relative := (DmaOffset(Port) + RingBytes - Port^.BaseSlot * SlotBytes) mod RingBytes;
  if not Port^.Entered then
  begin
    if Relative >= StartAheadSlots * SlotBytes then
      Exit(0);
    Port^.Entered := True;
  end;
  Result := (Relative mod (AudioPeriodCount * SlotBytes)) div 2;
end;

procedure PeriodWritten(Context: Pointer; Index: QWord);
var
  Port: PAudioPort;
  Slot: LongWord;
  PreviousLevel: TPriorityLevel;
begin
  Port := PAudioPort(Context);
  PreviousLevel := AcquireSpinLock(Port^.Lock);
  if Port^.NeedBase then
    ChooseBase(Port);
  Slot := LongWord((Port^.BaseSlot + Index) mod SlotCount);
  FillSlot(Port, Slot, PSmallInt(Port^.Output^.Periods[Index mod AudioPeriodCount]));
  Port^.Dirty[Slot] := True;
  Inc(Port^.PeriodsWritten);
  ReleaseSpinLock(Port^.Lock, PreviousLevel);
end;

{ Every 10 ms while playing, or while played slots still hold sound. }
procedure FollowDma(Context: Pointer);
var
  Port: PAudioPort;
  Current: LongWord;
  PreviousLevel: TPriorityLevel;
  AnyDirty: Boolean;
  Slot: LongWord;
  KeepGoing: Boolean;
begin
  Port := PAudioPort(Context);
  Current := DmaOffset(Port) div SlotBytes;
  PreviousLevel := AcquireSpinLock(Port^.Lock);
  while Port^.LastSlot <> Current do
  begin
    if Port^.Dirty[Port^.LastSlot] then
    begin
      FillSlot(Port, Port^.LastSlot, nil);
      Port^.Dirty[Port^.LastSlot] := False;
    end;
    Port^.LastSlot := (Port^.LastSlot + 1) mod SlotCount;
  end;
  AnyDirty := False;
  for Slot := 0 to SlotCount - 1 do
    if Port^.Dirty[Slot] then
      AnyDirty := True;
  KeepGoing := Port^.Running or AnyDirty;
  Port^.TimerArmed := KeepGoing;
  ReleaseSpinLock(Port^.Lock, PreviousLevel);
  if Port^.Running then
    AudioPeriodsElapsed(Port^.Output);
  if KeepGoing then
    SetTimer(Port^.Timer, TimerMilliseconds, Port^.TimerCall);
end;

{ --- Setting the port up ------------------------------------------------- }

procedure WriteMegahertz(Hertz: QWord);
begin
  DebugWriteDecimal(Hertz div 1000000);
  if Hertz mod 1000000 <> 0 then
  begin
    DebugWrite('.');
    if (Hertz mod 1000000) div 1000 mod 10 = 0 then
      DebugWriteDecimal((Hertz mod 1000000) div 10000)
    else
    begin
      if (Hertz mod 1000000) < 100000 then
        DebugWrite('0');
      if (Hertz mod 1000000) < 10000 then
        DebugWrite('0');
      DebugWriteDecimal((Hertz mod 1000000) div 1000);
    end;
  end;
  DebugWrite(' MHz');
end;

{ Steps 2 and 3: the clocks are running and the port is out of reset. }
function CheckClocks(Port: PAudioPort): Boolean;
var
  Hdmi: PHdmiPort;
  Provider: LongInt;
  Cell: LongWord;
  StateMachineHertz: QWord;
  BvbHertz: QWord;
  FromFirmware: Boolean;
  PixelHertz: LongWord;
  Config: LongWord;
  Gate: LongWord;
begin
  Result := False;
  Hdmi := @Port^.Hdmi;
  if not VideoCoreMailboxIsAvailable and not ForcedOn then
  begin
    BeginPortFailure(Hdmi, 2, 'clocks');
    DebugWriteLine('no VideoCore mailbox to ask whether the HDMI clocks run: the controller is left alone ' +
      '(hdmiaudio=force goes on)');
    DebugEndMessage;
    Exit;
  end;
  StateMachineHertz := 0;
  if FindNamedClock(Hdmi^.Node, 'hdmi', Provider, Cell) then
    StateMachineHertz := ClockRateHertz(Provider, Cell, FromFirmware);
  BvbHertz := 0;
  if FindNamedClock(Hdmi^.Node, 'bvb', Provider, Cell) then
    BvbHertz := ClockRateHertz(Provider, Cell, FromFirmware);
  Port^.AudioClockHertz := 0;
  if FindNamedClock(Hdmi^.Node, 'audio', Provider, Cell) then
    Port^.AudioClockHertz := ClockRateHertz(Provider, Cell, FromFirmware);
  if not QueryClockRate(FirmwareClockPixel, PixelHertz) then
    PixelHertz := 0;

  BeginPortLine(Hdmi);
  DebugWrite('clocks: HDMI state machine ');
  DebugWriteDecimal(StateMachineHertz);
  DebugWrite(' Hz, pixel BVB ');
  DebugWriteDecimal(BvbHertz);
  DebugWrite(' Hz, firmware pixel clock ');
  DebugWriteDecimal(PixelHertz);
  DebugWrite(' Hz (from the firmware); audio ');
  DebugWriteDecimal(Port^.AudioClockHertz);
  DebugWriteLine(' Hz (from the tree)');
  DebugEndMessage;

  if (StateMachineHertz = 0) and not ForcedOn then
  begin
    BeginPortFailure(Hdmi, 2, 'clocks');
    DebugWriteLine('the HDMI state machine clock is off (no display at boot?): the controller is left alone ' +
      '(hdmiaudio=force goes on)');
    DebugEndMessage;
    Exit;
  end;
  if Port^.AudioClockHertz = 0 then
  begin
    BeginPortFailure(Hdmi, 2, 'clocks');
    DebugWriteLine('no rate for the "audio" clock in the tree (the MAI''s sample clock divides it)');
    DebugEndMessage;
    Exit;
  end;

  if Hdmi^.Dvp <> nil then
  begin
    Config := ReadDvp(Hdmi, DvpSoftwareInit);
    if (Hdmi^.ResetLine >= 0) and ((Config and (LongWord(1) shl Hdmi^.ResetLine)) <> 0) then
    begin
      BeginPortLine(Hdmi);
      DebugWrite('held in reset (DVP SW_INIT 0x');
      DebugWriteHex(Config, 8);
      DebugWriteLine('): the firmware did not use this port, no audio on it');
      DebugEndMessage;
      Exit;
    end;
    if Hdmi^.AudioClockGate >= 0 then
    begin
      Gate := LongWord(1) shl (DvpAudioClockGateFirstBit + LongWord(Hdmi^.AudioClockGate));
      Config := ReadDvp(Hdmi, DvpMiscConfig);
      if (Config and Gate) <> 0 then
      begin
        WriteDvp(Hdmi, DvpMiscConfig, Config and not Gate);
        BeginPortLine(Hdmi);
        DebugWrite('the audio clock''s gate was off (DVP MISC_CONFIG 0x');
        DebugWriteHex(Config, 8);
        DebugWrite('): turned on, now 0x');
        DebugWriteHex(ReadDvp(Hdmi, DvpMiscConfig), 8);
        DebugWriteLine('');
        DebugEndMessage;
      end;
    end;
  end
  else
  begin
    BeginPortLine(Hdmi);
    DebugWriteLine('no DVP node behind "resets": the reset line and the audio clock gate are not checked');
    DebugEndMessage;
  end;
  Result := True;
end;

{ Steps 4 and 5: a display, in HDMI mode, with the packet RAM on. }
function CheckLink(Port: PAudioPort): Boolean;
var
  Hdmi: PHdmiPort;
  Hotplug: LongWord;
  Scheduler: LongWord;
  PacketConfig: LongWord;
begin
  Result := False;
  Hdmi := @Port^.Hdmi;
  Hotplug := ReadCore(Hdmi, HdmiHotplug);
  if (Hotplug and HotplugConnected) = 0 then
  begin
    BeginPortLine(Hdmi);
    DebugWrite('no display connected (HOTPLUG 0x');
    DebugWriteHex(Hotplug, 8);
    DebugWriteLine('): no audio on this port');
    DebugEndMessage;
    Exit;
  end;
  Scheduler := ReadCore(Hdmi, HdmiSchedulerControl);
  if (Scheduler and SchedulerModeHdmi) = 0 then
  begin
    BeginPortFailure(Hdmi, 5, 'link');
    DebugWrite('the firmware drives the display as DVI (SCHEDULER_CONTROL 0x');
    DebugWriteHex(Scheduler, 8);
    DebugWriteLine('): a DVI sink takes no audio (hdmi_drive=2 in config.txt forces HDMI)');
    DebugEndMessage;
    Exit;
  end;
  PacketConfig := ReadCore(Hdmi, HdmiRamPacketConfig);
  if (PacketConfig and RamPacketEnable) = 0 then
  begin
    WriteCore(Hdmi, HdmiRamPacketConfig, PacketConfig or RamPacketEnable);
    BeginPortLine(Hdmi);
    DebugWrite('the packet RAM was off (RAM_PACKET_CONFIG 0x');
    DebugWriteHex(PacketConfig, 8);
    DebugWriteLine('): turned on for the audio InfoFrame');
    DebugEndMessage;
  end;
  Result := True;
end;

{ Steps 6 and 7: the mode, the TMDS clock, N and CTS. }
function MeasureLink(Port: PAudioPort): Boolean;
var
  Hdmi: PHdmiPort;
begin
  Result := False;
  Hdmi := @Port^.Hdmi;
  if not ReadHdmiLink(Hdmi, Port^.Link) then
  begin
    BeginPortFailure(Hdmi, 6, 'mode');
    DebugWrite('the timing registers hold no mode: HORZA 0x');
    DebugWriteHex(ReadCore(Hdmi, HdmiHorizontalA), 8);
    DebugWrite(' VERTA0 0x');
    DebugWriteHex(ReadCore(Hdmi, HdmiVerticalA0), 8);
    DebugWriteLine('');
    DebugEndMessage;
    Exit;
  end;
  if not ComputeAudioClockRegeneration(Port^.Link.TmdsHertz, SampleRate, Port^.Regeneration) then
  begin
    BeginPortFailure(Hdmi, 7, 'N and CTS');
    DebugWrite('no N/CTS for a TMDS clock of ');
    DebugWriteDecimal(Port^.Link.TmdsHertz);
    DebugWriteLine(' Hz');
    DebugEndMessage;
    Exit;
  end;

  BeginPortLine(Hdmi);
  DebugWrite('display connected, ');
  DebugWriteDecimal(Port^.Link.ActiveWidth);
  DebugWrite('x');
  DebugWriteDecimal(Port^.Link.ActiveHeight);
  DebugWrite(' (');
  DebugWriteDecimal(Port^.Link.TotalWidth);
  DebugWrite('x');
  DebugWriteDecimal(Port^.Link.TotalHeight);
  DebugWrite(' total) at ');
  DebugWriteDecimal(Port^.Link.RefreshMillihertz div 1000);
  DebugWrite('.');
  if Port^.Link.RefreshMillihertz mod 1000 < 100 then
    DebugWrite('0');
  if Port^.Link.RefreshMillihertz mod 1000 < 10 then
    DebugWrite('0');
  DebugWriteDecimal(Port^.Link.RefreshMillihertz mod 1000);
  if Port^.Link.RefreshMeasured then
    DebugWrite(' Hz (measured)')
  else
    DebugWrite(' Hz (ASSUMED: the frame counter did not move)');
  DebugWrite(', ');
  DebugWriteDecimal(Port^.Link.BitsPerPixel);
  DebugWrite('-bit colour, pixel clock ');
  if Port^.Regeneration.FromTable then
    WriteMegahertz(Port^.Regeneration.TableClockHertz * 24 div Port^.Link.BitsPerPixel)
  else
    WriteMegahertz(Port^.Link.PixelHertz);
  DebugWrite(' (');
  DebugWriteDecimal(Port^.Link.TmdsHertz);
  DebugWriteLine(' Hz from the timing and frame rate), audio on');
  DebugEndMessage;

  BeginPortLine(Hdmi);
  DebugWrite('N ');
  DebugWriteDecimal(Port^.Regeneration.N);
  DebugWrite(' CTS ');
  DebugWriteDecimal(Port^.Regeneration.Cts);
  DebugWrite(' for ');
  DebugWriteDecimal(SampleRate);
  if Port^.Regeneration.FromTable then
  begin
    DebugWrite(' Hz (the HDMI table''s, TMDS clock ');
    DebugWriteDecimal(Port^.Regeneration.TableClockHertz);
    DebugWriteLine(' Hz)');
  end
  else
    DebugWriteLine(' Hz (computed: not a clock of the HDMI table)');
  DebugEndMessage;
  Result := True;
end;

{ Step 8: the DMA channel and the slots, all silence. }
function PrepareDma(Port: PAudioPort; ControllerPhandle, RequestCell: LongWord): Boolean;
var
  Hdmi: PHdmiPort;
  Slot: LongWord;
begin
  Result := False;
  Hdmi := @Port^.Hdmi;
  if not RequestDmaChannel(ControllerPhandle, RequestCell, Hdmi^.Name, Port^.Channel) then
    Exit;
  if not AllocateDmaBuffer(DmaChannelAttributes(Port^.Channel)^, RingBytes, DmaStreaming, Port^.Buffer) then
  begin
    BeginPortFailure(Hdmi, 8, 'DMA');
    DebugWrite('no ');
    DebugWriteDecimal(RingBytes div 1024);
    DebugWriteLine(' KiB of contiguous memory the DMA reaches for the slots');
    DebugEndMessage;
    Exit;
  end;
  if not TranslateDmaAddress(DmaChannelAttributes(Port^.Channel)^, Hdmi^.HdPhysical + Hdmi^.Mai.Data, 4,
    Port^.FifoBus) then
  begin
    BeginPortFailure(Hdmi, 8, 'DMA');
    DebugWrite('the DMA cannot reach the MAI data register at 0x');
    DebugWriteHex(Hdmi^.HdPhysical + Hdmi^.Mai.Data, 1);
    DebugWriteLine('');
    DebugEndMessage;
    Exit;
  end;
  BuildChannelStatus(SampleRate, Port^.Status);
  Slot := 0;
  while Slot < SlotCount do
  begin
    FillSlot(Port, Slot, nil);
    Inc(Slot);
  end;
  Result := True;
end;

{ Step 9, part: the audio InfoFrame into packet 4 of the packet RAM. }
function SendAudioInfoFrame(Port: PAudioPort): Boolean;
var
  Hdmi: PHdmiPort;
  Frame: TAudioInfoFrame;
  Words: TPacketRamWords;
  Index: LongWord;
  Bit: LongWord;
  Deadline: QWord;
begin
  Hdmi := @Port^.Hdmi;
  Bit := LongWord(1) shl AudioInfoFramePacket;
  { Stopped and idle before it is rewritten. }
  WriteCore(Hdmi, HdmiRamPacketConfig, ReadCore(Hdmi, HdmiRamPacketConfig) and not Bit);
  Deadline := ClockNanoseconds + PacketWaitNanoseconds;
  while ((ReadCore(Hdmi, HdmiRamPacketStatus) and Bit) <> 0) and (ClockNanoseconds < Deadline) do
    CpuRelax;
  BuildAudioInfoFrame(Channels, Frame);
  InfoFrameToPacketWords(Frame, Words);
  for Index := 0 to PacketRamWords - 1 do
    WritePacketWord(Hdmi, AudioInfoFramePacket * PacketStride + Index * 4, Words[Index]);
  WriteCore(Hdmi, HdmiRamPacketConfig, ReadCore(Hdmi, HdmiRamPacketConfig) or Bit);
  Deadline := ClockNanoseconds + PacketWaitNanoseconds;
  while ((ReadCore(Hdmi, HdmiRamPacketStatus) and Bit) = 0) and (ClockNanoseconds < Deadline) do
    CpuRelax;
  Result := (ReadCore(Hdmi, HdmiRamPacketStatus) and Bit) <> 0;
end;

function MaiThreshold: LongWord;
begin
  if SteppingD0 then
    Result := (LongWord(ThresholdPanic) shl 23) or (LongWord(ThresholdPanic) shl 15) or
      (LongWord(ThresholdDreq) shl 7) or LongWord(ThresholdDreq)
  else
    Result := (LongWord(ThresholdPanic) shl 24) or (LongWord(ThresholdPanic) shl 16) or
      (LongWord(ThresholdDreq) shl 8) or LongWord(ThresholdDreq);
end;

{ Step 9: the MAI and the audio packets, as Linux's startup and prepare
  do; the video side is not touched. }
function ProgramAudio(Port: PAudioPort): Boolean;
var
  Hdmi: PHdmiPort;
  ClockN: LongWord;
  ClockM: LongWord;
  InfoFrameSent: Boolean;
begin
  Result := False;
  Hdmi := @Port^.Hdmi;
  if not ComputeMaiSampleClock(LongWord(Port^.AudioClockHertz), SampleRate, ClockN, ClockM) then
  begin
    BeginPortFailure(Hdmi, 9, 'MAI');
    DebugWrite('no sample clock fraction of ');
    DebugWriteDecimal(Port^.AudioClockHertz);
    DebugWriteLine(' Hz');
    DebugEndMessage;
    Exit;
  end;
  WriteHd(Hdmi, Hdmi^.Mai.Control, MaiControlReset or MaiControlFlush or MaiControlDataLate or
    MaiControlErrorEmpty or MaiControlErrorFull);
  WriteHd(Hdmi, Hdmi^.Mai.SampleClock, (ClockN shl MaiSampleClockNShift) or (ClockM - 1));
  WriteHd(Hdmi, Hdmi^.Mai.Control, (Channels shl MaiControlChannelCountShift) or MaiControlWholeSample or
    MaiControlChannelAlign or MaiControlEnable);
  WriteHd(Hdmi, Hdmi^.Mai.Format, (MaiSampleRateCode(SampleRate) shl MaiFormatSampleRateShift) or
    (MaiFormatPcm shl MaiFormatAudioFormatShift));
  WriteHd(Hdmi, Hdmi^.Mai.Threshold, MaiThreshold);
  WriteCore(Hdmi, HdmiMaiConfig, MaiConfigBitReverse or MaiConfigFormatReverse or ChannelMask);
  WriteCore(Hdmi, HdmiMaiChannelMap, MaiChannelMap(ChannelMask));
  WriteCore(Hdmi, HdmiAudioPacketConfig, AudioPacketZeroDataOnSampleFlat or AudioPacketZeroDataOnInactiveChannels or
    (BFrameIdentifier shl AudioPacketBFrameIdentifierShift) or ChannelMask);
  WriteCore(Hdmi, HdmiClockRegenerationConfig, ClockRegenerationExternalCts or
    (Port^.Regeneration.N and ClockRegenerationNMask));
  WriteCore(Hdmi, HdmiCts0, Port^.Regeneration.Cts);
  WriteCore(Hdmi, HdmiCts1, Port^.Regeneration.Cts);
  InfoFrameSent := SendAudioInfoFrame(Port);

  BeginPortLine(Hdmi);
  DebugWrite('MAI sample clock ');
  DebugWriteDecimal(ClockN);
  DebugWrite('/');
  DebugWriteDecimal(ClockM);
  DebugWrite(' of ');
  DebugWriteDecimal(Port^.AudioClockHertz);
  DebugWrite(' Hz, ');
  if SteppingD0 then
    DebugWrite('D0 thresholds, ')
  else
    DebugWrite('C1 thresholds, ');
  if InfoFrameSent then
    DebugWrite('audio InfoFrame sent;')
  else
    DebugWrite('audio InfoFrame NOT sending (packet 4 never started);');
  WritePortRegisters(Hdmi);
  DebugWriteLine('');
  DebugEndMessage;
  Result := True;
end;

{ Step 10: the DMA is started and must move at about the sample rate. }
function StartAndCheckDma(Port: PAudioPort): Boolean;
var
  Hdmi: PHdmiPort;
  First: LongWord;
  Last: LongWord;
  StartTime: QWord;
  Elapsed: QWord;
  Frames: QWord;
  Rate: QWord;
begin
  Result := False;
  Hdmi := @Port^.Hdmi;
  if not StartCyclicDmaToDevice(Port^.Channel, Port^.Buffer.DeviceAddress, SlotBytes, SlotCount, Port^.FifoBus) then
  begin
    BeginPortFailure(Hdmi, 10, 'DMA start');
    DebugWriteLine('the channel would not take the control blocks');
    DebugEndMessage;
    Exit;
  end;
  First := DmaOffset(Port);
  StartTime := ClockNanoseconds;
  SleepMilliseconds(CheckMilliseconds);
  Last := DmaOffset(Port);
  Elapsed := ClockNanoseconds - StartTime;
  Frames := ((Last + RingBytes - First) mod RingBytes) div 8;
  Rate := 0;
  if Elapsed > 0 then
    Rate := Frames * 1000000000 div Elapsed;
  if Rate < SampleRate div 2 then
  begin
    BeginPortFailure(Hdmi, 10, 'DMA moving');
    DebugWriteDecimal(Frames);
    DebugWrite(' frames in ');
    DebugWriteDecimal(Elapsed div 1000000);
    DebugWrite(' ms, ');
    WriteDmaChannelState(Port^.Channel);
    WritePortRegisters(Hdmi);
    DebugWriteLine('');
    DebugEndMessage;
    StopDma(Port^.Channel);
    WriteHd(Hdmi, Hdmi^.Mai.Control, MaiControlReset);
    WriteHd(Hdmi, Hdmi^.Mai.Control, MaiControlFlush);
    Exit;
  end;
  BeginPortLine(Hdmi);
  DebugWrite('DMA moving: ');
  DebugWriteDecimal(Frames);
  DebugWrite(' frames in ');
  DebugWriteDecimal(Elapsed div 1000000);
  DebugWrite(' ms = ');
  DebugWriteDecimal(Rate);
  DebugWrite(' Hz (');
  DebugWriteDecimal(SampleRate);
  DebugWrite(' expected), MAI_CTL 0x');
  DebugWriteHex(ReadHd(Hdmi, Hdmi^.Mai.Control), 8);
  DebugWriteLine('');
  DebugEndMessage;
  Result := True;
end;

function RegisterOutput(Port: PAudioPort): Boolean;
var
  Routines: TAudioDriverRoutines;
  Number: Integer;
begin
  Number := AudioOutputCount;
  InitializeSpinLock(Port^.Lock);
  InitializeTimer(Port^.Timer);
  InitializeDeferredCall(Port^.TimerCall, @FollowDma, Port);
  Port^.NeedBase := True;
  Port^.LastSlot := DmaOffset(Port) div SlotBytes;
  Routines.Start := @StartPlaying;
  Routines.Stop := @StopPlaying;
  Routines.Position := @PlayingPosition;
  Routines.SetVolume := nil;
  Routines.Kind := AudioOutputKindHdmi;
  Routines.PeriodWritten := @PeriodWritten;
  Port^.Output := RegisterAudioOutput(Routines, Port);
  Result := Port^.Output <> nil;
  DebugBeginMessage;
  DebugWriteTag('audio');
  if Result then
  begin
    DebugWrite('/dev/audio');
    if Number > 0 then
      DebugWriteDecimal(Number);
    DebugWrite(': HDMI (');
    DebugWrite(Port^.Hdmi.Name);
    DebugWrite('), ');
    DebugWriteDecimal(Channels);
    DebugWrite(' channels, ');
    DebugWriteDecimal(SampleRate);
    DebugWriteLine(' Hz, volume by the mixer');
  end
  else
  begin
    DebugWrite('HDMI (');
    DebugWrite(Port^.Hdmi.Name);
    DebugWriteLine('): FAILED to register the output (memory, or four outputs already)');
  end;
  DebugEndMessage;
end;

{ Step 1, and the rest in order. }
procedure BringUpPort(Port: PAudioPort);
var
  Hdmi: PHdmiPort;
  Prop: TDeviceTreeProperty;
begin
  Hdmi := @Port^.Hdmi;
  if not FindProperty(SystemDeviceTree^, Hdmi^.Node, 'dmas', Prop) or (PropertyCellCount(Prop) < 2) then
  begin
    BeginPortLine(Hdmi);
    DebugWriteLine('no "dmas" in the tree (the overlay''s noaudio?): no audio on this port');
    DebugEndMessage;
    Exit;
  end;
  if not MapPortRegisters(Hdmi) then
    Exit;
  if not CheckClocks(Port) or not CheckLink(Port) or not MeasureLink(Port) then
    Exit;
  if not PrepareDma(Port, PropertyCell(Prop, 0), PropertyCell(Prop, 1)) then
    Exit;
  if not ProgramAudio(Port) or not StartAndCheckDma(Port) then
    Exit;
  RegisterOutput(Port);
end;

function ProbePort(Device: PPlatformDevice): Boolean;
var
  Port: PAudioPort;
begin
  Result := False;
  if (PortCount = MaximumPorts) or (Device^.DeviceTreeNode = NoDeviceTreeNode) then
    Exit;
  Port := PAudioPort(AllocateZeroedKernelMemory(SizeOf(TAudioPort)));
  if Port = nil then
    Exit;
  Port^.Hdmi.Device := Device;
  Port^.Hdmi.Node := Device^.DeviceTreeNode;
  if PlatformDeviceHasId(Device, 'brcm,bcm2712-hdmi1') then
  begin
    Port^.Hdmi.Name := 'hdmi1';
    Port^.Hdmi.Number := 1;
    Port^.Hdmi.Mai := MaiOffsetsHdmi1;
  end
  else
  begin
    Port^.Hdmi.Name := 'hdmi0';
    Port^.Hdmi.Number := 0;
    Port^.Hdmi.Mai := MaiOffsetsHdmi0;
  end;
  Ports[PortCount] := Port;
  Inc(PortCount);
  Result := True;
end;

const
  HdmiIds: array[0..2] of PChar = ('brcm,bcm2712-hdmi0', 'brcm,bcm2712-hdmi1', nil);
  HdmiDriver: TPlatformDriver = (
    Name: 'hdmi-audio';
    Ids: @HdmiIds[0];
    Probe: @ProbePort);

{ hdmiaudio=off or 0: True. hdmiaudio=force sets ForcedOn. }
function OptionTurnsItOff: Boolean;
var
  Value: array[0..15] of Char;
begin
  Result := False;
  if not GetKernelOptionValue(OptionHdmiAudio, @Value[0], SizeOf(Value)) then
    Exit;
  Result := TextIsEqual(@Value[0], 'off') or TextIsEqual(@Value[0], '0');
  ForcedOn := TextIsEqual(@Value[0], 'force');
end;

function InitializeHdmiAudio: Integer;
var
  Index: Integer;
begin
  Result := 0;
  if not DeviceTreeIsAvailable then
    Exit;
  BindPlatformDriver(HdmiDriver);
  if PortCount = 0 then
    Exit;
  if OptionTurnsItOff then
  begin
    DebugBeginMessage;
    DebugWriteTag('hdmi-audio');
    DebugWriteLine('hdmiaudio=off: HDMI audio left alone');
    DebugEndMessage;
    Exit;
  end;
  SteppingD0 := (FindCompatibleNode(SystemDeviceTree^, NoNode, 'brcm,bcm2712d0-vc6') <> NoNode) or
    (FindCompatibleNode(SystemDeviceTree^, NoNode, 'brcm,bcm2712d0-pinctrl') <> NoNode);
  for Index := 0 to PortCount - 1 do
  begin
    BringUpPort(Ports[Index]);
    if Ports[Index]^.Output <> nil then
      Inc(Result);
  end;
end;

end.
