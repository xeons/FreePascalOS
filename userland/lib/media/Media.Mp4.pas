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
  ISO base media files (MP4), plain and fragmented.

  Open walks the top-level boxes (skipping mdat) until the moov, which
  is read whole: mvhd (the movie time scale), mvex (trex defaults, mehd
  duration) and each trak: tkhd (track ID), mdia/mdhd (time scale, the
  track TimeBase, duration, language), hdlr (audio, video), the sample
  description (Media.Mp4.SampleEntries), the sample table
  (Media.Mp4.Tracks) and the edit list.

  Packets come in file order: the track whose next sample is earliest in
  the file goes first. When every track has given all its samples, the
  top-level boxes after the moov are walked on and each moof's samples
  added (Media.Mp4.Fragments). Data may keep arriving: a moof or a
  sample not yet wholly in the stream ends reading for now, and reading
  later goes on from there, so an init segment followed by media segments
  appended to the stream (a media source) plays as they come.

  An audio sample whose duration is shorter than the codec frame it holds
  has the rest trimmed (TrimEnd), as has one past the edit list's end.

  SeekTo reads the rest of the fragments, then sets each track to its
  last sync sample at or before the target (audio: the sample playing
  at the target less the pre-roll).
}
unit Media.Mp4;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Contnrs,
  Media.Packets,
  Media.Demuxers,
  Media.Mp4.Tracks;

type
  TMp4Demuxer = class(TMediaDemuxer)
  private
    FStates: TObjectList;
    FMovieTimescale: Int64;
    FScanPosition: Int64;
    FFragmented: Boolean;
    function ReadBoxBytes(Start, Finish: Int64): TBytes;
    procedure ReadMovie(const Data: TBytes);
    procedure ReadTrack(const Data: TBytes; Start, Finish: Integer);
    procedure ReadEditList(const Data: TBytes; Start, Finish: Integer; State: TMp4TrackState);
    procedure ReadMovieExtends(const Data: TBytes; Start, Finish: Integer);
    function ScanForFragment: Boolean;
    function NextState: TMp4TrackState;
    procedure SeekTrack(State: TMp4TrackState; Microseconds: Int64);
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
  Media.ByteReaders,
  Media.Mp4.Boxes,
  Media.Mp4.SampleEntries,
  Media.Mp4.Fragments,
  Media.Ogg.Codecs;

const
  MaximumIndexBox = 256 * 1024 * 1024;
  MaximumSampleSize = 256 * 1024 * 1024;

destructor TMp4Demuxer.Destroy;
begin
  FStates.Free;
  inherited Destroy;
end;

class function TMp4Demuxer.Recognizes(const Head: TBytes): Boolean;
var
  Kind: string;
begin
  if Length(Head) < 8 then
    Exit(False);
  Kind := FourCCAt(Head, 4);
  Result := (Kind = 'ftyp') or (Kind = 'styp') or (Kind = 'moov');
end;

function TMp4Demuxer.FormatName: string;
begin
  Result := 'mp4';
end;

function TMp4Demuxer.ReadBoxBytes(Start, Finish: Int64): TBytes;
begin
  Result := nil;
  if (Finish - Start > MaximumIndexBox) or (Finish < Start) then
    MediaFail('MP4 index box too large');
  if Finish > FStream.Size then
    MediaFail('MP4 box cut short');
  SetLength(Result, Finish - Start);
  FStream.Position := Start;
  if Length(Result) > 0 then
    FStream.ReadBuffer(Result[0], Length(Result));
end;

function FullBoxVersion(const Data: TBytes; const Box: TMp4Box): Integer;
begin
  if Box.Finish - Box.ContentStart < 4 then
    MediaFail(Box.Kind + ' too short');
  Result := Data[Box.ContentStart];
end;

procedure TMp4Demuxer.ReadEditList(const Data: TBytes; Start, Finish: Integer; State: TMp4TrackState);
var
  Box: TMp4Box;
  Version, EntrySize, Index: Integer;
  Count, Position, SegmentDuration, MediaTime, Empty: Int64;
  Found: Boolean;
begin
  if not FindChild(Data, Start, Finish, 'elst', Box) then
    Exit;
  Version := FullBoxVersion(Data, Box);
  if Version = 1 then
    EntrySize := 20
  else
    EntrySize := 12;
  Count := BigEndian32(Data, Box.ContentStart + 4);
  if Count * EntrySize > Box.Finish - Box.ContentStart - 8 then
    MediaFail('elst entry count does not fit');
  Empty := 0;
  Found := False;
  Position := Box.ContentStart + 8;
  for Index := 0 to Count - 1 do
  begin
    if Version = 1 then
    begin
      SegmentDuration := Int64(BigEndian64(Data, Position));
      MediaTime := Int64(BigEndian64(Data, Position + 8));
    end
    else
    begin
      SegmentDuration := BigEndian32(Data, Position);
      MediaTime := LongInt(BigEndian32(Data, Position + 4));
    end;
    Inc(Position, EntrySize);
    if (SegmentDuration < 0) or (SegmentDuration > High(Int64) div 1000000) then
      MediaFail('bad edit');
    if FMovieTimescale > 0 then
      SegmentDuration := ScaleTime(SegmentDuration, State.Timescale, FMovieTimescale);
    if MediaTime = -1 then
    begin
      Inc(Empty, SegmentDuration);
      Continue;
    end;
    State.EditShift := Empty - MediaTime;
    if (SegmentDuration > 0) and (Count - Index = 1) then
      State.EditEnd := Empty + SegmentDuration;
    Found := True;
    Break;
  end;
  if not Found then
    State.EditShift := Empty;
end;

procedure TMp4Demuxer.ReadTrack(const Data: TBytes; Start, Finish: Integer);
var
  Box, Media, Info, Table, Description, Header, Handler: TMp4Box;
  State: TMp4TrackState;
  Track: TMediaTrack;
  Version: Integer;
  MediaDuration: Int64;
  Language: Word;
  HandlerKind: string;
begin
  if not FindChild(Data, Start, Finish, 'tkhd', Header) or not FindChild(Data, Start, Finish, 'mdia', Media) then
    Exit;
  State := TMp4TrackState.Create;
  FStates.Add(State);
  Track := AddTrack;
  State.Track := Track;
  State.EditEnd := -1;
  Version := FullBoxVersion(Data, Header);
  if Version = 1 then
    State.TrackId := BigEndian32(Data, Header.ContentStart + 20)
  else
    State.TrackId := BigEndian32(Data, Header.ContentStart + 12);
  Track.ContainerId := State.TrackId;
  if not FindChild(Data, Media.ContentStart, Media.Finish, 'mdhd', Box) then
    MediaFail('track without mdhd');
  Version := FullBoxVersion(Data, Box);
  if Version = 1 then
  begin
    State.Timescale := BigEndian32(Data, Box.ContentStart + 20);
    MediaDuration := Int64(BigEndian64(Data, Box.ContentStart + 24));
    Language := BigEndian16(Data, Box.ContentStart + 32);
  end
  else
  begin
    State.Timescale := BigEndian32(Data, Box.ContentStart + 12);
    MediaDuration := BigEndian32(Data, Box.ContentStart + 16);
    if MediaDuration = $FFFFFFFF then
      MediaDuration := -1;
    Language := BigEndian16(Data, Box.ContentStart + 20);
  end;
  if State.Timescale <= 0 then
    MediaFail('track time scale of 0');
  Track.TimeBase := MakeTimeBase(1, State.Timescale);
  if MediaDuration > 0 then
    Track.Duration := MediaDuration;
  if Language <> 0 then
    Track.Language := Chr(((Language shr 10) and 31) + $60) + Chr(((Language shr 5) and 31) + $60) +
      Chr((Language and 31) + $60);
  HandlerKind := '';
  if FindChild(Data, Media.ContentStart, Media.Finish, 'hdlr', Handler) and (Handler.Finish - Handler.ContentStart >= 12) then
    HandlerKind := FourCCAt(Data, Handler.ContentStart + 8);
  if HandlerKind = 'soun' then
    Track.Kind := mkAudio
  else if HandlerKind = 'vide' then
    Track.Kind := mkVideo
  else if (HandlerKind = 'subt') or (HandlerKind = 'text') or (HandlerKind = 'sbtl') then
    Track.Kind := mkSubtitle
  else
    Track.Kind := mkUnknown;
  if FindChild(Data, Start, Finish, 'edts', Box) then
    ReadEditList(Data, Box.ContentStart, Box.Finish, State);
  if not FindChild(Data, Media.ContentStart, Media.Finish, 'minf', Info)
    or not FindChild(Data, Info.ContentStart, Info.Finish, 'stbl', Table) then
    Exit;
  if FindChild(Data, Table.ContentStart, Table.Finish, 'stsd', Description) then
    DescribeSampleEntry(Data, Description.ContentStart + 8, Description.Finish, Track);
  ReadSampleTable(Data, Table.ContentStart, Table.Finish, State, FStream.Size, Track.Codec = codecPcm);
  { Audio before time 0 is trimmed but for the codec's own delay. }
  State.TrimFrom := State.EditShift + ScaleTime(Track.CodecDelay, State.Timescale, Track.SampleRate);
  if Track.SampleRate <= 0 then
    State.TrimFrom := State.EditShift;
  if State.TrimFrom > 0 then
    State.TrimFrom := 0;
end;

procedure TMp4Demuxer.ReadMovieExtends(const Data: TBytes; Start, Finish: Integer);
var
  Offset, Index: Integer;
  Box: TMp4Box;
  State: TMp4TrackState;
  TrackId: LongWord;
begin
  FFragmented := True;
  Offset := Start;
  while NextBox(Data, Offset, Finish, Box) do
    if (Box.Kind = 'trex') and (Box.Finish - Box.ContentStart >= 24) then
    begin
      TrackId := BigEndian32(Data, Box.ContentStart + 4);
      for Index := 0 to FStates.Count - 1 do
      begin
        State := TMp4TrackState(FStates[Index]);
        if State.TrackId = TrackId then
        begin
          State.DefaultDuration := BigEndian32(Data, Box.ContentStart + 12);
          State.DefaultSize := BigEndian32(Data, Box.ContentStart + 16);
          State.DefaultFlags := BigEndian32(Data, Box.ContentStart + 20);
        end;
      end;
    end
    else if Box.Kind = 'mehd' then
    begin
      if FullBoxVersion(Data, Box) = 1 then
        FDuration := ScaleTime(Int64(BigEndian64(Data, Box.ContentStart + 4)), 1000000, FMovieTimescale)
      else
        FDuration := ScaleTime(BigEndian32(Data, Box.ContentStart + 4), 1000000, FMovieTimescale);
    end;
end;

procedure TMp4Demuxer.ReadMovie(const Data: TBytes);
var
  Offset: Integer;
  Box, Movie, Extends: TMp4Box;
  MovieDuration: Int64;
  HaveExtends: Boolean;
begin
  Offset := 0;
  if not NextBox(Data, Offset, Length(Data), Movie) then
    MediaFail('empty moov');
  MovieDuration := 0;
  FMovieTimescale := 0;
  if FindChild(Data, Movie.ContentStart, Movie.Finish, 'mvhd', Box) then
  begin
    if FullBoxVersion(Data, Box) = 1 then
    begin
      FMovieTimescale := BigEndian32(Data, Box.ContentStart + 20);
      MovieDuration := Int64(BigEndian64(Data, Box.ContentStart + 24));
    end
    else
    begin
      FMovieTimescale := BigEndian32(Data, Box.ContentStart + 12);
      MovieDuration := BigEndian32(Data, Box.ContentStart + 16);
    end;
  end;
  if (FMovieTimescale > 0) and (MovieDuration > 0) and (MovieDuration < High(Int64) div 1000000) then
    FDuration := ScaleTime(MovieDuration, 1000000, FMovieTimescale);
  HaveExtends := FindChild(Data, Movie.ContentStart, Movie.Finish, 'mvex', Extends);
  Offset := Movie.ContentStart;
  while NextBox(Data, Offset, Movie.Finish, Box) do
    if Box.Kind = 'trak' then
      ReadTrack(Data, Box.ContentStart, Box.Finish);
  if HaveExtends then
    ReadMovieExtends(Data, Extends.ContentStart, Extends.Finish);
end;

procedure TMp4Demuxer.Open;
var
  Box: TMp4Box;
  Position: Int64;
  HaveMovie: Boolean;
begin
  FStates := TObjectList.Create(True);
  Position := 0;
  HaveMovie := False;
  while ReadBoxHeader(FStream, Position, Box) do
  begin
    if Box.Kind = 'moov' then
    begin
      ReadMovie(ReadBoxBytes(Box.Start, Box.Finish));
      HaveMovie := True;
      Position := Box.Finish;
      Break;
    end;
    if Box.Kind = 'moof' then
      Break;
    Position := Box.Finish;
  end;
  if not HaveMovie then
    MediaFail('MP4 file without a moov box');
  if TrackCount = 0 then
    MediaFail('MP4 file without tracks');
  FScanPosition := Position;
end;

{ Walks the top-level boxes from the scan position to the next moof whose
  samples it adds; False if there is none (yet). }
function TMp4Demuxer.ScanForFragment: Boolean;
var
  Box: TMp4Box;
  Size: Int64;
begin
  Result := False;
  Size := FStream.Size;
  while ReadBoxHeader(FStream, FScanPosition, Box) do
  begin
    if Box.Kind = 'moof' then
    begin
      if Box.Finish > Size then
        Exit(False);
      ReadMovieFragment(ReadBoxBytes(Box.Start, Box.Finish), Box.Start, FStates, Size);
      FScanPosition := Box.Finish;
      Exit(True);
    end;
    FScanPosition := Box.Finish;
  end;
end;

function TMp4Demuxer.NextState: TMp4TrackState;
var
  Index: Integer;
  State: TMp4TrackState;
begin
  Result := nil;
  for Index := 0 to FStates.Count - 1 do
  begin
    State := TMp4TrackState(FStates[Index]);
    if State.Cursor < State.Count then
      if (Result = nil) or (State.Samples[State.Cursor].Offset < Result.Samples[Result.Cursor].Offset) then
        Result := State;
  end;
end;

{ A sample shorter than the codec frame in it (FFmpeg writes the last one
  so, to end the presentation without an edit) trims the frame's end. }
procedure TrimToSampleDuration(State: TMp4TrackState; var Packet: TMediaPacket);
var
  FrameSamples, Presented: Int64;
begin
  case State.Track.Codec of
    codecOpus: FrameSamples := OpusPacketDuration(Packet.Data);
    codecMp3: FrameSamples := MpegAudioFrameSamples(Packet.Data);
    codecFlac: FrameSamples := FlacFrameBlockSize(Packet.Data);
  else
    Exit;
  end;
  if FrameSamples <= 0 then
    Exit;
  Presented := State.TicksToSamples(State.Samples[State.Cursor - 1].Duration);
  if FrameSamples - Presented > Packet.TrimEnd then
    Packet.TrimEnd := FrameSamples - Presented;
end;

function TMp4Demuxer.ReadPacket(out Packet: TMediaPacket): Boolean;
var
  State: TMp4TrackState;
  Sample: TMp4Sample;
begin
  Packet := NewPacket(0);
  State := NextState;
  while State = nil do
  begin
    if not ScanForFragment then
      Exit(False);
    State := NextState;
  end;
  Sample := State.Samples[State.Cursor];
  if (Sample.Size > MaximumSampleSize) or (Sample.Offset < 0) then
    MediaFail('MP4 sample out of range');
  if Sample.Offset + Sample.Size > FStream.Size then
    { Not (yet) in the stream. }
    Exit(False);
  Packet := State.MakePacket(State.Cursor);
  SetLength(Packet.Data, Sample.Size);
  FStream.Position := Sample.Offset;
  if Sample.Size > 0 then
    FStream.ReadBuffer(Packet.Data[0], Sample.Size);
  Inc(State.Cursor);
  TrimToSampleDuration(State, Packet);
  Result := True;
end;

procedure TMp4Demuxer.SeekTrack(State: TMp4TrackState; Microseconds: Int64);
var
  Target: Int64;
  Index, Best: Integer;
begin
  if Microseconds <= 0 then
  begin
    State.Cursor := 0;
    Exit;
  end;
  if State.Track.Kind = mkVideo then
  begin
    Target := State.Track.FromMicroseconds(Microseconds);
    Best := 0;
    for Index := 0 to State.Count - 1 do
      if State.Samples[Index].Key and (State.PresentationTime(Index) <= Target) then
        Best := Index;
  end
  else
  begin
    Target := State.Track.FromMicroseconds(Microseconds - State.Track.SeekPreRoll);
    Best := 0;
    for Index := 0 to State.Count - 1 do
    begin
      if State.PresentationTime(Index) > Target then
        Break;
      if State.Samples[Index].Key then
        Best := Index;
    end;
  end;
  State.Cursor := Best;
end;

function TMp4Demuxer.SeekTo(Microseconds: Int64): Boolean;
var
  Index: Integer;
begin
  Result := True;
  try
    if Microseconds > 0 then
      while ScanForFragment do
        ;
  except
    on EMediaError do
      ;
  end;
  if Microseconds < 0 then
    Microseconds := 0;
  for Index := 0 to FStates.Count - 1 do
    SeekTrack(TMp4TrackState(FStates[Index]), Microseconds);
end;

end.
