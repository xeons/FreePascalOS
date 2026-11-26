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
  The demuxer: what every container reader is.

  A demuxer reads a container from a stream (a file, or memory): Open
  reads the headers and makes the track list; ReadPacket then gives the
  packets of all tracks in file order until the end; SeekTo moves so that
  the next packets start at or before a time (for video, at a key frame
  at or before it), for every track.

  Errors in the file raise EMediaError (Media.Errors). The demuxer owns
  its tracks and, when told to, the stream.
}
unit Media.Demuxers;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Contnrs,
  Media.Packets;

type
  TMediaDemuxer = class
  private
    FTracks: TObjectList;
    FOwnsStream: Boolean;
    function GetTrack(Index: Integer): TMediaTrack;
    function GetTrackCount: Integer;
  protected
    FStream: TStream;
    { The whole presentation in microseconds; -1 if not known. }
    FDuration: Int64;
    function AddTrack: TMediaTrack;
  public
    constructor Create(Stream: TStream; OwnsStream: Boolean = False); virtual;
    destructor Destroy; override;
    { Whether Head (the first bytes of a file, up to ProbeSize) looks like
      this container. }
    class function Recognizes(const Head: TBytes): Boolean; virtual;
    { Reads the headers; raises EMediaError if the stream is not this
      container or is broken. }
    procedure Open; virtual; abstract;
    { The next packet; False at the end. }
    function ReadPacket(out Packet: TMediaPacket): Boolean; virtual; abstract;
    { Moves to Microseconds (from the start of the presentation); False if
      the container cannot seek (the position is then unchanged). }
    function SeekTo(Microseconds: Int64): Boolean; virtual;
    { A short name for the format ('wav', 'ogg', 'matroska', 'webm',
      'mp4', 'flac', 'mp3'). }
    function FormatName: string; virtual; abstract;
    { The first track of Kind, or nil. }
    function FirstTrackOf(Kind: TMediaKind): TMediaTrack;
    property Tracks[Index: Integer]: TMediaTrack read GetTrack;
    property TrackCount: Integer read GetTrackCount;
    property Duration: Int64 read FDuration;
    property Stream: TStream read FStream;
  end;

  TMediaDemuxerClass = class of TMediaDemuxer;

const
  { How much of a file the containers' Recognizes are shown. }
  ProbeSize = 65536;

implementation

constructor TMediaDemuxer.Create(Stream: TStream; OwnsStream: Boolean);
begin
  inherited Create;
  FStream := Stream;
  FOwnsStream := OwnsStream;
  FTracks := TObjectList.Create(True);
  FDuration := -1;
end;

destructor TMediaDemuxer.Destroy;
begin
  FTracks.Free;
  if FOwnsStream then
    FStream.Free;
  inherited Destroy;
end;

class function TMediaDemuxer.Recognizes(const Head: TBytes): Boolean;
begin
  Result := False;
end;

function TMediaDemuxer.GetTrack(Index: Integer): TMediaTrack;
begin
  Result := TMediaTrack(FTracks[Index]);
end;

function TMediaDemuxer.GetTrackCount: Integer;
begin
  Result := FTracks.Count;
end;

function TMediaDemuxer.AddTrack: TMediaTrack;
begin
  Result := TMediaTrack.Create;
  Result.Index := FTracks.Count;
  FTracks.Add(Result);
end;

function TMediaDemuxer.SeekTo(Microseconds: Int64): Boolean;
begin
  Result := False;
end;

function TMediaDemuxer.FirstTrackOf(Kind: TMediaKind): TMediaTrack;
var
  Index: Integer;
begin
  Result := nil;
  for Index := 0 to TrackCount - 1 do
    if Tracks[Index].Kind = Kind then
      Exit(Tracks[Index]);
end;

end.
