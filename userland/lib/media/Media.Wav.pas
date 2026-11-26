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
  WAV files: RIFF WAVE (and RF64, its 64-bit form) holding PCM (8-bit
  unsigned, 16, 24 and 32-bit signed), IEEE floats (32 and 64-bit),
  WAVE_FORMAT_EXTENSIBLE with either, or MPEG Layer III (format 0x55).

  The data chunk is cut into packets of PacketFrames sample frames
  (whole MP3 frames are found by the MP3 decoder itself, so MP3 data
  goes as is, in pieces); seeking is a multiplication.
}
unit Media.Wav;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Media.Packets,
  Media.Demuxers,
  Media.ByteReaders;

type
  TWavDemuxer = class(TMediaDemuxer)
  private
    FReader: TMediaReader;
    FDataStart, FDataSize: Int64;
    FBlockAlign: Integer;
    FNextFrame: Int64;
    FTrack: TMediaTrack;
    procedure ReadFormat(const Chunk: TBytes);
    function FrameCount: Int64;
  public
    destructor Destroy; override;
    class function Recognizes(const Head: TBytes): Boolean; override;
    procedure Open; override;
    function ReadPacket(out Packet: TMediaPacket): Boolean; override;
    function SeekTo(Microseconds: Int64): Boolean; override;
    function FormatName: string; override;
  end;

const
  WavPacketFrames = 4096;
  { Bytes per packet for compressed data (MP3 in WAV). }
  WavCompressedPacketBytes = 8192;

implementation

uses
  Media.Errors;

const
  FormatPcm = 1;
  FormatFloat = 3;
  FormatMpegLayer3 = $55;
  FormatExtensible = $FFFE;

destructor TWavDemuxer.Destroy;
begin
  FReader.Free;
  inherited Destroy;
end;

class function TWavDemuxer.Recognizes(const Head: TBytes): Boolean;
begin
  Result := (Length(Head) >= 12) and ((FourCCAt(Head, 0) = 'RIFF') or (FourCCAt(Head, 0) = 'RF64'))
    and (FourCCAt(Head, 8) = 'WAVE');
end;

function TWavDemuxer.FormatName: string;
begin
  Result := 'wav';
end;

procedure TWavDemuxer.ReadFormat(const Chunk: TBytes);
var
  Tag, Bits: Integer;
begin
  if Length(Chunk) < 16 then
    MediaFail('WAV format chunk too short');
  Tag := LittleEndian16(Chunk, 0);
  FTrack.Channels := LittleEndian16(Chunk, 2);
  FTrack.SampleRate := LittleEndian32(Chunk, 4);
  FBlockAlign := LittleEndian16(Chunk, 12);
  Bits := LittleEndian16(Chunk, 14);
  if (Tag = FormatExtensible) and (Length(Chunk) >= 40) then
  begin
    { The sub-format GUID's first two bytes are the format tag. Valid
      bits fewer than the container's (at 18) still leave samples the
      container's width, which is what is decoded. }
    Tag := LittleEndian16(Chunk, 24);
  end;
  if (FTrack.Channels < 1) or (FTrack.SampleRate < 1) then
    MediaFail('WAV format has no channels or rate');
  FTrack.TimeBase := MakeTimeBase(1, FTrack.SampleRate);
  case Tag of
    FormatPcm, FormatFloat:
      begin
        FTrack.Codec := codecPcm;
        FTrack.CodecName := 'pcm';
        FTrack.PcmFloat := Tag = FormatFloat;
        FTrack.BitsPerSample := Bits;
        if FTrack.PcmFloat and not (Bits in [32, 64]) then
          MediaFailUnsupported(Format('%d-bit float WAV', [Bits]));
        if not FTrack.PcmFloat and not (Bits in [8, 16, 24, 32]) then
          MediaFailUnsupported(Format('%d-bit PCM WAV', [Bits]));
        if FBlockAlign <> FTrack.Channels * (Bits div 8) then
          FBlockAlign := FTrack.Channels * (Bits div 8);
      end;
    FormatMpegLayer3:
      begin
        FTrack.Codec := codecMp3;
        FTrack.CodecName := 'mp3';
        FBlockAlign := 0;
      end;
  else
    MediaFailUnsupported(Format('WAV format tag 0x%x', [Tag]));
  end;
end;

procedure TWavDemuxer.Open;
var
  Tag: string;
  ChunkSize, RiffSize64, DataSize64: Int64;
  HaveFormat, IsRf64: Boolean;
  FormatChunk: TBytes;
begin
  FReader := TMediaReader.Create(FStream);
  FReader.Position := 0;
  Tag := FReader.ReadFourCC;
  IsRf64 := Tag = 'RF64';
  FReader.ReadU32LE;
  if FReader.ReadFourCC <> 'WAVE' then
    MediaFail('not a WAVE file');
  FTrack := AddTrack;
  FTrack.Kind := mkAudio;
  HaveFormat := False;
  DataSize64 := -1;
  FDataStart := -1;
  while not FReader.AtEnd do
  begin
    if FReader.Size - FReader.Position < 8 then
      Break;
    Tag := FReader.ReadFourCC;
    ChunkSize := FReader.ReadU32LE;
    if Tag = 'ds64' then
    begin
      RiffSize64 := Int64(FReader.ReadU64LE);
      DataSize64 := Int64(FReader.ReadU64LE);
      if RiffSize64 < 0 then
        MediaFail('bad RF64 size');
      FReader.Skip(ChunkSize - 16);
    end
    else if Tag = 'fmt ' then
    begin
      FormatChunk := FReader.ReadBytes(ChunkSize);
      ReadFormat(FormatChunk);
      HaveFormat := True;
      if ((ChunkSize and 1) <> 0) and not FReader.AtEnd then
        FReader.Skip(1);
    end
    else if Tag = 'data' then
    begin
      FDataStart := FReader.Position;
      if IsRf64 and (ChunkSize = $FFFFFFFF) and (DataSize64 >= 0) then
        FDataSize := DataSize64
      else
        FDataSize := ChunkSize;
      { A size past the end (a recording cut short, or streamed with an
        unknown size) means: to the end. }
      if FDataStart + FDataSize > FReader.Size then
        FDataSize := FReader.Size - FDataStart;
      Break;
    end
    else
      FReader.Skip(Int64(ChunkSize) + (ChunkSize and 1));
  end;
  if not HaveFormat then
    MediaFail('WAV file has no format chunk');
  if FDataStart < 0 then
    MediaFail('WAV file has no data chunk');
  if FBlockAlign > 0 then
  begin
    FTrack.Duration := FrameCount;
    FDuration := FTrack.ToMicroseconds(FTrack.Duration);
  end;
  FNextFrame := 0;
  FReader.Position := FDataStart;
end;

function TWavDemuxer.FrameCount: Int64;
begin
  if FBlockAlign > 0 then
    Result := FDataSize div FBlockAlign
  else
    Result := FDataSize;
end;

function TWavDemuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
var
  Offset, Count: Int64;
begin
  Packet := NewPacket(0);
  if FBlockAlign > 0 then
  begin
    Offset := FNextFrame * FBlockAlign;
    Count := FrameCount - FNextFrame;
    if Count > WavPacketFrames then
      Count := WavPacketFrames;
    if Count <= 0 then
      Exit(False);
    FReader.Position := FDataStart + Offset;
    Packet.Data := FReader.ReadBytes(Count * FBlockAlign);
    Packet.PresentationTime := FNextFrame;
    Packet.DecodeTime := FNextFrame;
    Packet.Duration := Count;
    Packet.KeyFrame := True;
    Inc(FNextFrame, Count);
  end
  else
  begin
    { Compressed: FNextFrame counts bytes. }
    Count := FDataSize - FNextFrame;
    if Count > WavCompressedPacketBytes then
      Count := WavCompressedPacketBytes;
    if Count <= 0 then
      Exit(False);
    FReader.Position := FDataStart + FNextFrame;
    Packet.Data := FReader.ReadBytes(Count);
    Packet.KeyFrame := FNextFrame = 0;
    Inc(FNextFrame, Count);
  end;
  Result := True;
end;

function TWavDemuxer.SeekTo(Microseconds: Int64): Boolean;
var
  Frame: Int64;
begin
  if FBlockAlign <= 0 then
  begin
    if Microseconds <> 0 then
      Exit(False);
    FNextFrame := 0;
    Exit(True);
  end;
  Frame := FTrack.FromMicroseconds(Microseconds);
  if Frame < 0 then
    Frame := 0;
  if Frame > FrameCount then
    Frame := FrameCount;
  FNextFrame := Frame;
  Result := True;
end;

end.
