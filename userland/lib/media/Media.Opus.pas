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

  This file follows the Opus reference decoder (RFC 6716, libopus 1.5.2),
  which carries this notice:

  Copyright (c) 2001-2011 Xiph.Org, Skype Limited, Octasic,
                          Jean-Marc Valin, Timothy B. Terriberry,
                          CSIRO, Gregory Maxwell, Mark Borgerding,
                          Erik de Castro Lopo

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:
  - Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  - Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  - Neither the name of Internet Society, IETF or IETF Trust, nor the
    names of specific contributors, may be used to endorse or promote
    products derived from this software without specific prior written
    permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
}

{
  The Opus decoder (RFC 6716 with the RFC 8251 updates; Ogg and Matroska
  mappings as RFC 7845): SILK, CELT and hybrid frames of 2.5 to 60 ms,
  packets of up to 120 ms, mono, stereo and multistream (channel mapping
  families 0, 1 and 255), output at 48 kHz (or 8, 12, 16 or 24 kHz for
  the raw interface), with the header's output gain, the pre-skip, and
  loss concealment for empty packets.

  As a TAudioDecoder, Configure reads Track.Headers[0] (OpusHead) and
  output is 48 kHz floats in the WAVE channel order, soft-clipped to
  -1..1. The raw interface (ConfigureRaw, DecodeRaw, FinalRange) decodes
  bare Opus packets as the reference's opus_decode does, for conformance
  tests and the like.
}
unit Media.Opus;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Media.Frames,
  Media.Packets,
  Media.AudioDecoders,
  Media.Opus.StreamDecoder,
  Media.Opus.Multistream;

type
  TOpusHead = record
    Version: Integer;
    Channels: Integer;
    PreSkip: Integer;
    InputSampleRate: LongWord;
    OutputGainQ8: Integer;
    MappingFamily: Integer;
    StreamCount: Integer;
    CoupledCount: Integer;
    Mapping: array[0..254] of Byte;
  end;

  TOpusDecoder = class(TAudioDecoder)
  private
    FMultistream: TOpusMultistreamDecoder;
    FRaw: TOpusStreamDecoder;
    FHead: TOpusHead;
    FOrder: array[0..254] of Integer;
    FPcm: array of Single;
    FClipMemory: array[0..254] of Single;
    FLastDuration: Integer;
    procedure FreeDecoders;
    procedure SetChannelOrder;
    function GetFinalRange: LongWord;
  public
    destructor Destroy; override;
    procedure Configure(Track: TMediaTrack); override;
    function Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean; override;
    procedure Reset; override;
    { A single-stream decoder for bare packets at SampleRate (8000, 12000,
      16000, 24000 or 48000) with Channels (1 or 2) output channels. }
    procedure ConfigureRaw(Rate, ChannelCount: Integer);
    { Decodes one packet (Length = 0: a lost packet, concealed for the
      duration of the last one) into Output, room for MaximumFrames
      samples per channel; returns the samples per channel, or -1. }
    function DecodeRaw(Data: PByte; Length: Integer; Output: PSingle; MaximumFrames: Integer): Integer;
    { The same as 16-bit samples, soft-clipped and rounded as the
      reference's opus_decode. }
    function DecodeRawInt16(Data: PByte; Length: Integer; Output: PSmallInt; MaximumFrames: Integer): Integer;
    { The range coder state after the last packet (the encoder's
      OPUS_GET_FINAL_RANGE must equal it). }
    property FinalRange: LongWord read GetFinalRange;
    property Head: TOpusHead read FHead;
  end;

{ Reads an OpusHead packet; False if it is not a valid one. }
function ParseOpusHead(const Data: TBytes; out Head: TOpusHead): Boolean;

implementation

uses
  Math,
  Media.Errors;

const
  MaximumFrameSamples = 5760;

function ParseOpusHead(const Data: TBytes; out Head: TOpusHead): Boolean;
var
  Index: Integer;
begin
  Head := Default(TOpusHead);
  Result := False;
  if (Length(Data) < 19) or (Data[0] <> Ord('O')) or (Data[1] <> Ord('p')) or (Data[2] <> Ord('u')) or
    (Data[3] <> Ord('s')) or (Data[4] <> Ord('H')) or (Data[5] <> Ord('e')) or (Data[6] <> Ord('a')) or
    (Data[7] <> Ord('d')) then
    Exit;
  Head.Version := Data[8];
  if (Head.Version shr 4) <> 0 then
    Exit;
  Head.Channels := Data[9];
  Head.PreSkip := Data[10] or (Data[11] shl 8);
  Head.InputSampleRate := LongWord(Data[12]) or (LongWord(Data[13]) shl 8) or (LongWord(Data[14]) shl 16) or
    (LongWord(Data[15]) shl 24);
  Head.OutputGainQ8 := SmallInt(Data[16] or (Data[17] shl 8));
  Head.MappingFamily := Data[18];
  if Head.Channels < 1 then
    Exit;
  if Head.MappingFamily = 0 then
  begin
    if Head.Channels > 2 then
      Exit;
    Head.StreamCount := 1;
    Head.CoupledCount := Head.Channels - 1;
    Head.Mapping[0] := 0;
    Head.Mapping[1] := 1;
  end
  else
  begin
    if Length(Data) < 21 + Head.Channels then
      Exit;
    Head.StreamCount := Data[19];
    Head.CoupledCount := Data[20];
    if (Head.StreamCount < 1) or (Head.CoupledCount > Head.StreamCount) or
      (Head.StreamCount + Head.CoupledCount > 255) then
      Exit;
    for Index := 0 to Head.Channels - 1 do
    begin
      Head.Mapping[Index] := Data[21 + Index];
      if (Head.Mapping[Index] <> 255) and (Head.Mapping[Index] >= Head.StreamCount + Head.CoupledCount) then
        Exit;
    end;
    if (Head.MappingFamily = 1) and (Head.Channels > 8) then
      Exit;
  end;
  Result := True;
end;

destructor TOpusDecoder.Destroy;
begin
  FreeDecoders;
  inherited Destroy;
end;

procedure TOpusDecoder.FreeDecoders;
begin
  FreeAndNil(FMultistream);
  FreeAndNil(FRaw);
end;

procedure TOpusDecoder.SetChannelOrder;
const
  Order3: array[0..2] of Integer = (0, 2, 1);
  Order5: array[0..4] of Integer = (0, 2, 1, 3, 4);
  Order6: array[0..5] of Integer = (0, 2, 1, 5, 3, 4);
  Order7: array[0..6] of Integer = (0, 2, 1, 6, 5, 3, 4);
  Order8: array[0..7] of Integer = (0, 2, 1, 7, 5, 6, 3, 4);
var
  Index: Integer;
begin
  for Index := 0 to 254 do
    FOrder[Index] := Index;
  if FHead.MappingFamily <> 1 then
    Exit;
  case FHead.Channels of
    3: for Index := 0 to 2 do FOrder[Index] := Order3[Index];
    5: for Index := 0 to 4 do FOrder[Index] := Order5[Index];
    6: for Index := 0 to 5 do FOrder[Index] := Order6[Index];
    7: for Index := 0 to 6 do FOrder[Index] := Order7[Index];
    8: for Index := 0 to 7 do FOrder[Index] := Order8[Index];
  end;
end;

procedure TOpusDecoder.Configure(Track: TMediaTrack);
begin
  FreeDecoders;
  if Length(Track.Headers) < 1 then
    MediaFail('Opus track without an OpusHead');
  if not ParseOpusHead(Track.Headers[0], FHead) then
    MediaFail('bad OpusHead');
  FSampleRate := 48000;
  FChannels := FHead.Channels;
  FMultistream := TOpusMultistreamDecoder.Create(48000, FHead.Channels, FHead.StreamCount, FHead.CoupledCount,
    FHead.Mapping);
  FMultistream.SetGain(FHead.OutputGainQ8);
  SetChannelOrder;
  SetLength(FPcm, MaximumFrameSamples * FChannels);
  FillChar(FClipMemory, SizeOf(FClipMemory), 0);
  if Track.CodecDelay > 0 then
    FPendingSkip := Track.CodecDelay
  else
    FPendingSkip := FHead.PreSkip;
  FLastDuration := 960;
end;

procedure TOpusDecoder.Reset;
begin
  if FMultistream <> nil then
    FMultistream.Reset;
  if FRaw <> nil then
    FRaw.Reset;
  FillChar(FClipMemory, SizeOf(FClipMemory), 0);
end;

function TOpusDecoder.Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean;
var
  Samples, Index, Channel: Integer;
begin
  if FMultistream = nil then
    MediaFail('Opus decoder not configured');
  if Length(Packet.Data) = 0 then
    Samples := FMultistream.Decode(nil, 0, @FPcm[0], FLastDuration, False)
  else
    Samples := FMultistream.Decode(@Packet.Data[0], Length(Packet.Data), @FPcm[0], MaximumFrameSamples, False);
  if Samples < 0 then
    MediaFail('broken Opus packet');
  if Length(Packet.Data) > 0 then
    FLastDuration := Samples;
  OpusSoftClip(@FPcm[0], Samples, FChannels, @FClipMemory[0]);
  Output.SampleRate := 48000;
  Output.Channels := FChannels;
  Output.PresentationTime := Packet.PresentationTime;
  Output.Samples := nil;
  SetLength(Output.Samples, Samples * FChannels);
  for Index := 0 to Samples - 1 do
    for Channel := 0 to FChannels - 1 do
      Output.Samples[Index * FChannels + Channel] := FPcm[Index * FChannels + FOrder[Channel]];
  ApplyTrim(Output, Packet);
  Result := True;
end;

procedure TOpusDecoder.ConfigureRaw(Rate, ChannelCount: Integer);
begin
  FreeDecoders;
  if not ((Rate = 8000) or (Rate = 12000) or (Rate = 16000) or (Rate = 24000) or (Rate = 48000)) or
    not (ChannelCount in [1, 2]) then
    MediaFail('Opus decodes to 8, 12, 16, 24 or 48 kHz, mono or stereo');
  FRaw := TOpusStreamDecoder.Create(Rate, ChannelCount);
  FSampleRate := Rate;
  FChannels := ChannelCount;
  FHead := Default(TOpusHead);
  FHead.Channels := ChannelCount;
  SetChannelOrder;
  SetLength(FPcm, MaximumFrameSamples * ChannelCount);
  FillChar(FClipMemory, SizeOf(FClipMemory), 0);
end;

function TOpusDecoder.DecodeRaw(Data: PByte; Length: Integer; Output: PSingle; MaximumFrames: Integer): Integer;
var
  PacketLength: LongInt;
begin
  if FRaw = nil then
    MediaFail('Opus raw decoder not configured');
  if Length <= 0 then
    Result := FRaw.Decode(nil, 0, Output, Min(MaximumFrames, Max(FRaw.LastPacketDuration, FSampleRate div 400)),
      False, False, PacketLength)
  else
    Result := FRaw.Decode(Data, Length, Output, MaximumFrames, False, False, PacketLength);
end;

function TOpusDecoder.DecodeRawInt16(Data: PByte; Length: Integer; Output: PSmallInt; MaximumFrames: Integer): Integer;
var
  Index: Integer;
  Value: Single;
begin
  Result := DecodeRaw(Data, Length, @FPcm[0], Min(MaximumFrames, MaximumFrameSamples));
  if Result <= 0 then
    Exit;
  OpusSoftClip(@FPcm[0], Result, FChannels, @FClipMemory[0]);
  for Index := 0 to Result * FChannels - 1 do
  begin
    Value := FPcm[Index] * 32768;
    if Value > 32767 then
      Value := 32767
    else if Value < -32768 then
      Value := -32768;
    Output[Index] := Round(Value);
  end;
end;

function TOpusDecoder.GetFinalRange: LongWord;
begin
  if FRaw <> nil then
    Result := FRaw.FinalRange
  else if FMultistream <> nil then
    Result := FMultistream.FinalRange
  else
    Result := 0;
end;

end.
