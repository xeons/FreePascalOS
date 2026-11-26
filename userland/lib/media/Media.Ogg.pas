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
  Ogg files (RFC 3533) with Vorbis, Opus (RFC 7845), FLAC (the Ogg FLAC
  mapping) and Theora streams (Theora recognised, not timed).

  Pages are read in order and handed to their logical stream
  (Media.Ogg.Streams), which gives back timed packets. Several streams
  can be multiplexed; a chained file (one link after another) gives each
  link's streams tracks of their own as their first pages are met, each
  link's times starting again. Open reads until the first link's headers
  are complete; the duration comes from the last granule position of the
  first audio stream, found near the end of the file.

  SeekTo bisects the file for the last page of the first audio stream
  (of the first link) whose granule position is at or before the target
  (less the codec's pre-roll, 80 ms for Opus) and goes on from there:
  the packets ending on that page start at or before the target.
}
unit Media.Ogg;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Contnrs,
  Media.Packets,
  Media.Demuxers,
  Media.Ogg.Pages,
  Media.Ogg.Streams;

type
  TOggDemuxer = class(TMediaDemuxer)
  private
    FReader: TOggPageReader;
    FStreams: TObjectList;
    FNextOffset: Int64;
    FLastPageOffset: Int64;
    FDataOffset: Int64;
    FQueue: TOggPacketList;
    FQueueHead: Integer;
    FPrimary: TOggLogicalStream;
    function StreamFor(const Page: TOggPage): TOggLogicalStream;
    function ReadNextPage: Boolean;
    procedure FindDuration;
    procedure ClearQueue;
    procedure RestartAt(Offset: Int64; FromStart: Boolean);
    function FindPrimaryPage(From, Before: Int64; out Page: TOggPage): Boolean;
  public
    destructor Destroy; override;
    class function Recognizes(const Head: TBytes): Boolean; override;
    procedure Open; override;
    function ReadPacket(out Packet: TMediaPacket): Boolean; override;
    function SeekTo(Microseconds: Int64): Boolean; override;
    function FormatName: string; override;
  end;

implementation

uses
  Media.Errors;

const
  { Pages Open reads at most looking for the headers. }
  HeaderPageLimit = 2000;
  { The gap the bisection stops at, then reading pages in order. }
  BisectionGranularity = 65536;
  DurationScanLimit = 1 shl 20;

destructor TOggDemuxer.Destroy;
begin
  FStreams.Free;
  FReader.Free;
  inherited Destroy;
end;

class function TOggDemuxer.Recognizes(const Head: TBytes): Boolean;
begin
  Result := (Length(Head) >= 27) and (Head[0] = Ord('O')) and (Head[1] = Ord('g')) and (Head[2] = Ord('g'))
    and (Head[3] = Ord('S')) and (Head[4] = 0);
end;

function TOggDemuxer.FormatName: string;
begin
  Result := 'ogg';
end;

function TOggDemuxer.StreamFor(const Page: TOggPage): TOggLogicalStream;
var
  Index: Integer;
  Candidate: TOggLogicalStream;
begin
  Result := nil;
  if (Page.Flags and OggFlagFirst) <> 0 then
  begin
    { A first page seen before (read again after a seek) keeps its track. }
    for Index := 0 to FStreams.Count - 1 do
    begin
      Candidate := TOggLogicalStream(FStreams[Index]);
      if Candidate.FirstPageOffset = Page.Offset then
      begin
        Candidate.Restart(True);
        Exit(Candidate);
      end;
    end;
    Result := TOggLogicalStream.Create(Page.Serial, Page.Offset, AddTrack);
    FStreams.Add(Result);
    Exit;
  end;
  { The latest stream with this serial number (a later link may reuse it). }
  for Index := FStreams.Count - 1 downto 0 do
  begin
    Candidate := TOggLogicalStream(FStreams[Index]);
    if (Candidate.Serial = Page.Serial) and (Candidate.FirstPageOffset < Page.Offset) then
      Exit(Candidate);
  end;
end;

function TOggDemuxer.ReadNextPage: Boolean;
var
  Page: TOggPage;
  Logical: TOggLogicalStream;
begin
  Result := FReader.ReadPageFrom(FNextOffset, Page);
  if not Result then
    Exit;
  FNextOffset := Page.Offset + Page.Size;
  FLastPageOffset := Page.Offset;
  Logical := StreamFor(Page);
  if Logical <> nil then
    Logical.TakePage(Page, FQueue);
end;

procedure TOggDemuxer.ClearQueue;
begin
  FQueue := nil;
  FQueueHead := 0;
end;

procedure TOggDemuxer.Open;
var
  Pages, Index: Integer;
  AllComplete: Boolean;
  Logical: TOggLogicalStream;
begin
  FReader := TOggPageReader.Create(FStream);
  FStreams := TObjectList.Create(True);
  FNextOffset := 0;
  FDataOffset := -1;
  Pages := 0;
  repeat
    if not ReadNextPage then
      Break;
    Inc(Pages);
    AllComplete := FStreams.Count > 0;
    for Index := 0 to FStreams.Count - 1 do
      if not TOggLogicalStream(FStreams[Index]).HeadersComplete then
        AllComplete := False;
    if (FDataOffset < 0) and (Length(FQueue) > 0) then
      FDataOffset := FLastPageOffset;
  until AllComplete or (Pages >= HeaderPageLimit);
  if FStreams.Count = 0 then
    MediaFail('no Ogg pages');
  if TOggLogicalStream(FStreams[0]).Codec = codecUnknown then
    if FStreams.Count = 1 then
      MediaFailUnsupported('Ogg stream of an unknown codec');
  if FDataOffset < 0 then
    FDataOffset := FNextOffset;
  FPrimary := nil;
  for Index := 0 to FStreams.Count - 1 do
  begin
    Logical := TOggLogicalStream(FStreams[Index]);
    if (FPrimary = nil) and (Logical.Track.Kind = mkAudio) then
      FPrimary := Logical;
  end;
  if FPrimary = nil then
    FPrimary := TOggLogicalStream(FStreams[0]);
  FindDuration;
end;

procedure TOggDemuxer.FindDuration;
var
  Page: TOggPage;
  Window, Offset, Size, LastGranule: Int64;
begin
  Size := FStream.Size;
  Window := BisectionGranularity;
  LastGranule := -1;
  while True do
  begin
    Offset := Size - Window;
    if Offset < FDataOffset then
      Offset := FDataOffset;
    while FReader.ReadPageFrom(Offset, Page) do
    begin
      if (Page.Serial = FPrimary.Serial) and (Page.Granule >= 0) and (Page.Offset > FPrimary.FirstPageOffset) then
        LastGranule := Page.Granule;
      Offset := Page.Offset + Page.Size;
    end;
    if (LastGranule >= 0) or (Size - Window <= FDataOffset) or (Window >= DurationScanLimit) then
      Break;
    Window := Window * 4;
  end;
  FReader.Invalidate;
  if (LastGranule >= 0) and (FPrimary.Codec in [codecOpus, codecVorbis, codecFlac]) then
  begin
    FPrimary.Track.Duration := FPrimary.GranuleToTime(LastGranule);
    if FPrimary.Track.Duration < 0 then
      FPrimary.Track.Duration := 0;
    FDuration := FPrimary.Track.ToMicroseconds(FPrimary.Track.Duration);
  end;
end;

function TOggDemuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
begin
  while FQueueHead >= Length(FQueue) do
  begin
    ClearQueue;
    if not ReadNextPage then
    begin
      Packet := NewPacket(0);
      Exit(False);
    end;
  end;
  Packet := FQueue[FQueueHead];
  FQueue[FQueueHead].Data := nil;
  Inc(FQueueHead);
  Result := True;
end;

procedure TOggDemuxer.RestartAt(Offset: Int64; FromStart: Boolean);
var
  Index: Integer;
begin
  ClearQueue;
  for Index := 0 to FStreams.Count - 1 do
    TOggLogicalStream(FStreams[Index]).Restart(FromStart);
  FNextOffset := Offset;
end;

function TOggDemuxer.FindPrimaryPage(From, Before: Int64; out Page: TOggPage): Boolean;
begin
  Result := False;
  while FReader.ReadPageFrom(From, Page) do
  begin
    if Page.Offset >= Before then
      Exit(False);
    if (Page.Serial = FPrimary.Serial) and (Page.Granule >= 0) and (Page.Offset > FPrimary.FirstPageOffset) then
      Exit(True);
    From := Page.Offset + Page.Size;
  end;
end;

function TOggDemuxer.SeekTo(Microseconds: Int64): Boolean;
var
  Target, Low, High, Middle, Best: Int64;
  Page: TOggPage;
  Track: TMediaTrack;
begin
  Result := True;
  Track := FPrimary.Track;
  if not (FPrimary.Codec in [codecOpus, codecVorbis, codecFlac]) then
  begin
    if Microseconds > 0 then
      Exit(False);
    RestartAt(FDataOffset, True);
    Exit;
  end;
  Target := FPrimary.TimeToGranule(Track.FromMicroseconds(Microseconds - Track.SeekPreRoll));
  if Microseconds <= 0 then
  begin
    RestartAt(FDataOffset, True);
    Exit;
  end;
  Low := FDataOffset;
  High := FStream.Size;
  while High - Low > BisectionGranularity do
  begin
    Middle := Low + (High - Low) div 2;
    if FindPrimaryPage(Middle, High, Page) and (Page.Granule <= Target) then
      Low := Page.Offset
    else
      High := Middle;
  end;
  Best := -1;
  while FindPrimaryPage(Low, FStream.Size, Page) do
  begin
    if Page.Granule > Target then
      Break;
    Best := Page.Offset;
    Low := Page.Offset + Page.Size;
  end;
  FReader.Invalidate;
  if Best < 0 then
    RestartAt(FDataOffset, True)
  else
    RestartAt(Best, False);
end;

end.
