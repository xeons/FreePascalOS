#!/usr/bin/env python3
# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""
Checks the sound QEMU recorded during the tests (its wav audio backend):
the stretches of sound in it must be a 1000 Hz tone of about a second
and then a 440 Hz tone of about half a second.

    check-audio.py <recording.wav>
"""
import struct
import sys

# QEMU leaves the RIFF and data sizes at zero when it is ended by the
# debug exit device, so the 44-byte header is read by hand and the rest
# of the file taken as the samples.
data = open(sys.argv[1], 'rb').read()
if data[0:4] != b'RIFF' or data[8:16] != b'WAVEfmt ' or data[36:40] != b'data':
    sys.exit('not a WAV recording')
channels, rate = struct.unpack('<HI', data[22:28])
frames = data[44:len(data) - (len(data) - 44) % 2]
samples = struct.unpack('<%dh' % (len(frames) // 2), frames)[::channels]

# Stretches of sound: 50 ms windows that are loud, each with its
# frequency (from the zero crossings); neighbouring windows of about the
# same frequency make one tone.
window = rate // 20
found = []
for start in range(0, len(samples) - window + 1, window):
    part = samples[start:start + window]
    if max(abs(value) for value in part) < 2000:
        continue
    crossings = sum(1 for a, b in zip(part, part[1:]) if a < 0 <= b)
    hertz = crossings * rate / window
    if found and abs(found[-1][2] / found[-1][1] - hertz) < hertz * 0.1:
        found[-1][1] += 1
        found[-1][2] += hertz
    else:
        found.append([start, 1, hertz])
found = [(total / count, count * window / rate) for start, count, total in found
         if count > 1]
print('sound recorded: ' + ', '.join('%.0f Hz for %.2f s' % item for item in found))
expected = [(1000, 1.0), (440, 0.5)]
if len(found) != len(expected):
    sys.exit('expected %d tones' % len(expected))
for (hertz, seconds), (wanted_hertz, wanted_seconds) in zip(found, expected):
    if abs(hertz - wanted_hertz) > wanted_hertz * 0.02 or abs(seconds - wanted_seconds) > 0.15:
        sys.exit('expected %d Hz for %.1f s' % (wanted_hertz, wanted_seconds))
