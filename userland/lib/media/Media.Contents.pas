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
  The contents of libmedia.so: the frame and packet records, the
  containers (WAV, FLAC, Ogg, Matroska/WebM, MP4, MP3), the audio
  decoders (PCM, FLAC, Vorbis, Opus, MP3), the video decoder registry,
  colour conversion, resampling and channel mixing. Compiling this unit
  compiles all of them.
}
unit Media.Contents;

{$mode objfpc}

interface

uses
  Media.Errors,
  Media.Frames,
  Media.ColorConversion,
  Media.Packets,
  Media.ByteReaders,
  Media.Demuxers,
  Media.AudioDecoders,
  Media.VideoDecoders,
  Media.Wav,
  Media.FlacFile,
  Media.Ogg,
  Media.Matroska,
  Media.Mp4,
  Media.Ivf,
  Media.ObuStream,
  Media.Mp3File,
  Media.Containers,
  Media.Pcm,
  Media.Flac,
  Media.Vorbis,
  Media.Opus,
  Media.Mp3,
  Media.AudioCodecs,
  Media.Resampler,
  Media.ChannelMixer,
  Media.AudioConversion;

implementation

end.
