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
  One logical stream of an Ogg file: its packets put back together from
  pages, its headers, and the timestamps of its packets.

  Packets are complete when a segment shorter than 255 bytes ends them;
  one cut by a page boundary is carried to the next page of the stream
  (and dropped if that page does not say it continues one, or if a
  page starts with the rest of a packet whose beginning was not seen,
  after a seek).

  A page's granule position is the end time of the last packet completed
  on it, so the packets completed on a page are timed once the page is
  read: the first page of a stream (or the first after a seek) gives the
  start (granule less the page's durations, less Opus' pre-skip), and the
  times then run on from packet to packet. On the stream's first page a
  granule smaller than its packets' samples means samples to drop at the
  start (TrimStart); on its last page (end of stream) a granule smaller
  than the end means samples to drop at the end (TrimEnd), and the last
  packet's Duration is shortened to match.

  Timestamps follow the usual convention (that of FFmpeg) so they can be
  compared: Opus times count from the end of the pre-skip (the first
  packet is at minus the pre-skip); a Vorbis stream starts at 0 with the
  packet durations of Media.Ogg.VorbisModes, its first packet (which
  decodes to nothing) a packet's length before the granule positions'
  time 0.
}
unit Media.Ogg.Streams;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Packets,
  Media.Ogg.Pages,
  Media.Ogg.Codecs,
  Media.Ogg.VorbisModes;

type
  TOggPacketList = array of TMediaPacket;

  TOggLogicalStream = class
  private
    FPartial: TBytes;
    FPartialSize: Integer;
    FInPacket: Boolean;
    FDropContinuation: Boolean;
    FHaveTime: Boolean;
    FNextTime: Int64;
    FAtStart: Boolean;
    FFirstDuration: Int64;
    FHeaderCount: Integer;
    FFlacHeadersLeft: Integer;
    FVorbisModes: TVorbisModes;
    procedure AppendPartial(const Body: TBytes; Offset, Count: Integer);
    function TakePartial: TBytes;
    procedure TakeHeader(const Packet: TBytes);
    function IsHeader(const Packet: TBytes): Boolean;
    function PacketDuration(const Packet: TBytes): Int64;
    procedure TimePackets(var Packets: TOggPacketList; First: Integer; const Page: TOggPage);
    procedure TrimFromStart(var Packets: TOggPacketList; First: Integer; Amount: Int64);
    procedure TrimFromEnd(var Packets: TOggPacketList; First: Integer; Amount, DurationCut: Int64);
  public
    Serial: LongWord;
    { Where its first page is: tells the links of a chained file apart. }
    FirstPageOffset: Int64;
    Track: TMediaTrack;
    Codec: TCodecId;
    PreSkip: Integer;
    Ended: Boolean;
    constructor Create(ASerial: LongWord; Offset: Int64; ATrack: TMediaTrack);
    { Splits Page into packets: headers go to the track, the others are
      timed and added to Packets. }
    procedure TakePage(const Page: TOggPage; var Packets: TOggPacketList);
    function HeadersComplete: Boolean;
    { Forgets packet and time state: after a seek (FromStart: back to the
      first data page, timed as at the start). }
    procedure Restart(FromStart: Boolean);
    { The presentation time a granule position stands for. }
    function GranuleToTime(Granule: Int64): Int64;
    function TimeToGranule(Time: Int64): Int64;
  end;

implementation

uses
  Media.ByteReaders;

constructor TOggLogicalStream.Create(ASerial: LongWord; Offset: Int64; ATrack: TMediaTrack);
begin
  inherited Create;
  Serial := ASerial;
  FirstPageOffset := Offset;
  Track := ATrack;
  Track.ContainerId := ASerial;
  Track.Kind := mkUnknown;
  Codec := codecUnknown;
  FAtStart := True;
  FPartial := nil;
end;

procedure TOggLogicalStream.Restart(FromStart: Boolean);
begin
  FPartialSize := 0;
  FInPacket := False;
  FDropContinuation := not FromStart;
  FHaveTime := False;
  FAtStart := FromStart;
  FVorbisModes.PreviousBlock := 0;
  Ended := False;
end;

procedure TOggLogicalStream.AppendPartial(const Body: TBytes; Offset, Count: Integer);
begin
  if Count <= 0 then
    Exit;
  if FPartialSize + Count > Length(FPartial) then
    SetLength(FPartial, (FPartialSize + Count) * 2);
  Move(Body[Offset], FPartial[FPartialSize], Count);
  Inc(FPartialSize, Count);
end;

function TOggLogicalStream.TakePartial: TBytes;
begin
  Result := nil;
  SetLength(Result, FPartialSize);
  if FPartialSize > 0 then
    Move(FPartial[0], Result[0], FPartialSize);
  FPartialSize := 0;
end;

function TOggLogicalStream.HeadersComplete: Boolean;
begin
  case Codec of
    codecOpus: Result := FHeaderCount >= 2;
    codecVorbis, codecTheora: Result := FHeaderCount >= 3;
    codecFlac: Result := (FHeaderCount >= 1) and (FFlacHeadersLeft <= 0);
  else
    Result := FHeaderCount >= 1;
  end;
end;

function TOggLogicalStream.IsHeader(const Packet: TBytes): Boolean;
begin
  if FHeaderCount = 0 then
    Exit(True);
  case Codec of
    codecOpus: Result := FHeaderCount < 2;
    codecVorbis: Result := (FHeaderCount < 3) and (Length(Packet) > 0) and ((Packet[0] and 1) = 1);
    codecTheora: Result := (Length(Packet) > 0) and ((Packet[0] and $80) <> 0);
    codecFlac: Result := (FFlacHeadersLeft <> 0) and (Length(Packet) > 0) and (Packet[0] <> $FF);
  else
    Result := False;
  end;
end;

procedure TOggLogicalStream.TakeHeader(const Packet: TBytes);
var
  Head: TOpusHead;
  Info: TStreamInfo;
begin
  Inc(FHeaderCount);
  if FHeaderCount = 1 then
  begin
    Codec := OggCodecOf(Packet);
    Track.Codec := Codec;
    case Codec of
      codecOpus:
        begin
          Head := ReadOpusHead(Packet);
          Track.Kind := mkAudio;
          Track.CodecName := 'opus';
          Track.SampleRate := 48000;
          Track.Channels := Head.Channels;
          Track.TimeBase := MakeTimeBase(1, 48000);
          PreSkip := Head.PreSkip;
          Track.CodecDelay := Head.PreSkip;
          Track.SeekPreRoll := 80000;
          Track.AddHeader(Packet);
        end;
      codecVorbis:
        begin
          Track.Kind := mkAudio;
          Track.CodecName := 'vorbis';
          if Length(Packet) >= 16 then
          begin
            Track.Channels := Packet[11];
            Track.SampleRate := LittleEndian32(Packet, 12);
          end;
          if Track.SampleRate > 0 then
            Track.TimeBase := MakeTimeBase(1, Track.SampleRate);
          Track.AddHeader(Packet);
        end;
      codecFlac:
        begin
          Track.Kind := mkAudio;
          Track.CodecName := 'flac';
          { 0x7F "FLAC", version, header count, "fLaC", the STREAMINFO block. }
          FFlacHeadersLeft := BigEndian16(Packet, 7);
          if FFlacHeadersLeft = 0 then
            FFlacHeadersLeft := -1;
          Track.AddHeader(SliceBytes(Packet, 17, 34));
          Info := ReadStreamInfo(Track.Headers[0]);
          if Info.Valid then
          begin
            Track.SampleRate := Info.SampleRate;
            Track.Channels := Info.Channels;
            Track.BitsPerSample := Info.BitsPerSample;
            Track.TimeBase := MakeTimeBase(1, Info.SampleRate);
          end;
        end;
      codecTheora:
        begin
          Track.Kind := mkVideo;
          Track.CodecName := 'theora';
          if Length(Packet) >= 20 then
          begin
            Track.Width := BigEndian24(Packet, 14);
            Track.Height := BigEndian24(Packet, 17);
            Track.DisplayWidth := Track.Width;
            Track.DisplayHeight := Track.Height;
          end;
          Track.AddHeader(Packet);
        end;
    else
      Track.CodecName := 'unknown';
    end;
  end
  else
    case Codec of
      codecVorbis:
        begin
          Track.AddHeader(Packet);
          if FHeaderCount = 3 then
            FVorbisModes := ReadVorbisModes(Track.Headers[0], Packet);
        end;
      codecTheora:
        Track.AddHeader(Packet);
      codecFlac:
        if FFlacHeadersLeft > 0 then
          Dec(FFlacHeadersLeft);
    end;
end;

function TOggLogicalStream.PacketDuration(const Packet: TBytes): Int64;
begin
  case Codec of
    codecOpus: Result := OpusPacketDuration(Packet);
    codecVorbis: Result := VorbisPacketDuration(FVorbisModes, Packet);
    codecFlac: Result := FlacFrameBlockSize(Packet);
  else
    Result := 0;
  end;
end;

function TOggLogicalStream.GranuleToTime(Granule: Int64): Int64;
begin
  if Codec = codecOpus then
    Result := Granule - PreSkip
  else
    Result := Granule;
end;

function TOggLogicalStream.TimeToGranule(Time: Int64): Int64;
begin
  if Codec = codecOpus then
    Result := Time + PreSkip
  else
    Result := Time;
end;

procedure TOggLogicalStream.TrimFromStart(var Packets: TOggPacketList; First: Integer; Amount: Int64);
var
  Index: Integer;
  Part, Available: Int64;
begin
  Index := First;
  { A Vorbis stream's first packet decodes to nothing. }
  if (Codec = codecVorbis) and (Index <= High(Packets)) then
    Inc(Index);
  while (Amount > 0) and (Index <= High(Packets)) do
  begin
    Available := Packets[Index].Duration;
    Part := Amount;
    if Part > Available then
      Part := Available;
    Packets[Index].TrimStart := Part;
    Dec(Amount, Part);
    Inc(Index);
  end;
end;

procedure TOggLogicalStream.TrimFromEnd(var Packets: TOggPacketList; First: Integer; Amount, DurationCut: Int64);
var
  Index: Integer;
  Part: Int64;
begin
  Index := High(Packets);
  while (Index >= First) and ((Amount > 0) or (DurationCut > 0)) do
  begin
    Part := Amount;
    if Part > Packets[Index].Duration then
      Part := Packets[Index].Duration;
    if Part > 0 then
    begin
      Packets[Index].TrimEnd := Part;
      Dec(Amount, Part);
    end;
    Part := DurationCut;
    if Part > Packets[Index].Duration then
      Part := Packets[Index].Duration;
    Dec(Packets[Index].Duration, Part);
    Dec(DurationCut, Part);
    Dec(Index);
  end;
end;

procedure TOggLogicalStream.TimePackets(var Packets: TOggPacketList; First: Integer; const Page: TOggPage);
var
  Index: Integer;
  Total, Start, Real, PageEnd: Int64;
begin
  if First > High(Packets) then
    Exit;
  if not (Codec in [codecOpus, codecVorbis, codecFlac]) then
    Exit;
  Total := 0;
  for Index := First to High(Packets) do
    Inc(Total, Packets[Index].Duration);
  if not FHaveTime then
  begin
    if Page.Granule < 0 then
      Exit;
    Start := GranuleToTime(Page.Granule) - Total;
    if FAtStart then
    begin
      FFirstDuration := Packets[First].Duration;
      if Codec = codecVorbis then
      begin
        { Samples decodable from the page: all but the first packet's. }
        Real := Page.Granule - (Total - FFirstDuration);
        if Real < 0 then
          TrimFromStart(Packets, First, -Real);
      end
      else if Page.Granule < Total then
        TrimFromStart(Packets, First, Total - Page.Granule);
    end;
    FNextTime := Start;
    FHaveTime := True;
    FAtStart := False;
  end;
  for Index := First to High(Packets) do
  begin
    Packets[Index].PresentationTime := FNextTime;
    Packets[Index].DecodeTime := FNextTime;
    Inc(FNextTime, Packets[Index].Duration);
  end;
  if ((Page.Flags and OggFlagLast) <> 0) and (Page.Granule >= 0) then
  begin
    PageEnd := GranuleToTime(Page.Granule);
    if FNextTime > PageEnd then
    begin
      TrimFromEnd(Packets, First, FNextTime - PageEnd, FNextTime - PageEnd);
      FNextTime := PageEnd;
    end;
  end;
end;

procedure TOggLogicalStream.TakePage(const Page: TOggPage; var Packets: TOggPacketList);
var
  Segment, Offset, PacketStart, First: Integer;
  Data: TBytes;
  Packet: TMediaPacket;
  Dropping: Boolean;
begin
  if (Page.Flags and OggFlagContinued) = 0 then
  begin
    { A packet left unfinished by a page that was lost. }
    FPartialSize := 0;
    FInPacket := False;
    Dropping := False;
  end
  else
    Dropping := not FInPacket;
  if FDropContinuation then
  begin
    Dropping := (Page.Flags and OggFlagContinued) <> 0;
    FDropContinuation := False;
    FPartialSize := 0;
  end;
  First := Length(Packets);
  Offset := 0;
  PacketStart := 0;
  for Segment := 0 to Page.SegmentCount - 1 do
  begin
    Inc(Offset, Page.Lacing[Segment]);
    if Page.Lacing[Segment] < 255 then
    begin
      if Dropping then
      begin
        Dropping := False;
        FPartialSize := 0;
      end
      else
      begin
        AppendPartial(Page.Body, PacketStart, Offset - PacketStart);
        Data := TakePartial;
        if IsHeader(Data) then
          TakeHeader(Data)
        else
        begin
          Packet := NewPacket(Track.Index);
          Packet.Data := Data;
          Packet.KeyFrame := True;
          Packet.Duration := PacketDuration(Data);
          SetLength(Packets, Length(Packets) + 1);
          Packets[High(Packets)] := Packet;
        end;
      end;
      FInPacket := False;
      PacketStart := Offset;
    end;
  end;
  if PacketStart < Offset then
  begin
    if not Dropping then
    begin
      AppendPartial(Page.Body, PacketStart, Offset - PacketStart);
      FInPacket := True;
    end;
  end;
  if Dropping then
    FDropContinuation := True;
  TimePackets(Packets, First, Page);
  if (Page.Flags and OggFlagLast) <> 0 then
    Ended := True;
end;

end.
