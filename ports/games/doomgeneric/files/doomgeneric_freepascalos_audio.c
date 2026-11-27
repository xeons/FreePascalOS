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
 * Doom's audio output: a stream of /dev/audio (every open of the device
 * is a stream of its own, which the kernel mixes with the others' and
 * converts to the hardware's rate) at snd_samplerate, 16-bit stereo.
 *
 * Nothing runs on its own: audio_output_update is called about once a
 * tic (the sound and music modules' Update and Poll) and whenever Doom
 * waits (DG_SleepMs, so screen wipes and the menu keep it fed). It asks
 * the kernel how much is still queued and tops the stream up to
 * OUTPUT_LATENCY_MS: the effects' and the music's next frames added
 * together, clipped to 16 bits, written. A write never waits, a new
 * effect is heard within that time, and the music, whose clock is the
 * frames it has made, plays on without a gap as long as Doom gets to
 * run once in that time.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <freepascalos/syscall.h>

#include "doomtype.h"
#include "i_sound.h"

#include "doomgeneric_freepascalos_audio.h"

/* Audio output requests (CallControlHandle on /dev/audio,
   shared/Abi.SystemCalls.inc), for a sysroot whose header predates them. */
#ifndef FPOS_CONTROL_AUDIO_SET_FORMAT
#define FPOS_CONTROL_AUDIO_SET_FORMAT 101
#endif
#ifndef FPOS_CONTROL_AUDIO_GET_QUEUED
#define FPOS_CONTROL_AUDIO_GET_QUEUED 107
#endif
#ifndef FPOS_AUDIO_SAMPLE_SIGNED16
#define FPOS_AUDIO_SAMPLE_SIGNED16 2
#endif

#define AUDIO_DEVICE_PATH "/dev/audio"
#define LOWEST_OUTPUT_RATE 8000
#define HIGHEST_OUTPUT_RATE 48000
#define OUTPUT_LATENCY_MS 85
#define LARGEST_MIX_FRAMES (HIGHEST_OUTPUT_RATE * OUTPUT_LATENCY_MS / 1000)

static int audio_stream = -1;
static uint32_t output_rate;
static audio_source_mixer_t source_mixers[AUDIO_SOURCE_COUNT];
static int32_t mix_buffer[LARGEST_MIX_FRAMES * AUDIO_OUTPUT_CHANNELS];
static int16_t output_buffer[LARGEST_MIX_FRAMES * AUDIO_OUTPUT_CHANNELS];

static long control_audio(long request, long argument)
{
	return fpos_syscall3(FPOS_CALL_CONTROL_HANDLE, audio_stream, request, argument);
}

static void close_stream(void)
{
	if (audio_stream >= 0)
		close(audio_stream);
	audio_stream = -1;
}

static int open_stream(void)
{
	uint32_t rate = (uint32_t)snd_samplerate;
	if (rate < LOWEST_OUTPUT_RATE)
		rate = LOWEST_OUTPUT_RATE;
	if (rate > HIGHEST_OUTPUT_RATE)
		rate = HIGHEST_OUTPUT_RATE;
	audio_stream = open(AUDIO_DEVICE_PATH, O_WRONLY);
	if (audio_stream < 0) {
		fprintf(stderr, "doom: no audio output (%s); Doom plays silently\n", AUDIO_DEVICE_PATH);
		return 0;
	}
	if (control_audio(FPOS_CONTROL_AUDIO_SET_FORMAT,
			  (long)rate << 16 | AUDIO_OUTPUT_CHANNELS << 8 | FPOS_AUDIO_SAMPLE_SIGNED16) < 0) {
		fprintf(stderr, "doom: the audio output takes no %u Hz stereo stream; Doom plays silently\n",
			(unsigned)rate);
		close_stream();
		return 0;
	}
	output_rate = rate;
	return 1;
}

static int any_source_attached(void)
{
	int source;
	for (source = 0; source < AUDIO_SOURCE_COUNT; source++)
		if (source_mixers[source])
			return 1;
	return 0;
}

int audio_output_attach(enum audio_source source, audio_source_mixer_t mixer)
{
	if (audio_stream < 0 && !open_stream())
		return 0;
	source_mixers[source] = mixer;
	return 1;
}

void audio_output_detach(enum audio_source source)
{
	source_mixers[source] = NULL;
	if (!any_source_attached())
		close_stream();
}

uint32_t audio_output_rate(void)
{
	return output_rate;
}

/* A failed write ends the stream; the sources stay attached and are
   simply not asked for frames any more. */
static void mix_and_write(uint32_t frames)
{
	uint32_t index;
	int source;
	memset(mix_buffer, 0, (size_t)frames * AUDIO_OUTPUT_CHANNELS * sizeof(*mix_buffer));
	for (source = 0; source < AUDIO_SOURCE_COUNT; source++)
		if (source_mixers[source])
			source_mixers[source](mix_buffer, frames);
	for (index = 0; index < frames * AUDIO_OUTPUT_CHANNELS; index++) {
		int32_t sample = mix_buffer[index];
		if (sample > INT16_MAX)
			sample = INT16_MAX;
		else if (sample < INT16_MIN)
			sample = INT16_MIN;
		output_buffer[index] = (int16_t)sample;
	}
	if (write(audio_stream, output_buffer, (size_t)frames * AUDIO_OUTPUT_CHANNELS * sizeof(*output_buffer)) < 0) {
		fprintf(stderr, "doom: the audio stream failed; going on without sound\n");
		close_stream();
	}
}

void audio_output_update(void)
{
	long queued;
	uint32_t wanted_frames, queued_frames;
	if (audio_stream < 0)
		return;
	queued = control_audio(FPOS_CONTROL_AUDIO_GET_QUEUED, 0);
	if (queued < 0) {
		close_stream();
		return;
	}
	wanted_frames = output_rate * OUTPUT_LATENCY_MS / 1000;
	queued_frames = (uint32_t)(queued / (AUDIO_OUTPUT_CHANNELS * (long)sizeof(int16_t)));
	if (queued_frames < wanted_frames)
		mix_and_write(wanted_frames - queued_frames);
}
