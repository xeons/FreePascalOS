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
  Containers and decoders together: the container fixtures (one source
  WAV muxed by ffmpeg into Ogg, WebM/Matroska and MP4 in several codecs)
  decoded through OpenMediaFile and CreateAudioDecoder, as a player
  would. Lossless ones (FLAC, PCM, float) must give exactly the source's
  samples; lossy ones (Vorbis, MP3, Opus) its length to the sample and
  its waveform without any shift (a codec delay, pre-skip, edit list or
  end trim handled wrongly shows as a shifted chirp, which a
  signal-to-noise ratio catches at once).
}
unit MediaTest.EndToEnd;

{$mode objfpc}
{$H+}

interface

procedure RunEndToEndTests(const FixtureRoot: string);

implementation

uses
  SysUtils,
  TestChecks,
  MediaTest.Common,
  Media.Errors;

const
  LosslessFiles: array[0..6] of string = ('flac.mkv', 'flac.mp4', 'flac.oga', 'pcm.mkv', 'pcm.mp4', 'pcm-be.mkv',
    'float.mkv');
  LossyFiles: array[0..8] of string = ('vorbis.ogg', 'vorbis.webm', 'mp3.mkv', 'mp3.mp4', 'opus.ogg', 'opus.webm',
    'opus.mp4', 'opus-fragmented.mp4', 'live.webm');
  { The lossy encodings' least signal-to-noise ratio against the source
    (a shift of one sample costs far more on the chirp). }
  LossyMinimumSnr = 12.0;

function TryDecode(const Path: string; out Decoded: TDecodedAudio): Boolean;
begin
  Result := False;
  if not FileExists(Path) then
  begin
    WriteLn('skip end-to-end: ', ExtractFileName(Path), ' was not made');
    Exit;
  end;
  try
    Decoded := DecodeAudioFile(Path);
    Result := True;
  except
    on Error: EMediaUnsupported do
      WriteLn('skip end-to-end: ', ExtractFileName(Path), ' (', Error.Message, ')');
    on Error: Exception do
      Check(False, Format('end-to-end: %s decodes (%s: %s)', [ExtractFileName(Path), Error.ClassName,
        Error.Message]));
  end;
end;

procedure RunEndToEndTests(const FixtureRoot: string);
var
  Directory, Name: string;
  Source, Decoded: TDecodedAudio;
  Snr: Double;
begin
  Directory := FixturePath(FixtureRoot, 'containers');
  if not FileExists(FixturePath(Directory, 'source.wav')) then
  begin
    WriteLn('skip end-to-end: no container fixtures');
    Exit;
  end;
  Source := DecodeAudioFile(FixturePath(Directory, 'source.wav'));
  for Name in LosslessFiles do
    if TryDecode(FixturePath(Directory, Name), Decoded) then
      Check((Decoded.SampleRate = Source.SampleRate) and (Decoded.Channels = Source.Channels) and
        SameSamples(Decoded.Samples, Source.Samples), Format('end-to-end: %s (%s) gives the source''s samples (%d of %d)',
        [Name, Decoded.FormatName, Length(Decoded.Samples), Length(Source.Samples)]));
  for Name in LossyFiles do
    if TryDecode(FixturePath(Directory, Name), Decoded) then
    begin
      Snr := SignalToNoise(Decoded.Samples, Source.Samples);
      Check((Decoded.SampleRate = Source.SampleRate) and (Decoded.Channels = Source.Channels) and
        (Length(Decoded.Samples) = Length(Source.Samples)) and (Snr >= LossyMinimumSnr),
        Format('end-to-end: %s (%s) has the source''s length and waveform (%d of %d samples, SNR %.1f dB)',
        [Name, Decoded.FormatName, Length(Decoded.Samples), Length(Source.Samples), Snr]));
    end;
end;

end.
