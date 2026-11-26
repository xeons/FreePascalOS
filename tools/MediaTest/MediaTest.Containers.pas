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
  Tests of the Ogg, Matroska/WebM and MP4 demuxers over the files
  make-container-fixtures.py makes: every packet's size, MD5, timestamp,
  duration and key flag against ffprobe's (or the script's own list),
  each track's codec, rate, channels, time base, picture size and setup
  (OpusHead, STREAMINFO, av1C, avcC, AudioSpecificConfig MD5s), seeking,
  a fragmented MP4 fed in two pieces as a media source would, and files
  cut short or damaged (EMediaError at worst, never anything else).
}
unit MediaTest.Containers;

{$mode objfpc}
{$H+}

interface

procedure RunContainerTests(const FixtureRoot: string);

implementation

uses
  Classes,
  SysUtils,
  md5,
  TestChecks,
  Media.Errors,
  Media.Packets,
  Media.Demuxers,
  Media.Containers,
  Media.Mp4;

type
  TExpectedPacket = record
    Stream: Integer;
    Time: Int64;
    HasTime: Boolean;
    Duration: Int64;
    HasDuration: Boolean;
    Size: Integer;
    Key: Boolean;
    Digest: string;
  end;

  TExpectedPackets = array of TExpectedPacket;

  TActualPackets = array of array of TMediaPacket;

{ The helpers of MediaTest.Common, kept here so these tests do not
  depend on the decoders. }
function ReadFileBytes(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then
      Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function ReadManifestLines(const Path: string): TStringList;
var
  Lines: TStringList;
  Line: string;
begin
  Result := TStringList.Create;
  if not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    for Line in Lines do
      if (Trim(Line) <> '') and (Trim(Line)[1] <> '#') then
        Result.Add(Trim(Line));
  finally
    Lines.Free;
  end;
end;

function SplitFields(const Line: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Delimiter := ' ';
  Result.StrictDelimiter := True;
  Result.DelimitedText := Line;
end;

function MD5OfBytes(const Bytes: TBytes): string;
var
  Context: TMD5Context;
  Digest: TMD5Digest;
begin
  MD5Init(Context);
  if Length(Bytes) > 0 then
    MD5Update(Context, Bytes[0], Length(Bytes));
  MD5Final(Context, Digest);
  Result := MD5Print(Digest);
end;

function ReadExpectedPackets(const Path: string): TExpectedPackets;
var
  Lines, Fields: TStringList;
  Line: string;
  Count: Integer;
begin
  Result := nil;
  Lines := ReadManifestLines(Path);
  try
    SetLength(Result, Lines.Count);
    Count := 0;
    for Line in Lines do
    begin
      Fields := SplitFields(Line);
      try
        if Fields.Count < 6 then
          Continue;
        Result[Count].Stream := StrToInt(Fields[0]);
        Result[Count].HasTime := Fields[1] <> '-';
        if Result[Count].HasTime then
          Result[Count].Time := StrToInt64(Fields[1]);
        Result[Count].HasDuration := Fields[2] <> '-';
        if Result[Count].HasDuration then
          Result[Count].Duration := StrToInt64(Fields[2]);
        Result[Count].Size := StrToInt(Fields[3]);
        Result[Count].Key := Fields[4] = '1';
        Result[Count].Digest := Fields[5];
        Inc(Count);
      finally
        Fields.Free;
      end;
    end;
    SetLength(Result, Count);
  finally
    Lines.Free;
  end;
end;

function ReadAllPackets(Demuxer: TMediaDemuxer): TActualPackets;
var
  Packet: TMediaPacket;
  Track: Integer;
begin
  Result := nil;
  while Demuxer.ReadPacket(Packet) do
  begin
    Track := Packet.TrackIndex;
    if Track >= Length(Result) then
      SetLength(Result, Track + 1);
    SetLength(Result[Track], Length(Result[Track]) + 1);
    Result[Track][High(Result[Track])] := Packet;
  end;
end;

function DescribePacket(const Packet: TMediaPacket): string;
begin
  Result := Format('pts %d duration %d size %d key %d md5 %s', [Packet.PresentationTime, Packet.Duration,
    Length(Packet.Data), Ord(Packet.KeyFrame), MD5OfBytes(Packet.Data)]);
end;

function DescribeExpected(const Expected: TExpectedPacket): string;
begin
  Result := Format('pts %d duration %d size %d key %d md5 %s', [Expected.Time, Expected.Duration, Expected.Size,
    Ord(Expected.Key), Expected.Digest]);
end;

{ Compares the packets of one stream; '' or what differs first. }
function CompareStream(const Actual: array of TMediaPacket; const Expected: TExpectedPackets; Stream,
  Tolerance: Integer): string;
var
  Index, Position: Integer;
  Wanted: TExpectedPacket;
  Got: TMediaPacket;
  DurationWrong: Boolean;
  Last: Integer;
begin
  Result := '';
  Position := 0;
  Last := -1;
  for Index := 0 to High(Expected) do
    if Expected[Index].Stream = Stream then
      Last := Index;
  for Index := 0 to High(Expected) do
  begin
    Wanted := Expected[Index];
    if Wanted.Stream <> Stream then
      Continue;
    if Position > High(Actual) then
      Exit(Format('packet %d missing (%s)', [Position, DescribeExpected(Wanted)]));
    Got := Actual[Position];
    DurationWrong := False;
    if Wanted.HasDuration then
      if (Tolerance = 0) and (Index = Last) then
        { The end of the presentation (an edit list) may cut the last. }
        DurationWrong := (Got.Duration > Wanted.Duration) or (Got.Duration < 0)
      else if Tolerance = 0 then
        DurationWrong := Got.Duration <> Wanted.Duration
      else
        { Rounded times; the last block's duration is the file's own,
          which FFmpeg replaces with the codec's. }
        DurationWrong := (Got.Duration <> 0) and (Index <> Last) and (Abs(Got.Duration - Wanted.Duration) > Tolerance);
    if (Length(Got.Data) <> Wanted.Size) or (MD5OfBytes(Got.Data) <> Wanted.Digest)
      or (Wanted.HasTime and (Got.PresentationTime <> Wanted.Time)) or (Got.KeyFrame <> Wanted.Key) or DurationWrong then
      Exit(Format('packet %d: got %s, expected %s', [Position, DescribePacket(Got), DescribeExpected(Wanted)]));
    Inc(Position);
  end;
  if Position <> Length(Actual) then
    Result := Format('%d packets more than expected', [Length(Actual) - Position]);
end;

function CodecOfProbeName(const Name: string): TCodecId;
begin
  if Copy(Name, 1, 4) = 'pcm_' then
    Exit(codecPcm);
  if Name = 'opus' then Exit(codecOpus);
  if Name = 'vorbis' then Exit(codecVorbis);
  if Name = 'flac' then Exit(codecFlac);
  if Name = 'mp3' then Exit(codecMp3);
  if Name = 'aac' then Exit(codecAac);
  if Name = 'vp8' then Exit(codecVp8);
  if Name = 'vp9' then Exit(codecVp9);
  if Name = 'av1' then Exit(codecAv1);
  if Name = 'h264' then Exit(codecH264);
  if Name = 'theora' then Exit(codecTheora);
  Result := codecUnknown;
end;

procedure CheckTracks(Demuxer: TMediaDemuxer; const Path, Name, FormatWanted: string);
var
  Lines, Fields: TStringList;
  Line, ProbeCodec, Slash: string;
  Index, SlashAt: Integer;
  Track: TMediaTrack;
  Numerator, Denominator: Int64;
  Good, CompareSetup: Boolean;
begin
  Lines := ReadManifestLines(Path + '.streams');
  try
    Check(Demuxer.TrackCount >= Lines.Count, Name + ': ' + IntToStr(Lines.Count) + ' tracks');
    for Line in Lines do
    begin
      Fields := SplitFields(Line);
      try
        Index := StrToInt(Fields[0]);
        if Index >= Demuxer.TrackCount then
          Continue;
        Track := Demuxer.Tracks[Index];
        ProbeCodec := Fields[1];
        Slash := Fields[4];
        SlashAt := Pos('/', Slash);
        Numerator := StrToInt64(Copy(Slash, 1, SlashAt - 1));
        Denominator := StrToInt64(Copy(Slash, SlashAt + 1, Length(Slash)));
        Good := (Track.Codec = CodecOfProbeName(ProbeCodec))
          and (Track.TimeBase.Numerator * Denominator = Track.TimeBase.Denominator * Numerator);
        if StrToInt(Fields[2]) <> 0 then
          Good := Good and (Track.SampleRate = StrToInt(Fields[2])) and (Track.Channels = StrToInt(Fields[3]));
        if StrToInt(Fields[5]) <> 0 then
          Good := Good and (Track.Width = StrToInt(Fields[5])) and (Track.Height = StrToInt(Fields[6]));
        if ProbeCodec = 'pcm_s16be' then
          Good := Good and Track.PcmBigEndian and (Track.BitsPerSample = 16) and not Track.PcmFloat;
        if ProbeCodec = 'pcm_s16le' then
          Good := Good and not Track.PcmBigEndian and (Track.BitsPerSample = 16) and not Track.PcmFloat;
        if ProbeCodec = 'pcm_f32le' then
          Good := Good and Track.PcmFloat and (Track.BitsPerSample = 32);
        CompareSetup := (Fields[7] <> '-') and ((Track.Codec in [codecOpus, codecAv1, codecH264, codecAac])
          or ((Track.Codec = codecFlac) and (FormatWanted <> 'matroska')));
        { An av1C without configuration OBUs (a fragmented file's, written
          before the encoder's first frame): FFmpeg takes the sequence
          header from the stream instead. }
        if (Track.Codec = codecAv1) and (Length(Track.Headers) = 1) and (Length(Track.Headers[0]) <= 4) then
          CompareSetup := False;
        if CompareSetup then
          Good := Good and (Length(Track.Headers) >= 1) and (MD5OfBytes(Track.Headers[0]) = Fields[7]);
        if Track.Codec = codecFlac then
          Good := Good and (Length(Track.Headers) = 1) and (Length(Track.Headers[0]) = 34);
        if Track.Codec = codecVorbis then
          Good := Good and (Length(Track.Headers) = 3) and (Track.Headers[0][0] = 1) and (Track.Headers[1][0] = 3)
            and (Track.Headers[2][0] = 5);
        if not Good then
          WriteLn(Format('     track %d: codec %s timebase %d/%d rate %d channels %d size %dx%d headers %d', [Index,
            CodecIdName(Track.Codec), Track.TimeBase.Numerator, Track.TimeBase.Denominator, Track.SampleRate,
            Track.Channels, Track.Width, Track.Height, Length(Track.Headers)]));
        Check(Good, Format('%s: track %d (%s) described', [Name, Index, ProbeCodec]));
      finally
        Fields.Free;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure CheckPackets(const Actual: TActualPackets; const Expected: TExpectedPackets; const Name: string;
  Tolerance, StreamCount: Integer);
var
  Stream: Integer;
  Difference: string;
begin
  for Stream := 0 to StreamCount - 1 do
  begin
    if Stream <= High(Actual) then
      Difference := CompareStream(Actual[Stream], Expected, Stream, Tolerance)
    else
      Difference := CompareStream([], Expected, Stream, Tolerance);
    Check(Difference = '', Format('%s: stream %d packets', [Name, Stream]));
    if Difference <> '' then
      WriteLn('     ', Difference);
  end;
end;

function StreamCountOf(const Expected: TExpectedPackets): Integer;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to High(Expected) do
    if Expected[Index].Stream + 1 > Result then
      Result := Expected[Index].Stream + 1;
end;

{ The track seeking is judged by: the first video track, else track 0. }
function SeekTrackOf(Demuxer: TMediaDemuxer): TMediaTrack;
begin
  Result := Demuxer.FirstTrackOf(mkVideo);
  if Result = nil then
    Result := Demuxer.Tracks[0];
end;

{ Where a seek to Target (in Track's units) may land: the start of the
  packet playing at Target, or the next one after a gap. }
function SeekLandingTime(const Expected: TExpectedPackets; Stream: Integer; Target: Int64; out Covered: Boolean): Int64;
var
  Index: Integer;
begin
  Covered := False;
  Result := High(Int64);
  for Index := 0 to High(Expected) do
    if (Expected[Index].Stream = Stream) and Expected[Index].HasTime then
    begin
      if (Expected[Index].Time <= Target) and (Expected[Index].Time + Expected[Index].Duration > Target) then
        Covered := True;
      if (Expected[Index].Time > Target) and (Expected[Index].Time < Result) then
        Result := Expected[Index].Time;
    end;
end;

function ExpectedHas(const Expected: TExpectedPackets; Stream: Integer; const Packet: TMediaPacket): Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 0 to High(Expected) do
    if (Expected[Index].Stream = Stream) and Expected[Index].HasTime
      and (Expected[Index].Time = Packet.PresentationTime) then
      Exit(Expected[Index].Digest = MD5OfBytes(Packet.Data));
end;

procedure CheckSeeking(Demuxer: TMediaDemuxer; const Expected: TExpectedPackets; const Name: string);
var
  Track: TMediaTrack;
  Fraction: Integer;
  Target, Total, Time, Landing: Int64;
  Packet: TMediaPacket;
  Found, Good, Covered: Boolean;
  Report: string;
begin
  Track := SeekTrackOf(Demuxer);
  Total := Demuxer.Duration;
  if Total <= 0 then
    Total := 1000000;
  Good := True;
  Report := '';
  for Fraction := 1 to 3 do
  begin
    Target := Total * Fraction div 4;
    if not Demuxer.SeekTo(Target) then
    begin
      Good := False;
      Report := Report + Format(' seek to %d refused;', [Target]);
      Continue;
    end;
    Found := False;
    while Demuxer.ReadPacket(Packet) do
      if (Packet.TrackIndex = Track.Index) and (Packet.PresentationTime <> NoTimestamp) then
      begin
        Found := True;
        Break;
      end;
    if not Found then
    begin
      Good := False;
      Report := Report + Format(' nothing after %d;', [Target]);
      Continue;
    end;
    Time := Track.ToMicroseconds(Packet.PresentationTime);
    Landing := SeekLandingTime(Expected, Track.Index, Track.FromMicroseconds(Target), Covered);
    if not Covered and (Packet.PresentationTime = Landing) then
      Time := Target;
    if (Time > Target + 1000) or (Time < Target - 1500000) or not ExpectedHas(Expected, Track.Index, Packet)
      or ((Track.Kind = mkVideo) and not Packet.KeyFrame) then
    begin
      Good := False;
      Report := Report + Format(' seek to %d gave %d (%s);', [Target, Time, DescribePacket(Packet)]);
    end;
  end;
  Check(Good, Name + ': seeking');
  if not Good then
    WriteLn('    ', Report);
  Good := Demuxer.SeekTo(0);
  Found := False;
  while Good and Demuxer.ReadPacket(Packet) do
    if Packet.TrackIndex = Track.Index then
    begin
      Found := True;
      Break;
    end;
  Good := Good and Found and ExpectedHas(Expected, Track.Index, Packet);
  if Good then
    for Fraction := 0 to High(Expected) do
      if Expected[Fraction].Stream = Track.Index then
      begin
        Good := Expected[Fraction].Digest = MD5OfBytes(Packet.Data);
        Break;
      end;
  Check(Good, Name + ': seeking back to the start');
end;

procedure TestFile(const Directory, Name, FormatWanted: string; Tolerance: Integer);
var
  Path: string;
  Demuxer: TMediaDemuxer;
  Expected: TExpectedPackets;
  Actual: TActualPackets;
begin
  Path := Directory + Name;
  Expected := ReadExpectedPackets(Path + '.packets');
  try
    Demuxer := OpenMediaFile(Path);
  except
    on Error: Exception do
    begin
      Check(False, Name + ': opens (' + Error.ClassName + ': ' + Error.Message + ')');
      Exit;
    end;
  end;
  try
    Check(Demuxer.FormatName = FormatWanted, Name + ': format ' + FormatWanted + ' (got ' + Demuxer.FormatName + ')');
    try
      Actual := ReadAllPackets(Demuxer);
      { After reading: a chained file's later tracks appear as they come. }
      CheckTracks(Demuxer, Path, Name, FormatWanted);
      CheckPackets(Actual, Expected, Name, Tolerance, StreamCountOf(Expected));
      CheckSeeking(Demuxer, Expected, Name);
    except
      on Error: Exception do
        Check(False, Name + ': reading (' + Error.ClassName + ': ' + Error.Message + ')');
    end;
  finally
    Demuxer.Free;
  end;
end;

procedure TestMediaSource(const Directory, Name: string; InitBytes: Integer);
var
  Whole: TBytes;
  Stream: TMemoryStream;
  Demuxer: TMp4Demuxer;
  Packet: TMediaPacket;
  Saved: Int64;
  Expected: TExpectedPackets;
  Actual: TActualPackets;
  Track: Integer;
  Early: Boolean;
begin
  Whole := ReadFileBytes(Directory + Name);
  Expected := ReadExpectedPackets(Directory + Name + '.packets');
  Stream := TMemoryStream.Create;
  Demuxer := TMp4Demuxer.Create(Stream, True);
  try
    try
      Stream.WriteBuffer(Whole[0], InitBytes);
      Stream.Position := 0;
      Demuxer.Open;
      Early := Demuxer.ReadPacket(Packet);
      Check(not Early and (Demuxer.TrackCount >= 1), Name + ': init segment alone: tracks, no packets');
      Saved := Stream.Position;
      Stream.Position := Stream.Size;
      Stream.WriteBuffer(Whole[InitBytes], Length(Whole) - InitBytes);
      Stream.Position := Saved;
      Actual := nil;
      while Demuxer.ReadPacket(Packet) do
      begin
        Track := Packet.TrackIndex;
        if Track >= Length(Actual) then
          SetLength(Actual, Track + 1);
        SetLength(Actual[Track], Length(Actual[Track]) + 1);
        Actual[Track][High(Actual[Track])] := Packet;
      end;
      CheckPackets(Actual, Expected, Name + ' (appended segments)', 0, StreamCountOf(Expected));
    except
      on Error: Exception do
        Check(False, Name + ': media source (' + Error.ClassName + ': ' + Error.Message + ')');
    end;
  finally
    Demuxer.Free;
  end;
end;

{ Reads Bytes as a file to the end; True if nothing but EMediaError came
  out of it. }
function SurvivesDamage(const Bytes: TBytes): Boolean;
var
  Stream: TMemoryStream;
  Demuxer: TMediaDemuxer;
  Packet: TMediaPacket;
  Count: Integer;
begin
  Result := True;
  Stream := TMemoryStream.Create;
  if Length(Bytes) > 0 then
    Stream.WriteBuffer(Bytes[0], Length(Bytes));
  Demuxer := nil;
  try
    try
      Demuxer := OpenMediaStream(Stream, True);
      Count := 0;
      while Demuxer.ReadPacket(Packet) and (Count < 1000000) do
        Inc(Count);
      Demuxer.SeekTo(500000);
      while Demuxer.ReadPacket(Packet) and (Count < 2000000) do
        Inc(Count);
    except
      on EMediaError do ;
      on Error: Exception do
      begin
        WriteLn('     ', Error.ClassName, ': ', Error.Message);
        Result := False;
      end;
    end;
  finally
    Demuxer.Free;
  end;
end;

procedure TestDamage(const Directory, Name: string);
var
  Whole, Damaged: TBytes;
  Generator: Int64;
  Index, Round: Integer;
  Good: Boolean;
begin
  Whole := ReadFileBytes(Directory + Name);
  Good := SurvivesDamage(Copy(Whole, 0, Length(Whole) * 3 div 5));
  Good := SurvivesDamage(Copy(Whole, 0, 200)) and Good;
  Generator := Length(Whole);
  for Round := 1 to 6 do
  begin
    Damaged := Copy(Whole, 0, Length(Whole));
    for Index := 1 to 20 do
    begin
      Generator := (Generator * 1103515245 + 12345) and $7FFFFFFF;
      Damaged[Generator mod Length(Damaged)] := (Generator shr 16) and $FF;
    end;
    Good := SurvivesDamage(Damaged) and Good;
  end;
  Check(Good, Name + ': cut short and damaged copies read without crashing');
end;

procedure RunContainerTests(const FixtureRoot: string);
var
  Directory, Line: string;
  Lines, Fields: TStringList;
begin
  Directory := IncludeTrailingPathDelimiter(FixtureRoot) + 'containers' + PathDelim;
  Lines := ReadManifestLines(Directory + 'manifest.txt');
  try
    Check(Lines.Count > 0, 'container fixtures present');
    for Line in Lines do
    begin
      Fields := SplitFields(Line);
      try
        if (Fields[0] = 'file') and (Fields.Count >= 4) then
        begin
          TestFile(Directory, Fields[1], Fields[2], StrToInt(Fields[3]));
          TestDamage(Directory, Fields[1]);
        end
        else if (Fields[0] = 'mse') and (Fields.Count >= 3) then
          TestMediaSource(Directory, Fields[1], StrToInt(Fields[2]));
      finally
        Fields.Free;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

end.
