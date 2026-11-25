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
  HD Audio streams: one of the controller's DMA engines, playing or
  capturing an audio framework ring.

  A stream descriptor's buffer descriptor list has one entry per period
  of the ring, each raising an interrupt when done. Input streams come
  first among the descriptors, then output streams (the controller's
  capabilities say how many of each). The stream carries 16-bit stereo
  at 48 kHz, tagged so the codec's converter on the same tag takes it.
}
unit Drivers.HdAudio.Streams;

{$mode objfpc}
{$pointermath on}

interface

uses
  Io.Dma;

const
  FormatStereo16Bit48000 = $0011;

type
  THdAudioStream = record
    Descriptor: PByte;
    { Its number among all the descriptors (its interrupt bit). }
    Index: LongWord;
    Tag: LongWord;
    { The buffer descriptor list: shared DMA memory of the controller. }
    List: TDmaBuffer;
  end;

{ The first input and the first output stream's numbers. }
function FirstInputStream(Registers: PByte): LongWord;
function FirstOutputStream(Registers: PByte): LongWord;
{ Makes Stream number Index (on Tag) describe the ring of Pages (the
  controller's bus addresses for them; Dma is its attributes); False if
  memory is short. }
function PrepareStream(out Stream: THdAudioStream; Registers: PByte; Index, Tag: LongWord;
  constref Dma: TDmaAttributes; const Pages: array of QWord): Boolean;
{ Resets the stream and programs it again: it starts at the beginning of
  the ring. }
procedure ResetStream(var Stream: THdAudioStream);
procedure RunStream(var Stream: THdAudioStream);
{ Stops it and resets it. }
procedure HaltStream(var Stream: THdAudioStream);
{ Bytes into the ring the stream has moved. }
function StreamPosition(var Stream: THdAudioStream): LongWord;
{ Clears the stream's interrupt. }
procedure AcknowledgeStream(var Stream: THdAudioStream);

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.Clock,
  Io.AudioOutput,
  Drivers.HdAudio.Codecs;

const
  StreamDescriptorBase = $80;
  StreamDescriptorSize = $20;

  StreamControl = $00;
  StreamStatus = $03;
  StreamPositionInRing = $04;
  StreamCycleLength = $08;
  StreamLastValidIndex = $0C;
  StreamFormat = $12;
  StreamListLower = $18;
  StreamListUpper = $1C;
  StreamControlReset = 1;
  StreamControlRun = 2;
  StreamControlInterruptOnCompletion = 4;
  HaltTimeoutMilliseconds = 100;

function FirstInputStream(Registers: PByte): LongWord;
begin
  Result := 0;
end;

function FirstOutputStream(Registers: PByte): LongWord;
begin
  { After the input streams. }
  Result := (Read16(Registers, RegisterCapabilities) shr 8) and $F;
end;

function PrepareStream(out Stream: THdAudioStream; Registers: PByte; Index, Tag: LongWord;
  constref Dma: TDmaAttributes; const Pages: array of QWord): Boolean;
var
  List: PQWord;
  Entry: Integer;
begin
  Stream.Index := Index;
  Stream.Tag := Tag;
  Stream.Descriptor := Registers + StreamDescriptorBase + Index * StreamDescriptorSize;
  if not AllocateDmaBuffer(Dma, AudioPeriodCount * 16, DmaShared, Stream.List) then
    Exit(False);
  List := PQWord(Stream.List.Address);
  { Address, then length and "interrupt on completion" in one word. }
  for Entry := 0 to AudioPeriodCount - 1 do
  begin
    List[Entry * 2] := Pages[Entry];
    List[Entry * 2 + 1] := AudioPeriodBytes or (QWord(1) shl 32);
  end;
  ResetStream(Stream);
  Result := True;
end;

{ Waits (a while at most) for the stream's control bits Mask to read
  back as Expected. }
procedure WaitForControl(var Stream: THdAudioStream; Mask, Expected: Byte);
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(HaltTimeoutMilliseconds);
  while ((Read8(Stream.Descriptor, StreamControl) and Mask) <> Expected) and (ClockTickCount < Deadline) do
    CpuRelax;
end;

procedure ResetStream(var Stream: THdAudioStream);
var
  Control: LongWord;
begin
  Write8(Stream.Descriptor, StreamControl, StreamControlReset);
  WaitForControl(Stream, StreamControlReset, StreamControlReset);
  Write8(Stream.Descriptor, StreamControl, 0);
  WaitForControl(Stream, StreamControlReset, 0);
  Write32(Stream.Descriptor, StreamCycleLength, AudioPeriodCount * AudioPeriodBytes);
  Write16(Stream.Descriptor, StreamLastValidIndex, AudioPeriodCount - 1);
  Write32(Stream.Descriptor, StreamListLower, LongWord(Stream.List.DeviceAddress));
  Write32(Stream.Descriptor, StreamListUpper, LongWord(Stream.List.DeviceAddress shr 32));
  Control := Read32(Stream.Descriptor, StreamControl) and $FFFFFF;
  Control := (Control and not ($F shl 20)) or (Stream.Tag shl 20) or StreamControlInterruptOnCompletion;
  Write32(Stream.Descriptor, StreamControl, Control);
  Write16(Stream.Descriptor, StreamFormat, FormatStereo16Bit48000);
end;

procedure RunStream(var Stream: THdAudioStream);
begin
  Write8(Stream.Descriptor, StreamControl, Read8(Stream.Descriptor, StreamControl) or StreamControlRun);
end;

procedure HaltStream(var Stream: THdAudioStream);
begin
  Write8(Stream.Descriptor, StreamControl, Read8(Stream.Descriptor, StreamControl) and not StreamControlRun);
  { The run bit reads back clear once the DMA engine has stopped. }
  WaitForControl(Stream, StreamControlRun, 0);
  ResetStream(Stream);
end;

function StreamPosition(var Stream: THdAudioStream): LongWord;
begin
  Result := Read32(Stream.Descriptor, StreamPositionInRing);
end;

procedure AcknowledgeStream(var Stream: THdAudioStream);
begin
  Write8(Stream.Descriptor, StreamStatus, Read8(Stream.Descriptor, StreamStatus));
end;

end.
