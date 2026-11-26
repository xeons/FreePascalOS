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
  Matroska track entries: the TrackEntry elements read into a track
  (codec, setup, picture or sound attributes) and what reading its
  blocks needs (the number blocks use, header stripping, the default
  duration, the codec delay).

  The codec's setup is turned into the container-independent Headers of
  Media.Packets: A_VORBIS and V_THEORA's CodecPrivate is the three header
  packets Xiph-laced; A_OPUS' is the OpusHead; A_FLAC's is "fLaC" and the
  metadata blocks, of which the STREAMINFO body is kept; V_AV1's is the
  av1C body, V_MPEG4/ISO/AVC's the avcC, A_AAC's the AudioSpecificConfig.

  Of the content encodings only header stripping (compression algorithm
  3: the same leading bytes taken out of every frame) is undone; frames
  compressed with zlib, bzip2 or LZO, or encrypted, are refused.
}
unit Media.Matroska.Tracks;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Packets,
  Media.Ebml,
  Media.Ogg.VorbisModes;

type
  TMatroskaTrack = class
  public
    Number: Int64;
    Track: TMediaTrack;
    { Frames lose these leading bytes in the file (header stripping). }
    StripPrefix: TBytes;
    { In TimestampScale units; 0 if not given. }
    DefaultDuration: Int64;
    DefaultDurationNanoseconds: Int64;
    { The codec delay in TimestampScale units, taken off timestamps. }
    DelayTicks: Int64;
    VorbisModes: TVorbisModes;
    { Frames are compressed or encrypted in a way not undone. }
    Unsupported: Boolean;
    { Samples per second for trims (48000 for Opus). }
    TrimRate: Integer;
  end;

{ Reads the TrackEntry whose data starts at the reader's position and
  ends at EntryEnd into Track (a new track of the demuxer) and Info. }
procedure ReadTrackEntry(Reader: TEbmlReader; EntryEnd: Int64; Info: TMatroskaTrack; TimestampScale: Int64);

implementation

uses
  Media.Errors,
  Media.ByteReaders,
  Media.Ogg.Codecs;

const
  IdTrackNumber = $D7;
  IdTrackType = $83;
  IdFlagDefault = $88;
  IdDefaultDuration = $23E383;
  IdName = $536E;
  IdLanguage = $22B59C;
  IdLanguageBcp47 = $22B59D;
  IdCodecId = $86;
  IdCodecPrivate = $63A2;
  IdCodecDelay = $56AA;
  IdSeekPreRoll = $56BB;
  IdVideo = $E0;
  IdPixelWidth = $B0;
  IdPixelHeight = $BA;
  IdDisplayWidth = $54B0;
  IdDisplayHeight = $54BA;
  IdAudio = $E1;
  IdSamplingFrequency = $B5;
  IdOutputSamplingFrequency = $78B5;
  IdChannels = $9F;
  IdBitDepth = $6264;
  IdContentEncodings = $6D80;
  IdContentEncoding = $6240;
  IdContentEncodingType = $5033;
  IdContentCompression = $5034;
  IdContentEncryption = $5035;
  IdContentCompAlgo = $4254;
  IdContentCompSettings = $4255;

  TrackTypeVideo = 1;
  TrackTypeAudio = 2;
  TrackTypeSubtitle = 17;

type
  TEntryFields = record
    TrackType: Integer;
    CodecId: string;
    CodecPrivate: TBytes;
    CodecDelay, SeekPreRoll: Int64;
    SamplingFrequency, OutputSamplingFrequency: Double;
  end;

function ElementEnd(const Element: TEbmlElement; ParentEnd: Int64): Int64;
begin
  if Element.Size = EbmlUnknownSize then
    MediaFail('unknown size inside a track entry');
  Result := Element.DataStart + Element.Size;
  if Result > ParentEnd then
    MediaFail('element runs past its parent');
end;

procedure ReadVideo(Reader: TEbmlReader; EndAt: Int64; Track: TMediaTrack);
var
  Element: TEbmlElement;
  Last: Int64;
begin
  while (Reader.Position < EndAt) and Reader.ReadElement(Element) do
  begin
    Last := ElementEnd(Element, EndAt);
    case Element.Id of
      IdPixelWidth: Track.Width := Reader.ReadUnsigned(Element.Size);
      IdPixelHeight: Track.Height := Reader.ReadUnsigned(Element.Size);
      IdDisplayWidth: Track.DisplayWidth := Reader.ReadUnsigned(Element.Size);
      IdDisplayHeight: Track.DisplayHeight := Reader.ReadUnsigned(Element.Size);
    end;
    Reader.Position := Last;
  end;
end;

procedure ReadAudio(Reader: TEbmlReader; EndAt: Int64; Track: TMediaTrack; var Fields: TEntryFields);
var
  Element: TEbmlElement;
  Last: Int64;
begin
  while (Reader.Position < EndAt) and Reader.ReadElement(Element) do
  begin
    Last := ElementEnd(Element, EndAt);
    case Element.Id of
      IdSamplingFrequency: Fields.SamplingFrequency := Reader.ReadFloat(Element.Size);
      IdOutputSamplingFrequency: Fields.OutputSamplingFrequency := Reader.ReadFloat(Element.Size);
      IdChannels: Track.Channels := Reader.ReadUnsigned(Element.Size);
      IdBitDepth: Track.BitsPerSample := Reader.ReadUnsigned(Element.Size);
    end;
    Reader.Position := Last;
  end;
end;

procedure ReadCompression(Reader: TEbmlReader; EndAt: Int64; Info: TMatroskaTrack);
var
  Element: TEbmlElement;
  Last: Int64;
  Algorithm: Integer;
  Settings: TBytes;
begin
  Algorithm := 0;
  Settings := nil;
  while (Reader.Position < EndAt) and Reader.ReadElement(Element) do
  begin
    Last := ElementEnd(Element, EndAt);
    case Element.Id of
      IdContentCompAlgo: Algorithm := Reader.ReadUnsigned(Element.Size);
      IdContentCompSettings: Settings := Reader.ReadBytes(Element.Size);
    end;
    Reader.Position := Last;
  end;
  if Algorithm = 3 then
    Info.StripPrefix := Settings
  else
    Info.Unsupported := True;
end;

procedure ReadContentEncodings(Reader: TEbmlReader; EndAt: Int64; Info: TMatroskaTrack);
var
  Element, Child: TEbmlElement;
  Last, ChildEnd: Int64;
begin
  while (Reader.Position < EndAt) and Reader.ReadElement(Element) do
  begin
    Last := ElementEnd(Element, EndAt);
    if Element.Id = IdContentEncoding then
      while (Reader.Position < Last) and Reader.ReadElement(Child) do
      begin
        ChildEnd := ElementEnd(Child, Last);
        case Child.Id of
          IdContentEncodingType:
            if Reader.ReadUnsigned(Child.Size) <> 0 then
              Info.Unsupported := True;
          IdContentCompression: ReadCompression(Reader, ChildEnd, Info);
          IdContentEncryption: Info.Unsupported := True;
        end;
        Reader.Position := ChildEnd;
      end;
    Reader.Position := Last;
  end;
end;

{ The packets of a Xiph-laced CodecPrivate (count less one, the sizes of
  all but the last in 255-byte steps, then the packets). }
procedure AddXiphLacedHeaders(Track: TMediaTrack; const Data: TBytes);
var
  Count, Index, Offset, Total: Integer;
  Sizes: array of Integer;
begin
  if Length(Data) < 1 then
    MediaFail('empty codec setup');
  Count := Data[0] + 1;
  Sizes := nil;
  SetLength(Sizes, Count);
  Offset := 1;
  Total := 0;
  for Index := 0 to Count - 2 do
  begin
    Sizes[Index] := 0;
    repeat
      if Offset >= Length(Data) then
        MediaFail('codec setup cut short');
      Inc(Sizes[Index], Data[Offset]);
      Inc(Offset);
    until Data[Offset - 1] <> 255;
    Inc(Total, Sizes[Index]);
  end;
  Sizes[Count - 1] := Length(Data) - Offset - Total;
  if Sizes[Count - 1] < 0 then
    MediaFail('codec setup cut short');
  for Index := 0 to Count - 1 do
  begin
    Track.AddHeader(SliceBytes(Data, Offset, Sizes[Index]));
    Inc(Offset, Sizes[Index]);
  end;
end;

{ The STREAMINFO body of "fLaC" and metadata blocks. }
function FlacStreamInfo(const Data: TBytes): TBytes;
var
  Offset, BlockSize: Integer;
begin
  Result := nil;
  Offset := 0;
  if (Length(Data) >= 4) and (FourCCAt(Data, 0) = 'fLaC') then
    Offset := 4;
  while Offset + 4 <= Length(Data) do
  begin
    BlockSize := BigEndian24(Data, Offset + 1);
    if (Data[Offset] and $7F) = 0 then
      Exit(SliceBytes(Data, Offset + 4, BlockSize));
    if (Data[Offset] and $80) <> 0 then
      Break;
    Inc(Offset, 4 + BlockSize);
  end;
end;

procedure DescribeCodec(Info: TMatroskaTrack; const Fields: TEntryFields; TimestampScale: Int64);
var
  Track: TMediaTrack;
  Id: string;
  Head: TOpusHead;
  StreamInfo: TStreamInfo;
begin
  Track := Info.Track;
  Id := Fields.CodecId;
  Track.CodecName := Id;
  if Id = 'A_VORBIS' then
  begin
    Track.Codec := codecVorbis;
    AddXiphLacedHeaders(Track, Fields.CodecPrivate);
    if Length(Track.Headers) = 3 then
      Info.VorbisModes := ReadVorbisModes(Track.Headers[0], Track.Headers[2]);
  end
  else if Id = 'A_OPUS' then
  begin
    Track.Codec := codecOpus;
    Track.AddHeader(Fields.CodecPrivate);
    Head := ReadOpusHead(Fields.CodecPrivate);
    if Head.Valid then
      Track.CodecDelay := Head.PreSkip
    else
      Track.CodecDelay := Fields.CodecDelay * 48000 div 1000000000;
    Track.SampleRate := 48000;
  end
  else if Id = 'A_FLAC' then
  begin
    Track.Codec := codecFlac;
    Track.AddHeader(FlacStreamInfo(Fields.CodecPrivate));
    StreamInfo := ReadStreamInfo(Track.Headers[0]);
    if StreamInfo.Valid and (Track.BitsPerSample = 0) then
      Track.BitsPerSample := StreamInfo.BitsPerSample;
  end
  else if Id = 'A_MPEG/L3' then
    Track.Codec := codecMp3
  else if (Id = 'A_PCM/INT/LIT') or (Id = 'A_PCM/INT/BIG') or (Id = 'A_PCM/FLOAT/IEEE') then
  begin
    Track.Codec := codecPcm;
    Track.PcmBigEndian := Id = 'A_PCM/INT/BIG';
    Track.PcmFloat := Id = 'A_PCM/FLOAT/IEEE';
  end
  else if Copy(Id, 1, 5) = 'A_AAC' then
  begin
    Track.Codec := codecAac;
    if Length(Fields.CodecPrivate) > 0 then
      Track.AddHeader(Fields.CodecPrivate);
  end
  else if Id = 'V_VP8' then
    Track.Codec := codecVp8
  else if Id = 'V_VP9' then
    Track.Codec := codecVp9
  else if Id = 'V_AV1' then
  begin
    Track.Codec := codecAv1;
    if Length(Fields.CodecPrivate) > 0 then
      Track.AddHeader(Fields.CodecPrivate);
  end
  else if Id = 'V_MPEG4/ISO/AVC' then
  begin
    Track.Codec := codecH264;
    if Length(Fields.CodecPrivate) > 0 then
      Track.AddHeader(Fields.CodecPrivate);
  end
  else if Id = 'V_MPEGH/ISO/HEVC' then
  begin
    Track.Codec := codecHevc;
    if Length(Fields.CodecPrivate) > 0 then
      Track.AddHeader(Fields.CodecPrivate);
  end
  else if Id = 'V_THEORA' then
  begin
    Track.Codec := codecTheora;
    AddXiphLacedHeaders(Track, Fields.CodecPrivate);
  end
  else
    Track.Codec := codecUnknown;
  if Track.Codec = codecOpus then
    Info.TrimRate := 48000
  else
    Info.TrimRate := Track.SampleRate;
  if Fields.SeekPreRoll > 0 then
    Track.SeekPreRoll := Fields.SeekPreRoll div 1000
  else if Track.Codec = codecOpus then
    Track.SeekPreRoll := 80000;
  { MP3's encoder delay, as FFmpeg writes it: samples the decoder drops
    at the start. (Vorbis' CodecDelay is its first packet, which decodes
    to nothing anyway; Opus' is the pre-skip, above.) }
  if (Track.Codec = codecMp3) and (Fields.CodecDelay > 0) and (Track.SampleRate > 0) then
    Track.CodecDelay := (Fields.CodecDelay * Track.SampleRate + 500000000) div 1000000000;
  { FFmpeg's rounding (to nearest, halves away from zero). }
  Info.DelayTicks := (Fields.CodecDelay + TimestampScale div 2) div TimestampScale;
end;

procedure ReadTrackEntry(Reader: TEbmlReader; EntryEnd: Int64; Info: TMatroskaTrack; TimestampScale: Int64);
var
  Element: TEbmlElement;
  Last: Int64;
  Fields: TEntryFields;
  Track: TMediaTrack;
  Language: string;
begin
  Fields := Default(TEntryFields);
  Track := Info.Track;
  Language := 'eng';
  while (Reader.Position < EntryEnd) and Reader.ReadElement(Element) do
  begin
    Last := ElementEnd(Element, EntryEnd);
    case Element.Id of
      IdTrackNumber: Info.Number := Reader.ReadUnsigned(Element.Size);
      IdTrackType: Fields.TrackType := Reader.ReadUnsigned(Element.Size);
      IdFlagDefault: Track.DefaultTrack := Reader.ReadUnsigned(Element.Size) <> 0;
      IdDefaultDuration: Info.DefaultDurationNanoseconds := Reader.ReadUnsigned(Element.Size);
      IdName: Track.Name := Reader.ReadString(Element.Size);
      IdLanguage: Language := Reader.ReadString(Element.Size);
      IdLanguageBcp47: Language := Reader.ReadString(Element.Size);
      IdCodecId: Fields.CodecId := Reader.ReadString(Element.Size);
      IdCodecPrivate:
        begin
          if Element.Size > 16 * 1024 * 1024 then
            MediaFail('codec setup too large');
          Fields.CodecPrivate := Reader.ReadBytes(Element.Size);
        end;
      IdCodecDelay: Fields.CodecDelay := Reader.ReadUnsigned(Element.Size);
      IdSeekPreRoll: Fields.SeekPreRoll := Reader.ReadUnsigned(Element.Size);
      IdVideo: ReadVideo(Reader, Last, Track);
      IdAudio: ReadAudio(Reader, Last, Track, Fields);
      IdContentEncodings: ReadContentEncodings(Reader, Last, Info);
    end;
    Reader.Position := Last;
  end;
  Track.Language := Language;
  Track.ContainerId := Info.Number;
  case Fields.TrackType of
    TrackTypeVideo: Track.Kind := mkVideo;
    TrackTypeAudio: Track.Kind := mkAudio;
    TrackTypeSubtitle: Track.Kind := mkSubtitle;
  else
    Track.Kind := mkUnknown;
  end;
  if Fields.OutputSamplingFrequency > 0 then
    Track.SampleRate := Round(Fields.OutputSamplingFrequency)
  else if Fields.SamplingFrequency > 0 then
    Track.SampleRate := Round(Fields.SamplingFrequency)
  else if Track.Kind = mkAudio then
    Track.SampleRate := 8000;
  if (Track.Kind = mkAudio) and (Track.Channels = 0) then
    Track.Channels := 1;
  if Track.DisplayWidth = 0 then
    Track.DisplayWidth := Track.Width;
  if Track.DisplayHeight = 0 then
    Track.DisplayHeight := Track.Height;
  if Info.DefaultDurationNanoseconds > 0 then
  begin
    Info.DefaultDuration := (Info.DefaultDurationNanoseconds + TimestampScale div 2) div TimestampScale;
    if Track.Kind = mkVideo then
    begin
      Track.FrameRateNumerator := 1000000000;
      Track.FrameRateDenominator := Info.DefaultDurationNanoseconds;
    end;
  end;
  DescribeCodec(Info, Fields, TimestampScale);
end;

end.
