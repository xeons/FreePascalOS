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
 * An OPL driver (opl_driver_t, Chocolate Doom's opl/opl_internal.h) for
 * FreePascalOS: the Nuked OPL3 emulator (opl/opl3.c) as the music source
 * of Doom's audio output, in place of Chocolate Doom's SDL driver.
 *
 * Chocolate Doom's music player (i_oplmusic.c) writes the chip's
 * registers and schedules its next MIDI events with OPL_SetCallback.
 * Here the clock those callbacks wait for is the music's own frames:
 * when the audio output asks for frames, the emulator makes them up to
 * the next callback's time, the callback runs (writing registers,
 * scheduling the next), and so on until the frames asked for are made.
 * Everything happens in Doom's thread, during audio_output_update, so
 * there is nothing to lock and no thread to wait on; the music's timing
 * is exact to the frame whatever the tic rate, and it is made only as
 * far ahead as the stream's latency.
 *
 * The chip's two timers are emulated on the same clock (DBOPL and Nuked
 * leave them to the driver), as Doom's OPL detection reads them;
 * OPL_Delay (opl.c, patched) runs the clock forward by making frames
 * that are thrown away.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "opl.h"
#include "opl3.h"
#include "opl_internal.h"
#include "opl_queue.h"

#include "doomgeneric_freepascalos_audio.h"

/* Frames made per call into the emulator. */
#define GENERATE_CHUNK_FRAMES 512

#define TIMER_1_RATE 12500 /* ticks a second: 80 us */
#define TIMER_2_RATE 3125  /* 320 us */
#define TIMER_COUNTER_RANGE 0x100

#define STATUS_ANY_TIMER_EXPIRED 0x80
#define STATUS_TIMER_1_EXPIRED 0x40
#define STATUS_TIMER_2_EXPIRED 0x20
#define TIMER_CONTROL_RESET_FLAGS 0x80
#define TIMER_CONTROL_MASK_TIMER_1 0x40
#define TIMER_CONTROL_MASK_TIMER_2 0x20
#define TIMER_CONTROL_START_TIMER_1 0x01
#define TIMER_CONTROL_START_TIMER_2 0x02

struct opl_timer {
	unsigned int rate;
	int enabled;
	unsigned int value;
	uint64_t expire_time; /* microseconds */
};

static int driver_started;
static opl3_chip chip;
static uint32_t frame_rate;
static opl_callback_queue_t *callback_queue;

/* The clock: frames made since the driver started, and that in
   microseconds. While the music is paused the callbacks' times move on
   with it (pause_offset), so they fire as far after the pause as they
   were due before it. */
static uint64_t frames_made;
static uint64_t current_time;
static uint64_t pause_offset;
static int paused;

static unsigned int selected_register;
static struct opl_timer timer_1 = {TIMER_1_RATE, 0, 0, 0};
static struct opl_timer timer_2 = {TIMER_2_RATE, 0, 0, 0};

static int16_t chunk_buffer[GENERATE_CHUNK_FRAMES * AUDIO_OUTPUT_CHANNELS];

/* --- The clock ------------------------------------------------------------ */

static uint64_t frames_until(uint64_t time)
{
	uint64_t microseconds;
	if (time <= current_time)
		return 0;
	microseconds = time - current_time;
	return (microseconds * frame_rate + OPL_SECOND - 1) / OPL_SECOND;
}

static void advance_clock(uint32_t frames)
{
	uint64_t previous_time = current_time;
	frames_made += frames;
	current_time = frames_made * OPL_SECOND / frame_rate;
	if (paused)
		pause_offset += current_time - previous_time;
}

/* Runs every callback due by now; a callback may schedule more (even
   for now: they run too). */
static void run_due_callbacks(void)
{
	opl_callback_t callback;
	void *data;
	while (!OPL_Queue_IsEmpty(callback_queue) && current_time >= OPL_Queue_Peek(callback_queue) + pause_offset) {
		if (!OPL_Queue_Pop(callback_queue, &callback, &data))
			break;
		callback(data);
	}
}

/* Makes Frames frames, adding them to Mix when it is given, running each
   callback at its frame. */
static void generate(int32_t *mix, uint32_t frames)
{
	while (frames > 0) {
		uint64_t chunk = frames < GENERATE_CHUNK_FRAMES ? frames : GENERATE_CHUNK_FRAMES;
		uint32_t index;
		run_due_callbacks();
		if (!paused && !OPL_Queue_IsEmpty(callback_queue)) {
			uint64_t until_callback = frames_until(OPL_Queue_Peek(callback_queue) + pause_offset);
			if (until_callback > 0 && until_callback < chunk)
				chunk = until_callback;
		}
		OPL3_GenerateStream(&chip, chunk_buffer, (uint32_t)chunk);
		if (mix) {
			for (index = 0; index < chunk * AUDIO_OUTPUT_CHANNELS; index++)
				mix[index] += chunk_buffer[index];
			mix += chunk * AUDIO_OUTPUT_CHANNELS;
		}
		advance_clock((uint32_t)chunk);
		frames -= (uint32_t)chunk;
	}
	run_due_callbacks();
}

/* The music source of the audio output. */
static void mix_music(int32_t *mix, uint32_t frames)
{
	generate(mix, frames);
}

void OPL_FreePascalOS_Delay(uint64_t us)
{
	uint64_t frames = (us * frame_rate + OPL_SECOND - 1) / OPL_SECOND;
	while (frames > 0) {
		uint32_t chunk = frames < GENERATE_CHUNK_FRAMES ? (uint32_t)frames : GENERATE_CHUNK_FRAMES;
		generate(NULL, chunk);
		frames -= chunk;
	}
}

/* --- Timers ----------------------------------------------------------------- */

static void start_timer(struct opl_timer *timer)
{
	if (timer->enabled)
		timer->expire_time = current_time + (uint64_t)(TIMER_COUNTER_RANGE - timer->value) * OPL_SECOND / timer->rate;
}

static void write_timer_control(unsigned int value)
{
	if (value & TIMER_CONTROL_RESET_FLAGS) {
		timer_1.enabled = 0;
		timer_2.enabled = 0;
		return;
	}
	if (!(value & TIMER_CONTROL_MASK_TIMER_1)) {
		timer_1.enabled = (value & TIMER_CONTROL_START_TIMER_1) != 0;
		start_timer(&timer_1);
	}
	if (!(value & TIMER_CONTROL_MASK_TIMER_2)) {
		timer_2.enabled = (value & TIMER_CONTROL_START_TIMER_2) != 0;
		start_timer(&timer_2);
	}
}

/* --- The driver ------------------------------------------------------------- */

static int driver_initialize(unsigned int port_base)
{
	(void)port_base;
	callback_queue = OPL_Queue_Create();
	if (!callback_queue)
		return 0;
	if (!audio_output_attach(AUDIO_SOURCE_MUSIC, mix_music)) {
		OPL_Queue_Destroy(callback_queue);
		callback_queue = NULL;
		return 0;
	}
	frame_rate = audio_output_rate();
	frames_made = 0;
	current_time = 0;
	pause_offset = 0;
	paused = 0;
	selected_register = 0;
	timer_1.enabled = 0;
	timer_2.enabled = 0;
	OPL3_Reset(&chip, frame_rate);
	driver_started = 1;
	return 1;
}

static void driver_shut_down(void)
{
	if (!driver_started)
		return;
	audio_output_detach(AUDIO_SOURCE_MUSIC);
	OPL_Queue_Destroy(callback_queue);
	callback_queue = NULL;
	driver_started = 0;
}

/* The status port: the timers' flags. The OPL3's second register port
   reads 0xFF, which is how the detection tells an OPL3. */
static unsigned int driver_read_port(opl_port_t port)
{
	unsigned int status = 0;
	if (port == OPL_REGISTER_PORT_OPL3)
		return 0xFF;
	if (timer_1.enabled && current_time > timer_1.expire_time)
		status |= STATUS_ANY_TIMER_EXPIRED | STATUS_TIMER_1_EXPIRED;
	if (timer_2.enabled && current_time > timer_2.expire_time)
		status |= STATUS_ANY_TIMER_EXPIRED | STATUS_TIMER_2_EXPIRED;
	return status;
}

static void driver_write_register(unsigned int number, unsigned int value)
{
	switch (number) {
	case OPL_REG_TIMER1:
		timer_1.value = value;
		start_timer(&timer_1);
		break;
	case OPL_REG_TIMER2:
		timer_2.value = value;
		start_timer(&timer_2);
		break;
	case OPL_REG_TIMER_CTRL:
		write_timer_control(value);
		break;
	default:
		/* Buffered: the chip takes successive writes a couple of its
		   samples apart, as the real one needed. */
		OPL3_WriteRegBuffered(&chip, (uint16_t)number, (uint8_t)value);
		break;
	}
}

static void driver_write_port(opl_port_t port, unsigned int value)
{
	if (port == OPL_REGISTER_PORT)
		selected_register = value;
	else if (port == OPL_REGISTER_PORT_OPL3)
		selected_register = value | 0x100;
	else if (port == OPL_DATA_PORT)
		driver_write_register(selected_register, value);
}

static void driver_set_callback(uint64_t us, opl_callback_t callback, void *data)
{
	OPL_Queue_Push(callback_queue, callback, data, current_time - pause_offset + us);
}

static void driver_clear_callbacks(void)
{
	OPL_Queue_Clear(callback_queue);
}

/* Callbacks run only inside audio_output_update, in Doom's own thread:
   no other code can be running then, so there is nothing to lock. */
static void driver_lock(void)
{
}

static void driver_unlock(void)
{
}

static void driver_set_paused(int now_paused)
{
	paused = now_paused;
}

/* A tempo change: the callbacks' times are on the clock less the pauses. */
static void driver_adjust_callbacks(float factor)
{
	OPL_Queue_AdjustCallbacks(callback_queue, current_time - pause_offset, factor);
}

opl_driver_t opl_freepascalos_driver = {
	"FreePascalOS",
	driver_initialize,
	driver_shut_down,
	driver_read_port,
	driver_write_port,
	driver_set_callback,
	driver_clear_callbacks,
	driver_lock,
	driver_unlock,
	driver_set_paused,
	driver_adjust_callbacks,
};
