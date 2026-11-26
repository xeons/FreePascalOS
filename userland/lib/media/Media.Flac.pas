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
  The FLAC decoder (RFC 9639): one frame per packet.

  The frame header gives the block size, rate, channels, their
  assignment and the sample size; each channel is a subframe
  (Media.Flac.Subframes), the side channel of a stereo pair one bit
  wider; then the pair is decorrelated (left/side, side/right,
  mid/side), the frame's CRC-16 checked, and the integers scaled to
  floats by 2^(bits - 1), which is exact.

  DecodeFrameIntegers gives the integer samples themselves, for the
  STREAMINFO MD5 check and the tests.
}
unit Media.Flac;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Media.Frames,
  Media.Packets,
  Media.AudioDecoders,
  Media.Flac.Headers,
  Media.Flac.Subframes;

type
  TFlacDecoder = class(TAudioDecoder)
  private
    FInfo: TFlacStreamInfo;
    FChannelSamples: array[0..7] of TFlacSamples;
    FBitsPerSample: Integer;
    FBlockSize: Integer;
  public
    procedure Configure(Track: TMediaTrack); override;
    { Sets the stream up from a STREAMINFO body directly. }
    procedure ConfigureStreamInfo(const StreamInfo: TBytes);
    function Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean; override;
    { Decodes one frame into the decoder's channel buffers (Samples);
      raises EMediaError for a broken frame. }
    procedure DecodeFrameIntegers(Data: PByte; Size: Integer);
    { The last frame's samples of Channel (BlockSize of them). }
    function Samples(Channel: Integer): PInt64;
    property BlockSize: Integer read FBlockSize;
    property BitsPerSample: Integer read FBitsPerSample;
    property StreamInfo: TFlacStreamInfo read FInfo;
  end;

implementation

uses
  Media.Errors,
  Media.Flac.BitReader;

procedure TFlacDecoder.Configure(Track: TMediaTrack);
begin
  if Length(Track.Headers) > 0 then
    ConfigureStreamInfo(Track.Headers[0])
  else
  begin
    { No STREAMINFO: every frame header has to say everything. }
    FInfo := Default(TFlacStreamInfo);
    FInfo.SampleRate := Track.SampleRate;
    FInfo.Channels := Track.Channels;
    FInfo.BitsPerSample := Track.BitsPerSample;
    FSampleRate := Track.SampleRate;
    FChannels := Track.Channels;
  end;
  FPendingSkip := Track.CodecDelay;
end;

procedure TFlacDecoder.ConfigureStreamInfo(const StreamInfo: TBytes);
begin
  if not ParseFlacStreamInfo(StreamInfo, FInfo) then
    MediaFail('bad FLAC STREAMINFO');
  FSampleRate := FInfo.SampleRate;
  FChannels := FInfo.Channels;
  FBitsPerSample := FInfo.BitsPerSample;
end;

function TFlacDecoder.Samples(Channel: Integer): PInt64;
begin
  Result := @FChannelSamples[Channel][0];
end;

procedure TFlacDecoder.DecodeFrameIntegers(Data: PByte; Size: Integer);
var
  Header: TFlacFrameHeader;
  Reader: TFlacBitReader;
  Channel, Index, ChannelBits, FrameEnd: Integer;
  Left, Right, Mid, Side: PInt64;
  MidValue, SideValue: Int64;
begin
  if not ParseFlacFrameHeader(Data, Size, FInfo, Header) then
    MediaFail('bad FLAC frame header');
  if (Header.BitsPerSample > 32) or (Header.Channels > 8) then
    MediaFail('bad FLAC frame header');
  for Channel := 0 to Header.Channels - 1 do
    if Length(FChannelSamples[Channel]) < Header.BlockSize then
      SetLength(FChannelSamples[Channel], Header.BlockSize);
  StartBitReader(Reader, Data + Header.Length, Size - Header.Length);
  for Channel := 0 to Header.Channels - 1 do
  begin
    ChannelBits := Header.BitsPerSample;
    case Header.Assignment of
      caLeftSide, caMidSide:
        if Channel = 1 then
          Inc(ChannelBits);
      caSideRight:
        if Channel = 0 then
          Inc(ChannelBits);
    end;
    if not DecodeFlacSubframe(Reader, Header.BlockSize, ChannelBits, @FChannelSamples[Channel][0]) then
      MediaFail('bad FLAC subframe');
  end;
  AlignToByte(Reader);
  FrameEnd := Header.Length + BytePosition(Reader) + 2;
  if (FrameEnd > Size) or (FlacCrc16(Data, FrameEnd) <> 0) then
    MediaFail('FLAC frame CRC mismatch');
  if Header.Channels = 2 then
  begin
    Left := @FChannelSamples[0][0];
    Right := @FChannelSamples[1][0];
    case Header.Assignment of
      caLeftSide:
        for Index := 0 to Header.BlockSize - 1 do
          Right[Index] := Left[Index] - Right[Index];
      caSideRight:
        for Index := 0 to Header.BlockSize - 1 do
          Left[Index] := Left[Index] + Right[Index];
      caMidSide:
        begin
          Mid := Left;
          Side := Right;
          for Index := 0 to Header.BlockSize - 1 do
          begin
            SideValue := Side[Index];
            MidValue := (Mid[Index] shl 1) or (SideValue and 1);
            Left[Index] := SarInt64(MidValue + SideValue, 1);
            Right[Index] := SarInt64(MidValue - SideValue, 1);
          end;
        end;
    end;
  end;
  FBlockSize := Header.BlockSize;
  FBitsPerSample := Header.BitsPerSample;
  FChannels := Header.Channels;
  FSampleRate := Header.SampleRate;
end;

function TFlacDecoder.Decode(const Packet: TMediaPacket; var Output: TAudioBuffer): Boolean;
var
  Channel, Index, ChannelCount: Integer;
  Scale: Double;
  Source: PInt64;
  Target: PSingle;
begin
  if Length(Packet.Data) = 0 then
    MediaFail('empty FLAC packet');
  DecodeFrameIntegers(@Packet.Data[0], Length(Packet.Data));
  ChannelCount := FChannels;
  Output.SampleRate := FSampleRate;
  Output.Channels := ChannelCount;
  Output.PresentationTime := Packet.PresentationTime;
  Output.Samples := nil;
  SetLength(Output.Samples, FBlockSize * ChannelCount);
  Scale := 1 / (Int64(1) shl (FBitsPerSample - 1));
  for Channel := 0 to ChannelCount - 1 do
  begin
    Source := @FChannelSamples[Channel][0];
    Target := @Output.Samples[Channel];
    for Index := 0 to FBlockSize - 1 do
    begin
      Target^ := Source[Index] * Scale;
      Inc(Target, ChannelCount);
    end;
  end;
  ApplyTrim(Output, Packet);
  Result := True;
end;

end.
