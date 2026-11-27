/*
 * FreePascalOS
 * Copyright (C) 2026 Brandon Scott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * Doom's audio output on FreePascalOS: one stream of /dev/audio (16-bit
 * stereo) that the sound effects and the music are mixed into. Each is a
 * source: a function that adds its next frames to the mix. The stream
 * is open while a source is attached.
 */

#ifndef DOOMGENERIC_FREEPASCALOS_AUDIO_H
#define DOOMGENERIC_FREEPASCALOS_AUDIO_H

#include <stdint.h>

#define AUDIO_OUTPUT_CHANNELS 2

enum audio_source {
	AUDIO_SOURCE_EFFECTS,
	AUDIO_SOURCE_MUSIC,
	AUDIO_SOURCE_COUNT
};

/* Adds Frames stereo frames (left, right; 16-bit range, unclipped) to
   Mix. */
typedef void (*audio_source_mixer_t)(int32_t *mix, uint32_t frames);

/* Attaches Mixer as the source, opening the stream if it is the first;
   0 when there is no audio output. */
int audio_output_attach(enum audio_source source, audio_source_mixer_t mixer);

/* Detaches the source; the last one closes the stream. */
void audio_output_detach(enum audio_source source);

/* The stream's frame rate (valid while a source is attached). */
uint32_t audio_output_rate(void);

/* Tops the stream up to its latency with the sources' next frames, so a
   write never waits. Cheap when it is full: called every tic and while
   Doom waits. */
void audio_output_update(void);

#endif
