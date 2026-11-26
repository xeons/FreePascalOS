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
  mediaplay --info: what a media file holds (its container, length and
  tracks), one line per track.
}
unit MediaPlay.Info;

{$mode objfpc}
{$H+}

interface

uses
  Media.Demuxers;

function DurationText(Microseconds: Int64): string;
procedure PrintMediaInfo(const Path: string; Demuxer: TMediaDemuxer);

implementation

uses
  SysUtils,
  Media.Packets,
  Media.AudioCodecs,
  Media.VideoDecoders;

function DurationText(Microseconds: Int64): string;
var
  Seconds: Int64;
begin
  if Microseconds < 0 then
    Exit('unknown');
  Seconds := Microseconds div 1000000;
  Result := Format('%d:%.2d:%.2d.%.3d', [Seconds div 3600, (Seconds div 60) mod 60, Seconds mod 60,
    (Microseconds mod 1000000) div 1000]);
end;

function DecodableText(Track: TMediaTrack): string;
begin
  case Track.Kind of
    mkAudio:
      if AudioDecoderClassOf(Track.Codec) <> nil then
        Exit('');
    mkVideo:
      if VideoDecoderRegistered(Track.Codec) then
        Exit('');
  end;
  Result := ' (not decoded)';
end;

procedure PrintMediaInfo(const Path: string; Demuxer: TMediaDemuxer);
var
  Index: Integer;
  Track: TMediaTrack;
  Line: string;
begin
  WriteLn(Path, ': ', Demuxer.FormatName, ', ', DurationText(Demuxer.Duration), ', ', Demuxer.TrackCount, ' track(s)');
  for Index := 0 to Demuxer.TrackCount - 1 do
  begin
    Track := Demuxer.Tracks[Index];
    Line := Format('  track %d: %s %s', [Index, MediaKindName(Track.Kind), CodecIdName(Track.Codec)]);
    if Track.CodecName <> '' then
      Line := Line + ' [' + Track.CodecName + ']';
    case Track.Kind of
      mkAudio:
        begin
          Line := Line + Format(', %d Hz, %d channel(s)', [Track.SampleRate, Track.Channels]);
          if Track.BitsPerSample > 0 then
            Line := Line + Format(', %d bits', [Track.BitsPerSample]);
        end;
      mkVideo:
        Line := Line + Format(', %dx%d', [Track.Width, Track.Height]);
    end;
    if Track.Duration >= 0 then
      Line := Line + ', ' + DurationText(Track.ToMicroseconds(Track.Duration));
    if Track.Language <> '' then
      Line := Line + ', ' + Track.Language;
    if Track.Name <> '' then
      Line := Line + ', "' + Track.Name + '"';
    WriteLn(Line, DecodableText(Track));
  end;
end;

end.
