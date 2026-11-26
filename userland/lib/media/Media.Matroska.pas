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
  Matroska and WebM files.

  Open reads the EBML header (the DocType tells WebM from Matroska) and
  the segment's top-level elements up to the first cluster: SeekHead
  (where the Info, Tracks and Cues are when they are not first), Info
  (TimestampScale, Duration) and Tracks (Media.Matroska.Tracks). Clusters
  are then read in order, of known or unknown size (a cluster of unknown
  size ends at the next top-level element), their SimpleBlocks and
  BlockGroups (Block, BlockDuration, ReferenceBlock: not a key frame,
  DiscardPadding) split into frames (Media.Matroska.Blocks), each a
  packet.

  Times are in TimestampScale nanoseconds (the track TimeBase), the
  codec delay taken off. A frame's duration is the BlockDuration, else
  the track's DefaultDuration, else what the codec packet says (Opus'
  TOC byte, Vorbis' mode), and the frames of a lace follow each other by
  it (PCM's from its size, MP3's and FLAC's frame headers). DiscardPadding shortens the last frame (Duration) and becomes
  TrimEnd in samples.

  SeekTo picks the last cluster at or before the target from the Cues
  (of the video track if there is one), or from an index made by walking
  the clusters, steps back while a video track's first key frame there is
  later than the target, and then drops what comes before: video until a
  key frame, audio packets ending before the target less the pre-roll.
}
unit Media.Matroska;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Contnrs,
  Media.Packets,
  Media.Demuxers,
  Media.Ebml,
  Media.Matroska.Tracks,
  Media.Matroska.Blocks,
  Media.Matroska.Cues;

type
  TMatroskaDemuxer = class(TMediaDemuxer)
  private
    FReader: TEbmlReader;
    FInfos: TObjectList;
    FDocType: string;
    FTimestampScale: Int64;
    FSegmentStart, FSegmentEnd: Int64;
    FFirstCluster: Int64;
    FCuesPosition: Int64;
    FIndex: TClusterIndex;
    FIndexReady: Boolean;
    { Where reading goes on, and the cluster it is in. }
    FInCluster: Boolean;
    FClusterEnd: Int64;
    FClusterTime: Int64;
    FClusterStart: Int64;
    FQueue: array of TMediaPacket;
    FQueueHead: Integer;
    { Dropping after a seek. }
    FDropAudioBefore: Int64;
    FWaitForKey: array of Boolean;
    procedure ReadHeader;
    procedure ReadSeekHead(EndAt: Int64; var InfoPosition, TracksPosition: Int64);
    procedure ReadInfo(EndAt: Int64);
    procedure ReadTracks(EndAt: Int64);
    function InfoOfNumber(Number: Int64): TMatroskaTrack;
    function SeekTrackInfo: TMatroskaTrack;
    function NextElement(out Element: TEbmlElement): Boolean;
    procedure ReadBlockGroup(EndAt: Int64);
    procedure QueueBlock(const Data: TBytes; BlockDuration: Int64; HasReference: Boolean; DiscardPadding: Int64;
      Simple: Boolean);
    function FrameDuration(Info: TMatroskaTrack; const Frame: TBytes): Int64;
    procedure BuildIndex;
    function FirstKeyTimeIn(Position: Int64; Info: TMatroskaTrack; out Time: Int64): Boolean;
    function Wanted(const Packet: TMediaPacket): Boolean;
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
  Media.Errors,
  Media.Ogg.Codecs,
  Media.Ogg.VorbisModes;

const
  IdEbml = $1A45DFA3;
  IdDocType = $4282;
  IdSegment = $18538067;
  IdSeekHead = $114D9B74;
  IdSeek = $4DBB;
  IdSeekId = $53AB;
  IdSeekPosition = $53AC;
  IdInfo = $1549A966;
  IdTimestampScale = $2AD7B1;
  IdDuration = $4489;
  IdTracks = $1654AE6B;
  IdTrackEntry = $AE;
  IdCues = $1C53BB6B;
  IdSimpleBlock = $A3;
  IdBlockGroup = $A0;
  IdBlock = $A1;
  IdBlockDuration = $9B;
  IdReferenceBlock = $FB;
  IdDiscardPadding = $75A2;
  MaximumBlockSize = 256 * 1024 * 1024;
  NoDrop = Low(Int64);

destructor TMatroskaDemuxer.Destroy;
begin
  FInfos.Free;
  FReader.Free;
  inherited Destroy;
end;

class function TMatroskaDemuxer.Recognizes(const Head: TBytes): Boolean;
begin
  Result := (Length(Head) >= 4) and (Head[0] = $1A) and (Head[1] = $45) and (Head[2] = $DF) and (Head[3] = $A3);
end;

function TMatroskaDemuxer.FormatName: string;
begin
  if FDocType = 'webm' then
    Result := 'webm'
  else
    Result := 'matroska';
end;

function KnownEnd(const Element: TEbmlElement; Limit: Int64): Int64;
begin
  if Element.Size = EbmlUnknownSize then
    Result := Limit
  else
  begin
    Result := Element.DataStart + Element.Size;
    if Result > Limit then
      Result := Limit;
  end;
end;

procedure TMatroskaDemuxer.ReadHeader;
var
  Element, Child: TEbmlElement;
  HeaderEnd: Int64;
begin
  if not FReader.ReadElement(Element) or (Element.Id <> IdEbml) or (Element.Size = EbmlUnknownSize) then
    MediaFail('not an EBML file');
  HeaderEnd := Element.DataStart + Element.Size;
  FDocType := 'matroska';
  while (FReader.Position < HeaderEnd) and FReader.ReadElement(Child) do
  begin
    if Child.Size = EbmlUnknownSize then
      MediaFail('bad EBML header');
    if Child.Id = IdDocType then
      FDocType := FReader.ReadString(Child.Size);
    FReader.Position := Child.DataStart + Child.Size;
  end;
  if (FDocType <> 'matroska') and (FDocType <> 'webm') then
    MediaFailUnsupported('EBML document of type ' + FDocType);
  FReader.Position := HeaderEnd;
end;

procedure TMatroskaDemuxer.ReadSeekHead(EndAt: Int64; var InfoPosition, TracksPosition: Int64);
var
  Seek, Field: TEbmlElement;
  SeekEnd: Int64;
  Id: QWord;
  Position: Int64;
begin
  while (FReader.Position < EndAt) and FReader.ReadElement(Seek) do
  begin
    SeekEnd := KnownEnd(Seek, EndAt);
    if Seek.Id = IdSeek then
    begin
      Id := 0;
      Position := -1;
      while (FReader.Position < SeekEnd) and FReader.ReadElement(Field) do
      begin
        if Field.Id = IdSeekId then
          Id := FReader.ReadUnsigned(Field.Size)
        else if Field.Id = IdSeekPosition then
          Position := FReader.ReadUnsigned(Field.Size);
        FReader.Position := KnownEnd(Field, SeekEnd);
      end;
      if Position >= 0 then
        case Id of
          IdInfo: InfoPosition := FSegmentStart + Position;
          IdTracks: TracksPosition := FSegmentStart + Position;
          IdCues: FCuesPosition := FSegmentStart + Position;
        end;
    end;
    FReader.Position := SeekEnd;
  end;
end;

procedure TMatroskaDemuxer.ReadInfo(EndAt: Int64);
var
  Element: TEbmlElement;
  InfoDuration: Double;
begin
  InfoDuration := -1;
  while (FReader.Position < EndAt) and FReader.ReadElement(Element) do
  begin
    case Element.Id of
      IdTimestampScale: FTimestampScale := FReader.ReadUnsigned(Element.Size);
      IdDuration: InfoDuration := FReader.ReadFloat(Element.Size);
    end;
    FReader.Position := KnownEnd(Element, EndAt);
  end;
  if FTimestampScale <= 0 then
    FTimestampScale := 1000000;
  if InfoDuration >= 0 then
    FDuration := Round(InfoDuration * FTimestampScale / 1000);
end;

function GreatestCommonDivisor(A, B: Int64): Int64;
var
  Remainder: Int64;
begin
  while B <> 0 do
  begin
    Remainder := A mod B;
    A := B;
    B := Remainder;
  end;
  Result := A;
end;

procedure TMatroskaDemuxer.ReadTracks(EndAt: Int64);
var
  Element: TEbmlElement;
  Info: TMatroskaTrack;
  Divisor: Int64;
begin
  while (FReader.Position < EndAt) and FReader.ReadElement(Element) do
  begin
    if Element.Id = IdTrackEntry then
    begin
      Info := TMatroskaTrack.Create;
      FInfos.Add(Info);
      Info.Track := AddTrack;
      Divisor := GreatestCommonDivisor(FTimestampScale, 1000000000);
      Info.Track.TimeBase := MakeTimeBase(FTimestampScale div Divisor, 1000000000 div Divisor);
      ReadTrackEntry(FReader, KnownEnd(Element, EndAt), Info, FTimestampScale);
      if FDuration > 0 then
        Info.Track.Duration := Info.Track.FromMicroseconds(FDuration);
    end;
    FReader.Position := KnownEnd(Element, EndAt);
  end;
end;

procedure TMatroskaDemuxer.Open;
var
  Element: TEbmlElement;
  InfoPosition, TracksPosition, ElementEnd: Int64;
  HaveInfo, HaveTracks: Boolean;
begin
  FReader := TEbmlReader.Create(FStream);
  FInfos := TObjectList.Create(True);
  FTimestampScale := 1000000;
  FCuesPosition := -1;
  FFirstCluster := -1;
  FDropAudioBefore := NoDrop;
  ReadHeader;
  { The segment, skipping anything before it. }
  repeat
    if not FReader.ReadElement(Element) then
      MediaFail('no Matroska segment');
    if Element.Id = IdSegment then
      Break;
    if Element.Size = EbmlUnknownSize then
      MediaFail('no Matroska segment');
    FReader.Position := Element.DataStart + Element.Size;
  until False;
  FSegmentStart := Element.DataStart;
  FSegmentEnd := KnownEnd(Element, FReader.Size);
  if Element.Size = EbmlUnknownSize then
    FSegmentEnd := High(Int64);
  InfoPosition := -1;
  TracksPosition := -1;
  HaveInfo := False;
  HaveTracks := False;
  while (FReader.Position < FSegmentEnd) and FReader.ReadElement(Element) do
  begin
    if Element.Id = IdCluster then
    begin
      FFirstCluster := Element.Start;
      Break;
    end;
    if Element.Size = EbmlUnknownSize then
      MediaFail('top-level element of unknown size');
    ElementEnd := Element.DataStart + Element.Size;
    case Element.Id of
      IdSeekHead: ReadSeekHead(ElementEnd, InfoPosition, TracksPosition);
      IdInfo:
        begin
          ReadInfo(ElementEnd);
          HaveInfo := True;
        end;
      IdTracks:
        begin
          ReadTracks(ElementEnd);
          HaveTracks := True;
        end;
      IdCues: FCuesPosition := Element.Start;
    end;
    FReader.Position := ElementEnd;
  end;
  if FFirstCluster < 0 then
    FFirstCluster := FReader.Position;
  if not HaveInfo and (InfoPosition >= 0) then
  begin
    FReader.Position := InfoPosition;
    if FReader.ReadElement(Element) and (Element.Id = IdInfo) then
      ReadInfo(KnownEnd(Element, FReader.Size));
  end;
  if not HaveTracks and (TracksPosition >= 0) then
  begin
    FReader.Position := TracksPosition;
    if FReader.ReadElement(Element) and (Element.Id = IdTracks) then
      ReadTracks(KnownEnd(Element, FReader.Size));
  end;
  if TrackCount = 0 then
    MediaFail('Matroska file without tracks');
  SetLength(FWaitForKey, TrackCount);
  FReader.Position := FFirstCluster;
  FInCluster := False;
end;

function TMatroskaDemuxer.InfoOfNumber(Number: Int64): TMatroskaTrack;
var
  Index: Integer;
begin
  for Index := 0 to FInfos.Count - 1 do
    if TMatroskaTrack(FInfos[Index]).Number = Number then
      Exit(TMatroskaTrack(FInfos[Index]));
  Result := nil;
end;

function TMatroskaDemuxer.FrameDuration(Info: TMatroskaTrack; const Frame: TBytes): Int64;
var
  Samples: Int64;
begin
  Result := 0;
  if Info.DefaultDuration > 0 then
    Exit(Info.DefaultDuration);
  case Info.Track.Codec of
    codecOpus: Samples := OpusPacketDuration(Frame);
    codecVorbis: Samples := VorbisPacketDuration(Info.VorbisModes, Frame);
    codecMp3: Samples := MpegAudioFrameSamples(Frame);
    codecFlac: Samples := FlacFrameBlockSize(Frame);
    codecPcm:
      if (Info.Track.Channels > 0) and (Info.Track.BitsPerSample >= 8) then
        Samples := Length(Frame) div (Info.Track.Channels * (Info.Track.BitsPerSample div 8))
      else
        Samples := 0;
  else
    Exit;
  end;
  if (Info.TrimRate > 0) and (Samples > 0) then
    Result := (Samples * 1000000000 div Info.TrimRate + FTimestampScale div 2) div FTimestampScale;
end;

procedure TMatroskaDemuxer.QueueBlock(const Data: TBytes; BlockDuration: Int64; HasReference: Boolean;
  DiscardPadding: Int64; Simple: Boolean);
var
  Block: TMatroskaBlock;
  Info: TMatroskaTrack;
  Index, Count, PrefixSize: Integer;
  Time, Each: Int64;
  Packet: TMediaPacket;
  Frame: TBytes;
begin
  Block := ParseBlock(Data);
  Info := InfoOfNumber(Block.TrackNumber);
  if (Info = nil) or Info.Unsupported then
    Exit;
  Time := FClusterTime + Block.RelativeTime - Info.DelayTicks;
  Count := Length(Block.Frames);
  PrefixSize := Length(Info.StripPrefix);
  Each := 0;
  if (BlockDuration > 0) and (Count > 1) and (Info.DefaultDuration = 0) then
    Each := BlockDuration div Count;
  for Index := 0 to Count - 1 do
  begin
    Frame := nil;
    SetLength(Frame, PrefixSize + Block.Frames[Index].Size);
    if PrefixSize > 0 then
      Move(Info.StripPrefix[0], Frame[0], PrefixSize);
    if Block.Frames[Index].Size > 0 then
      Move(Data[Block.Frames[Index].Offset], Frame[PrefixSize], Block.Frames[Index].Size);
    Packet := NewPacket(Info.Track.Index);
    Packet.Data := Frame;
    Packet.PresentationTime := Time;
    Packet.DecodeTime := Time;
    if Simple then
      Packet.KeyFrame := (Block.Flags and BlockFlagKey) <> 0
    else
      Packet.KeyFrame := not HasReference;
    if (Count = 1) and (BlockDuration > 0) then
      Packet.Duration := BlockDuration
    else if Each > 0 then
      Packet.Duration := Each
    else
      Packet.Duration := FrameDuration(Info, Frame);
    if (Index = Count - 1) and (DiscardPadding > 0) then
    begin
      { Rounded to the nearest sample, as FFmpeg does. }
      Packet.TrimEnd := (DiscardPadding * Info.TrimRate + 500000000) div 1000000000;
      { A BlockDuration given is already the shortened one (as FFmpeg
        writes it); a duration from the codec is not. }
      if BlockDuration = 0 then
        Dec(Packet.Duration, (DiscardPadding + FTimestampScale div 2) div FTimestampScale);
      if Packet.Duration < 0 then
        Packet.Duration := 0;
    end;
    Inc(Time, Packet.Duration);
    if Wanted(Packet) then
    begin
      SetLength(FQueue, Length(FQueue) + 1);
      FQueue[High(FQueue)] := Packet;
    end;
  end;
end;

{ After a seek: video waits for a key frame, audio for the target. }
function TMatroskaDemuxer.Wanted(const Packet: TMediaPacket): Boolean;
var
  Track: TMediaTrack;
begin
  Result := True;
  Track := Tracks[Packet.TrackIndex];
  if FWaitForKey[Packet.TrackIndex] then
  begin
    if not Packet.KeyFrame then
      Exit(False);
    FWaitForKey[Packet.TrackIndex] := False;
  end;
  if (FDropAudioBefore <> NoDrop) and (Track.Kind = mkAudio) then
  begin
    if (Packet.Duration > 0) and (Packet.PresentationTime + Packet.Duration <= FDropAudioBefore) then
      Exit(False);
  end;
end;

procedure TMatroskaDemuxer.ReadBlockGroup(EndAt: Int64);
var
  Element: TEbmlElement;
  Data: TBytes;
  BlockDuration, DiscardPadding: Int64;
  HasReference, HaveBlock: Boolean;
begin
  Data := nil;
  BlockDuration := 0;
  DiscardPadding := 0;
  HasReference := False;
  HaveBlock := False;
  while (FReader.Position < EndAt) and FReader.ReadElement(Element) do
  begin
    if Element.Size = EbmlUnknownSize then
      MediaFail('block group element of unknown size');
    if Element.DataStart + Element.Size > EndAt then
      MediaFail('block runs past its group');
    case Element.Id of
      IdBlock:
        begin
          if Element.Size > MaximumBlockSize then
            MediaFail('block too large');
          Data := FReader.ReadBytes(Element.Size);
          HaveBlock := True;
        end;
      IdBlockDuration: BlockDuration := FReader.ReadUnsigned(Element.Size);
      IdReferenceBlock: HasReference := True;
      IdDiscardPadding: DiscardPadding := FReader.ReadSigned(Element.Size);
    end;
    FReader.Position := Element.DataStart + Element.Size;
  end;
  if HaveBlock then
    QueueBlock(Data, BlockDuration, HasReference, DiscardPadding, False);
end;

{ The next element of the segment or of the current cluster, entering and
  leaving clusters; False at the end. }
function TMatroskaDemuxer.NextElement(out Element: TEbmlElement): Boolean;
begin
  Result := False;
  while True do
  begin
    if FInCluster and (FClusterEnd >= 0) and (FReader.Position >= FClusterEnd) then
      FInCluster := False;
    if FReader.Position >= FSegmentEnd then
      Exit(False);
    if not FReader.ReadElement(Element) then
      Exit(False);
    if Element.Id = IdCluster then
    begin
      FInCluster := True;
      FClusterTime := 0;
      FClusterStart := Element.Start;
      if Element.Size = EbmlUnknownSize then
        FClusterEnd := -1
      else
        FClusterEnd := Element.DataStart + Element.Size;
      Continue;
    end;
    if IsTopLevelId(Element.Id) then
    begin
      FInCluster := False;
      if Element.Size = EbmlUnknownSize then
        Exit(False);
      FReader.Position := Element.DataStart + Element.Size;
      Continue;
    end;
    if not FInCluster then
    begin
      { Something between clusters (Void, CRC-32): skipped. }
      if Element.Size = EbmlUnknownSize then
        MediaFail('element of unknown size');
      FReader.Position := Element.DataStart + Element.Size;
      Continue;
    end;
    if Element.Size = EbmlUnknownSize then
      MediaFail('cluster element of unknown size');
    if (FClusterEnd >= 0) and (Element.DataStart + Element.Size > FClusterEnd) then
      MediaFail('element runs past its cluster');
    Exit(True);
  end;
end;

function TMatroskaDemuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
var
  Element: TEbmlElement;
  Data: TBytes;
  ElementEnd: Int64;
begin
  while FQueueHead >= Length(FQueue) do
  begin
    FQueue := nil;
    FQueueHead := 0;
    if not NextElement(Element) then
    begin
      Packet := NewPacket(0);
      Exit(False);
    end;
    ElementEnd := Element.DataStart + Element.Size;
    if ElementEnd > FReader.Size then
    begin
      { Cut short: what is there is not a whole block. }
      FReader.Position := FReader.Size;
      Continue;
    end;
    case Element.Id of
      IdClusterTimestamp: FClusterTime := FReader.ReadUnsigned(Element.Size);
      IdSimpleBlock:
        begin
          if Element.Size > MaximumBlockSize then
            MediaFail('block too large');
          Data := FReader.ReadBytes(Element.Size);
          QueueBlock(Data, 0, False, 0, True);
        end;
      IdBlockGroup: ReadBlockGroup(ElementEnd);
    end;
    FReader.Position := ElementEnd;
  end;
  Packet := FQueue[FQueueHead];
  FQueue[FQueueHead].Data := nil;
  Inc(FQueueHead);
  Result := True;
end;

function TMatroskaDemuxer.SeekTrackInfo: TMatroskaTrack;
var
  Index: Integer;
begin
  for Index := 0 to FInfos.Count - 1 do
    if TMatroskaTrack(FInfos[Index]).Track.Kind = mkVideo then
      Exit(TMatroskaTrack(FInfos[Index]));
  Result := TMatroskaTrack(FInfos[0]);
end;

procedure TMatroskaDemuxer.BuildIndex;
var
  Element: TEbmlElement;
  Info: TMatroskaTrack;
begin
  if FIndexReady then
    Exit;
  FIndexReady := True;
  FIndex := nil;
  Info := SeekTrackInfo;
  try
    if FCuesPosition >= 0 then
    begin
      FReader.Position := FCuesPosition;
      if FReader.ReadElement(Element) and (Element.Id = IdCues) and (Element.Size <> EbmlUnknownSize) then
      begin
        FIndex := ReadCues(FReader, Element.DataStart + Element.Size, FSegmentStart, Info.Number);
        if Length(FIndex) = 0 then
          FIndex := ReadCues(FReader, Element.DataStart + Element.Size, FSegmentStart, 0);
      end;
    end;
  except
    on EMediaError do
      FIndex := nil;
  end;
  if Length(FIndex) = 0 then
    FIndex := WalkClusters(FReader, FFirstCluster, FSegmentEnd);
end;

{ The time of the first key frame of Info's track in the cluster at
  Position (False if it has none). }
function TMatroskaDemuxer.FirstKeyTimeIn(Position: Int64; Info: TMatroskaTrack; out Time: Int64): Boolean;
var
  Element: TEbmlElement;
  Block: TMatroskaBlock;
  Data: TBytes;
  Packet: TMediaPacket;
  SavedQueue: Integer;
  Cluster: Int64;
begin
  Result := False;
  Time := 0;
  FReader.Position := Position;
  FInCluster := False;
  FQueue := nil;
  FQueueHead := 0;
  if not NextElement(Element) then
    Exit;
  Cluster := FClusterStart;
  repeat
    if Element.Id = IdClusterTimestamp then
      FClusterTime := FReader.ReadUnsigned(Element.Size)
    else if Element.Id = IdSimpleBlock then
    begin
      Data := FReader.ReadBytes(Element.Size);
      Block := ParseBlock(Data);
      if (Block.TrackNumber = Info.Number) and ((Block.Flags and BlockFlagKey) <> 0) then
      begin
        Time := FClusterTime + Block.RelativeTime - Info.DelayTicks;
        Exit(True);
      end;
    end
    else if Element.Id = IdBlockGroup then
    begin
      SavedQueue := Length(FQueue);
      ReadBlockGroup(Element.DataStart + Element.Size);
      while SavedQueue < Length(FQueue) do
      begin
        Packet := FQueue[SavedQueue];
        if (Packet.TrackIndex = Info.Track.Index) and Packet.KeyFrame then
        begin
          Time := Packet.PresentationTime;
          FQueue := nil;
          Exit(True);
        end;
        Inc(SavedQueue);
      end;
    end;
    FReader.Position := Element.DataStart + Element.Size;
    { Only this cluster. }
    if not NextElement(Element) or not FInCluster then
      Exit;
  until FClusterStart <> Cluster;
end;

function TMatroskaDemuxer.SeekTo(Microseconds: Int64): Boolean;
var
  Info: TMatroskaTrack;
  Target, AudioTarget, KeyTime, PreRoll: Int64;
  Entry, Index: Integer;
begin
  Result := False;
  try
    BuildIndex;
    Info := SeekTrackInfo;
    if Microseconds < 0 then
      Microseconds := 0;
    Target := Info.Track.FromMicroseconds(Microseconds);
    PreRoll := 0;
    for Index := 0 to TrackCount - 1 do
      if (Tracks[Index].Kind = mkAudio) and (Tracks[Index].SeekPreRoll > PreRoll) then
        PreRoll := Tracks[Index].SeekPreRoll;
    AudioTarget := Info.Track.FromMicroseconds(Microseconds - PreRoll);
    FDropAudioBefore := NoDrop;
    for Index := 0 to High(FWaitForKey) do
      FWaitForKey[Index] := False;
    for Index := 0 to FInfos.Count - 1 do
      TMatroskaTrack(FInfos[Index]).VorbisModes.PreviousBlock := 0;
    if Length(FIndex) = 0 then
    begin
      if Microseconds > 0 then
        Exit(False);
      FReader.Position := FFirstCluster;
    end
    else
    begin
      if Info.Track.Kind = mkVideo then
        Entry := FindClusterEntry(FIndex, Target)
      else
        Entry := FindClusterEntry(FIndex, AudioTarget);
      if Info.Track.Kind = mkVideo then
        while (Entry > 0) and not (FirstKeyTimeIn(FIndex[Entry].Position, Info, KeyTime) and (KeyTime <= Target)) do
          Dec(Entry);
      FReader.Position := FIndex[Entry].Position;
      if Microseconds > 0 then
        FDropAudioBefore := AudioTarget;
    end;
    for Index := 0 to TrackCount - 1 do
      FWaitForKey[Index] := Tracks[Index].Kind = mkVideo;
    FInCluster := False;
    FQueue := nil;
    FQueueHead := 0;
    Result := True;
  except
    on EMediaError do
      Result := False;
  end;
end;

end.
