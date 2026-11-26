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
  Native FLAC files (RFC 9639): "fLaC", the metadata blocks (STREAMINFO
  becomes the track's header; SEEKTABLE is kept for seeking; an ID3v2
  tag in front is skipped), then frames, one packet each.

  Frames carry no length, so a frame ends where the next valid frame
  header starts and the CRC-16 of the bytes before it comes out zero
  (both, so sample data that happens to look like a sync code cannot cut
  a frame short). The file is read through a buffer of its own.

  Seeking takes the seek table's last point at or before the target, or
  without one bisects the file by frame headers' sample numbers, then
  steps frame by frame to the frame holding the target.
}
unit Media.FlacFile;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Media.Packets,
  Media.Demuxers,
  Media.Flac.Headers;

type
  TFlacSeekPoint = record
    Sample: Int64;
    Offset: Int64;
  end;

  TFlacDemuxer = class(TMediaDemuxer)
  private
    FInfo: TFlacStreamInfo;
    FTrack: TMediaTrack;
    FFirstFrame: Int64;
    FFileSize: Int64;
    FSeekPoints: array of TFlacSeekPoint;
    { The file's bytes FBufferStart .. FBufferStart + FBufferLength - 1. }
    FBuffer: TBytes;
    FBufferStart: Int64;
    FBufferLength: Integer;
    { The next frame's offset in the file. }
    FPosition: Int64;
    function Load(Offset: Int64; Count: Integer): Boolean;
    function ByteAt(Offset: Int64): Integer;
    function HeaderAt(Offset: Int64; out Header: TFlacFrameHeader): Boolean;
    function FindHeader(From, Limit: Int64; out Offset: Int64; out Header: TFlacFrameHeader): Boolean;
    function FrameEnd(Start: Int64; const Header: TFlacFrameHeader): Int64;
    procedure ReadMetadata;
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
  Media.ByteReaders;

const
  BufferChunk = 65536;
  { No frame is longer (16 bits x 8 channels x 65535 samples, verbatim). }
  MaximumFrameBytes = 16 * 1024 * 1024;
  BlockStreamInfo = 0;
  BlockSeekTable = 3;

function Id3v2Size(const Head: TBytes): Integer;
begin
  Result := 0;
  if (Length(Head) >= 10) and (Head[0] = Ord('I')) and (Head[1] = Ord('D')) and (Head[2] = Ord('3')) then
  begin
    Result := ((Head[6] and $7F) shl 21) or ((Head[7] and $7F) shl 14) or ((Head[8] and $7F) shl 7) or
      (Head[9] and $7F);
    Inc(Result, 10);
    { A footer doubles the header at the end. }
    if (Head[5] and $10) <> 0 then
      Inc(Result, 10);
  end;
end;

class function TFlacDemuxer.Recognizes(const Head: TBytes): Boolean;
var
  Start: Integer;
begin
  Start := Id3v2Size(Head);
  Result := (Length(Head) >= Start + 4) and (FourCCAt(Head, Start) = 'fLaC');
end;

function TFlacDemuxer.FormatName: string;
begin
  Result := 'flac';
end;

function TFlacDemuxer.Load(Offset: Int64; Count: Integer): Boolean;
var
  Wanted, Got: Integer;
begin
  if (Offset >= FBufferStart) and (Offset + Count <= FBufferStart + FBufferLength) then
    Exit(True);
  if Offset + Count > FFileSize then
    Count := FFileSize - Offset;
  if Count <= 0 then
    Exit(False);
  Wanted := Count;
  if Wanted < BufferChunk then
    Wanted := BufferChunk;
  if Offset + Wanted > FFileSize then
    Wanted := FFileSize - Offset;
  if Length(FBuffer) < Wanted then
    SetLength(FBuffer, Wanted);
  FStream.Position := Offset;
  Got := FStream.Read(FBuffer[0], Wanted);
  FBufferStart := Offset;
  FBufferLength := Got;
  Result := Got >= Count;
end;

function TFlacDemuxer.ByteAt(Offset: Int64): Integer;
begin
  if (Offset < FBufferStart) or (Offset >= FBufferStart + FBufferLength) then
    if not Load(Offset, 1) then
      Exit(-1);
  Result := FBuffer[Offset - FBufferStart];
end;

function TFlacDemuxer.HeaderAt(Offset: Int64; out Header: TFlacFrameHeader): Boolean;
const
  LongestHeader = 16;
var
  Available: Integer;
begin
  Header := Default(TFlacFrameHeader);
  if (ByteAt(Offset) <> $FF) or ((ByteAt(Offset + 1) and $FE) <> $F8) then
    Exit(False);
  Available := LongestHeader;
  if Offset + Available > FFileSize then
    Available := FFileSize - Offset;
  if not Load(Offset, Available) then
    Exit(False);
  Result := ParseFlacFrameHeader(@FBuffer[Offset - FBufferStart], Available, FInfo, Header);
  { A header must agree with the stream. }
  if Result then
    Result := (Header.SampleRate = FInfo.SampleRate) and (Header.Channels = FInfo.Channels) and
      (Header.BitsPerSample = FInfo.BitsPerSample) and
      ((FInfo.MaximumBlockSize = 0) or (Header.BlockSize <= FInfo.MaximumBlockSize));
end;

function TFlacDemuxer.FindHeader(From, Limit: Int64; out Offset: Int64; out Header: TFlacFrameHeader): Boolean;
begin
  Offset := From;
  while (Offset < Limit) and (Offset + 6 <= FFileSize) do
  begin
    if (ByteAt(Offset) = $FF) and HeaderAt(Offset, Header) then
      Exit(True);
    Inc(Offset);
  end;
  Result := False;
end;

function TFlacDemuxer.FrameEnd(Start: Int64; const Header: TFlacFrameHeader): Int64;
var
  Offset, Limit: Int64;
  Crc: Word;
  Value: Integer;
  Next: TFlacFrameHeader;
begin
  Crc := 0;
  Offset := Start;
  Limit := Start + MaximumFrameBytes;
  if Limit > FFileSize then
    Limit := FFileSize;
  { The smallest possible frame: the header, a byte of subframe, CRC. }
  while Offset < Start + Header.Length + 3 do
  begin
    Value := ByteAt(Offset);
    if Value < 0 then
      MediaFail('FLAC frame cut short');
    Crc := FlacCrc16Step(Crc, Value);
    Inc(Offset);
  end;
  while Offset < Limit do
  begin
    Value := ByteAt(Offset);
    if (Value = $FF) and (Crc = 0) and HeaderAt(Offset, Next) and
      (Next.VariableBlockSize = Header.VariableBlockSize) then
      Exit(Offset);
    Crc := FlacCrc16Step(Crc, Value);
    Inc(Offset);
  end;
  { The last frame runs to the end (an ID3v1 tag after it comes along;
    the decoder stops at the frame's own end). }
  Result := Limit;
end;

procedure TFlacDemuxer.ReadMetadata;
var
  Reader: TMediaReader;
  BlockHeader, BlockType: Integer;
  BlockLength: LongWord;
  Last: Boolean;
  Body: TBytes;
  Index, Count: Integer;
  Point: TFlacSeekPoint;
  HaveInfo: Boolean;
  Head: TBytes;
begin
  Reader := TMediaReader.Create(FStream);
  try
    Head := nil;
    SetLength(Head, 10);
    Reader.Position := 0;
    SetLength(Head, Reader.ReadUpTo(Head[0], 10));
    Reader.Position := Id3v2Size(Head);
    if Reader.ReadFourCC <> 'fLaC' then
      MediaFail('not a FLAC file');
    HaveInfo := False;
    repeat
      BlockHeader := Reader.ReadU8;
      Last := (BlockHeader and $80) <> 0;
      BlockType := BlockHeader and $7F;
      BlockLength := Reader.ReadU24BE;
      if BlockType = BlockStreamInfo then
      begin
        Body := Reader.ReadBytes(BlockLength);
        if not ParseFlacStreamInfo(Body, FInfo) then
          MediaFail('bad FLAC STREAMINFO');
        FTrack.AddHeader(SliceBytes(Body, 0, 34));
        HaveInfo := True;
      end
      else if BlockType = BlockSeekTable then
      begin
        Body := Reader.ReadBytes(BlockLength);
        Count := Length(Body) div 18;
        SetLength(FSeekPoints, 0);
        for Index := 0 to Count - 1 do
        begin
          Point.Sample := Int64(BigEndian64(Body, Index * 18));
          Point.Offset := Int64(BigEndian64(Body, Index * 18 + 8));
          { Placeholders are all ones. }
          if Point.Sample = -1 then
            Continue;
          SetLength(FSeekPoints, Length(FSeekPoints) + 1);
          FSeekPoints[High(FSeekPoints)] := Point;
        end;
      end
      else if BlockType = 127 then
        MediaFail('bad FLAC metadata block')
      else
        Reader.Skip(BlockLength);
    until Last;
    if not HaveInfo then
      MediaFail('FLAC file without STREAMINFO');
    FFirstFrame := Reader.Position;
  finally
    Reader.Free;
  end;
end;

procedure TFlacDemuxer.Open;
begin
  FFileSize := FStream.Size;
  FTrack := AddTrack;
  FTrack.Kind := mkAudio;
  FTrack.Codec := codecFlac;
  FTrack.CodecName := 'flac';
  ReadMetadata;
  FTrack.SampleRate := FInfo.SampleRate;
  FTrack.Channels := FInfo.Channels;
  FTrack.BitsPerSample := FInfo.BitsPerSample;
  FTrack.TimeBase := MakeTimeBase(1, FInfo.SampleRate);
  if FInfo.TotalSamples > 0 then
  begin
    FTrack.Duration := FInfo.TotalSamples;
    FDuration := FTrack.ToMicroseconds(FInfo.TotalSamples);
  end;
  FPosition := FFirstFrame;
end;

function TFlacDemuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
var
  Header: TFlacFrameHeader;
  Start, Finish: Int64;
  Size: Integer;
begin
  Packet := NewPacket(0);
  if FPosition >= FFileSize then
    Exit(False);
  if not HeaderAt(FPosition, Header) then
  begin
    { Damage, or the tags at the end: find the next frame, if any. }
    if not FindHeader(FPosition, FFileSize, Start, Header) then
    begin
      FPosition := FFileSize;
      Exit(False);
    end;
    FPosition := Start;
  end;
  Start := FPosition;
  Finish := FrameEnd(Start, Header);
  Size := Finish - Start;
  if not Load(Start, Size) then
    MediaFail('FLAC frame cut short');
  Packet.Data := SliceBytes(FBuffer, Start - FBufferStart, Size);
  Packet.PresentationTime := FlacFirstSample(Header, FInfo);
  Packet.DecodeTime := Packet.PresentationTime;
  Packet.Duration := Header.BlockSize;
  Packet.KeyFrame := True;
  if (FInfo.TotalSamples > 0) and (Packet.PresentationTime + Header.BlockSize > FInfo.TotalSamples) and
    (Packet.PresentationTime < FInfo.TotalSamples) then
    Packet.TrimEnd := Packet.PresentationTime + Header.BlockSize - FInfo.TotalSamples;
  FPosition := Finish;
  Result := True;
end;

function TFlacDemuxer.SeekTo(Microseconds: Int64): Boolean;
var
  Target, Low, High, Middle, Found: Int64;
  Header: TFlacFrameHeader;
  Index: Integer;
begin
  Target := FTrack.FromMicroseconds(Microseconds);
  if Target < 0 then
    Target := 0;
  Low := FFirstFrame;
  if Length(FSeekPoints) > 0 then
  begin
    for Index := 0 to System.High(FSeekPoints) do
      if (FSeekPoints[Index].Sample <= Target) and (FFirstFrame + FSeekPoints[Index].Offset < FFileSize) then
        Low := FFirstFrame + FSeekPoints[Index].Offset;
  end
  else
  begin
    High := FFileSize;
    while High - Low > BufferChunk do
    begin
      Middle := Low + (High - Low) div 2;
      if not FindHeader(Middle, High, Found, Header) then
      begin
        High := Middle;
        Continue;
      end;
      if FlacFirstSample(Header, FInfo) <= Target then
        Low := Found
      else
        High := Middle;
    end;
  end;
  { Step to the frame that holds Target. }
  FPosition := Low;
  while HeaderAt(FPosition, Header) do
  begin
    if FlacFirstSample(Header, FInfo) + Header.BlockSize > Target then
      Break;
    FPosition := FrameEnd(FPosition, Header);
    if FPosition >= FFileSize then
      Break;
  end;
  Result := True;
end;

end.
