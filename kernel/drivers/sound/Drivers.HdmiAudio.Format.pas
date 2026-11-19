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
  What HDMI audio puts on the link, worked out without the hardware
  (plain Pascal, checked on the host by make hdmi-audio-test):

  - Audio clock regeneration. The sink rebuilds the sample clock from
    the TMDS character clock: 128 x fs = f_TMDS x N / CTS. N and CTS
    come from the HDMI specification's table for the common clocks
    (25.2, 27, 54, 74.25, 148.5, 297 and 594 MHz, and each divided by
    1.001); for any other clock N is the recommended 128 x fs / 1000
    (4096, 6272, 6144) and CTS = f_TMDS x N / (128 x fs), rounded.
    88.2/96 and 176.4/192 kHz take twice and four times the N of 44.1
    and 48 kHz with the same CTS.

  - The MAI's sample clock: N/M of the audio clock (108 MHz on the
    BCM2711/2712) per sample, the best fraction with N < 2^24 and M
    <= 256 (108 MHz / 48 kHz = 2250/1, / 44.1 kHz = 120000/49).

  - IEC 60958 subframes, what the MAI FIFO takes (one 32-bit word a
    sample, as ALSA's IEC958_SUBFRAME_LE): bits 0-3 the preamble (8 =
    Z, a block's first frame, left; 2 = X, left; 4 = Y, right), 4-27
    the sample (24 bits; 16-bit samples in 12-27), 28 validity (0:
    valid), 29 user data, 30 the channel status bit of this frame, 31
    even parity over bits 4-30. A block is 192 frames; frame n of the
    block carries bit n of the channel status (byte n div 8, bit n mod
    8): consumer, linear PCM, copying permitted, original, the sample
    rate, 16-bit words.

  - The audio InfoFrame (CEA-861 type 84h, version 1, 10 bytes): the
    channel count (CC = channels - 1), coding type and sample size
    "refer to the stream", speaker allocation 0 (front left and right),
    and a checksum that makes the bytes add up to 0. The controller's
    packet RAM takes it 7 bytes at a time in two words (3 bytes, then 4).
}
unit Drivers.HdmiAudio.Format;

{$mode objfpc}
{$pointermath on}

interface

const
  { Bits of a subframe. }
  SubframePreambleZ = $08;
  SubframePreambleX = $02;
  SubframePreambleY = $04;
  SubframeSampleShift = 12;
  SubframeValidity = LongWord(1) shl 28;
  SubframeUser = LongWord(1) shl 29;
  SubframeChannelStatus = LongWord(1) shl 30;
  SubframeParity = LongWord(1) shl 31;

  FramesPerBlock = 192;
  ChannelStatusBytes = 24;

  AudioInfoFrameType = $84;
  AudioInfoFrameVersion = 1;
  AudioInfoFramePayloadBytes = 10;
  { The header (type, version, length), the checksum, the payload. }
  AudioInfoFrameBytes = 4 + AudioInfoFramePayloadBytes;
  { One packet of the packet RAM: 24h bytes. }
  PacketRamWords = 9;

  { The largest N and M of the MAI's sample clock register. }
  MaiSampleClockMaximumN = $FFFFFF;
  MaiSampleClockMaximumM = 256;

  { How far a clock may be from a table entry and still take its
    values: the 1.001 pairs are 1000 ppm apart. }
  TableMatchPartsPerMillion = 300;

type
  PSmallInt = ^SmallInt;

  TAudioClockRegeneration = record
    N: LongWord;
    Cts: LongWord;
    { The values came from the specification's table (the clock is one
      of its clocks), not from the formula. }
    FromTable: Boolean;
    { The table's clock that matched, in Hz (0 if none). }
    TableClockHertz: QWord;
  end;

  TChannelStatus = array[0..ChannelStatusBytes - 1] of Byte;
  TAudioInfoFrame = array[0..AudioInfoFrameBytes - 1] of Byte;
  TPacketRamWords = array[0..PacketRamWords - 1] of LongWord;

{ N and CTS for a TMDS character clock and sample rate. False if the
  rate is not one HDMI carries (32, 44.1, 48, 88.2, 96, 176.4 or 192
  kHz) or the clock is 0. }
function ComputeAudioClockRegeneration(TmdsHertz: QWord; SampleRate: LongWord;
  out Values: TAudioClockRegeneration): Boolean;

{ The MAI format register's sample rate code (0: not indicated). }
function MaiSampleRateCode(SampleRate: LongWord): LongWord;

{ N/M ~ AudioClockHertz / SampleRate with N <= MaiSampleClockMaximumN
  and M <= MaiSampleClockMaximumM. False if no fraction fits. }
function ComputeMaiSampleClock(AudioClockHertz, SampleRate: LongWord; out N, M: LongWord): Boolean;

{ The channel status block for 16-bit linear PCM at SampleRate. }
procedure BuildChannelStatus(SampleRate: LongWord; out Status: TChannelStatus);
function ChannelStatusBit(constref Status: TChannelStatus; FrameInBlock: LongWord): Boolean;

{ One subframe: Channel 0 (left) or 1 (right) of frame FrameInBlock
  (0-191) of a block. }
function MakeSubframe(Sample: SmallInt; Channel: LongWord; FrameInBlock: LongWord;
  constref Status: TChannelStatus): LongWord;

{ FrameCount stereo frames of 16-bit samples (Source; nil for silence)
  as subframes (two words a frame) into Destination; the first is frame
  FirstFrameInBlock of its block. }
procedure PackSubframes(Source: PSmallInt; Destination: PLongWord; FrameCount: LongWord;
  FirstFrameInBlock: LongWord; constref Status: TChannelStatus);

{ The audio InfoFrame for linear PCM with Channels channels (1-8). }
procedure BuildAudioInfoFrame(Channels: LongWord; out Frame: TAudioInfoFrame);
{ The frame as the packet RAM takes it, the rest of the packet zero. }
procedure InfoFrameToPacketWords(constref Frame: TAudioInfoFrame; out Words: TPacketRamWords);

{ The MAI channel map of BCM2711 and later: channel I of the stream to
  slot I, four bits each, for the channels in Mask. }
function MaiChannelMap(ChannelMask: LongWord): LongWord;

implementation

type
  TClockEntry = record
    { The clock is BaseHertz, or BaseHertz / 1.001. }
    BaseHertz: QWord;
    DividedBy1001: Boolean;
    N32: LongWord;
    N44: LongWord;
    N48: LongWord;
  end;

const
  { The HDMI specification's recommended N for each clock (CTS follows
    from the clock); the clocks divided by 1.001 need other N for the
    CTS to come out whole. }
  ClockTable: array[0..13] of TClockEntry = (
    (BaseHertz: 25200000; DividedBy1001: True; N32: 4576; N44: 7007; N48: 6864),
    (BaseHertz: 25200000; DividedBy1001: False; N32: 4096; N44: 6272; N48: 6144),
    (BaseHertz: 27000000; DividedBy1001: False; N32: 4096; N44: 6272; N48: 6144),
    (BaseHertz: 27027000; DividedBy1001: False; N32: 4096; N44: 6272; N48: 6144),
    (BaseHertz: 54000000; DividedBy1001: False; N32: 4096; N44: 6272; N48: 6144),
    (BaseHertz: 54054000; DividedBy1001: False; N32: 4096; N44: 6272; N48: 6144),
    (BaseHertz: 74250000; DividedBy1001: True; N32: 11648; N44: 17836; N48: 11648),
    (BaseHertz: 74250000; DividedBy1001: False; N32: 4096; N44: 6272; N48: 6144),
    (BaseHertz: 148500000; DividedBy1001: True; N32: 11648; N44: 8918; N48: 5824),
    (BaseHertz: 148500000; DividedBy1001: False; N32: 4096; N44: 6272; N48: 6144),
    (BaseHertz: 297000000; DividedBy1001: True; N32: 5824; N44: 4459; N48: 5824),
    (BaseHertz: 297000000; DividedBy1001: False; N32: 3072; N44: 4704; N48: 5120),
    (BaseHertz: 594000000; DividedBy1001: True; N32: 5824; N44: 8918; N48: 5824),
    (BaseHertz: 594000000; DividedBy1001: False; N32: 3072; N44: 9408; N48: 6144));

  DefaultN32 = 4096;
  DefaultN44 = 6272;
  DefaultN48 = 6144;

{ The rate as a base rate (32000, 44100, 48000) times 1, 2 or 4. }
function SplitSampleRate(SampleRate: LongWord; out BaseRate, Multiple: LongWord): Boolean;
begin
  Result := True;
  case SampleRate of
    32000: begin BaseRate := 32000; Multiple := 1; end;
    44100: begin BaseRate := 44100; Multiple := 1; end;
    48000: begin BaseRate := 48000; Multiple := 1; end;
    88200: begin BaseRate := 44100; Multiple := 2; end;
    96000: begin BaseRate := 48000; Multiple := 2; end;
    176400: begin BaseRate := 44100; Multiple := 4; end;
    192000: begin BaseRate := 48000; Multiple := 4; end;
  else
    BaseRate := 0;
    Multiple := 0;
    Result := False;
  end;
end;

function TableN(constref Entry: TClockEntry; BaseRate: LongWord): LongWord;
begin
  case BaseRate of
    32000: Result := Entry.N32;
    44100: Result := Entry.N44;
  else
    Result := Entry.N48;
  end;
end;

function DefaultN(BaseRate: LongWord): LongWord;
begin
  case BaseRate of
    32000: Result := DefaultN32;
    44100: Result := DefaultN44;
  else
    Result := DefaultN48;
  end;
end;

{ Numerator / Denominator rounded to the nearest whole number. }
function DivideRounded(Numerator, Denominator: QWord): QWord;
begin
  Result := (Numerator + Denominator div 2) div Denominator;
end;

{ The entry's clock in Hz, rounded. }
function EntryHertz(constref Entry: TClockEntry): QWord;
begin
  if Entry.DividedBy1001 then
    Result := DivideRounded(Entry.BaseHertz * 1000, 1001)
  else
    Result := Entry.BaseHertz;
end;

function ClockMatches(TmdsHertz, TableHertz: QWord): Boolean;
var
  Difference: QWord;
begin
  if TmdsHertz > TableHertz then
    Difference := TmdsHertz - TableHertz
  else
    Difference := TableHertz - TmdsHertz;
  Result := Difference * 1000000 <= TableHertz * TableMatchPartsPerMillion;
end;

function ComputeAudioClockRegeneration(TmdsHertz: QWord; SampleRate: LongWord;
  out Values: TAudioClockRegeneration): Boolean;
var
  BaseRate: LongWord;
  Multiple: LongWord;
  Index: Integer;
  Numerator: QWord;
  Denominator: QWord;
begin
  Values.N := 0;
  Values.Cts := 0;
  Values.FromTable := False;
  Values.TableClockHertz := 0;
  Result := False;
  if (TmdsHertz = 0) or not SplitSampleRate(SampleRate, BaseRate, Multiple) then
    Exit;
  for Index := Low(ClockTable) to High(ClockTable) do
    if ClockMatches(TmdsHertz, EntryHertz(ClockTable[Index])) then
    begin
      Values.N := TableN(ClockTable[Index], BaseRate) * Multiple;
      { CTS from the exact clock (BaseHertz x 1000 / 1001 when divided):
        N x f / (128 x fs), the same for every multiple of the rate. }
      Numerator := ClockTable[Index].BaseHertz * TableN(ClockTable[Index], BaseRate);
      Denominator := QWord(128) * BaseRate;
      if ClockTable[Index].DividedBy1001 then
      begin
        Numerator := Numerator * 1000;
        Denominator := Denominator * 1001;
      end;
      Values.Cts := LongWord(DivideRounded(Numerator, Denominator));
      Values.FromTable := True;
      Values.TableClockHertz := EntryHertz(ClockTable[Index]);
      Exit(True);
    end;
  Values.N := DefaultN(BaseRate) * Multiple;
  Values.Cts := LongWord(DivideRounded(TmdsHertz * DefaultN(BaseRate), QWord(128) * BaseRate));
  Result := Values.Cts <> 0;
end;

function MaiSampleRateCode(SampleRate: LongWord): LongWord;
begin
  case SampleRate of
    8000: Result := 1;
    11025: Result := 2;
    12000: Result := 3;
    16000: Result := 4;
    22050: Result := 5;
    24000: Result := 6;
    32000: Result := 7;
    44100: Result := 8;
    48000: Result := 9;
    64000: Result := 10;
    88200: Result := 11;
    96000: Result := 12;
    128000: Result := 13;
    176400: Result := 14;
    192000: Result := 15;
  else
    Result := 0;
  end;
end;

{ The best fraction by continued fractions: each convergent while it
  fits, then the best semiconvergent between the last two. }
function ComputeMaiSampleClock(AudioClockHertz, SampleRate: LongWord; out N, M: LongWord): Boolean;
var
  Numerator: QWord;
  Denominator: QWord;
  Quotient: QWord;
  Remainder: QWord;
  PreviousN, CurrentN, NextN: QWord;
  PreviousM, CurrentM, NextM: QWord;
  Steps: QWord;
  Limit: QWord;
begin
  N := 0;
  M := 0;
  Result := False;
  if (AudioClockHertz = 0) or (SampleRate = 0) then
    Exit;
  Numerator := AudioClockHertz;
  Denominator := SampleRate;
  PreviousN := 0;
  CurrentN := 1;
  PreviousM := 1;
  CurrentM := 0;
  while Denominator <> 0 do
  begin
    Quotient := Numerator div Denominator;
    Remainder := Numerator mod Denominator;
    NextN := PreviousN + Quotient * CurrentN;
    NextM := PreviousM + Quotient * CurrentM;
    if (NextN > MaiSampleClockMaximumN) or (NextM > MaiSampleClockMaximumM) then
    begin
      { As many steps of this term as still fit. }
      Steps := Quotient;
      if CurrentN <> 0 then
      begin
        Limit := (MaiSampleClockMaximumN - PreviousN) div CurrentN;
        if Limit < Steps then
          Steps := Limit;
      end;
      if CurrentM <> 0 then
      begin
        Limit := (MaiSampleClockMaximumM - PreviousM) div CurrentM;
        if Limit < Steps then
          Steps := Limit;
      end;
      { The semiconvergent is only better from half the term on. }
      if (Steps * 2 >= Quotient) and (Steps > 0) then
      begin
        CurrentN := PreviousN + Steps * CurrentN;
        CurrentM := PreviousM + Steps * CurrentM;
      end;
      Break;
    end;
    PreviousN := CurrentN;
    CurrentN := NextN;
    PreviousM := CurrentM;
    CurrentM := NextM;
    Numerator := Denominator;
    Denominator := Remainder;
  end;
  if (CurrentN = 0) or (CurrentM = 0) then
    Exit;
  N := LongWord(CurrentN);
  M := LongWord(CurrentM);
  Result := True;
end;

{ IEC 60958-3 consumer channel status, byte 3: the sample frequency. }
function ChannelStatusRateCode(SampleRate: LongWord): Byte;
begin
  case SampleRate of
    22050: Result := $04;
    24000: Result := $06;
    32000: Result := $03;
    44100: Result := $00;
    48000: Result := $02;
    88200: Result := $08;
    96000: Result := $0A;
    176400: Result := $0C;
    192000: Result := $0E;
  else
    { Not indicated. }
    Result := $01;
  end;
end;

procedure BuildChannelStatus(SampleRate: LongWord; out Status: TChannelStatus);
const
  ConsumerCopyPermitted = $04;  { byte 0: consumer, audio, no copyright, no emphasis }
  CategoryPcmEncoderOriginal = $82;  { byte 1: PCM encoder/decoder, original }
  WordLength20Is16Bits = $02;  { byte 4: at most 20 bits, 16 used }
var
  Index: Integer;
begin
  for Index := 0 to ChannelStatusBytes - 1 do
    Status[Index] := 0;
  Status[0] := ConsumerCopyPermitted;
  Status[1] := CategoryPcmEncoderOriginal;
  Status[2] := 0;  { source and channel numbers not given }
  Status[3] := ChannelStatusRateCode(SampleRate);
  Status[4] := WordLength20Is16Bits;
end;

function ChannelStatusBit(constref Status: TChannelStatus; FrameInBlock: LongWord): Boolean;
begin
  FrameInBlock := FrameInBlock mod FramesPerBlock;
  Result := (Status[FrameInBlock div 8] and (1 shl (FrameInBlock mod 8))) <> 0;
end;

{ True if Value has an odd number of bits set. }
function HasOddParity(Value: LongWord): Boolean;
begin
  Value := Value xor (Value shr 16);
  Value := Value xor (Value shr 8);
  Value := Value xor (Value shr 4);
  Value := Value xor (Value shr 2);
  Value := Value xor (Value shr 1);
  Result := (Value and 1) <> 0;
end;

function MakeSubframe(Sample: SmallInt; Channel: LongWord; FrameInBlock: LongWord;
  constref Status: TChannelStatus): LongWord;
var
  Value: LongWord;
begin
  FrameInBlock := FrameInBlock mod FramesPerBlock;
  Value := (LongWord(Word(Sample)) shl SubframeSampleShift) and $0FFFFFF0;
  if ChannelStatusBit(Status, FrameInBlock) then
    Value := Value or SubframeChannelStatus;
  if HasOddParity(Value and $7FFFFFF0) then
    Value := Value or SubframeParity;
  if Channel <> 0 then
    Value := Value or SubframePreambleY
  else if FrameInBlock = 0 then
    Value := Value or SubframePreambleZ
  else
    Value := Value or SubframePreambleX;
  Result := Value;
end;

procedure PackSubframes(Source: PSmallInt; Destination: PLongWord; FrameCount: LongWord;
  FirstFrameInBlock: LongWord; constref Status: TChannelStatus);
var
  Frame: LongWord;
  InBlock: LongWord;
  Left: SmallInt;
  Right: SmallInt;
begin
  Frame := 0;
  InBlock := FirstFrameInBlock mod FramesPerBlock;
  while Frame < FrameCount do
  begin
    if Source <> nil then
    begin
      Left := Source[Frame * 2];
      Right := Source[Frame * 2 + 1];
    end
    else
    begin
      Left := 0;
      Right := 0;
    end;
    Destination[Frame * 2] := MakeSubframe(Left, 0, InBlock, Status);
    Destination[Frame * 2 + 1] := MakeSubframe(Right, 1, InBlock, Status);
    Inc(InBlock);
    if InBlock = FramesPerBlock then
      InBlock := 0;
    Inc(Frame);
  end;
end;

procedure BuildAudioInfoFrame(Channels: LongWord; out Frame: TAudioInfoFrame);
var
  Index: Integer;
  Sum: LongWord;
begin
  for Index := 0 to AudioInfoFrameBytes - 1 do
    Frame[Index] := 0;
  if Channels < 1 then
    Channels := 1
  else if Channels > 8 then
    Channels := 8;
  Frame[0] := AudioInfoFrameType;
  Frame[1] := AudioInfoFrameVersion;
  Frame[2] := AudioInfoFramePayloadBytes;
  { Payload byte 1: coding type 0 (refer to the stream), channel count - 1.
    Bytes 2-10: sample rate and size from the stream, speaker allocation
    0 (front left and right), level shift 0, down-mix allowed. }
  Frame[4] := Byte(Channels - 1);
  Sum := 0;
  for Index := 0 to AudioInfoFrameBytes - 1 do
    Sum := Sum + Frame[Index];
  Frame[3] := Byte((256 - (Sum and $FF)) and $FF);
end;

procedure InfoFrameToPacketWords(constref Frame: TAudioInfoFrame; out Words: TPacketRamWords);
var
  Index: Integer;
  WordIndex: Integer;
  Chunk: array[0..6] of Byte;
  ByteIndex: Integer;
begin
  for Index := 0 to PacketRamWords - 1 do
    Words[Index] := 0;
  Index := 0;
  WordIndex := 0;
  while Index < AudioInfoFrameBytes do
  begin
    for ByteIndex := 0 to 6 do
      if Index + ByteIndex < AudioInfoFrameBytes then
        Chunk[ByteIndex] := Frame[Index + ByteIndex]
      else
        Chunk[ByteIndex] := 0;
    Words[WordIndex] := LongWord(Chunk[0]) or (LongWord(Chunk[1]) shl 8) or (LongWord(Chunk[2]) shl 16);
    Words[WordIndex + 1] := LongWord(Chunk[3]) or (LongWord(Chunk[4]) shl 8) or (LongWord(Chunk[5]) shl 16) or
      (LongWord(Chunk[6]) shl 24);
    Inc(WordIndex, 2);
    Inc(Index, 7);
  end;
end;

function MaiChannelMap(ChannelMask: LongWord): LongWord;
var
  Channel: LongWord;
begin
  Result := 0;
  for Channel := 0 to 7 do
    if (ChannelMask and (LongWord(1) shl Channel)) <> 0 then
      Result := Result or (Channel shl (4 * Channel));
end;

end.
