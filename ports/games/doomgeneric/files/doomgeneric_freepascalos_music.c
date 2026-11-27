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
 * Doom's music on FreePascalOS, as it sounded on an AdLib or a Sound
 * Blaster: FM synthesis on an emulated OPL chip. This is the music
 * module doomgeneric asks the platform for (DG_music_module); it is
 * Chocolate Doom's OPL music player (music_opl_module, i_oplmusic.c:
 * MUS scores converted to MIDI, played with the instruments of the
 * WAD's GENMIDI lump, as DMX did) on the OPL driver of
 * opl_freepascalos.c, which mixes the chip into the audio output with
 * the sound effects.
 *
 * Settings:
 *   snd_musicdevice  (~/.doom/default.cfg) 3 (Sound Blaster) or 2
 *                    (AdLib): OPL music, the default; 0: no music.
 *                    -nomusic turns it off too.
 *   snd_dmxoption    (~/.doom/doomgenericdoom.cfg)
 *                    "-opl3" (the default): an OPL3, 18 voices in
 *                    stereo; "" an OPL2, 9 voices in mono, as an AdLib.
 *                    "-reverse" swaps the channels back (DMX had them
 *                    the wrong way round). DMXOPTION in the environment
 *                    overrides it.
 * Which DMX the voices are allocated like follows the game's version,
 * as in Chocolate Doom (Doom 1.666 and Doom II 1.666 differ from 1.9).
 */

#include <stdio.h>

#include "doomtype.h"
#include "doomstat.h"
#include "i_sound.h"

#include "doomgeneric_freepascalos_audio.h"

static snddevice_t music_devices[] = {
	SNDDEVICE_ADLIB,
	SNDDEVICE_SB,
};

static boolean music_device_selected(void)
{
	unsigned index;
	for (index = 0; index < sizeof(music_devices) / sizeof(music_devices[0]); index++)
		if (snd_musicdevice == (int)music_devices[index])
			return true;
	return false;
}

/* As Chocolate Doom's S_Init. */
static void select_driver_version(void)
{
	if (gameversion == exe_doom_1_666)
		I_SetOPLDriverVer(logical_gamemission == doom ? opl_doom1_1_666 : opl_doom2_1_666);
	else
		I_SetOPLDriverVer(opl_doom_1_9);
}

static boolean music_initialize(void)
{
	if (!music_device_selected()) {
		printf("doom: music is off (snd_musicdevice %d)\n", snd_musicdevice);
		return false;
	}
	select_driver_version();
	return music_opl_module.Init();
}

static void music_shut_down(void)
{
	music_opl_module.Shutdown();
}

/* 0-127, set as the OPL voices' levels. */
static void music_set_volume(int volume)
{
	music_opl_module.SetMusicVolume(volume);
}

static void music_pause(void)
{
	music_opl_module.PauseMusic();
}

static void music_resume(void)
{
	music_opl_module.ResumeMusic();
}

static void *music_register(void *data, int length)
{
	return music_opl_module.RegisterSong(data, length);
}

static void music_unregister(void *handle)
{
	music_opl_module.UnRegisterSong(handle);
}

/* Looping songs start again 5 ms after their last track ends. */
static void music_play(void *handle, boolean looping)
{
	music_opl_module.PlaySong(handle, looping);
}

static void music_stop(void)
{
	music_opl_module.StopSong();
}

static boolean music_is_playing(void)
{
	return music_opl_module.MusicIsPlaying();
}

/* Once a tic: the music is made as the audio output is topped up. */
static void music_poll(void)
{
	audio_output_update();
}

music_module_t DG_music_module = {
	music_devices,
	sizeof(music_devices) / sizeof(music_devices[0]),
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
	music_poll,
};
