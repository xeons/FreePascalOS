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
 * A check, on the build machine, of the doomgeneric port's music: the
 * port's music module (doomgeneric_freepascalos_music.c), its OPL driver
 * (opl_freepascalos.c) and Chocolate Doom's OPL player, built with the
 * build machine's compiler (run.sh), play a song of a WAD through the
 * WAD's GENMIDI instruments into a WAV file. The audio output and the
 * few engine functions they call are stood in for here: the music
 * source is asked for frames the way audio_output_update asks for
 * them, a tic's worth at a time.
 *
 *   music_check WAD LUMP SECONDS RATE DMXOPTION OUTPUT.wav
 *
 * Prints the RMS level of the music, the CPU time it took to make and
 * that as a share of the music's length; fails (status 1) if the music
 * is silent.
 */

#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "doomtype.h"
#include "doomstat.h"
#include "i_sound.h"
#include "z_zone.h"

#include "doomgeneric_freepascalos_audio.h"

#define TIC_FRAMES_DIVISOR 35
#define SILENCE_RMS 100.0

/* --- The engine's variables and functions the music uses ----------------- */

int snd_musicdevice = SNDDEVICE_SB;
int snd_samplerate = 44100;
GameVersion_t gameversion = exe_doom_1_9;
GameMission_t gamemission = doom;

struct wad_lump {
	char name[9];
	uint32_t offset;
	uint32_t size;
};

static FILE *wad_file;
static struct wad_lump *wad_lumps;
static uint32_t wad_lump_count;

static uint32_t read_le32(const unsigned char *bytes)
{
	return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static int open_wad(const char *path)
{
	unsigned char header[12];
	unsigned char entry[16];
	uint32_t index, directory;
	wad_file = fopen(path, "rb");
	if (!wad_file || fread(header, 1, sizeof(header), wad_file) != sizeof(header))
		return 0;
	wad_lump_count = read_le32(header + 4);
	directory = read_le32(header + 8);
	wad_lumps = calloc(wad_lump_count, sizeof(*wad_lumps));
	if (!wad_lumps || fseek(wad_file, (long)directory, SEEK_SET) != 0)
		return 0;
	for (index = 0; index < wad_lump_count; index++) {
		if (fread(entry, 1, sizeof(entry), wad_file) != sizeof(entry))
			return 0;
		wad_lumps[index].offset = read_le32(entry);
		wad_lumps[index].size = read_le32(entry + 4);
		memcpy(wad_lumps[index].name, entry + 8, 8);
	}
	return 1;
}

static void *read_lump(const char *name, uint32_t *size)
{
	uint32_t index;
	for (index = wad_lump_count; index-- > 0;) {
		if (strncasecmp(wad_lumps[index].name, name, 8) == 0) {
			void *data = malloc(wad_lumps[index].size);
			if (!data || fseek(wad_file, (long)wad_lumps[index].offset, SEEK_SET) != 0 ||
			    fread(data, 1, wad_lumps[index].size, wad_file) != wad_lumps[index].size) {
				free(data);
				return NULL;
			}
			*size = wad_lumps[index].size;
			return data;
		}
	}
	return NULL;
}

void I_Error(char *error, ...)
{
	fprintf(stderr, "music_check: I_Error: %s\n", error);
	exit(2);
}

void *W_CacheLumpName(char *name, int tag)
{
	uint32_t size;
	void *data = read_lump(name, &size);
	(void)tag;
	if (!data)
		I_Error("no such lump");
	return data;
}

void W_ReleaseLumpName(char *name)
{
	(void)name;
}

void *Z_Malloc(int size, int tag, void *user)
{
	(void)tag;
	(void)user;
	return malloc((size_t)size);
}

void Z_Free(void *block)
{
	free(block);
}

boolean M_WriteFile(char *name, void *source, int length)
{
	FILE *file = fopen(name, "wb");
	size_t written;
	if (!file)
		return false;
	written = fwrite(source, 1, (size_t)length, file);
	fclose(file);
	return written == (size_t)length;
}

static char temporary_folder[4096] = ".";

char *M_TempFile(char *name)
{
	size_t length = strlen(temporary_folder) + strlen(name) + 2;
	char *path = malloc(length);
	snprintf(path, length, "%s/%s", temporary_folder, name);
	return path;
}

int M_snprintf(char *buffer, size_t size, const char *format, ...)
{
	va_list arguments;
	int result;
	va_start(arguments, format);
	result = vsnprintf(buffer, size, format, arguments);
	va_end(arguments);
	return result;
}

boolean M_StringConcat(char *destination, const char *source, size_t size)
{
	size_t length = strlen(destination);
	if (length < size)
		snprintf(destination + length, size - length, "%s", source);
	return true;
}

/* --- The audio output ------------------------------------------------------- */

static audio_source_mixer_t music_mixer;
static uint32_t check_rate;

int audio_output_attach(enum audio_source source, audio_source_mixer_t mixer)
{
	if (source == AUDIO_SOURCE_MUSIC)
		music_mixer = mixer;
	return 1;
}

void audio_output_detach(enum audio_source source)
{
	if (source == AUDIO_SOURCE_MUSIC)
		music_mixer = NULL;
}

uint32_t audio_output_rate(void)
{
	return check_rate;
}

void audio_output_update(void)
{
}

/* --- The check -------------------------------------------------------------- */

extern music_module_t DG_music_module;

static void write_le16(FILE *file, uint16_t value)
{
	fputc(value & 0xFF, file);
	fputc(value >> 8, file);
}

static void write_le32(FILE *file, uint32_t value)
{
	write_le16(file, (uint16_t)(value & 0xFFFF));
	write_le16(file, (uint16_t)(value >> 16));
}

static void write_wav_header(FILE *file, uint32_t rate, uint32_t frames)
{
	uint32_t data_size = frames * AUDIO_OUTPUT_CHANNELS * 2;
	fwrite("RIFF", 1, 4, file);
	write_le32(file, 36 + data_size);
	fwrite("WAVEfmt ", 1, 8, file);
	write_le32(file, 16);
	write_le16(file, 1);
	write_le16(file, AUDIO_OUTPUT_CHANNELS);
	write_le32(file, rate);
	write_le32(file, rate * AUDIO_OUTPUT_CHANNELS * 2);
	write_le16(file, AUDIO_OUTPUT_CHANNELS * 2);
	write_le16(file, 16);
	fwrite("data", 1, 4, file);
	write_le32(file, data_size);
}

int main(int argc, char **argv)
{
	uint32_t lump_size, total_frames, made, tic_frames;
	void *lump, *song;
	FILE *output;
	int32_t *mix;
	int16_t *samples;
	double square_sum = 0, rms, seconds_of_cpu;
	clock_t cpu_before, cpu_spent = 0;
	const char *folder;
	if (argc != 7) {
		fprintf(stderr, "usage: music_check WAD LUMP SECONDS RATE DMXOPTION OUTPUT.wav\n");
		return 2;
	}
	check_rate = (uint32_t)atoi(argv[4]);
	snd_samplerate = (int)check_rate;
	snd_dmxoption = argv[5];
	folder = getenv("TMPDIR");
	if (folder && *folder)
		snprintf(temporary_folder, sizeof(temporary_folder), "%s", folder);
	if (!open_wad(argv[1])) {
		fprintf(stderr, "music_check: %s is no WAD\n", argv[1]);
		return 2;
	}
	lump = read_lump(argv[2], &lump_size);
	if (!lump) {
		fprintf(stderr, "music_check: no lump %s\n", argv[2]);
		return 2;
	}
	if (!DG_music_module.Init() || !music_mixer) {
		fprintf(stderr, "music_check: the music module did not start\n");
		return 1;
	}
	DG_music_module.SetMusicVolume(127);
	song = DG_music_module.RegisterSong(lump, (int)lump_size);
	if (!song) {
		fprintf(stderr, "music_check: %s did not load\n", argv[2]);
		return 1;
	}
	DG_music_module.PlaySong(song, true);

	total_frames = (uint32_t)(atof(argv[3]) * check_rate);
	tic_frames = check_rate / TIC_FRAMES_DIVISOR;
	mix = malloc((size_t)tic_frames * AUDIO_OUTPUT_CHANNELS * sizeof(*mix));
	samples = malloc((size_t)tic_frames * AUDIO_OUTPUT_CHANNELS * sizeof(*samples));
	output = fopen(argv[6], "wb");
	if (!mix || !samples || !output)
		return 2;
	write_wav_header(output, check_rate, total_frames);
	for (made = 0; made < total_frames; made += tic_frames) {
		uint32_t frames = total_frames - made < tic_frames ? total_frames - made : tic_frames;
		uint32_t index;
		memset(mix, 0, (size_t)frames * AUDIO_OUTPUT_CHANNELS * sizeof(*mix));
		cpu_before = clock();
		music_mixer(mix, frames);
		cpu_spent += clock() - cpu_before;
		for (index = 0; index < frames * AUDIO_OUTPUT_CHANNELS; index++) {
			int32_t sample = mix[index];
			if (sample > INT16_MAX)
				sample = INT16_MAX;
			if (sample < INT16_MIN)
				sample = INT16_MIN;
			samples[index] = (int16_t)sample;
			square_sum += (double)sample * sample;
		}
		fwrite(samples, sizeof(*samples), (size_t)frames * AUDIO_OUTPUT_CHANNELS, output);
	}
	fclose(output);
	DG_music_module.StopSong();
	DG_music_module.UnRegisterSong(song);
	DG_music_module.Shutdown();

	rms = sqrt(square_sum / ((double)total_frames * AUDIO_OUTPUT_CHANNELS));
	seconds_of_cpu = (double)cpu_spent / CLOCKS_PER_SEC;
	printf("%s %s, %u Hz, dmxoption \"%s\": %.1f s, RMS %.0f, %.3f s of CPU (%.2f%% of one core)\n", argv[1],
	       argv[2], (unsigned)check_rate, argv[5], (double)total_frames / check_rate, rms, seconds_of_cpu,
	       100.0 * seconds_of_cpu * check_rate / total_frames);
	if (rms < SILENCE_RMS) {
		fprintf(stderr, "music_check: the music is silent\n");
		return 1;
	}
	return 0;
}
