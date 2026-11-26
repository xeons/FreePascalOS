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
  Compressed media: tracks and packets, what a container (demuxer) gives
  and a decoder takes.

  A track says what codec its packets are in and carries the codec's
  setup in a container-independent form (Headers):
    Vorbis   the three header packets (identification, comment, setup)
    Opus     the OpusHead packet (RFC 7845 layout, little-endian; an MP4
             dOps box is turned into it)
    FLAC     the 34-byte STREAMINFO block body
    VP8      nothing
    VP9      the vpcC box body (version and flags first), when there is one
    AV1      the av1C box body, when there is one
    PCM      nothing (BitsPerSample, PcmFloat, PcmBigEndian say it all)
    MP3      nothing
  Times are counted in the track's TimeBase (seconds = Time *
  Numerator / Denominator).
}
unit Media.Packets;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  { A time that is not known. }
  NoTimestamp = Low(Int64);

type
  TMediaKind = (mkUnknown, mkAudio, mkVideo, mkSubtitle);

  TCodecId = (
    codecUnknown,
    { Integer PCM (8-bit unsigned, else signed) or float, BitsPerSample wide. }
    codecPcm,
    codecVorbis,
    codecOpus,
    codecFlac,
    codecMp3,
    codecVp8,
    codecVp9,
    codecAv1,
    { Recognised so a file can say what it holds; not decoded. }
    codecAac,
    codecH264,
    codecHevc,
    codecTheora);

  TTimeBase = record
    Numerator, Denominator: Int64;
  end;

  THeaderPackets = array of TBytes;

  TMediaTrack = class
  public
    { The position in the demuxer's track list. }
    Index: Integer;
    { The container's own number for it (Matroska TrackNumber, MP4
      track_ID, Ogg serial number). }
    ContainerId: Int64;
    Kind: TMediaKind;
    Codec: TCodecId;
    { The container's name for the codec (Matroska CodecID, MP4 sample
      entry four-character code), for messages. }
    CodecName: string;
    Headers: THeaderPackets;
    TimeBase: TTimeBase;
    { In TimeBase units; -1 if not known. }
    Duration: Int64;
    { Audio. }
    SampleRate: Integer;
    Channels: Integer;
    BitsPerSample: Integer;
    PcmFloat: Boolean;
    PcmBigEndian: Boolean;
    { Samples (at the decoder's output rate) the decoder drops at the
      start (Opus pre-skip, encoder delay). }
    CodecDelay: Integer;
    { Microseconds of decoding to do before a seek target (Opus: 80 ms). }
    SeekPreRoll: Int64;
    { Video. }
    Width, Height: Integer;
    DisplayWidth, DisplayHeight: Integer;
    { Frames per second as a fraction; 0/0 if not known. }
    FrameRateNumerator, FrameRateDenominator: Int64;
    Language: string;
    Name: string;
    DefaultTrack: Boolean;
    constructor Create;
    { Seconds * 1 000 000 of a time in TimeBase units. }
    function ToMicroseconds(Time: Int64): Int64;
    function FromMicroseconds(Microseconds: Int64): Int64;
    procedure AddHeader(const Header: TBytes);
  end;

  TMediaPacket = record
    TrackIndex: Integer;
    Data: TBytes;
    { In the track's TimeBase; NoTimestamp if not known. }
    PresentationTime: Int64;
    DecodeTime: Int64;
    Duration: Int64;
    KeyFrame: Boolean;
    { Samples (at the decoder's output rate) to drop from the start and
      the end of what this packet decodes to: Ogg's granule positions,
      Matroska's DiscardPadding. }
    TrimStart: Integer;
    TrimEnd: Integer;
  end;

function MakeTimeBase(Numerator, Denominator: Int64): TTimeBase;
{ Value * Multiplier / Divisor without overflowing for media sizes
  (rounded down; Divisor > 0). }
function ScaleTime(Value, Multiplier, Divisor: Int64): Int64;
{ An empty packet of TrackIndex with unknown times. }
function NewPacket(TrackIndex: Integer): TMediaPacket;
function CodecIdName(Codec: TCodecId): string;
function MediaKindName(Kind: TMediaKind): string;

implementation

function MakeTimeBase(Numerator, Denominator: Int64): TTimeBase;
begin
  Result.Numerator := Numerator;
  Result.Denominator := Denominator;
end;

function ScaleTime(Value, Multiplier, Divisor: Int64): Int64;
var
  Whole, Remainder: Int64;
begin
  if Value = NoTimestamp then
    Exit(NoTimestamp);
  if Divisor <= 0 then
    Exit(0);
  { Splitting Value keeps Value * Multiplier in range for times up to
    years at nanosecond bases. }
  Whole := Value div Divisor;
  Remainder := Value mod Divisor;
  Result := Whole * Multiplier + (Remainder * Multiplier) div Divisor;
  if (Remainder < 0) and ((Remainder * Multiplier) mod Divisor <> 0) then
    Dec(Result);
end;

function NewPacket(TrackIndex: Integer): TMediaPacket;
begin
  Result := Default(TMediaPacket);
  Result.TrackIndex := TrackIndex;
  Result.Data := nil;
  Result.PresentationTime := NoTimestamp;
  Result.DecodeTime := NoTimestamp;
  Result.Duration := 0;
end;

constructor TMediaTrack.Create;
begin
  inherited Create;
  TimeBase := MakeTimeBase(1, 1000);
  Duration := -1;
  DefaultTrack := True;
end;

function TMediaTrack.ToMicroseconds(Time: Int64): Int64;
begin
  if Time = NoTimestamp then
    Exit(NoTimestamp);
  Result := ScaleTime(Time, TimeBase.Numerator * 1000000, TimeBase.Denominator);
end;

function TMediaTrack.FromMicroseconds(Microseconds: Int64): Int64;
begin
  if Microseconds = NoTimestamp then
    Exit(NoTimestamp);
  Result := ScaleTime(Microseconds, TimeBase.Denominator, TimeBase.Numerator * 1000000);
end;

procedure TMediaTrack.AddHeader(const Header: TBytes);
begin
  SetLength(Headers, Length(Headers) + 1);
  Headers[High(Headers)] := Header;
end;

function CodecIdName(Codec: TCodecId): string;
begin
  case Codec of
    codecPcm: Result := 'pcm';
    codecVorbis: Result := 'vorbis';
    codecOpus: Result := 'opus';
    codecFlac: Result := 'flac';
    codecMp3: Result := 'mp3';
    codecVp8: Result := 'vp8';
    codecVp9: Result := 'vp9';
    codecAv1: Result := 'av1';
    codecAac: Result := 'aac';
    codecH264: Result := 'h264';
    codecHevc: Result := 'hevc';
    codecTheora: Result := 'theora';
  else
    Result := 'unknown';
  end;
end;

function MediaKindName(Kind: TMediaKind): string;
begin
  case Kind of
    mkAudio: Result := 'audio';
    mkVideo: Result := 'video';
    mkSubtitle: Result := 'subtitle';
  else
    Result := 'unknown';
  end;
end;

end.
