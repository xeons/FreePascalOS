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
  Opening a media file whatever its container: the first bytes are
  shown to each demuxer (Recognizes) in turn, and the first that knows
  them reads the file. The formats are told apart by their signatures
  (RIFF/WAVE, OggS, the EBML header, an ftyp box, fLaC, ID3 or an MPEG
  audio frame header), never by the file name.
}
unit Media.Containers;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Media.Demuxers;

{ The demuxer class for a file starting with Head, or nil. }
function FindDemuxerClass(const Head: TBytes): TMediaDemuxerClass;
{ A demuxer for Stream, opened (its headers read); raises EMediaError
  (EMediaUnsupported for an unknown format). The demuxer owns Stream
  when OwnsStream is set, even when this fails (it is freed then). }
function OpenMediaStream(Stream: TStream; OwnsStream: Boolean = True): TMediaDemuxer;
function OpenMediaFile(const Path: string): TMediaDemuxer;

implementation

uses
  Media.Errors,
  Media.Wav,
  Media.FlacFile,
  Media.Ogg,
  Media.Matroska,
  Media.Mp4,
  Media.Mp3File;

function FindDemuxerClass(const Head: TBytes): TMediaDemuxerClass;
const
  { The order matters only for MP3, whose frame sync is the weakest
    signature: it goes last. }
  Candidates: array[0..5] of TMediaDemuxerClass = (TWavDemuxer, TFlacDemuxer, TOggDemuxer, TMatroskaDemuxer,
    TMp4Demuxer, TMp3Demuxer);
var
  Candidate: TMediaDemuxerClass;
begin
  Result := nil;
  for Candidate in Candidates do
    if Candidate.Recognizes(Head) then
      Exit(Candidate);
end;

function OpenMediaStream(Stream: TStream; OwnsStream: Boolean): TMediaDemuxer;
var
  Head: TBytes;
  Count: Integer;
  DemuxerClass: TMediaDemuxerClass;
begin
  Result := nil;
  try
    Head := nil;
    SetLength(Head, ProbeSize);
    Stream.Position := 0;
    Count := Stream.Read(Head[0], ProbeSize);
    SetLength(Head, Count);
    Stream.Position := 0;
    DemuxerClass := FindDemuxerClass(Head);
    if DemuxerClass = nil then
      MediaFailUnsupported('not a media file this system reads');
  except
    if OwnsStream then
      Stream.Free;
    raise;
  end;
  Result := DemuxerClass.Create(Stream, OwnsStream);
  try
    Result.Open;
  except
    Result.Free;
    raise;
  end;
end;

function OpenMediaFile(const Path: string): TMediaDemuxer;
begin
  Result := OpenMediaStream(TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite), True);
end;

end.
