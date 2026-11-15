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
  The contents of libaudio.so: playing sound, the WAV file format and the
  voice engine.

  Compiling this unit compiles every unit of the library. Programs use
  the individual units:

    Audio.Formats    sample kinds and converting samples
    Audio.Device     the audio output device (/dev/audio): format,
                     volume, writing samples, draining
    Audio.Wave       reading and writing PCM WAV files
    Audio.Synthesis  generating tones
    Audio.Filters    state variable and one-pole filters
    Audio.EffectChain  the effect interface and a voice's chain of them
    Audio.Voices     source, submix and mastering voices; buffer queues
    Audio.Engine     the voice graph, processed on a thread of its own
                     or rendered offline
    Audio.Effects.*  built-in effects: Reverb, Echo, Equalizer, Dynamics
                     (volume meter and limiter)
    Audio.Spatial    3D audio: listener, emitters, panning, Doppler
}
unit Audio.Contents;

{$mode objfpc}

interface

uses
  Audio.Formats,
  Audio.Device,
  Audio.Wave,
  Audio.Synthesis,
  Audio.Filters,
  Audio.EffectChain,
  Audio.Voices,
  Audio.Engine,
  Audio.Effects.Dynamics,
  Audio.Effects.Echo,
  Audio.Effects.Equalizer,
  Audio.Effects.Reverb,
  Audio.Spatial;

implementation

end.
