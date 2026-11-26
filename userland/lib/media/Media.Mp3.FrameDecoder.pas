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
  Decoding one whole Layer III frame: side information, the bit
  reservoir (main data may start up to 511 bytes back, in earlier
  frames), then for each granule and channel scale factors and Huffman
  data, joint stereo, reordering, alias reduction, IMDCT and synthesis.

  The state carried from frame to frame is the reservoir, the IMDCT
  overlap and the synthesis filter's history; Reset clears it (a seek).
  A frame whose main data begins before what the reservoir holds (the
  first frames after a seek) decodes to silence, so the timing stays.
}
unit Media.Mp3.FrameDecoder;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Mp3.BitStream,
  Media.Mp3.SideInfo,
  Media.Mp3.Scalefactors,
  Media.Mp3.Hybrid,
  Media.Mp3.Synthesis;

const
  Mp3MaximumReservoirBytes = 511;
  Mp3MaximumFramePayload = 2304;
  { The most samples one frame decodes to (both channels). }
  Mp3MaximumFrameSamples = 1152 * 2;

type
  TMp3FrameStatus = (mfDecoded, mfSilence, mfBroken, mfUnsupported);

  TMp3FrameDecoder = class
  private
    FReservoir: array[0..Mp3MaximumReservoirBytes - 1] of Byte;
    FReservoirBytes: Integer;
    FOverlap: array[0..1] of TMp3Overlap;
    FSynthesisState: TMp3SynthesisState;
    { Scratch for one frame. }
    FMainData: array[0..Mp3MaximumReservoirBytes + Mp3MaximumFramePayload + 15] of Byte;
    FMainStream: TMp3BitStream;
    FGranules: TMp3GranuleInfos;
    FLines: array[0..2 * 576 - 1] of Single;
    FMultipliers: TMp3BandMultipliers;
    FIntensityPositions: array[0..1] of TMp3IntensityPositions;
    FWork: TMp3SynthesisLines;
    function RestoreReservoir(var FrameStream: TMp3BitStream; MainDataBegin: Integer): Boolean;
    procedure SaveReservoir;
    procedure DecodeGranule(Header: PByte; Granules: PMp3GranuleInfo; Channels: Integer);
  public
    constructor Create;
    procedure Reset;
    { Decodes the frame at Frame (FrameBytes long, header included) into
      Output (interleaved floats: HeaderFrameSamples * channels). }
    function DecodeFrame(Frame: PByte; FrameBytes: Integer; Output: PSingle): TMp3FrameStatus;
  end;

implementation

uses
  Media.Mp3.Header,
  Media.Mp3.Huffman,
  Media.Mp3.Stereo;

constructor TMp3FrameDecoder.Create;
begin
  inherited Create;
  Reset;
end;

procedure TMp3FrameDecoder.Reset;
begin
  FReservoirBytes := 0;
  FillChar(FOverlap, SizeOf(FOverlap), 0);
  FillChar(FSynthesisState, SizeOf(FSynthesisState), 0);
end;

function TMp3FrameDecoder.RestoreReservoir(var FrameStream: TMp3BitStream; MainDataBegin: Integer): Boolean;
var
  FrameBytes, BytesHave, From: Integer;
begin
  FrameBytes := (FrameStream.Limit - FrameStream.Position) div 8;
  BytesHave := FReservoirBytes;
  if BytesHave > MainDataBegin then
    BytesHave := MainDataBegin;
  From := FReservoirBytes - MainDataBegin;
  if From < 0 then
    From := 0;
  if BytesHave > 0 then
    Move(FReservoir[From], FMainData[0], BytesHave);
  if FrameBytes > 0 then
    Move((FrameStream.Data + FrameStream.Position div 8)^, FMainData[BytesHave], FrameBytes);
  { Slack for the Huffman decoder's look-ahead. }
  FillChar(FMainData[BytesHave + FrameBytes], 16, 0);
  InitBitStream(FMainStream, @FMainData[0], BytesHave + FrameBytes);
  Result := FReservoirBytes >= MainDataBegin;
end;

procedure TMp3FrameDecoder.SaveReservoir;
var
  Position, Remains: Integer;
begin
  Position := (FMainStream.Position + 7) div 8;
  Remains := FMainStream.Limit div 8 - Position;
  if Remains > Mp3MaximumReservoirBytes then
  begin
    Inc(Position, Remains - Mp3MaximumReservoirBytes);
    Remains := Mp3MaximumReservoirBytes;
  end;
  if Remains > 0 then
    Move(FMainData[Position], FReservoir[0], Remains)
  else
    Remains := 0;
  FReservoirBytes := Remains;
end;

procedure TMp3FrameDecoder.DecodeGranule(Header: PByte; Granules: PMp3GranuleInfo; Channels: Integer);
var
  Channel, Limit, AliasBands, LongBands: Integer;
  Granule: PMp3GranuleInfo;
begin
  for Channel := 0 to Channels - 1 do
  begin
    Granule := Granules + Channel;
    Limit := FMainStream.Position + Granule^.Part23Length;
    DecodeScalefactors(Header, FIntensityPositions[Channel], FMainStream, Granule^, FMultipliers, Channel);
    DecodeHuffman(@FLines[576 * Channel], FMainStream, Granule^, @FMultipliers[0], Limit);
  end;
  if HeaderHasIntensityStereo(Header) then
    IntensityStereo(@FLines[0], FIntensityPositions[1], Granules, Header)
  else if HeaderIsMidSideStereo(Header) then
    MidSideStereo(@FLines[0], 576);
  for Channel := 0 to Channels - 1 do
  begin
    Granule := Granules + Channel;
    AliasBands := 31;
    if Granule^.MixedBlockFlag <> 0 then
    begin
      { Mixed blocks: the first 36 lines (two subbands; four at MPEG-2.5's
        8 kHz) are long. }
      if HeaderRateIndex(Header) = 2 then
        LongBands := 4
      else
        LongBands := 2;
    end
    else
      LongBands := 0;
    if Granule^.ShortBandCount <> 0 then
    begin
      AliasBands := LongBands - 1;
      ReorderShortLines(@FLines[576 * Channel + LongBands * 18], @FWork[0],
        Granule^.BandWidths + Granule^.LongBandCount);
    end;
    ReduceAliasing(@FLines[576 * Channel], AliasBands);
    InverseTransformGranule(@FLines[576 * Channel], FOverlap[Channel], Granule^.BlockType, LongBands);
    InvertOddSubbands(@FLines[576 * Channel]);
  end;
end;

function TMp3FrameDecoder.DecodeFrame(Frame: PByte; FrameBytes: Integer; Output: PSingle): TMp3FrameStatus;
var
  FrameStream: TMp3BitStream;
  MainDataBegin, Channels, GranuleCount, GranuleIndex, SampleCount: Integer;
  Enough: Boolean;
begin
  Channels := HeaderChannels(Frame);
  SampleCount := HeaderFrameSamples(Frame) * Channels;
  if HeaderLayer(Frame) <> 1 then
  begin
    FillChar(Output^, SampleCount * SizeOf(Single), 0);
    Exit(mfUnsupported);
  end;
  if FrameBytes - Mp3HeaderSize > Mp3MaximumFramePayload then
    FrameBytes := Mp3MaximumFramePayload + Mp3HeaderSize;
  InitBitStream(FrameStream, Frame + Mp3HeaderSize, FrameBytes - Mp3HeaderSize);
  if HeaderHasCrc(Frame) then
    GetBits(FrameStream, 16);
  MainDataBegin := ReadSideInfo(FrameStream, FGranules, Frame);
  if (MainDataBegin < 0) or (FrameStream.Position > FrameStream.Limit) then
  begin
    FillChar(Output^, SampleCount * SizeOf(Single), 0);
    FReservoirBytes := 0;
    Exit(mfBroken);
  end;
  Enough := RestoreReservoir(FrameStream, MainDataBegin);
  if HeaderIsMpeg1(Frame) then
    GranuleCount := 2
  else
    GranuleCount := 1;
  if Enough then
  begin
    for GranuleIndex := 0 to GranuleCount - 1 do
    begin
      FillChar(FLines, SizeOf(FLines), 0);
      DecodeGranule(Frame, @FGranules[GranuleIndex * Channels], Channels);
      SynthesizeGranule(FSynthesisState, @FLines[0], 18, Channels, Output + GranuleIndex * 576 * Channels, FWork);
    end;
    Result := mfDecoded;
  end
  else
  begin
    FillChar(Output^, SampleCount * SizeOf(Single), 0);
    Result := mfSilence;
  end;
  SaveReservoir;
end;

end.
