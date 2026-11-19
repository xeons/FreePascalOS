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
  One HDMI port of the BCM2712 (the tree's "brcm,bcm2712-hdmi0" and
  "-hdmi1"), as the audio driver sees it: its register blocks found by
  "reg-names", the registers audio touches, the clocks and the reset
  line from the tree, and the log lines' shape.

  Register blocks (the node has nine; the platform device list keeps
  eight, so they are read from the node itself):

    "hdmi"    the HDMI core (10_7C70_1400 for hdmi0, 10_7C70_6400 for
              hdmi1): the audio packets, clock regeneration, the
              scheduler, the timing, hot plug
    "packet"  the packet RAM: InfoFrames, 24h bytes each, packet N (the
              InfoFrame type - 80h) at N * 24h
    "hd"      shared by both ports (10_7C72_0000): each port's MAI (the
              audio FIFO) and frame counter, hdmi1's 20h further on

  Offsets and bits from Linux's vc4_hdmi_regs.h and vc4_regs.h (the
  BCM2712 "vc6" tables).
}
unit Drivers.HdmiAudio.Port;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.PlatformDevices;

const
  { The HDMI core block. }
  HdmiMaiChannelMap = $0A4;
  HdmiMaiConfig = $0A8;
  HdmiAudioPacketConfig = $0C0;
  HdmiRamPacketConfig = $0C4;
  HdmiRamPacketStatus = $0CC;
  HdmiClockRegenerationConfig = $0D0;
  HdmiCts0 = $0D4;
  HdmiCts1 = $0D8;
  HdmiSchedulerControl = $0E8;
  HdmiHorizontalA = $0EC;
  HdmiHorizontalB = $0F0;
  HdmiVerticalA0 = $0F4;
  HdmiVerticalB0 = $0F8;
  HdmiMiscControl = $114;
  HdmiGeneralControlPacketConfig = $194;
  HdmiGeneralControlPacketWord1 = $198;
  HdmiHotplug = $1C8;

  HotplugConnected = LongWord(1) shl 0;
  SchedulerModeHdmi = LongWord(1) shl 0;
  SchedulerHdmiActive = LongWord(1) shl 1;
  RamPacketEnable = LongWord(1) shl 16;
  AudioInfoFramePacket = 4;
  PacketStride = $24;

  MaiConfigBitReverse = LongWord(1) shl 26;
  MaiConfigFormatReverse = LongWord(1) shl 27;

  AudioPacketZeroDataOnSampleFlat = LongWord(1) shl 29;
  AudioPacketZeroDataOnInactiveChannels = LongWord(1) shl 24;
  AudioPacketBFrameIdentifierShift = 10;
  { The B frame identifier: the preamble value of a block's first frame. }
  BFrameIdentifier = 8;

  ClockRegenerationExternalCts = LongWord(1) shl 24;
  ClockRegenerationNMask = $FFFFF;

  GeneralControlPacketEnable = LongWord(1) shl 31;

  { The MAI (per port in the "hd" block). }
  MaiControlReset = LongWord(1) shl 0;
  MaiControlErrorFull = LongWord(1) shl 1;
  MaiControlErrorEmpty = LongWord(1) shl 2;
  MaiControlEnable = LongWord(1) shl 3;
  MaiControlChannelCountShift = 4;
  MaiControlParityEnable = LongWord(1) shl 8;
  MaiControlFlush = LongWord(1) shl 9;
  MaiControlEmpty = LongWord(1) shl 10;
  MaiControlFull = LongWord(1) shl 11;
  MaiControlWholeSample = LongWord(1) shl 12;
  MaiControlChannelAlign = LongWord(1) shl 13;
  MaiControlBusy = LongWord(1) shl 14;
  MaiControlDataLate = LongWord(1) shl 15;

  MaiFormatSampleRateShift = 8;
  MaiFormatAudioFormatShift = 16;
  MaiFormatPcm = 2;

  MaiSampleClockNShift = 8;

  { The DVP block (the "brcm,brcm2711-dvp" node): the ports' reset lines
    and the gates of their 108 MHz audio clocks (a set bit stops it). }
  DvpSoftwareInit = $04;
  DvpMiscConfig = $08;
  DvpAudioClockGateFirstBit = 3;

type
  { Where each port's MAI registers are in the "hd" block. }
  TMaiOffsets = record
    Control: LongWord;
    Threshold: LongWord;
    Format: LongWord;
    Data: LongWord;
    SampleClock: LongWord;
    FrameCount: LongWord;
  end;

  PHdmiPort = ^THdmiPort;
  THdmiPort = record
    Name: PChar;
    Number: LongWord;
    Device: PPlatformDevice;
    Node: LongInt;
    Core: PByte;
    Packet: PByte;
    Hd: PByte;
    HdPhysical: QWord;
    Dvp: PByte;
    Mai: TMaiOffsets;
    { The tree's reset line of the port (a bit of the DVP's
      SW_INIT) and its audio clock (a gate of the DVP), -1 if unknown. }
    ResetLine: LongInt;
    AudioClockGate: LongInt;
  end;

const
  MaiOffsetsHdmi0: TMaiOffsets = (Control: $10; Threshold: $14; Format: $18; Data: $1C; SampleClock: $20;
    FrameCount: $60);
  MaiOffsetsHdmi1: TMaiOffsets = (Control: $30; Threshold: $34; Format: $38; Data: $3C; SampleClock: $40;
    FrameCount: $64);

function ReadCore(Port: PHdmiPort; Offset: LongWord): LongWord;
procedure WriteCore(Port: PHdmiPort; Offset: LongWord; Value: LongWord);
function ReadHd(Port: PHdmiPort; Offset: LongWord): LongWord;
procedure WriteHd(Port: PHdmiPort; Offset: LongWord; Value: LongWord);
procedure WritePacketWord(Port: PHdmiPort; Offset: LongWord; Value: LongWord);
function ReadDvp(Port: PHdmiPort; Offset: LongWord): LongWord;
procedure WriteDvp(Port: PHdmiPort; Offset: LongWord; Value: LongWord);

{ Register block Name ("hdmi", "packet", "hd") of the node: where it is
  and how long. }
function FindNamedRegister(Node: LongInt; Name: PChar; out Physical, Size: QWord): Boolean;
{ Maps the port's blocks and finds its DVP; False (and logged) if one is
  missing. }
function MapPortRegisters(Port: PHdmiPort): Boolean;

{ The clock named Name in the node's "clocks"/"clock-names": the
  provider's node and the specifier's first cell. }
function FindNamedClock(Node: LongInt; Name: PChar; out Provider: LongInt; out Cell: LongWord): Boolean;
{ The rate of a provider's clock Cell: the firmware's for
  "raspberrypi,firmware-clocks" (VideoCore mailbox), "clock-frequency"
  for a fixed clock, else its first parent's (a gate). 0 if unknown. }
function ClockRateHertz(Provider: LongInt; Cell: LongWord; out FromFirmware: Boolean): QWord;

{ "[hdmi-audio] hdmi0: " }
procedure BeginPortLine(Port: PHdmiPort);
{ "[hdmi-audio] hdmi0: FAILED at step N (Step): " }
procedure BeginPortFailure(Port: PHdmiPort; StepNumber: LongWord; Step: PChar);
{ " MAI_CTL 0x... MAI_THR ... " for failure lines. }
procedure WritePortRegisters(Port: PHdmiPort);

implementation

uses
  Runtime.Atomic,
  Memory.DeviceMapping,
  DeviceTree.Blob,
  DeviceTree.Addresses,
  Firmware.DeviceTree,
  Drivers.VideoCoreMailbox,
  Debug.Output;

const
  MaximumClockDepth = 4;
  DvpBlockBytes = $10;

function ReadCore(Port: PHdmiPort; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Port^.Core + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteCore(Port: PHdmiPort; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Port^.Core + Offset)^ := Value;
end;

function ReadHd(Port: PHdmiPort; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Port^.Hd + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteHd(Port: PHdmiPort; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Port^.Hd + Offset)^ := Value;
end;

procedure WritePacketWord(Port: PHdmiPort; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Port^.Packet + Offset)^ := Value;
end;

function ReadDvp(Port: PHdmiPort; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Port^.Dvp + Offset)^;
  FullMemoryBarrier;
end;

procedure WriteDvp(Port: PHdmiPort; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Port^.Dvp + Offset)^ := Value;
end;

{ The position of Name in the node's string list property, or -1. }
function StringIndex(Node: LongInt; PropertyName: PChar; Name: PChar): LongInt;
var
  Prop: TDeviceTreeProperty;
  Index: LongWord;
  Text: PChar;
begin
  Result := -1;
  if not FindProperty(SystemDeviceTree^, Node, PropertyName, Prop) then
    Exit;
  Index := 0;
  repeat
    Text := PropertyString(Prop, Index);
    if (Text <> nil) and DeviceTreeTextIsEqual(Text, Name) then
      Exit(LongInt(Index));
    Inc(Index);
  until Text = nil;
end;

function FindNamedRegister(Node: LongInt; Name: PChar; out Physical, Size: QWord): Boolean;
var
  Index: LongInt;
begin
  Physical := 0;
  Size := 0;
  Index := StringIndex(Node, 'reg-names', Name);
  Result := (Index >= 0) and NodeRegisterPhysical(SystemDeviceTree^, Node, LongWord(Index), Physical, Size);
end;

function MapNamed(Port: PHdmiPort; Name: PChar; out Physical: QWord): PByte;
var
  Size: QWord;
begin
  Result := nil;
  if FindNamedRegister(Port^.Node, Name, Physical, Size) then
    Result := PByte(MapDeviceMemory(Physical, Size));
  if Result = nil then
  begin
    BeginPortFailure(Port, 1, 'resources');
    DebugWrite('no register block "');
    DebugWrite(Name);
    DebugWriteLine('" in the node (reg-names), or it could not be mapped');
    DebugEndMessage;
  end;
end;

{ The node and first cell of entry Index of a phandle list property
  whose providers say how many cells follow in CellsName. }
function PhandleListEntry(Node: LongInt; ListName, CellsName: PChar; Index: LongWord;
  out Provider: LongInt; out Cell: LongWord): Boolean;
var
  Prop: TDeviceTreeProperty;
  Position: LongWord;
  Count: LongWord;
  Entry: LongWord;
  Cells: LongWord;
begin
  Result := False;
  Provider := NoNode;
  Cell := 0;
  if not FindProperty(SystemDeviceTree^, Node, ListName, Prop) then
    Exit;
  Count := PropertyCellCount(Prop);
  Position := 0;
  Entry := 0;
  while Position < Count do
  begin
    Provider := FindNodeByPhandle(SystemDeviceTree^, PropertyCell(Prop, Position));
    if Provider = NoNode then
      Exit;
    if not ReadCellProperty(SystemDeviceTree^, Provider, CellsName, Cells) then
      Cells := 0;
    if Entry = Index then
    begin
      if Cells > 0 then
        Cell := PropertyCell(Prop, Position + 1);
      Exit(True);
    end;
    Position := Position + 1 + Cells;
    Inc(Entry);
  end;
  Provider := NoNode;
end;

function FindNamedClock(Node: LongInt; Name: PChar; out Provider: LongInt; out Cell: LongWord): Boolean;
var
  Index: LongInt;
begin
  Provider := NoNode;
  Cell := 0;
  Index := StringIndex(Node, 'clock-names', Name);
  Result := (Index >= 0) and PhandleListEntry(Node, 'clocks', '#clock-cells', LongWord(Index), Provider, Cell);
end;

function ClockRateAtDepth(Provider: LongInt; Cell: LongWord; Depth: LongWord; out FromFirmware: Boolean): QWord;
var
  Frequency: LongWord;
  Parent: LongInt;
  ParentCell: LongWord;
  FirmwareHertz: LongWord;
begin
  Result := 0;
  FromFirmware := False;
  if (Provider = NoNode) or (Depth > MaximumClockDepth) then
    Exit;
  if NodeIsCompatible(SystemDeviceTree^, Provider, 'raspberrypi,firmware-clocks') then
  begin
    FromFirmware := True;
    if QueryClockRate(Cell, FirmwareHertz) then
      Result := FirmwareHertz;
    Exit;
  end;
  if ReadCellProperty(SystemDeviceTree^, Provider, 'clock-frequency', Frequency) then
    Exit(Frequency);
  if PhandleListEntry(Provider, 'clocks', '#clock-cells', 0, Parent, ParentCell) then
    Result := ClockRateAtDepth(Parent, ParentCell, Depth + 1, FromFirmware);
end;

function ClockRateHertz(Provider: LongInt; Cell: LongWord; out FromFirmware: Boolean): QWord;
begin
  Result := ClockRateAtDepth(Provider, Cell, 0, FromFirmware);
end;

function MapPortRegisters(Port: PHdmiPort): Boolean;
var
  Physical: QWord;
  Size: QWord;
  DvpNode: LongInt;
  Line: LongWord;
  ClockProvider: LongInt;
  ClockCell: LongWord;
begin
  Result := False;
  Port^.Core := MapNamed(Port, 'hdmi', Physical);
  if Port^.Core = nil then
    Exit;
  Port^.Packet := MapNamed(Port, 'packet', Physical);
  if Port^.Packet = nil then
    Exit;
  Port^.Hd := MapNamed(Port, 'hd', Port^.HdPhysical);
  if Port^.Hd = nil then
    Exit;
  { The DVP is the provider of the port's reset line, and its audio
    clock's gate. }
  Port^.ResetLine := -1;
  Port^.AudioClockGate := -1;
  Port^.Dvp := nil;
  if PhandleListEntry(Port^.Node, 'resets', '#reset-cells', 0, DvpNode, Line) and
     NodeIsCompatible(SystemDeviceTree^, DvpNode, 'brcm,brcm2711-dvp') and
     NodeRegisterPhysical(SystemDeviceTree^, DvpNode, 0, Physical, Size) then
  begin
    Port^.Dvp := PByte(MapDeviceMemory(Physical, DvpBlockBytes));
    Port^.ResetLine := LongInt(Line);
    if FindNamedClock(Port^.Node, 'audio', ClockProvider, ClockCell) and (ClockProvider = DvpNode) then
      Port^.AudioClockGate := LongInt(ClockCell);
  end;
  Result := True;
end;

procedure BeginPortLine(Port: PHdmiPort);
begin
  DebugBeginMessage;
  DebugWriteTag('hdmi-audio');
  DebugWrite(Port^.Name);
  DebugWrite(': ');
end;

procedure BeginPortFailure(Port: PHdmiPort; StepNumber: LongWord; Step: PChar);
begin
  BeginPortLine(Port);
  DebugWrite('FAILED at step ');
  DebugWriteDecimal(StepNumber);
  DebugWrite(' (');
  DebugWrite(Step);
  DebugWrite('): ');
end;

procedure WriteRegister(Name: PChar; Value: LongWord);
begin
  DebugWrite(' ');
  DebugWrite(Name);
  DebugWrite(' 0x');
  DebugWriteHex(Value, 8);
end;

procedure WritePortRegisters(Port: PHdmiPort);
begin
  WriteRegister('MAI_CTL', ReadHd(Port, Port^.Mai.Control));
  WriteRegister('MAI_THR', ReadHd(Port, Port^.Mai.Threshold));
  WriteRegister('MAI_FMT', ReadHd(Port, Port^.Mai.Format));
  WriteRegister('MAI_SMP', ReadHd(Port, Port^.Mai.SampleClock));
  WriteRegister('AUDIO_PACKET_CONFIG', ReadCore(Port, HdmiAudioPacketConfig));
  WriteRegister('CRP_CFG', ReadCore(Port, HdmiClockRegenerationConfig));
  WriteRegister('CTS_0', ReadCore(Port, HdmiCts0));
  WriteRegister('RAM_PACKET_CONFIG', ReadCore(Port, HdmiRamPacketConfig));
  WriteRegister('RAM_PACKET_STATUS', ReadCore(Port, HdmiRamPacketStatus));
  WriteRegister('SCHEDULER_CONTROL', ReadCore(Port, HdmiSchedulerControl));
  WriteRegister('HOTPLUG', ReadCore(Port, HdmiHotplug));
end;

end.
