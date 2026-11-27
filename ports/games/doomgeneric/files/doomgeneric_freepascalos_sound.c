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
 * Doom's sound effects on FreePascalOS: a sound module (sound_module_t,
 * i_sound.h) that mixes the playing effects itself and writes them to
 * an audio stream of /dev/audio (every open of the device is a stream
 * of its own, which the kernel mixes with the others' and converts to
 * the hardware's rate).
 *
 * An effect is a DMX lump: 3, 0, the sample rate (16 bits), the length
 * (32 bits), then unsigned 8-bit samples; as DMX did, the first and last
 * 16 bytes of the samples are skipped. Each channel steps through its
 * effect at its rate over the output's (32.32 fixed point, linear
 * interpolation between samples) with a left and a right gain from
 * Doom's volume (0-127) and separation (0 left .. 254 right).
 *
 * Nothing runs on its own: Doom calls Update about once a tic, and it
 * tops the stream up to OUTPUT_LATENCY_MS of mixed sound (asking the
 * kernel how much is still queued), so a write never waits and a new
 * effect is heard within that time. Without an audio output the module
 * does not start, and Doom plays silently.
 *
 * Music is not played: the music module is silent (OPL emulation for
 * Doom's MUS scores is still to come).
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <freepascalos/syscall.h>

#include "doomtype.h"
#include "deh_str.h"
#include "i_sound.h"
#include "m_misc.h"
#include "w_wad.h"
#include "z_zone.h"

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
#define OUTPUT_CHANNELS 2
#define LOWEST_OUTPUT_RATE 8000
#define HIGHEST_OUTPUT_RATE 48000
#define OUTPUT_LATENCY_MS 85
#define LARGEST_MIX_FRAMES (HIGHEST_OUTPUT_RATE * OUTPUT_LATENCY_MS / 1000)

#define MIXER_CHANNEL_COUNT 16
#define DMX_HEADER_SIZE 8
#define DMX_SKIPPED_BYTES 16
#define DMX_SHORTEST_LENGTH 48
#define FULL_GAIN 256

/* The variables m_config.c and i_sound.c bind; this module has no
   libsamplerate. */
int use_libsamplerate = 0;
float libsamplerate_scale = 0.65f;

struct sound_effect {
	const uint8_t *samples;
	uint32_t length;
	uint32_t rate;
};

struct mixer_channel {
	const struct sound_effect *effect;
	uint64_t position; /* in samples, 32.32 fixed point */
	uint64_t step;
	int left_gain;
	int right_gain;
};

static int audio_stream = -1;
static uint32_t output_rate;
static boolean use_sound_prefix;
static struct mixer_channel channels[MIXER_CHANNEL_COUNT];
static int32_t mix_buffer[LARGEST_MIX_FRAMES * OUTPUT_CHANNELS];
static int16_t output_buffer[LARGEST_MIX_FRAMES * OUTPUT_CHANNELS];

static snddevice_t handled_devices[] = {
	SNDDEVICE_SB,
	SNDDEVICE_PAS,
	SNDDEVICE_GUS,
	SNDDEVICE_WAVEBLASTER,
	SNDDEVICE_SOUNDCANVAS,
	SNDDEVICE_AWE32,
};

static long control_audio(long request, long argument)
{
	return fpos_syscall3(FPOS_CALL_CONTROL_HANDLE, audio_stream, request, argument);
}

static void close_audio(void)
{
	if (audio_stream >= 0)
		close(audio_stream);
	audio_stream = -1;
}

/* --- Effects -------------------------------------------------------------- */

static void sound_lump_name(sfxinfo_t *sfx, char *name, size_t capacity)
{
	if (sfx->link)
		sfx = sfx->link;
	if (use_sound_prefix)
		M_snprintf(name, capacity, "ds%s", DEH_String(sfx->name));
	else
		M_StringCopy(name, DEH_String(sfx->name), capacity);
}

/* Reads a DMX lump's samples into Effect; false if it is no DMX sound. */
static boolean read_effect(const uint8_t *data, uint32_t lump_length, struct sound_effect *effect)
{
	uint32_t length;
	uint8_t *samples;
	if (lump_length < DMX_HEADER_SIZE || data[0] != 3 || data[1] != 0)
		return false;
	length = (uint32_t)data[4] | (uint32_t)data[5] << 8 | (uint32_t)data[6] << 16 | (uint32_t)data[7] << 24;
	if (length > lump_length - DMX_HEADER_SIZE || length <= DMX_SHORTEST_LENGTH)
		return false;
	effect->rate = (uint32_t)data[2] | (uint32_t)data[3] << 8;
	if (effect->rate == 0)
		return false;
	length -= 2 * DMX_SKIPPED_BYTES;
	samples = malloc(length);
	if (!samples)
		return false;
	memcpy(samples, data + DMX_HEADER_SIZE + DMX_SKIPPED_BYTES, length);
	effect->samples = samples;
	effect->length = length;
	return true;
}

/* The effect's samples, read from its lump the first time it plays and
   kept (in the C heap: Doom's zone is small, and the lump is released);
   NULL if the lump is no DMX sound. */
static const struct sound_effect *load_effect(sfxinfo_t *sfx)
{
	struct sound_effect *effect = sfx->driver_data;
	if (effect)
		return effect->length ? effect : NULL;
	if (sfx->lumpnum < 0)
		return NULL;
	effect = calloc(1, sizeof(*effect));
	if (!effect)
		return NULL;
	sfx->driver_data = effect;
	if (!read_effect(W_CacheLumpNum(sfx->lumpnum, PU_STATIC), (uint32_t)W_LumpLength((unsigned)sfx->lumpnum),
			 effect))
		effect->length = 0;
	W_ReleaseLumpNum(sfx->lumpnum);
	return effect->length ? effect : NULL;
}

/* --- Mixing ------------------------------------------------------------- */

static void set_channel_gains(struct mixer_channel *channel, int volume, int separation)
{
	if (volume < 0)
		volume = 0;
	if (volume > 127)
		volume = 127;
	if (separation < 0)
		separation = 0;
	if (separation > 254)
		separation = 254;
	/* Full volume in the middle is about half on each side, as with
	   Chocolate Doom's panning; a side alone gets it all. */
	channel->left_gain = (254 - separation) * volume * FULL_GAIN / (254 * 127);
	channel->right_gain = separation * volume * FULL_GAIN / (254 * 127);
}

static void mix_channel(struct mixer_channel *channel, int32_t *output, uint32_t frames)
{
	const struct sound_effect *effect = channel->effect;
	uint64_t end = (uint64_t)effect->length << 32;
	uint32_t frame;
	for (frame = 0; frame < frames && channel->position < end; frame++) {
		uint32_t index = (uint32_t)(channel->position >> 32);
		uint32_t fraction = (uint32_t)(channel->position >> 16) & 0xFFFF;
		int32_t first = (int32_t)effect->samples[index] - 128;
		int32_t second = index + 1 < effect->length ? (int32_t)effect->samples[index + 1] - 128 : first;
		int32_t sample = (first * 256) + (((second - first) * 256 * (int32_t)fraction) >> 16);
		output[frame * OUTPUT_CHANNELS] += sample * channel->left_gain / FULL_GAIN;
		output[frame * OUTPUT_CHANNELS + 1] += sample * channel->right_gain / FULL_GAIN;
		channel->position += channel->step;
	}
	if (channel->position >= end)
		channel->effect = NULL;
}

static void mix_and_write(uint32_t frames)
{
	uint32_t index;
	int channel;
	memset(mix_buffer, 0, (size_t)frames * OUTPUT_CHANNELS * sizeof(*mix_buffer));
	for (channel = 0; channel < MIXER_CHANNEL_COUNT; channel++)
		if (channels[channel].effect)
			mix_channel(&channels[channel], mix_buffer, frames);
	for (index = 0; index < frames * OUTPUT_CHANNELS; index++) {
		int32_t sample = mix_buffer[index];
		if (sample > INT16_MAX)
			sample = INT16_MAX;
		else if (sample < INT16_MIN)
			sample = INT16_MIN;
		output_buffer[index] = (int16_t)sample;
	}
	if (write(audio_stream, output_buffer, (size_t)frames * OUTPUT_CHANNELS * sizeof(*output_buffer)) < 0) {
		fprintf(stderr, "doom: the audio stream failed; going on without sound\n");
		close_audio();
	}
}

/* --- The sound module --------------------------------------------------- */

static boolean sound_initialize(boolean use_sfx_prefix)
{
	long result;
	use_sound_prefix = use_sfx_prefix;
	memset(channels, 0, sizeof(channels));
	output_rate = (uint32_t)snd_samplerate;
	if (output_rate < LOWEST_OUTPUT_RATE)
		output_rate = LOWEST_OUTPUT_RATE;
	if (output_rate > HIGHEST_OUTPUT_RATE)
		output_rate = HIGHEST_OUTPUT_RATE;
	audio_stream = open(AUDIO_DEVICE_PATH, O_WRONLY);
	if (audio_stream < 0) {
		fprintf(stderr, "doom: no audio output (%s); sound effects are off\n", AUDIO_DEVICE_PATH);
		return false;
	}
	result = control_audio(FPOS_CONTROL_AUDIO_SET_FORMAT,
			       (long)output_rate << 16 | OUTPUT_CHANNELS << 8 | FPOS_AUDIO_SAMPLE_SIGNED16);
	if (result < 0) {
		fprintf(stderr, "doom: the audio output takes no %u Hz stereo stream; sound effects are off\n",
			(unsigned)output_rate);
		close_audio();
		return false;
	}
	return true;
}

static void sound_shut_down(void)
{
	close_audio();
}

static int sound_lump_number(sfxinfo_t *sfx)
{
	char name[9];
	sound_lump_name(sfx, name, sizeof(name));
	return W_GetNumForName(name);
}

static void sound_update(void)
{
	long queued;
	uint32_t wanted_frames, queued_frames;
	if (audio_stream < 0)
		return;
	queued = control_audio(FPOS_CONTROL_AUDIO_GET_QUEUED, 0);
	if (queued < 0) {
		close_audio();
		return;
	}
	wanted_frames = output_rate * OUTPUT_LATENCY_MS / 1000;
	queued_frames = (uint32_t)(queued / (OUTPUT_CHANNELS * (long)sizeof(int16_t)));
	if (queued_frames < wanted_frames)
		mix_and_write(wanted_frames - queued_frames);
}

static void sound_update_parameters(int channel, int volume, int separation)
{
	if (channel >= 0 && channel < MIXER_CHANNEL_COUNT)
		set_channel_gains(&channels[channel], volume, separation);
}

static int sound_start(sfxinfo_t *sfx, int channel, int volume, int separation)
{
	const struct sound_effect *effect;
	struct mixer_channel *mixer_channel;
	if (audio_stream < 0 || channel < 0 || channel >= MIXER_CHANNEL_COUNT)
		return -1;
	mixer_channel = &channels[channel];
	mixer_channel->effect = NULL;
	effect = load_effect(sfx);
	if (!effect)
		return -1;
	mixer_channel->position = 0;
	mixer_channel->step = ((uint64_t)effect->rate << 32) / output_rate;
	set_channel_gains(mixer_channel, volume, separation);
	mixer_channel->effect = effect;
	return channel;
}

static void sound_stop(int channel)
{
	if (channel >= 0 && channel < MIXER_CHANNEL_COUNT)
		channels[channel].effect = NULL;
}

static boolean sound_is_playing(int channel)
{
	return channel >= 0 && channel < MIXER_CHANNEL_COUNT && channels[channel].effect != NULL;
}

/* Effects are read when first played: they are small, and a WAD's are
   read in no time. */
static void sound_cache(sfxinfo_t *sounds, int count)
{
	(void)sounds;
	(void)count;
}

sound_module_t DG_sound_module = {
	handled_devices,
	sizeof(handled_devices) / sizeof(handled_devices[0]),
	sound_initialize,
	sound_shut_down,
	sound_lump_number,
	sound_update,
	sound_update_parameters,
	sound_start,
	sound_stop,
	sound_is_playing,
	sound_cache,
};

/* --- Music: silent -------------------------------------------------------- */

static boolean music_initialize(void)
{
	return false;
}

static void music_shut_down(void)
{
}

static void music_set_volume(int volume)
{
	(void)volume;
}

static void music_pause(void)
{
}

static void music_resume(void)
{
}

static void *music_register(void *data, int length)
{
	(void)data;
	(void)length;
	return NULL;
}

static void music_unregister(void *handle)
{
	(void)handle;
}

static void music_play(void *handle, boolean looping)
{
	(void)handle;
	(void)looping;
}

static void music_stop(void)
{
}

static boolean music_is_playing(void)
{
	return false;
}

music_module_t DG_music_module = {
	handled_devices,
	sizeof(handled_devices) / sizeof(handled_devices[0]),
	music_initialize,
	music_shut_down,
	music_set_volume,
	music_pause,
	music_resume,
	music_register,
	music_unregister,
	music_play,
	music_stop,
	music_is_playing,
	NULL,
};
