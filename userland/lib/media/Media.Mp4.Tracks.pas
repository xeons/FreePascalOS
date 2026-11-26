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
  An MP4 track's samples: where each is, how big, its decode time,
  composition offset, duration and whether it is a sync sample, in one
  compact array.

  A plain file's sample table (stbl) is expanded into it: stts (decode
  durations), ctts (composition offsets), stsc (samples per chunk), stsz
  or stz2 (sizes), stco or co64 (chunk offsets) and stss (sync samples;
  without it every sample is one). The counts are checked against the
  boxes' sizes so a damaged table cannot ask for more memory than the
  file could describe. PCM's one-frame samples are grouped into packets
  of up to 1024 frames within a chunk. Fragments (Media.Mp4) add their runs at the end.

  Times: the edit list's first media edit (after any empty ones) shifts
  presentation times so its media time is at the empty edits' length,
  and ends the presentation after its duration; audio samples before
  time 0 (beyond the codec's own delay) and after the end become
  TrimStart and TrimEnd, and the last sample's Duration is cut to the end.
}
unit Media.Mp4.Tracks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Packets;

type
  TMp4Sample = packed record
    Offset: Int64;
    DecodeTime: Int64;
    Size: LongWord;
    Duration: LongWord;
    CompositionOffset: LongInt;
    Key: Boolean;
  end;

  TMp4TrackState = class
  public
    Track: TMediaTrack;
    TrackId: LongWord;
    Timescale: Int64;
    Samples: array of TMp4Sample;
    Count: Integer;
    { The next sample to give. }
    Cursor: Integer;
    { Added to decode and composition times (the edit list). }
    EditShift: Int64;
    { Presentation ends here (after the shift); -1 if not limited. }
    EditEnd: Int64;
    { Presentation time from which samples are trimmed at the start (the
      codec's own delay excepted). }
    TrimFrom: Int64;
    { Fragment defaults (trex). }
    DefaultDuration, DefaultSize, DefaultFlags: LongWord;
    { Where the next fragment's samples start when it has no tfdt. }
    NextDecodeTime: Int64;
    procedure Add(const Sample: TMp4Sample);
    { Ticks of the track's time scale as samples of its rate. }
    function TicksToSamples(Ticks: Int64): Int64;
    function MakePacket(Index: Integer): TMediaPacket;
    { The presentation time of sample Index. }
    function PresentationTime(Index: Integer): Int64;
  end;

const
  { The most samples a track may have. }
  MaximumSamples = 1 shl 24;
  PcmGroupSamples = 1024;

{ Fills State from the stbl box contents at Start..Finish of Data (of a
  file StreamSize bytes long). With GroupSamples (PCM, whose samples are
  single frames), up to PcmGroupSamples consecutive samples of a chunk of
  equal size make one. }
procedure ReadSampleTable(const Data: TBytes; Start, Finish: Integer; State: TMp4TrackState; StreamSize: Int64;
  GroupSamples: Boolean);

implementation

uses
  Media.Errors,
  Media.ByteReaders,
  Media.Mp4.Boxes;

procedure TMp4TrackState.Add(const Sample: TMp4Sample);
begin
  if Count >= MaximumSamples then
    MediaFail('MP4 track with too many samples');
  if Count >= Length(Samples) then
    SetLength(Samples, Count + Count div 2 + 64);
  Samples[Count] := Sample;
  Inc(Count);
  NextDecodeTime := Sample.DecodeTime + Sample.Duration;
end;

function TMp4TrackState.PresentationTime(Index: Integer): Int64;
begin
  Result := Samples[Index].DecodeTime + Samples[Index].CompositionOffset + EditShift;
end;

function TMp4TrackState.TicksToSamples(Ticks: Int64): Int64;
begin
  if (Track.SampleRate <= 0) or (Timescale <= 0) or (Timescale = Track.SampleRate) then
    Result := Ticks
  else
    Result := Ticks * Track.SampleRate div Timescale;
end;

function TMp4TrackState.MakePacket(Index: Integer): TMediaPacket;
var
  Sample: TMp4Sample;
  Start, Finish, Overlap, Low, High: Int64;
begin
  Sample := Samples[Index];
  Result := NewPacket(Track.Index);
  Result.PresentationTime := PresentationTime(Index);
  Result.DecodeTime := Sample.DecodeTime + EditShift;
  Result.Duration := Sample.Duration;
  Result.KeyFrame := Sample.Key;
  if Track.Kind <> mkAudio then
    Exit;
  Start := Result.PresentationTime;
  Finish := Start + Sample.Duration;
  { The part of the sample in [TrimFrom, 0). }
  Low := Start;
  if Low < TrimFrom then
    Low := TrimFrom;
  High := Finish;
  if High > 0 then
    High := 0;
  if High > Low then
    Result.TrimStart := TicksToSamples(High - Low);
  if (EditEnd >= 0) and (Finish > EditEnd) then
  begin
    Overlap := Finish - EditEnd;
    if Overlap > Sample.Duration then
      Overlap := Sample.Duration;
    Result.TrimEnd := TicksToSamples(Overlap);
    Dec(Result.Duration, Overlap);
  end;
end;

type
  TTableBoxes = record
    Stts, Ctts, Stsc, Stsz, Stz2, Stco, Co64, Stss: TMp4Box;
    HaveStts, HaveCtts, HaveStsc, HaveStsz, HaveStz2, HaveStco, HaveCo64, HaveStss: Boolean;
  end;

{ The entry count of a full box whose entries are EntrySize bytes after
  HeaderBytes of the contents, checked against the box's size. }
function EntryCount(const Data: TBytes; const Box: TMp4Box; HeaderBytes, EntrySize: Integer): Integer;
var
  Count: Int64;
begin
  if Box.Finish - Box.ContentStart < HeaderBytes then
    MediaFail(Box.Kind + ' too short');
  Count := BigEndian32(Data, Box.ContentStart + HeaderBytes - 4);
  if Count * EntrySize > Box.Finish - Box.ContentStart - HeaderBytes then
    MediaFail(Box.Kind + ' entry count does not fit');
  Result := Count;
end;

procedure FindTables(const Data: TBytes; Start, Finish: Integer; out Boxes: TTableBoxes);
var
  Offset: Integer;
  Box: TMp4Box;
begin
  Boxes := Default(TTableBoxes);
  Offset := Start;
  while NextBox(Data, Offset, Finish, Box) do
    if Box.Kind = 'stts' then begin Boxes.Stts := Box; Boxes.HaveStts := True; end
    else if Box.Kind = 'ctts' then begin Boxes.Ctts := Box; Boxes.HaveCtts := True; end
    else if Box.Kind = 'stsc' then begin Boxes.Stsc := Box; Boxes.HaveStsc := True; end
    else if Box.Kind = 'stsz' then begin Boxes.Stsz := Box; Boxes.HaveStsz := True; end
    else if Box.Kind = 'stz2' then begin Boxes.Stz2 := Box; Boxes.HaveStz2 := True; end
    else if Box.Kind = 'stco' then begin Boxes.Stco := Box; Boxes.HaveStco := True; end
    else if Box.Kind = 'co64' then begin Boxes.Co64 := Box; Boxes.HaveCo64 := True; end
    else if Box.Kind = 'stss' then begin Boxes.Stss := Box; Boxes.HaveStss := True; end;
end;

function SampleSize(const Data: TBytes; const Boxes: TTableBoxes; Constant: Int64; FieldBits: Integer; Index: Int64): LongWord;
var
  Base, Position: Int64;
begin
  if Boxes.HaveStsz then
  begin
    if Constant <> 0 then
      Exit(Constant);
    Exit(BigEndian32(Data, Boxes.Stsz.ContentStart + 12 + Index * 4));
  end;
  Base := Boxes.Stz2.ContentStart + 12;
  case FieldBits of
    4:
      begin
        Position := Base + Index div 2;
        if (Index and 1) = 0 then
          Result := Data[Position] shr 4
        else
          Result := Data[Position] and 15;
      end;
    8: Result := Data[Base + Index];
  else
    Result := BigEndian16(Data, Base + Index * 2);
  end;
end;

procedure ReadSampleTable(const Data: TBytes; Start, Finish: Integer; State: TMp4TrackState; StreamSize: Int64;
  GroupSamples: Boolean);
var
  Boxes: TTableBoxes;
  FieldBits: Integer;
  Total, ConstantSize, ChunkCount, StscCount, SttsCount, CttsCount, SyncCount: Int64;
  Chunk, StscIndex, InChunk, PerChunk, NextFirstChunk, SampleIndex: Int64;
  SttsIndex, SttsLeft, CttsIndex, CttsLeft, SyncIndex, NextSync: Int64;
  Offset, DecodeTime: Int64;
  Sample: TMp4Sample;
begin
  FindTables(Data, Start, Finish, Boxes);
  if not (Boxes.HaveStsz or Boxes.HaveStz2) or not Boxes.HaveStsc or not (Boxes.HaveStco or Boxes.HaveCo64)
    or not Boxes.HaveStts then
    Exit;
  FieldBits := 0;
  ConstantSize := 0;
  if Boxes.HaveStsz then
  begin
    if Boxes.Stsz.Finish - Boxes.Stsz.ContentStart < 12 then
      MediaFail('stsz too short');
    ConstantSize := BigEndian32(Data, Boxes.Stsz.ContentStart + 4);
    if ConstantSize = 0 then
      Total := EntryCount(Data, Boxes.Stsz, 12, 4)
    else
    begin
      Total := BigEndian32(Data, Boxes.Stsz.ContentStart + 8);
      if (Total < 0) or (Total > MaximumSamples) or (Int64(Total) * ConstantSize > StreamSize) then
        MediaFail('stsz sample count too large');
    end;
  end
  else
  begin
    if Boxes.Stz2.Finish - Boxes.Stz2.ContentStart < 12 then
      MediaFail('stz2 too short');
    FieldBits := Data[Boxes.Stz2.ContentStart + 7];
    if not (FieldBits in [4, 8, 16]) then
      MediaFail('bad stz2 field size');
    Total := BigEndian32(Data, Boxes.Stz2.ContentStart + 8);
    if (Total < 0) or (Int64(Total) * FieldBits div 8 > Boxes.Stz2.Finish - Boxes.Stz2.ContentStart - 12) then
      MediaFail('stz2 sample count does not fit');
  end;
  if Boxes.HaveCo64 then
    ChunkCount := EntryCount(Data, Boxes.Co64, 8, 8)
  else
    ChunkCount := EntryCount(Data, Boxes.Stco, 8, 4);
  StscCount := EntryCount(Data, Boxes.Stsc, 8, 12);
  SttsCount := EntryCount(Data, Boxes.Stts, 8, 8);
  CttsCount := 0;
  if Boxes.HaveCtts then
    CttsCount := EntryCount(Data, Boxes.Ctts, 8, 8);
  SyncCount := 0;
  if Boxes.HaveStss then
    SyncCount := EntryCount(Data, Boxes.Stss, 8, 4);
  if (Total = 0) or (StscCount = 0) or (ChunkCount = 0) then
    Exit;
  SetLength(State.Samples, State.Count + Total);
  SampleIndex := 0;
  StscIndex := 0;
  SttsIndex := 0;
  SttsLeft := 0;
  CttsIndex := 0;
  CttsLeft := 0;
  SyncIndex := 0;
  NextSync := -1;
  if SyncCount > 0 then
    NextSync := BigEndian32(Data, Boxes.Stss.ContentStart + 8) - 1;
  DecodeTime := 0;
  Chunk := 1;
  while (Chunk <= ChunkCount) and (SampleIndex < Total) do
  begin
    { The stsc entry for this chunk. }
    while (StscIndex + 1 < StscCount)
      and (BigEndian32(Data, Boxes.Stsc.ContentStart + 8 + (StscIndex + 1) * 12) <= Chunk) do
      Inc(StscIndex);
    PerChunk := BigEndian32(Data, Boxes.Stsc.ContentStart + 8 + StscIndex * 12 + 4);
    if StscIndex + 1 < StscCount then
      NextFirstChunk := BigEndian32(Data, Boxes.Stsc.ContentStart + 8 + (StscIndex + 1) * 12)
    else
      NextFirstChunk := High(Int64);
    if NextFirstChunk <= Chunk then
      MediaFail('stsc out of order');
    if Boxes.HaveCo64 then
      Offset := Int64(BigEndian64(Data, Boxes.Co64.ContentStart + 8 + (Chunk - 1) * 8))
    else
      Offset := BigEndian32(Data, Boxes.Stco.ContentStart + 8 + (Chunk - 1) * 4);
    InChunk := 0;
    while (InChunk < PerChunk) and (SampleIndex < Total) do
    begin
      Sample := Default(TMp4Sample);
      Sample.Offset := Offset;
      Sample.Size := SampleSize(Data, Boxes, ConstantSize, FieldBits, SampleIndex);
      while (SttsLeft = 0) and (SttsIndex < SttsCount) do
      begin
        SttsLeft := BigEndian32(Data, Boxes.Stts.ContentStart + 8 + SttsIndex * 8);
        Inc(SttsIndex);
      end;
      if SttsIndex > 0 then
        Sample.Duration := BigEndian32(Data, Boxes.Stts.ContentStart + 8 + (SttsIndex - 1) * 8 + 4);
      if SttsLeft > 0 then
        Dec(SttsLeft);
      Sample.DecodeTime := DecodeTime;
      Inc(DecodeTime, Sample.Duration);
      while (CttsLeft = 0) and (CttsIndex < CttsCount) do
      begin
        CttsLeft := BigEndian32(Data, Boxes.Ctts.ContentStart + 8 + CttsIndex * 8);
        Inc(CttsIndex);
      end;
      if CttsIndex > 0 then
        Sample.CompositionOffset := LongInt(BigEndian32(Data, Boxes.Ctts.ContentStart + 8 + (CttsIndex - 1) * 8 + 4));
      if CttsLeft > 0 then
        Dec(CttsLeft);
      if SyncCount = 0 then
        Sample.Key := not Boxes.HaveStss
      else
      begin
        while (NextSync >= 0) and (NextSync < SampleIndex) do
        begin
          Inc(SyncIndex);
          if SyncIndex < SyncCount then
            NextSync := BigEndian32(Data, Boxes.Stss.ContentStart + 8 + SyncIndex * 4) - 1
          else
            NextSync := -1;
        end;
        Sample.Key := NextSync = SampleIndex;
      end;
      if GroupSamples and (ConstantSize > 0) and (InChunk mod PcmGroupSamples <> 0) and (State.Count > 0) then
      begin
        Inc(State.Samples[State.Count - 1].Size, Sample.Size);
        Inc(State.Samples[State.Count - 1].Duration, Sample.Duration);
      end
      else
      begin
        State.Samples[State.Count] := Sample;
        Inc(State.Count);
      end;
      Inc(Offset, Sample.Size);
      Inc(SampleIndex);
      Inc(InChunk);
    end;
    Inc(Chunk);
  end;
  SetLength(State.Samples, State.Count);
  State.NextDecodeTime := DecodeTime;
end;

end.
