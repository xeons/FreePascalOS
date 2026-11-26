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
  The audio decoders libmedia has, by codec: CreateAudioDecoder makes
  and configures the one for a track.
}
unit Media.AudioCodecs;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Packets,
  Media.AudioDecoders;

{ The decoder class for Codec, or nil if libmedia has none. }
function AudioDecoderClassOf(Codec: TCodecId): TAudioDecoderClass;
{ A decoder configured for Track; raises EMediaUnsupported for a codec
  without a decoder and EMediaError for a broken setup. }
function CreateAudioDecoder(Track: TMediaTrack): TAudioDecoder;

implementation

uses
  Media.Errors,
  Media.Pcm,
  Media.Flac,
  Media.Vorbis,
  Media.Opus,
  Media.Mp3;

function AudioDecoderClassOf(Codec: TCodecId): TAudioDecoderClass;
begin
  case Codec of
    codecPcm: Result := TPcmDecoder;
    codecFlac: Result := TFlacDecoder;
    codecVorbis: Result := TVorbisDecoder;
    codecOpus: Result := TOpusDecoder;
    codecMp3: Result := TMp3Decoder;
  else
    Result := nil;
  end;
end;

function CreateAudioDecoder(Track: TMediaTrack): TAudioDecoder;
var
  DecoderClass: TAudioDecoderClass;
begin
  DecoderClass := AudioDecoderClassOf(Track.Codec);
  if DecoderClass = nil then
    MediaFailUnsupported('no decoder for ' + CodecIdName(Track.Codec) + ' (' + Track.CodecName + ')');
  Result := DecoderClass.Create;
  try
    Result.Configure(Track);
  except
    Result.Free;
    raise;
  end;
end;

end.
