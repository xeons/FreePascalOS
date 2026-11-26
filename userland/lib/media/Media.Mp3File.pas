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
  MPEG audio elementary streams (.mp3 files): one track, one packet per
  frame.

  ID3v2 tags at the start and ID3v1 / APE tags at the end are skipped
  (Media.Mp3.Tags). The first frame is found by its header and checked by
  the headers of the frames after it; every later frame must match it
  (version, layer, rate), and when one does not (damage, a tag in the
  middle) the next matching frame is looked for.

  A Xing / Info or VBRI first frame gives the frame count (so the
  duration) and a seek table, and is not passed on; LAME's tag in it
  gives the encoder delay and padding, which become the track's
  CodecDelay (delay + 529, the decoder's own delay) and the last packet's
  TrimEnd (padding - 529), so the decoded audio is exactly what was
  encoded. Without a table, seeking assumes a constant bit rate.

  Times are in samples (TimeBase 1 / rate), counted on the decoded audio
  after the delay is dropped.
}
unit Media.Mp3File;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Classes,
  SysUtils,
  Media.Packets,
  Media.Demuxers,
  Media.Mp3.Tags;

type
  TMp3Demuxer = class(TMediaDemuxer)
  private
    FTrack: TMediaTrack;
    FHeader: array[0..3] of Byte;
    FFreeFormatBytes: Integer;
    FFrameSamples: Integer;
    { The first frame (maybe the information frame), the first audio
      frame and the end of the audio. }
    FFirstFrame, FAudioStart, FAudioEnd: Int64;
    FInfo: TMp3StreamInfo;
    FPosition: Int64;
    FFrameIndex: Int64;
    function ReadBytesAt(Position: Int64; Count: Integer): TBytes;
    function FrameBytesAt(Position: Int64; Header: PByte): Integer;
    function MatchingFrameAt(Position: Int64; out FrameBytes: Integer): Boolean;
    function Resynchronise(From: Int64): Int64;
    procedure FindFirstFrame(Start: Int64);
    function AverageFrameBytes: Double;
    function TotalFrames: Int64;
    function SeekPosition(Fraction: Double): Int64;
  public
    class function Recognizes(const Head: TBytes): Boolean; override;
    procedure Open; override;
    function ReadPacket(out Packet: TMediaPacket): Boolean; override;
    function SeekTo(Microseconds: Int64): Boolean; override;
    function FormatName: string; override;
  end;

implementation

uses
  Media.Errors,
  Media.Mp3.Header;

const
  { How far into the audio the first frame is looked for. }
  SearchBytes = 65536;
  { The decoder's delay (a Layer III decoder's output lags by 528 + 1
    samples, as LAME counts). }
  DecoderDelay = 529;
  { Frames after the first that must match it for a stream to be taken. }
  ConfirmingFrames = 3;

function FrameLengthIn(Data: PByte; Available, FreeFormatBytes: Integer): Integer;
var
  Probe: Integer;
begin
  Result := HeaderFullFrameBytes(Data, FreeFormatBytes);
  if Result > 0 then
    Exit;
  { Free format: up to the next matching header. }
  Probe := Mp3HeaderSize;
  while (Probe < Mp3MaximumFreeFormatBytes) and (Probe + Mp3HeaderSize <= Available) do
  begin
    if HeadersMatch(Data, Data + Probe) then
      Exit(Probe);
    Inc(Probe);
  end;
  Result := 0;
end;

{ Whether a stream of matching Layer III frames starts at Offset of
  Data (the data may end after one confirmed frame). }
function StreamStartsAt(Data: PByte; Count, Offset: Integer; out FreeFormatBytes: Integer): Boolean;
var
  Position, Length, Matches: Integer;
begin
  Result := False;
  FreeFormatBytes := 0;
  if (Offset + Mp3HeaderSize > Count) or not HeaderIsValid(Data + Offset) or (HeaderLayer(Data + Offset) <> 1) then
    Exit;
  Length := FrameLengthIn(Data + Offset, Count - Offset, 0);
  if Length <= Mp3HeaderSize then
    Exit;
  if HeaderIsFreeFormat(Data + Offset) then
    FreeFormatBytes := Length - HeaderPadding(Data + Offset);
  Position := Offset;
  Matches := 0;
  while Matches < ConfirmingFrames do
  begin
    Length := HeaderFullFrameBytes(Data + Position, FreeFormatBytes);
    if Length <= Mp3HeaderSize then
      Exit;
    Inc(Position, Length);
    if Position + Mp3HeaderSize > Count then
      Exit(Matches > 0);
    if not HeadersMatch(Data + Offset, Data + Position) then
      Exit;
    Inc(Matches);
  end;
  Result := True;
end;

class function TMp3Demuxer.Recognizes(const Head: TBytes): Boolean;
var
  Start, Offset, FreeFormatBytes, TagLength: Integer;
begin
  Result := False;
  Start := 0;
  repeat
    if Start >= Length(Head) then
      Exit(Start > 0);
    TagLength := Id3v2TagLength(@Head[Start], Length(Head) - Start);
    Inc(Start, TagLength);
  until TagLength = 0;
  { A tag longer than what is shown: an ID3 tagged file. }
  if Start >= Length(Head) then
    Exit(Start > 0);
  Offset := Start;
  while (Offset < Length(Head) - Mp3HeaderSize) and (Offset < Start + 4096) do
  begin
    if StreamStartsAt(@Head[0], Length(Head), Offset, FreeFormatBytes) then
      Exit(True);
    Inc(Offset);
  end;
end;

function TMp3Demuxer.FormatName: string;
begin
  Result := 'mp3';
end;

function TMp3Demuxer.ReadBytesAt(Position: Int64; Count: Integer): TBytes;
var
  Got: Integer;
begin
  Result := nil;
  if Count <= 0 then
    Exit;
  SetLength(Result, Count);
  FStream.Position := Position;
  Got := FStream.Read(Result[0], Count);
  SetLength(Result, Got);
end;

function TMp3Demuxer.FrameBytesAt(Position: Int64; Header: PByte): Integer;
begin
  Result := HeaderFullFrameBytes(Header, FFreeFormatBytes);
  if (Result <= Mp3HeaderSize) or (Position + Result > FAudioEnd) then
    Result := 0;
end;

function TMp3Demuxer.MatchingFrameAt(Position: Int64; out FrameBytes: Integer): Boolean;
var
  Header: TBytes;
begin
  FrameBytes := 0;
  if Position + Mp3HeaderSize > FAudioEnd then
    Exit(False);
  Header := ReadBytesAt(Position, Mp3HeaderSize);
  if (Length(Header) < Mp3HeaderSize) or not HeadersMatch(@FHeader[0], @Header[0]) then
    Exit(False);
  FrameBytes := FrameBytesAt(Position, @Header[0]);
  Result := FrameBytes > 0;
end;

function TMp3Demuxer.Resynchronise(From: Int64): Int64;
const
  ChunkBytes = 16384;
var
  Chunk: TBytes;
  Offset, Length1, Length2: Integer;
  Position: Int64;
begin
  Position := From;
  while Position + Mp3HeaderSize <= FAudioEnd do
  begin
    Chunk := ReadBytesAt(Position, ChunkBytes);
    if Length(Chunk) < Mp3HeaderSize then
      Break;
    for Offset := 0 to Length(Chunk) - Mp3HeaderSize do
      if HeadersMatch(@FHeader[0], @Chunk[Offset]) then
      begin
        { Taken if the next frame matches too, or the audio ends with it. }
        if not MatchingFrameAt(Position + Offset, Length1) then
          Continue;
        if (Position + Offset + Length1 + Mp3HeaderSize > FAudioEnd)
          or MatchingFrameAt(Position + Offset + Length1, Length2) then
          Exit(Position + Offset);
      end;
    Inc(Position, Length(Chunk) - Mp3HeaderSize + 1);
  end;
  Result := -1;
end;

procedure TMp3Demuxer.FindFirstFrame(Start: Int64);
var
  Data: TBytes;
  Offset, FreeFormatBytes: Integer;
begin
  Data := ReadBytesAt(Start, SearchBytes);
  if FAudioEnd - Start < Length(Data) then
    SetLength(Data, FAudioEnd - Start);
  for Offset := 0 to Length(Data) - Mp3HeaderSize do
    if StreamStartsAt(@Data[0], Length(Data), Offset, FreeFormatBytes) then
    begin
      FFirstFrame := Start + Offset;
      Move(Data[Offset], FHeader[0], Mp3HeaderSize);
      FFreeFormatBytes := FreeFormatBytes;
      Exit;
    end;
  MediaFail('no MPEG audio frames found');
end;

procedure TMp3Demuxer.Open;
const
  { How much of the end is searched for tags. }
  TailBytes = 65536;
var
  Start, FileSize, TailStart: Int64;
  Head, Tail, FirstFrame: TBytes;
  TagLength, FrameBytes: Integer;
  Frames: Int64;
begin
  FileSize := FStream.Size;
  Start := 0;
  repeat
    Head := ReadBytesAt(Start, 10);
    if Length(Head) < 10 then
      Break;
    TagLength := Id3v2TagLength(@Head[0], Length(Head));
    Inc(Start, TagLength);
  until (TagLength = 0) or (Start >= FileSize);
  TailStart := FileSize - TailBytes;
  if TailStart < Start then
    TailStart := Start;
  Tail := ReadBytesAt(TailStart, FileSize - TailStart);
  FAudioEnd := FileSize;
  if Length(Tail) > 0 then
    Dec(FAudioEnd, TrailingTagLength(@Tail[0], Length(Tail)));
  if FAudioEnd <= Start then
    MediaFail('no audio in the MP3 file');
  FindFirstFrame(Start);

  FTrack := AddTrack;
  FTrack.Kind := mkAudio;
  FTrack.Codec := codecMp3;
  FTrack.CodecName := 'mp3';
  FTrack.SampleRate := HeaderSampleRate(@FHeader[0]);
  FTrack.Channels := HeaderChannels(@FHeader[0]);
  FTrack.TimeBase := MakeTimeBase(1, FTrack.SampleRate);
  FFrameSamples := HeaderFrameSamples(@FHeader[0]);

  FrameBytes := HeaderFullFrameBytes(@FHeader[0], FFreeFormatBytes);
  FirstFrame := ReadBytesAt(FFirstFrame, FrameBytes);
  FInfo := ReadStreamInfo(@FirstFrame[0], Length(FirstFrame));
  if FInfo.HasInfoFrame then
    FAudioStart := FFirstFrame + FrameBytes
  else
    FAudioStart := FFirstFrame;
  if FInfo.HasEncoderDelay then
    FTrack.CodecDelay := FInfo.EncoderDelay + DecoderDelay;

  Frames := TotalFrames;
  if Frames > 0 then
  begin
    FTrack.Duration := Frames * FFrameSamples;
    if FInfo.HasEncoderDelay then
      FTrack.Duration := FTrack.Duration - FInfo.EncoderDelay - FInfo.EncoderPadding;
    if FTrack.Duration < 0 then
      FTrack.Duration := 0;
    FDuration := FTrack.ToMicroseconds(FTrack.Duration);
  end;
  FPosition := FAudioStart;
  FFrameIndex := 0;
end;

function TMp3Demuxer.AverageFrameBytes: Double;
begin
  if (FInfo.FrameCount > 0) and (FInfo.ByteCount > 0) then
    Result := FInfo.ByteCount / FInfo.FrameCount
  else
    Result := FFrameSamples * HeaderBitrateKbps(@FHeader[0]) * 125 / HeaderSampleRate(@FHeader[0]);
  if Result <= Mp3HeaderSize then
    Result := HeaderFullFrameBytes(@FHeader[0], FFreeFormatBytes);
  if Result <= 0 then
    Result := 1;
end;

function TMp3Demuxer.TotalFrames: Int64;
begin
  if FInfo.FrameCount > 0 then
    Result := FInfo.FrameCount
  else
    Result := Round((FAudioEnd - FAudioStart) / AverageFrameBytes);
end;

function TMp3Demuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
var
  FrameBytes, NextBytes: Integer;
  Next: Int64;
  Last: Boolean;
begin
  Packet := NewPacket(0);
  if not MatchingFrameAt(FPosition, FrameBytes) then
  begin
    FPosition := Resynchronise(FPosition + 1);
    if (FPosition < 0) or not MatchingFrameAt(FPosition, FrameBytes) then
    begin
      FPosition := FAudioEnd;
      Exit(False);
    end;
  end;
  Packet.Data := ReadBytesAt(FPosition, FrameBytes);
  Packet.PresentationTime := FFrameIndex * FFrameSamples - FTrack.CodecDelay;
  Packet.DecodeTime := Packet.PresentationTime;
  Packet.Duration := FFrameSamples;
  Packet.KeyFrame := True;
  Next := FPosition + FrameBytes;
  if (FInfo.FrameCount > 0) and FInfo.HasEncoderDelay then
    Last := FFrameIndex = FInfo.FrameCount - 1
  else
    Last := not MatchingFrameAt(Next, NextBytes);
  if Last and FInfo.HasEncoderDelay and (FInfo.EncoderPadding > DecoderDelay) then
    Packet.TrimEnd := FInfo.EncoderPadding - DecoderDelay;
  FPosition := Next;
  Inc(FFrameIndex);
  Result := True;
end;

function TMp3Demuxer.SeekPosition(Fraction: Double): Int64;
var
  Percent, Lower, Upper, Index: Integer;
  Part, Bytes: Double;
  FrameTarget, Walked: Int64;
begin
  if FInfo.HasXingTable and (FInfo.ByteCount > 0) then
  begin
    Part := Fraction * 100;
    Percent := Trunc(Part);
    if Percent > 99 then
      Percent := 99;
    Lower := FInfo.XingTable[Percent];
    if Percent < 99 then
      Upper := FInfo.XingTable[Percent + 1]
    else
      Upper := 256;
    Bytes := (Lower + (Upper - Lower) * (Part - Percent)) / 256 * FInfo.ByteCount;
    Exit(FFirstFrame + Round(Bytes));
  end;
  if (Length(FInfo.VbriTable) > 0) and (FInfo.VbriFramesPerEntry > 0) then
  begin
    FrameTarget := Round(Fraction * TotalFrames);
    Result := FAudioStart;
    Walked := 0;
    Index := 0;
    while (Index < Length(FInfo.VbriTable)) and (Walked + FInfo.VbriFramesPerEntry <= FrameTarget) do
    begin
      Inc(Result, FInfo.VbriTable[Index]);
      Inc(Walked, FInfo.VbriFramesPerEntry);
      Inc(Index);
    end;
    Exit;
  end;
  Result := FAudioStart + Round(Fraction * TotalFrames) * Round(AverageFrameBytes);
end;

function TMp3Demuxer.SeekTo(Microseconds: Int64): Boolean;
var
  TargetSample, Frames: Int64;
  Fraction: Double;
  Position: Int64;
begin
  TargetSample := FTrack.FromMicroseconds(Microseconds);
  if TargetSample <= 0 then
  begin
    FPosition := FAudioStart;
    FFrameIndex := 0;
    Exit(True);
  end;
  Frames := TotalFrames;
  if Frames <= 0 then
    Exit(False);
  Fraction := (TargetSample + FTrack.CodecDelay) / (Frames * FFrameSamples);
  if Fraction > 1 then
    Fraction := 1;
  Position := SeekPosition(Fraction);
  if Position < FAudioStart then
    Position := FAudioStart;
  Position := Resynchronise(Position);
  if Position < 0 then
  begin
    FPosition := FAudioEnd;
    FFrameIndex := Frames;
    Exit(True);
  end;
  FPosition := Position;
  if FInfo.HasXingTable or (Length(FInfo.VbriTable) > 0) then
    FFrameIndex := Round(Fraction * Frames)
  else
    FFrameIndex := Round((Position - FAudioStart) / AverageFrameBytes);
  Result := True;
end;

end.
