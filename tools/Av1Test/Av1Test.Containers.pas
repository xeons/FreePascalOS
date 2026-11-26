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
  AV1 in containers, end to end: a WebM, MP4 or OBU file opened by
  libmedia (Media.Containers), its video track decoded through
  libmedia's decoder registry (the TVideoDecoder Av1.MediaDecoder
  registers), the frames in the order they come out.
}
unit Av1Test.Containers;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Media.Frames, Media.Packets, Media.Demuxers, Media.Containers, Media.VideoDecoders,
  Av1.MediaDecoder;

type
  TVideoFrames = array of TVideoFrame;

{ Every frame of the file's first video track; raises on failure. }
function DecodeContainerFile(const FileName: string): TVideoFrames;

implementation

function DecodeContainerFile(const FileName: string): TVideoFrames;
var
  Demuxer: TMediaDemuxer;
  Track: TMediaTrack;
  Decoder: TVideoDecoder;
  Packet: TMediaPacket;
  Frame: TVideoFrame;
  Count: Integer;

  procedure TakeFrames;
  begin
    while Decoder.ReceiveFrame(Frame) do
    begin
      if Count = Length(Result) then
        SetLength(Result, Count * 2 + 4);
      Result[Count] := Frame;
      Inc(Count);
    end;
  end;

begin
  Result := nil;
  Count := 0;
  Demuxer := OpenMediaFile(FileName);
  try
    Track := Demuxer.FirstTrackOf(mkVideo);
    if (Track = nil) or (Track.Codec <> codecAv1) then
      raise Exception.Create('no AV1 video track');
    Decoder := CreateVideoDecoder(codecAv1);
    if Decoder = nil then
      raise Exception.Create('no AV1 decoder registered');
    try
      Decoder.Configure(Track);
      while Demuxer.ReadPacket(Packet) do
        if Packet.TrackIndex = Track.Index then
        begin
          Decoder.SendPacket(Packet);
          TakeFrames;
        end;
      Decoder.Flush;
      TakeFrames;
    finally
      Decoder.Free;
    end;
  finally
    Demuxer.Free;
  end;
  SetLength(Result, Count);
end;

end.
