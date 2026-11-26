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
  End to end: test streams put in WebM and MP4 files (by ffmpeg, without
  re-encoding) read with libmedia's demuxers and decoded through its
  decoder registry, as mediaplay -k does; every picture must have the
  reference decoder's MD5. Directory/containers.txt lists 'file md5file'.
}
unit VideoTest.Containers;

{$mode objfpc}
{$H+}

interface

procedure CheckContainers(const Directory: string);

implementation

uses
  SysUtils, Classes, TestChecks, Media.Frames, Media.Packets, Media.Demuxers, Media.Containers,
  Media.VideoDecoders, Video.MediaDecoders, VideoTest.Streams;

function DecodeFile(const Path: string): TStringArray;
var
  Demuxer: TMediaDemuxer;
  Decoder: TVideoDecoder;
  Packet: TMediaPacket;
  Frame: TVideoFrame;
  Index, VideoTrack: LongInt;
begin
  Result := nil;
  Demuxer := OpenMediaFile(Path);
  Decoder := nil;
  try
    VideoTrack := -1;
    for Index := 0 to Demuxer.TrackCount - 1 do
      if (VideoTrack < 0) and (Demuxer.Tracks[Index].Kind = mkVideo) then
        VideoTrack := Index;
    if VideoTrack < 0 then
      raise Exception.Create('no video track');
    VideoThreadCount := 2;
    Decoder := CreateVideoDecoder(Demuxer.Tracks[VideoTrack].Codec);
    if Decoder = nil then
      raise Exception.Create('no decoder for ' + CodecIdName(Demuxer.Tracks[VideoTrack].Codec));
    Decoder.Configure(Demuxer.Tracks[VideoTrack]);
    while Demuxer.ReadPacket(Packet) do
    begin
      if Packet.TrackIndex <> VideoTrack then
        Continue;
      Decoder.SendPacket(Packet);
      while Decoder.ReceiveFrame(Frame) do
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := FrameMd5(Frame);
      end;
    end;
    Decoder.Flush;
    while Decoder.ReceiveFrame(Frame) do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := FrameMd5(Frame);
    end;
  finally
    Decoder.Free;
    Demuxer.Free;
  end;
end;

procedure CheckContainers(const Directory: string);
var
  List: TStringList;
  Index, Separator, Frame: LongInt;
  Line, FileName: string;
  Expected, Actual: TStringArray;
  Same: Boolean;
begin
  List := TStringList.Create;
  try
    List.LoadFromFile(IncludeTrailingPathDelimiter(Directory) + 'containers.txt');
    for Index := 0 to List.Count - 1 do
    begin
      Line := Trim(List[Index]);
      Separator := Pos(' ', Line);
      if Separator = 0 then
        Continue;
      FileName := Copy(Line, 1, Separator - 1);
      Expected := ReadExpected(IncludeTrailingPathDelimiter(Directory) + Trim(Copy(Line, Separator + 1, MaxInt)));
      try
        Actual := DecodeFile(IncludeTrailingPathDelimiter(Directory) + FileName);
      except
        on E: Exception do
        begin
          Check(False, FileName + ': ' + E.ClassName + ': ' + E.Message);
          Continue;
        end;
      end;
      Same := Length(Actual) = Length(Expected);
      if Same then
        for Frame := 0 to High(Actual) do
          if Actual[Frame] <> Expected[Frame] then
            Same := False;
      Check(Same, Format('%s through libmedia: %d pictures bit exact', [FileName, Length(Expected)]));
      if not Same then
        WriteLn(Format('     %d pictures decoded, %d expected', [Length(Actual), Length(Expected)]));
    end;
  finally
    List.Free;
  end;
end;

end.
