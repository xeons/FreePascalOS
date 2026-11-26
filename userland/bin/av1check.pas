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
  av1check - checks libav1 on the system

      av1check

  Decodes the AV1 streams built into it (8-bit inter frames with every
  loop filter, 10-bit film grain, 4:4:4 screen content with palettes and
  intra block copy, superres with two tiles) on one thread and on four,
  and compares the hash of every frame shown with the hash of the frame
  libaom's reference decoder gave when the streams were made; then the
  first stream again from a WebM file through libmedia's demuxer and
  decoder registry. Prints a line for each failure and then a summary
  ending in "ok" or "failed"; the exit status is 1 on failure.
  "av1check -w FILE" writes that WebM file instead (for mediaplay -k).
  coretest runs both.
}
program av1check;

{$mode objfpc}
{$H+}

uses
  {$ifdef UNIX}cthreads,{$endif}
  Classes, SysUtils, Media.Frames, Media.Packets, Media.Demuxers, Media.Containers, Media.VideoDecoders,
  Av1.Decoder, Av1.MediaDecoder, Av1Check.Streams;

var
  Failures: Integer = 0;
  FramesChecked: Integer = 0;

{ The 64-bit FNV-1a hash of the frame's planes, as aomdec writes them. }
function HashFrame(const Frame: TVideoFrame): QWord;
var
  Plane, PlaneCount, Row, Column, RowBytes: Integer;
  Data: PByte;
begin
  Result := QWord($cbf29ce484222325);
  if Frame.Layout = plMonochrome then
    PlaneCount := 1
  else
    PlaneCount := 3;
  for Plane := 0 to PlaneCount - 1 do
  begin
    if Frame.BitDepth = 8 then
      RowBytes := Frame.Planes[Plane].Width
    else
      RowBytes := Frame.Planes[Plane].Width * 2;
    for Row := 0 to Frame.Planes[Plane].Height - 1 do
    begin
      Data := @Frame.Planes[Plane].Data[Row * Frame.Planes[Plane].Stride];
      for Column := 0 to RowBytes - 1 do
      begin
        Result := Result xor Data[Column];
        Result := Result * QWord($100000001b3);
      end;
    end;
  end;
end;

function ReadLittleEndian32(Data: PByte): LongWord;
begin
  Result := Data[0] or (Data[1] shl 8) or (Data[2] shl 16) or (LongWord(Data[3]) shl 24);
end;

procedure Fail(const Message: string);
begin
  Inc(Failures);
  WriteLn('av1check: FAIL ', Message);
end;

procedure CheckStream(const Stream: TCheckStream; Threads: Integer);
var
  Decoder: TAv1Decoder;
  Frame: TVideoFrame;
  Offset, FrameSize, Shown: Integer;
  Hash: QWord;
begin
  Shown := 0;
  Decoder := TAv1Decoder.Create(Threads);
  try
    try
      Offset := Stream.Data[6] or (Stream.Data[7] shl 8);
      while Offset + 12 <= Stream.Size do
      begin
        FrameSize := ReadLittleEndian32(Stream.Data + Offset);
        Decoder.Decode(Stream.Data + Offset + 12, FrameSize);
        Inc(Offset, 12 + FrameSize);
        while Decoder.TakeFrame(Frame) do
        begin
          Hash := HashFrame(Frame);
          if Shown >= Stream.FrameCount then
            Fail(Format('%s (%d threads): more frames than expected', [Stream.Name, Threads]))
          else if Hash <> Stream.Hashes[Shown] then
            Fail(Format('%s (%d threads): frame %d differs', [Stream.Name, Threads, Shown]));
          Inc(Shown);
          Inc(FramesChecked);
        end;
      end;
      if Shown <> Stream.FrameCount then
        Fail(Format('%s (%d threads): %d frames shown, expected %d', [Stream.Name, Threads, Shown,
          Stream.FrameCount]));
    except
      on Error: Exception do
        Fail(Format('%s (%d threads): %s', [Stream.Name, Threads, Error.Message]));
    end;
  finally
    Decoder.Free;
  end;
end;

{ The first stream again, from a WebM file through libmedia: its
  Matroska demuxer and the AV1 decoder its registry hands out. }
procedure CheckWebm;
var
  Stream: TBytesStream;
  Demuxer: TMediaDemuxer;
  Track: TMediaTrack;
  Decoder: TVideoDecoder;
  Packet: TMediaPacket;
  Frame: TVideoFrame;
  Data: TBytes;
  Shown: Integer;
begin
  Shown := 0;
  Data := nil;
  SetLength(Data, SizeOf(SampleWebm));
  Move(SampleWebm, Data[0], SizeOf(SampleWebm));
  try
    Stream := TBytesStream.Create(Data);
    Demuxer := OpenMediaStream(Stream, True);
    try
      Track := Demuxer.FirstTrackOf(mkVideo);
      Decoder := CreateVideoDecoder(codecAv1);
      if (Track = nil) or (Decoder = nil) then
      begin
        Fail('webm: no AV1 track or decoder');
        Exit;
      end;
      try
        Decoder.Configure(Track);
        while Demuxer.ReadPacket(Packet) do
        begin
          Decoder.SendPacket(Packet);
          while Decoder.ReceiveFrame(Frame) do
          begin
            if (Shown >= Streams[0].FrameCount) or (HashFrame(Frame) <> Streams[0].Hashes[Shown]) then
              Fail(Format('webm: frame %d differs', [Shown]));
            Inc(Shown);
            Inc(FramesChecked);
          end;
        end;
      finally
        Decoder.Free;
      end;
    finally
      Demuxer.Free;
    end;
    if Shown <> Streams[0].FrameCount then
      Fail(Format('webm: %d frames shown, expected %d', [Shown, Streams[0].FrameCount]));
  except
    on Error: Exception do
      Fail('webm: ' + Error.Message);
  end;
end;

{ av1check -w FILE: writes the WebM sample, for mediaplay. }
procedure WriteSample(const FileName: string);
var
  Output: TFileStream;
begin
  Output := TFileStream.Create(FileName, fmCreate);
  try
    Output.WriteBuffer(SampleWebm, SizeOf(SampleWebm));
  finally
    Output.Free;
  end;
end;

var
  Index: Integer;
begin
  if (ParamCount = 2) and (ParamStr(1) = '-w') then
  begin
    WriteSample(ParamStr(2));
    Exit;
  end;
  for Index := 0 to StreamCount - 1 do
  begin
    CheckStream(Streams[Index], 1);
    CheckStream(Streams[Index], 4);
  end;
  CheckWebm;
  if Failures = 0 then
    WriteLn(Format('av1check: %d streams and a WebM file, %d frames, ok', [StreamCount, FramesChecked]))
  else
  begin
    WriteLn(Format('av1check: %d streams and a WebM file, %d frames, failed', [StreamCount, FramesChecked]));
    Halt(1);
  end;
end.
