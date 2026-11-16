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
  USB audio devices (audio class 1.0): sound output.

  In the device's configuration the driver looks for an audio streaming
  interface with an alternate setting that takes 16-bit stereo at
  48 kHz (format type I) through an isochronous OUT endpoint, and for
  the audio control interface's feature unit (mute and volume). It
  selects that setting, sets the endpoint's sampling rate and registers
  an audio output (Io.AudioOutput).

  While the output plays, the endpoint's isochronous stream
  (Drivers.XhciIsochronous) takes packets straight from the framework's
  ring: each service interval's frames (48 a millisecond), in two pieces
  where a packet crosses from one page of the ring to the next. As
  packets complete, the bytes played move the output's position on.
}
unit Drivers.UsbAudio;

{$mode objfpc}
{$pointermath on}

interface

{ Offers the driver to the USB core (before the controllers start). }
procedure RegisterUsbAudioDriver;

implementation

uses
  Abi.SystemCalls,
  Memory.KernelHeap,
  Io.AudioOutput,
  Drivers.Xhci,
  Drivers.XhciIsochronous,
  Debug.Output;

const
  ClassAudio = 1;
  SubclassAudioControl = 1;
  SubclassAudioStreaming = 2;
  DescriptorClassInterface = $24;
  ControlFeatureUnit = $06;
  StreamingFormatType = $02;
  FormatTypeOne = 1;
  EndpointTransferMask = 3;
  EndpointIsochronous = 1;

  RequestSetInterface = 11;
  RequestSetCurrent = $01;
  { Host to device: standard to an interface, class to an interface,
    class to an endpoint. }
  StandardToInterface = $01;
  ClassToInterface = $21;
  ClassToEndpoint = $22;
  SamplingFrequencyControl = $01;
  MuteControl = $01;
  VolumeControl = $02;
  FeatureMute = $01;
  FeatureVolume = $02;
  { The volume range used: -50 dB (at 1%) to 0 dB, in 1/256 dB. }
  QuietestDecibels = 50;

  SampleRate = 48000;
  BytesPerFrame = 4;
  RingBytes = AudioPeriodCount * AudioPeriodBytes;
  MaximumFeatureChannels = 3;

type
  PUsbAudio = ^TUsbAudio;
  TUsbAudio = record
    Device: PUsbDevice;
    StreamingInterface: Byte;
    Alternate: Byte;
    Endpoint: Byte;
    MaximumPacket: Word;
    Interval: Byte;
    ControlInterface: Byte;
    FeatureUnit: Byte;
    { Each channel's feature controls (0 is the master). }
    FeatureControls: array[0..MaximumFeatureChannels - 1] of Byte;
    PacketBytes: LongWord;
    Output: PAudioOutput;
    { Where the next packet starts in the ring, the bytes played since
      the start, and which start packets belong to. }
    ReadOffset: LongWord;
    Played: QWord;
    Generation: LongWord;
  end;

{ --- Finding the streaming setting --------------------------------------- }

function ReadWord(Data: PByte): Word;
begin
  Result := Data[0] or (Word(Data[1]) shl 8);
end;

function ReadTriple(Data: PByte): LongWord;
begin
  Result := Data[0] or (LongWord(Data[1]) shl 8) or (LongWord(Data[2]) shl 16);
end;

{ True if a format type I descriptor takes 16-bit stereo at 48 kHz. }
function FormatFits(Descriptor: PByte): Boolean;
var
  RateCount: Integer;
  Index: Integer;
begin
  Result := False;
  if (Descriptor[0] < 8) or (Descriptor[3] <> FormatTypeOne) or (Descriptor[4] <> 2) or (Descriptor[5] <> 2) or
     (Descriptor[6] <> 16) then
    Exit;
  RateCount := Descriptor[7];
  if RateCount = 0 then
    { A continuous range: lower and upper. }
    Exit((Descriptor[0] >= 14) and (ReadTriple(Descriptor + 8) <= SampleRate) and
      (ReadTriple(Descriptor + 11) >= SampleRate));
  for Index := 0 to RateCount - 1 do
    if (8 + Index * 3 + 3 <= Descriptor[0]) and (ReadTriple(Descriptor + 8 + Index * 3) = SampleRate) then
      Exit(True);
end;

{ Walks the configuration for the streaming setting and the feature
  unit. }
function ParseConfiguration(Audio: PUsbAudio): Boolean;
var
  Data: PByte;
  Position: LongWord;
  Length: Byte;
  Kind: Byte;
  InterfaceNumber: Byte;
  Alternate: Byte;
  IsControl: Boolean;
  IsStreaming: Boolean;
  FormatOk: Boolean;
  Channel: Integer;
  ControlSize: Byte;
begin
  Result := False;
  Data := Audio^.Device^.Configuration;
  Position := 0;
  InterfaceNumber := 0;
  Alternate := 0;
  IsControl := False;
  IsStreaming := False;
  FormatOk := False;
  while Position + 2 <= Audio^.Device^.ConfigurationLength do
  begin
    Length := Data[Position];
    Kind := Data[Position + 1];
    if (Length < 2) or (Position + Length > Audio^.Device^.ConfigurationLength) then
      Break;
    if (Kind = UsbDescriptorInterface) and (Length >= 9) then
    begin
      InterfaceNumber := Data[Position + 2];
      Alternate := Data[Position + 3];
      IsControl := (Data[Position + 5] = ClassAudio) and (Data[Position + 6] = SubclassAudioControl);
      IsStreaming := (Data[Position + 5] = ClassAudio) and (Data[Position + 6] = SubclassAudioStreaming);
      FormatOk := False;
    end
    else if (Kind = DescriptorClassInterface) and IsControl and (Length >= 7) and
            (Data[Position + 2] = ControlFeatureUnit) and (Audio^.FeatureUnit = 0) then
    begin
      Audio^.ControlInterface := InterfaceNumber;
      Audio^.FeatureUnit := Data[Position + 3];
      ControlSize := Data[Position + 5];
      if ControlSize > 0 then
        for Channel := 0 to MaximumFeatureChannels - 1 do
          if 6 + LongWord(Channel) * ControlSize < Length then
            Audio^.FeatureControls[Channel] := Data[Position + 6 + LongWord(Channel) * ControlSize];
    end
    else if (Kind = DescriptorClassInterface) and IsStreaming and (Alternate > 0) and
            (Data[Position + 2] = StreamingFormatType) then
      FormatOk := FormatFits(Data + Position)
    else if (Kind = UsbDescriptorEndpoint) and IsStreaming and FormatOk and (Length >= 7) and
            ((Data[Position + 3] and EndpointTransferMask) = EndpointIsochronous) and
            ((Data[Position + 2] and $80) = 0) and not Result then
    begin
      Audio^.StreamingInterface := InterfaceNumber;
      Audio^.Alternate := Alternate;
      Audio^.Endpoint := Data[Position + 2];
      Audio^.MaximumPacket := ReadWord(Data + Position + 4) and $7FF;
      Audio^.Interval := Data[Position + 6];
      Result := True;
    end;
    Position := Position + Length;
  end;
end;

{ Bytes in one service interval: 48 frames a millisecond. }
function PacketBytesFor(Audio: PUsbAudio): LongWord;
var
  Microseconds: LongWord;
  Interval: Byte;
begin
  Interval := Audio^.Interval;
  if Interval = 0 then
    Interval := 1;
  if Audio^.Device^.Speed in [UsbSpeedHigh, UsbSpeedSuper] then
    Microseconds := LongWord(125) shl (Interval - 1)
  else
    Microseconds := LongWord(Interval) * 1000;
  Result := SampleRate div 1000 * Microseconds div 1000 * BytesPerFrame;
end;

{ --- Packets ---------------------------------------------------------------- }

function NextPacket(Context: Pointer; out Packet: TIsochronousPacket): Boolean;
var
  Audio: PUsbAudio;
  Page: LongWord;
  Offset: LongWord;
  First: LongWord;
begin
  Audio := PUsbAudio(Context);
  Page := Audio^.ReadOffset div AudioPeriodBytes;
  Offset := Audio^.ReadOffset mod AudioPeriodBytes;
  First := AudioPeriodBytes - Offset;
  if First > Audio^.PacketBytes then
    First := Audio^.PacketBytes;
  Packet.Physical[0] := Audio^.Output^.PeriodsPhysical[Page] + Offset;
  Packet.Length[0] := First;
  Packet.PieceCount := 1;
  if First < Audio^.PacketBytes then
  begin
    { The rest from the start of the next page. }
    Packet.Physical[1] := Audio^.Output^.PeriodsPhysical[(Page + 1) mod AudioPeriodCount];
    Packet.Length[1] := Audio^.PacketBytes - First;
    Packet.PieceCount := 2;
  end;
  Packet.Tag := Audio^.Generation;
  Audio^.ReadOffset := (Audio^.ReadOffset + Audio^.PacketBytes) mod RingBytes;
  Result := True;
end;

procedure PacketDone(Context: Pointer; Tag: QWord);
var
  Audio: PUsbAudio;
  PeriodBefore: QWord;
begin
  Audio := PUsbAudio(Context);
  { Packets of an earlier start do not count. }
  if Tag <> Audio^.Generation then
    Exit;
  PeriodBefore := Audio^.Played div AudioPeriodBytes;
  Audio^.Played := Audio^.Played + Audio^.PacketBytes;
  if Audio^.Played div AudioPeriodBytes <> PeriodBefore then
    AudioPeriodsElapsed(Audio^.Output);
end;

{ --- The framework's routines ------------------------------------------------ }

procedure StartPlaying(Context: Pointer);
var
  Audio: PUsbAudio;
begin
  Audio := PUsbAudio(Context);
  Inc(Audio^.Generation);
  Audio^.ReadOffset := 0;
  Audio^.Played := 0;
  UsbStartIsochronous(Audio^.Device);
end;

procedure StopPlaying(Context: Pointer);
begin
  UsbStopIsochronous(PUsbAudio(Context)^.Device);
end;

function PlayingPosition(Context: Pointer): LongWord;
begin
  Result := LongWord(PUsbAudio(Context)^.Played mod RingBytes);
end;

procedure SetVolume(Context: Pointer; Percent: LongWord);
var
  Audio: PUsbAudio;
  Channel: Integer;
  Muted: Byte;
  Level: SmallInt;
  Target: Word;
begin
  Audio := PUsbAudio(Context);
  if Audio^.FeatureUnit = 0 then
    Exit;
  Muted := 0;
  if Percent = 0 then
    Muted := 1;
  Level := SmallInt((LongInt(Percent) - 100) * QuietestDecibels * 256 div 100);
  Target := (Word(Audio^.FeatureUnit) shl 8) or Audio^.ControlInterface;
  for Channel := 0 to MaximumFeatureChannels - 1 do
  begin
    if (Audio^.FeatureControls[Channel] and FeatureMute) <> 0 then
      UsbControlTransfer(Audio^.Device, ClassToInterface, RequestSetCurrent, (MuteControl shl 8) or Channel, Target,
        @Muted, 1);
    if (Audio^.FeatureControls[Channel] and FeatureVolume) <> 0 then
      UsbControlTransfer(Audio^.Device, ClassToInterface, RequestSetCurrent, (VolumeControl shl 8) or Channel,
        Target, @Level, 2);
  end;
end;

{ --- Taking a device ------------------------------------------------------------ }

{ The streaming setting chosen and the endpoint's rate. }
function ChooseStreamingSetting(Audio: PUsbAudio): Boolean;
var
  Rate: array[0..2] of Byte;
begin
  Result := UsbControlTransfer(Audio^.Device, StandardToInterface, RequestSetInterface, Audio^.Alternate,
    Audio^.StreamingInterface, nil, 0);
  if not Result then
    Exit;
  { Endpoints with one rate may not have the control: it can fail. }
  Rate[0] := Byte(SampleRate);
  Rate[1] := Byte(SampleRate shr 8);
  Rate[2] := Byte(SampleRate shr 16);
  UsbControlTransfer(Audio^.Device, ClassToEndpoint, RequestSetCurrent, SamplingFrequencyControl shl 8,
    Audio^.Endpoint, @Rate[0], 3);
end;

{ After waking from suspend to RAM the device is back in its first
  setting: the streaming one again (the framework sets the volume). }
procedure ResumeAudioDevice(Device: PUsbDevice; Context: Pointer);
begin
  ChooseStreamingSetting(PUsbAudio(Context));
end;

function ProbeUsbAudio(Device: PUsbDevice): Boolean;
var
  Audio: PUsbAudio;
  Packets: TIsochronousRoutines;
  Routines: TAudioDriverRoutines;
begin
  Result := False;
  Audio := PUsbAudio(AllocateZeroedKernelMemory(SizeOf(TUsbAudio)));
  if Audio = nil then
    Exit;
  Audio^.Device := Device;
  if not ParseConfiguration(Audio) then
  begin
    FreeKernelMemory(Audio);
    Exit;
  end;
  Audio^.PacketBytes := PacketBytesFor(Audio);
  if (Audio^.PacketBytes = 0) or (Audio^.PacketBytes > Audio^.MaximumPacket) or
     not ChooseStreamingSetting(Audio) then
  begin
    FreeKernelMemory(Audio);
    Exit;
  end;
  UsbSetResumeHandler(Device, @ResumeAudioDevice, Audio);
  Packets.NextPacket := @NextPacket;
  Packets.PacketDone := @PacketDone;
  if not UsbOpenIsochronousOut(Device, Audio^.Endpoint, Audio^.MaximumPacket, Audio^.Interval, Packets, Audio) then
    Exit;
  Routines.Start := @StartPlaying;
  Routines.Stop := @StopPlaying;
  Routines.Position := @PlayingPosition;
  Routines.SetVolume := @SetVolume;
  Routines.Kind := AudioOutputKindUsb;
  Audio^.Output := RegisterAudioOutput(Routines, Audio);
  if Audio^.Output = nil then
    Exit;

  DebugBeginMessage;
  DebugWriteTag('audio');
  DebugWrite('USB audio on port ');
  DebugWriteDecimal(Device^.PortNumber);
  DebugWrite(', endpoint ');
  DebugWriteDecimal(Audio^.Endpoint);
  DebugWrite(', ');
  DebugWriteDecimal(Audio^.PacketBytes);
  DebugWriteLine(' bytes a packet');
  DebugEndMessage;
  Result := True;
end;

procedure RegisterUsbAudioDriver;
begin
  RegisterUsbClassDriver(@ProbeUsbAudio);
end;

end.
