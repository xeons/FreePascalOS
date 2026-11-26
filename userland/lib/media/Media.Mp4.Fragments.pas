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
  Movie fragments (moof): each track fragment (traf) adds its runs of
  samples to its track.

  tfhd names the track and may give a base data offset, a sample
  description and default duration, size and flags (over the trex
  defaults of the moov's mvex); without a base offset the base is the
  moof's start when default-base-is-moof is set or for the first track
  fragment, else where the previous track fragment's data ended. tfdt
  gives the decode time of the first sample (else the track's samples
  run on). Each trun gives its sample count, a data offset from the base
  (else it follows the previous run), the first sample's flags, and per
  sample (as its flags say) a duration, size, flags and composition
  offset. A sample is a sync sample unless its flags say
  sample_is_non_sync_sample.
}
unit Media.Mp4.Fragments;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Contnrs,
  Media.Mp4.Tracks;

{ Adds the samples of the moof whose bytes are Data (it starts at
  MoofStart in the file) to the tracks of States (TMp4TrackState).
  StreamSize bounds what sample counts can be believed. }
procedure ReadMovieFragment(const Data: TBytes; MoofStart: Int64; States: TObjectList; StreamSize: Int64);

implementation

uses
  Media.Errors,
  Media.ByteReaders,
  Media.Mp4.Boxes;

const
  TfhdBaseDataOffset = $01;
  TfhdDescription = $02;
  TfhdDefaultDuration = $08;
  TfhdDefaultSize = $10;
  TfhdDefaultFlags = $20;
  TfhdDefaultBaseIsMoof = $20000;

  TrunDataOffset = $01;
  TrunFirstSampleFlags = $04;
  TrunDuration = $100;
  TrunSize = $200;
  TrunFlags = $400;
  TrunCompositionOffset = $800;

  SampleNonSync = $10000;
  MaximumRunSamples = 1 shl 20;

function StateOfTrack(States: TObjectList; TrackId: LongWord): TMp4TrackState;
var
  Index: Integer;
begin
  for Index := 0 to States.Count - 1 do
    if TMp4TrackState(States[Index]).TrackId = TrackId then
      Exit(TMp4TrackState(States[Index]));
  Result := nil;
end;

type
  TFragmentDefaults = record
    Duration, Size, Flags: LongWord;
  end;

{ Reads one trun; Position is where its data starts (moved past it). }
procedure ReadRun(const Data: TBytes; const Box: TMp4Box; State: TMp4TrackState; const Defaults: TFragmentDefaults;
  Base: Int64; var Position: Int64; var DecodeTime: Int64; StreamSize: Int64);
var
  Flags, FirstFlags, SampleFlags: LongWord;
  Count, Index, FieldBytes, Offset: Int64;
  Sample: TMp4Sample;
  HaveFirstFlags: Boolean;
begin
  if Box.Finish - Box.ContentStart < 8 then
    MediaFail('trun too short');
  Flags := BigEndian32(Data, Box.ContentStart) and $FFFFFF;
  Count := BigEndian32(Data, Box.ContentStart + 4);
  Offset := Box.ContentStart + 8;
  if (Flags and TrunDataOffset) <> 0 then
  begin
    Position := Base + LongInt(BigEndian32(Data, Offset));
    Inc(Offset, 4);
  end;
  HaveFirstFlags := (Flags and TrunFirstSampleFlags) <> 0;
  FirstFlags := 0;
  if HaveFirstFlags then
  begin
    FirstFlags := BigEndian32(Data, Offset);
    Inc(Offset, 4);
  end;
  FieldBytes := 0;
  if (Flags and TrunDuration) <> 0 then Inc(FieldBytes, 4);
  if (Flags and TrunSize) <> 0 then Inc(FieldBytes, 4);
  if (Flags and TrunFlags) <> 0 then Inc(FieldBytes, 4);
  if (Flags and TrunCompositionOffset) <> 0 then Inc(FieldBytes, 4);
  if (Count > MaximumRunSamples) or (Count * FieldBytes > Box.Finish - Offset) then
    MediaFail('trun sample count does not fit');
  if (FieldBytes = 0) and (Count * Defaults.Size > StreamSize) then
    MediaFail('trun runs past the file');
  for Index := 0 to Count - 1 do
  begin
    Sample := Default(TMp4Sample);
    Sample.Duration := Defaults.Duration;
    Sample.Size := Defaults.Size;
    SampleFlags := Defaults.Flags;
    if (Flags and TrunDuration) <> 0 then
    begin
      Sample.Duration := BigEndian32(Data, Offset);
      Inc(Offset, 4);
    end;
    if (Flags and TrunSize) <> 0 then
    begin
      Sample.Size := BigEndian32(Data, Offset);
      Inc(Offset, 4);
    end;
    if (Flags and TrunFlags) <> 0 then
    begin
      SampleFlags := BigEndian32(Data, Offset);
      Inc(Offset, 4);
    end;
    if (Index = 0) and HaveFirstFlags then
      SampleFlags := FirstFlags;
    if (Flags and TrunCompositionOffset) <> 0 then
    begin
      Sample.CompositionOffset := LongInt(BigEndian32(Data, Offset));
      Inc(Offset, 4);
    end;
    Sample.Key := (SampleFlags and SampleNonSync) = 0;
    Sample.Offset := Position;
    Sample.DecodeTime := DecodeTime;
    Inc(Position, Sample.Size);
    Inc(DecodeTime, Sample.Duration);
    State.Add(Sample);
  end;
end;

procedure ReadTrackFragment(const Data: TBytes; const Traf: TMp4Box; MoofStart: Int64; var NextBase: Int64;
  States: TObjectList; StreamSize: Int64);
var
  Offset: Integer;
  Box, Header: TMp4Box;
  Flags: LongWord;
  Field: Integer;
  State: TMp4TrackState;
  Defaults: TFragmentDefaults;
  Base, Position, DecodeTime: Int64;
begin
  if not FindChild(Data, Traf.ContentStart, Traf.Finish, 'tfhd', Header) then
    MediaFail('track fragment without tfhd');
  if Header.Finish - Header.ContentStart < 8 then
    MediaFail('tfhd too short');
  Flags := BigEndian32(Data, Header.ContentStart) and $FFFFFF;
  State := StateOfTrack(States, BigEndian32(Data, Header.ContentStart + 4));
  if State = nil then
    Exit;
  Defaults.Duration := State.DefaultDuration;
  Defaults.Size := State.DefaultSize;
  Defaults.Flags := State.DefaultFlags;
  Field := Header.ContentStart + 8;
  if (Flags and TfhdBaseDataOffset) <> 0 then
  begin
    Base := Int64(BigEndian64(Data, Field));
    Inc(Field, 8);
  end
  else if (Flags and TfhdDefaultBaseIsMoof) <> 0 then
    Base := MoofStart
  else
    Base := NextBase;
  if (Flags and TfhdDescription) <> 0 then
    Inc(Field, 4);
  if (Flags and TfhdDefaultDuration) <> 0 then
  begin
    Defaults.Duration := BigEndian32(Data, Field);
    Inc(Field, 4);
  end;
  if (Flags and TfhdDefaultSize) <> 0 then
  begin
    Defaults.Size := BigEndian32(Data, Field);
    Inc(Field, 4);
  end;
  if (Flags and TfhdDefaultFlags) <> 0 then
    Defaults.Flags := BigEndian32(Data, Field);
  DecodeTime := State.NextDecodeTime;
  if FindChild(Data, Traf.ContentStart, Traf.Finish, 'tfdt', Box) then
  begin
    if Data[Box.ContentStart] = 1 then
      DecodeTime := Int64(BigEndian64(Data, Box.ContentStart + 4))
    else
      DecodeTime := BigEndian32(Data, Box.ContentStart + 4);
  end;
  Position := Base;
  Offset := Traf.ContentStart;
  while NextBox(Data, Offset, Traf.Finish, Box) do
    if Box.Kind = 'trun' then
      ReadRun(Data, Box, State, Defaults, Base, Position, DecodeTime, StreamSize);
  State.NextDecodeTime := DecodeTime;
  NextBase := Position;
end;

procedure ReadMovieFragment(const Data: TBytes; MoofStart: Int64; States: TObjectList; StreamSize: Int64);
var
  Offset: Integer;
  Box: TMp4Box;
  NextBase: Int64;
begin
  NextBase := MoofStart;
  Offset := 0;
  while NextBox(Data, Offset, Length(Data), Box) do
  begin
    if Box.Kind = 'moof' then
    begin
      Offset := Box.ContentStart;
      Continue;
    end;
    if Box.Kind = 'traf' then
      ReadTrackFragment(Data, Box, MoofStart, NextBase, States, StreamSize);
  end;
end;

end.
