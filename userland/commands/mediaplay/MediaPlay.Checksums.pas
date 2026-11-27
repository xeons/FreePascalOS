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
  mediaplay --checksum: decodes every track and prints checksums
  instead of playing, so a file's decoding can be compared with another
  decoder's (ffmpeg -f framemd5 style):

    video TRACK FRAME PTS WIDTHxHEIGHT MD5   for each decoded frame: the
                                             MD5 of its planes' visible
                                             samples, row by row
    packet TRACK NUMBER PTS SIZE MD5         for each packet of a track
                                             without a decoder
    audio TRACK FRAMES RATE CHANNELS MD5     for each audio track: the
                                             MD5 of all its samples as
                                             16-bit little-endian
}
unit MediaPlay.Checksums;

{$mode objfpc}
{$H+}

interface

uses
  Media.Demuxers;

{ Prints the checksums of Demuxer's tracks; False if a decoder failed. }
function PrintChecksums(Demuxer: TMediaDemuxer): Boolean;

implementation

uses
  SysUtils,
  Crypto.Digests,
  Media.Errors,
  Media.Frames,
  Media.Packets,
  Media.AudioDecoders,
  Media.AudioCodecs,
  Media.VideoDecoders,
  Media.AudioConversion;

type
  TTrackState = record
    AudioDecoder: TAudioDecoder;
    VideoDecoder: TVideoDecoder;
    Digest: TDigestContext;
    Count: Int64;
  end;

function DigestText(var Context: TDigestContext): string;
var
  Output: TDigestOutput;
begin
  FinishDigest(Context, Output);
  Result := HexText(@Output[0], DigestSize(DigestMd5));
end;

function FrameDigest(const Frame: TVideoFrame): string;
var
  Context: TDigestContext;
  PlaneIndex, Row, RowBytes, BytesPerSample: Integer;
begin
  BeginDigest(Context, DigestMd5);
  if Frame.BitDepth > 8 then
    BytesPerSample := 2
  else
    BytesPerSample := 1;
  for PlaneIndex := 0 to 2 do
    with Frame.Planes[PlaneIndex] do
    begin
      RowBytes := Width * BytesPerSample;
      for Row := 0 to Height - 1 do
        UpdateDigest(Context, @Data[Row * Stride], RowBytes);
    end;
  Result := DigestText(Context);
end;

procedure PrintVideoFrames(TrackIndex: Integer; var State: TTrackState);
var
  Frame: TVideoFrame;
begin
  while State.VideoDecoder.ReceiveFrame(Frame) do
  begin
    WriteLn(Format('video %d %d %d %dx%d %s', [TrackIndex, State.Count, Frame.PresentationTime, Frame.Width,
      Frame.Height, FrameDigest(Frame)]));
    Inc(State.Count);
  end;
end;

procedure AddAudio(var State: TTrackState; const Buffer: TAudioBuffer);
var
  Bytes: TBytes;
begin
  if Length(Buffer.Samples) = 0 then
    Exit;
  Bytes := nil;
  SetLength(Bytes, Length(Buffer.Samples) * 2);
  EncodeOutputSamples(@Buffer.Samples[0], Length(Buffer.Samples), OutputSigned16, @Bytes[0]);
  UpdateDigest(State.Digest, @Bytes[0], Length(Bytes));
  Inc(State.Count, AudioFrameCount(Buffer));
end;

function PrintChecksums(Demuxer: TMediaDemuxer): Boolean;
var
  States: array of TTrackState;
  Index: Integer;
  Track: TMediaTrack;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Context: TDigestContext;
  PacketNumbers: array of Int64;
begin
  Result := True;
  States := nil;
  SetLength(States, Demuxer.TrackCount);
  PacketNumbers := nil;
  SetLength(PacketNumbers, Demuxer.TrackCount);
  try
    for Index := 0 to Demuxer.TrackCount - 1 do
    begin
      Track := Demuxer.Tracks[Index];
      States[Index] := Default(TTrackState);
      BeginDigest(States[Index].Digest, DigestMd5);
      try
        case Track.Kind of
          mkAudio:
            if AudioDecoderClassOf(Track.Codec) <> nil then
              States[Index].AudioDecoder := CreateAudioDecoder(Track);
          mkVideo:
            begin
              States[Index].VideoDecoder := CreateVideoDecoder(Track.Codec);
              if States[Index].VideoDecoder <> nil then
                States[Index].VideoDecoder.Configure(Track);
            end;
        end;
      except
        on Error: EMediaError do
        begin
          WriteLn(Format('track %d: %s', [Index, Error.Message]));
          FreeAndNil(States[Index].VideoDecoder);
          Result := False;
        end;
      end;
    end;
    Buffer := Default(TAudioBuffer);
    while Demuxer.ReadPacket(Packet) do
    begin
      Index := Packet.TrackIndex;
      if (Index < 0) or (Index >= Length(States)) then
        Continue;
      try
        if States[Index].AudioDecoder <> nil then
        begin
          if States[Index].AudioDecoder.Decode(Packet, Buffer) then
            AddAudio(States[Index], Buffer);
        end
        else if States[Index].VideoDecoder <> nil then
        begin
          States[Index].VideoDecoder.SendPacket(Packet);
          PrintVideoFrames(Index, States[Index]);
        end
        else
        begin
          BeginDigest(Context, DigestMd5);
          if Length(Packet.Data) > 0 then
            UpdateDigest(Context, @Packet.Data[0], Length(Packet.Data));
          WriteLn(Format('packet %d %d %d %d %s', [Index, PacketNumbers[Index], Packet.PresentationTime,
            Length(Packet.Data), DigestText(Context)]));
          Inc(PacketNumbers[Index]);
        end;
      except
        on Error: EMediaError do
        begin
          WriteLn(Format('track %d packet at %d: %s', [Index, Packet.PresentationTime, Error.Message]));
          Result := False;
        end;
      end;
    end;
    for Index := 0 to High(States) do
    begin
      if States[Index].VideoDecoder <> nil then
      begin
        States[Index].VideoDecoder.Flush;
        PrintVideoFrames(Index, States[Index]);
      end;
      if States[Index].AudioDecoder <> nil then
        WriteLn(Format('audio %d %d %d %d %s', [Index, States[Index].Count, States[Index].AudioDecoder.SampleRate,
          States[Index].AudioDecoder.Channels, DigestText(States[Index].Digest)]));
    end;
  finally
    for Index := 0 to High(States) do
    begin
      States[Index].AudioDecoder.Free;
      States[Index].VideoDecoder.Free;
    end;
  end;
end;

end.
