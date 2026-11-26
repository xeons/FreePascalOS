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
  Where to seek in a Matroska file: an index of cluster positions by
  time, from the Cues (CuePoint: CueTime, CueTrackPositions with
  CueTrack and CueClusterPosition, relative to the segment's data) or,
  for a file without them, from walking the clusters (reading only each
  cluster's Timestamp; a cluster of unknown size is walked element by
  element to find its end).
}
unit Media.Matroska.Cues;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Ebml;

type
  TClusterEntry = record
    Time: Int64;
    Position: Int64;
  end;

  TClusterIndex = array of TClusterEntry;

{ The Cues whose data starts at the reader's position and ends at
  CuesEnd; positions made absolute with SegmentStart. Only the points of
  track TrackNumber are kept (all if it is 0). }
function ReadCues(Reader: TEbmlReader; CuesEnd, SegmentStart, TrackNumber: Int64): TClusterIndex;
{ The clusters from FirstCluster to SegmentEnd, by walking them. }
function WalkClusters(Reader: TEbmlReader; FirstCluster, SegmentEnd: Int64): TClusterIndex;
{ The last entry at or before Time (0 if none is). }
function FindClusterEntry(const Index: TClusterIndex; Time: Int64): Integer;
{ Whether Id is that of a top-level element of a segment. }
function IsTopLevelId(Id: LongWord): Boolean;

const
  IdCluster = $1F43B675;
  IdClusterTimestamp = $E7;

implementation

uses
  Media.Errors;

const
  IdCuePoint = $BB;
  IdCueTime = $B3;
  IdCueTrackPositions = $B7;
  IdCueTrack = $F7;
  IdCueClusterPosition = $F1;
  MaximumEntries = 4 * 1024 * 1024;

function IsTopLevelId(Id: LongWord): Boolean;
begin
  case Id of
    IdCluster, $1C53BB6B, $1254C367, $1941A469, $1043A770, $114D9B74, $1549A966, $1654AE6B, $18538067, $1A45DFA3:
      Result := True;
  else
    Result := False;
  end;
end;

procedure AddEntry(var Index: TClusterIndex; var Count: Integer; Time, Position: Int64);
begin
  if (Count > 0) and (Index[Count - 1].Position = Position) then
    Exit;
  if Count >= MaximumEntries then
    Exit;
  if Count >= Length(Index) then
    SetLength(Index, Count * 2 + 16);
  Index[Count].Time := Time;
  Index[Count].Position := Position;
  Inc(Count);
end;

procedure SortByTime(var Index: TClusterIndex);
var
  Outer, Inner: Integer;
  Entry: TClusterEntry;
begin
  { Cues are almost always in order already: insertion sort. }
  for Outer := 1 to High(Index) do
  begin
    Entry := Index[Outer];
    Inner := Outer - 1;
    while (Inner >= 0) and (Index[Inner].Time > Entry.Time) do
    begin
      Index[Inner + 1] := Index[Inner];
      Dec(Inner);
    end;
    Index[Inner + 1] := Entry;
  end;
end;

function ReadCues(Reader: TEbmlReader; CuesEnd, SegmentStart, TrackNumber: Int64): TClusterIndex;
var
  Point, Child, Field: TEbmlElement;
  PointEnd, ChildEnd, FieldEnd, Time, Track, Position: Int64;
  Count: Integer;
begin
  Result := nil;
  Count := 0;
  while (Reader.Position < CuesEnd) and Reader.ReadElement(Point) do
  begin
    if Point.Size = EbmlUnknownSize then
      MediaFail('cue point of unknown size');
    PointEnd := Point.DataStart + Point.Size;
    if Point.Id = IdCuePoint then
    begin
      Time := -1;
      while (Reader.Position < PointEnd) and Reader.ReadElement(Child) do
      begin
        if Child.Size = EbmlUnknownSize then
          MediaFail('cue of unknown size');
        ChildEnd := Child.DataStart + Child.Size;
        if Child.Id = IdCueTime then
          Time := Reader.ReadUnsigned(Child.Size)
        else if Child.Id = IdCueTrackPositions then
        begin
          Track := 0;
          Position := -1;
          while (Reader.Position < ChildEnd) and Reader.ReadElement(Field) do
          begin
            if Field.Size = EbmlUnknownSize then
              MediaFail('cue of unknown size');
            FieldEnd := Field.DataStart + Field.Size;
            if Field.Id = IdCueTrack then
              Track := Reader.ReadUnsigned(Field.Size)
            else if Field.Id = IdCueClusterPosition then
              Position := Reader.ReadUnsigned(Field.Size);
            Reader.Position := FieldEnd;
          end;
          if (Time >= 0) and (Position >= 0) and ((TrackNumber = 0) or (Track = TrackNumber)) then
            AddEntry(Result, Count, Time, SegmentStart + Position);
        end;
        Reader.Position := ChildEnd;
      end;
    end;
    Reader.Position := PointEnd;
  end;
  SetLength(Result, Count);
  SortByTime(Result);
end;

function WalkClusters(Reader: TEbmlReader; FirstCluster, SegmentEnd: Int64): TClusterIndex;
var
  Element, Child: TEbmlElement;
  Count: Integer;
  Time, ClusterStart: Int64;
  Ended: Boolean;
begin
  Result := nil;
  Count := 0;
  Reader.Position := FirstCluster;
  while (Reader.Position < SegmentEnd) and Reader.ReadElement(Element) do
  begin
    if Element.Id <> IdCluster then
    begin
      if Element.Size = EbmlUnknownSize then
        Break;
      Reader.Position := Element.DataStart + Element.Size;
      Continue;
    end;
    ClusterStart := Element.Start;
    Time := -1;
    Ended := False;
    while not Ended and (Reader.Position < SegmentEnd) and Reader.ReadElement(Child) do
    begin
      if IsTopLevelId(Child.Id) then
      begin
        Reader.Position := Child.Start;
        Ended := True;
        Break;
      end;
      if Child.Size = EbmlUnknownSize then
        MediaFail('cluster element of unknown size');
      if Child.Id = IdClusterTimestamp then
      begin
        Time := Reader.ReadUnsigned(Child.Size);
        if Element.Size <> EbmlUnknownSize then
        begin
          Reader.Position := Element.DataStart + Element.Size;
          Ended := True;
          Break;
        end;
      end;
      Reader.Position := Child.DataStart + Child.Size;
    end;
    if Time >= 0 then
      AddEntry(Result, Count, Time, ClusterStart);
    if not Ended then
      Break;
  end;
  SetLength(Result, Count);
end;

function FindClusterEntry(const Index: TClusterIndex; Time: Int64): Integer;
var
  Low, High, Middle: Integer;
begin
  Result := 0;
  Low := 0;
  High := Length(Index) - 1;
  while Low <= High do
  begin
    Middle := (Low + High) div 2;
    if Index[Middle].Time <= Time then
    begin
      Result := Middle;
      Low := Middle + 1;
    end
    else
      High := Middle - 1;
  end;
end;

end.
