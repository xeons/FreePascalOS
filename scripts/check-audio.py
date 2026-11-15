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
Checks the sound QEMU recorded during the tests (its wav audio backend).

The recording must hold the tones of EXPECTED in order: stretches like
"600+1500:1.0" (tones together, and how many seconds), separated by
commas. Without EXPECTED, what coretest plays on the HD Audio output:
1000 Hz for a second, 440 Hz for half a second (a WAV file), 600 and
1500 Hz together for a second (two programs mixed), then 800, 2000 and
300 Hz for half a second each (played at other rates, sample formats and
channel counts), then 1200 Hz for half a second from the voice engine
(voicetest play), then 900 Hz for a second (recorded meanwhile from the
monitor input).

Each 50 ms window is measured at the expected frequencies (Goertzel's
algorithm); the tones clearly there make the window's set, and
neighbouring windows with the same set make one stretch.

    check-audio.py <recording.wav> [EXPECTED]
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

import math

DEFAULT_EXPECTED = '1000:1.0,440:0.5,600+1500:1.0,800:0.5,2000:0.5,300:0.5,1200:0.5,900:1.0'


def parse_expected(text):
    stretches = []
    for part in text.split(','):
        tones, seconds = part.split(':')
        stretches.append((sorted(int(hertz) for hertz in tones.split('+')), float(seconds)))
    return stretches


expected = parse_expected(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_EXPECTED)
CANDIDATES = sorted({hertz for tones, _ in expected for hertz in tones})


def amplitude(part, hertz):
    coefficient = 2 * math.cos(2 * math.pi * hertz / rate)
    previous = before = 0.0
    for value in part:
        previous, before = value + coefficient * previous - before, previous
    power = previous * previous + before * before - coefficient * previous * before
    return 2 * math.sqrt(max(power, 0)) / len(part)


window = rate // 20
stretches = []
for start in range(0, len(samples) - window + 1, window):
    part = samples[start:start + window]
    levels = {hertz: amplitude(part, hertz) for hertz in CANDIDATES}
    loudest = max(levels.values())
    tones = frozenset(hertz for hertz, level in levels.items()
                      if level > 1000 and level > loudest * 0.3) if loudest > 1000 else frozenset()
    if stretches and stretches[-1][0] == tones:
        stretches[-1][1] += 1
    else:
        stretches.append([tones, 1])
found = [(sorted(tones), count * window / rate) for tones, count in stretches if tones and count >= 3]
print('sound recorded: ' + ', '.join('+'.join('%d' % hertz for hertz in tones) + ' Hz for %.2f s' % seconds
                                     for tones, seconds in found))
if len(found) != len(expected):
    sys.exit('expected %d stretches of sound' % len(expected))
for (tones, seconds), (wanted_tones, wanted_seconds) in zip(found, expected):
    if tones != wanted_tones or abs(seconds - wanted_seconds) > 0.2:
        sys.exit('expected %s Hz for %.1f s' % ('+'.join(map(str, wanted_tones)), wanted_seconds))
