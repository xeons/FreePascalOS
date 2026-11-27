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
 * doomgeneric's platform layer for FreePascalOS: a window of the display
 * server (<freepascalos/windowing.h>), its keyboard, a monotonic clock.
 *
 * The engine draws its 320x200 frame into DG_ScreenBuffer ($00RRGGBB
 * words). Doom's pixels were never square: the frame was shown on a 4:3
 * screen, so each one is 1.2 times as tall as it is wide. The window's
 * surface gets the frame scaled to the largest 4:3 rectangle that fits,
 * centred, with black bars on the sides that are left over; it starts
 * as a whole multiple of 320x240 logical units (1/96 inch) that fits
 * the screen, in pixels at the display's scale, and follows resizes and
 * scale changes.
 *
 * Keys arrive as scan codes (set 1, extended keys with
 * FPOS_KEY_CODE_EXTENDED) and are translated to Doom's key codes
 * (doomkeys.h) into a queue DG_GetKey empties. When the window loses the
 * keyboard every key still held is released, so none sticks. Closing
 * the window quits the way the menu's Quit does (I_Quit: the
 * configuration saved, sound shut down). The sound effects and the
 * music are doomgeneric_freepascalos_sound.c and _music.c, mixed into
 * one stream by doomgeneric_freepascalos_audio.c.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <freepascalos/windowing.h>

#include "doomgeneric.h"
#include "doomkeys.h"
#include "i_system.h"

#include "doomgeneric_freepascalos_audio.h"

#define FRAME_WIDTH DOOMGENERIC_RESX
#define FRAME_HEIGHT DOOMGENERIC_RESY

/* The frame as it was seen: 4:3, 320x240 logical units at scale 1. */
#define DISPLAY_ASPECT_WIDTH 4
#define DISPLAY_ASPECT_HEIGHT 3
#define BASE_WINDOW_WIDTH 320
#define BASE_WINDOW_HEIGHT 240
/* The window starts at no more than this many times the base size, and
   leaves at least this many logical units of the screen around it (the
   frame, the taskbar). */
#define LARGEST_START_MULTIPLE 3
#define SCREEN_MARGIN 96

#define WINDOW_TITLE "Doom"
#define OPAQUE_BLACK 0xFF000000u

#define KEY_QUEUE_CAPACITY 64

struct key_event {
	unsigned char doom_key;
	unsigned char pressed;
};

static struct fpos_display display;
static struct fpos_window window;

/* Where the frame goes in the surface, and which frame column each of
   its surface columns shows (rebuilt when the surface changes). */
static int32_t frame_left, frame_top, frame_width, frame_height;
static uint16_t *source_column_of;
static int layout_stale = 1;

static struct key_event key_queue[KEY_QUEUE_CAPACITY];
static unsigned key_queue_first, key_queue_count;
static unsigned char doom_key_held[256];

static struct timespec clock_start;

/* --- Keys --------------------------------------------------------------- */

/* Doom's key for a scan code (set 1; FPOS_KEY_CODE_EXTENDED for E0 keys);
   0 for keys Doom has no use for. */
static unsigned char doom_key_of_scan_code(uint32_t code)
{
	static const unsigned char main_keys[0x59] = {
		[0x01] = KEY_ESCAPE,
		[0x02] = '1', [0x03] = '2', [0x04] = '3', [0x05] = '4', [0x06] = '5',
		[0x07] = '6', [0x08] = '7', [0x09] = '8', [0x0A] = '9', [0x0B] = '0',
		[0x0C] = KEY_MINUS, [0x0D] = KEY_EQUALS, [0x0E] = KEY_BACKSPACE, [0x0F] = KEY_TAB,
		[0x10] = 'q', [0x11] = 'w', [0x12] = 'e', [0x13] = 'r', [0x14] = 't',
		[0x15] = 'y', [0x16] = 'u', [0x17] = 'i', [0x18] = 'o', [0x19] = 'p',
		[0x1A] = '[', [0x1B] = ']', [0x1C] = KEY_ENTER, [0x1D] = KEY_FIRE,
		[0x1E] = 'a', [0x1F] = 's', [0x20] = 'd', [0x21] = 'f', [0x22] = 'g',
		[0x23] = 'h', [0x24] = 'j', [0x25] = 'k', [0x26] = 'l', [0x27] = ';',
		[0x28] = '\'', [0x29] = '`', [0x2A] = KEY_RSHIFT, [0x2B] = '\\',
		[0x2C] = 'z', [0x2D] = 'x', [0x2E] = 'c', [0x2F] = 'v', [0x30] = 'b',
		[0x31] = 'n', [0x32] = 'm', [0x33] = ',', [0x34] = '.', [0x35] = '/',
		[0x36] = KEY_RSHIFT, [0x37] = KEYP_MULTIPLY, [0x38] = KEY_LALT, [0x39] = KEY_USE,
		[0x3A] = KEY_CAPSLOCK,
		[0x3B] = KEY_F1, [0x3C] = KEY_F2, [0x3D] = KEY_F3, [0x3E] = KEY_F4, [0x3F] = KEY_F5,
		[0x40] = KEY_F6, [0x41] = KEY_F7, [0x42] = KEY_F8, [0x43] = KEY_F9, [0x44] = KEY_F10,
		[0x45] = KEY_NUMLOCK, [0x46] = KEY_SCRLCK,
		[0x47] = KEYP_7, [0x48] = KEYP_8, [0x49] = KEYP_9, [0x4A] = KEYP_MINUS,
		[0x4B] = KEYP_4, [0x4C] = KEYP_5, [0x4D] = KEYP_6, [0x4E] = KEYP_PLUS,
		[0x4F] = KEYP_1, [0x50] = KEYP_2, [0x51] = KEYP_3,
		[0x57] = KEY_F11, [0x58] = KEY_F12,
	};
	if (!(code & FPOS_KEY_CODE_EXTENDED))
		return code < sizeof(main_keys) ? main_keys[code] : 0;
	switch (code & ~(uint32_t)FPOS_KEY_CODE_EXTENDED) {
	case 0x1C: return KEYP_ENTER;
	case 0x1D: return KEY_FIRE; /* right Ctrl */
	case 0x35: return KEYP_DIVIDE;
	case 0x37: return KEY_PRTSCR;
	case 0x38: return KEY_RALT; /* right Alt (AltGr) */
	case 0x45: return KEY_PAUSE;
	case 0x47: return KEY_HOME;
	case 0x48: return KEY_UPARROW;
	case 0x49: return KEY_PGUP;
	case 0x4B: return KEY_LEFTARROW;
	case 0x4D: return KEY_RIGHTARROW;
	case 0x4F: return KEY_END;
	case 0x50: return KEY_DOWNARROW;
	case 0x51: return KEY_PGDN;
	case 0x52: return KEY_INS;
	case 0x53: return KEY_DEL;
	default: return 0;
	}
}

static void queue_key(unsigned char doom_key, int pressed)
{
	if (doom_key == 0 || key_queue_count == KEY_QUEUE_CAPACITY)
		return;
	key_queue[(key_queue_first + key_queue_count) % KEY_QUEUE_CAPACITY] =
		(struct key_event){.doom_key = doom_key, .pressed = (unsigned char)(pressed != 0)};
	key_queue_count++;
	doom_key_held[doom_key] = (unsigned char)(pressed != 0);
}

/* The window lost the keyboard: what is held now will not be released
   to us, so release it here. */
static void release_held_keys(void)
{
	unsigned key;
	for (key = 1; key < 256; key++)
		if (doom_key_held[key])
			queue_key((unsigned char)key, 0);
}

/* --- The surface ------------------------------------------------------ */

static void resize_surface(int32_t width, int32_t height)
{
	if (width < 1 || height < 1)
		return;
	if (fpos_window_set_surface(&window, width, height) == 0)
		layout_stale = 1;
}

/* The largest 4:3 rectangle in the surface, centred; the bars around it
   black; a column map for it. */
static void lay_out_frame(void)
{
	int32_t column;
	uint16_t *columns;
	if (window.width * DISPLAY_ASPECT_HEIGHT >= window.height * DISPLAY_ASPECT_WIDTH) {
		frame_height = window.height;
		frame_width = window.height * DISPLAY_ASPECT_WIDTH / DISPLAY_ASPECT_HEIGHT;
	} else {
		frame_width = window.width;
		frame_height = window.width * DISPLAY_ASPECT_HEIGHT / DISPLAY_ASPECT_WIDTH;
	}
	if (frame_width < 1)
		frame_width = 1;
	if (frame_height < 1)
		frame_height = 1;
	frame_left = (window.width - frame_width) / 2;
	frame_top = (window.height - frame_height) / 2;
	columns = realloc(source_column_of, (size_t)frame_width * sizeof(*columns));
	if (!columns)
		I_Error("doom: out of memory for a %dx%d window", (int)window.width, (int)window.height);
	source_column_of = columns;
	for (column = 0; column < frame_width; column++)
		source_column_of[column] = (uint16_t)((int64_t)column * FRAME_WIDTH / frame_width);
	for (column = 0; column < window.width * window.height; column++)
		window.pixels[column] = OPAQUE_BLACK;
	layout_stale = 0;
}

static void draw_scaled_frame(void)
{
	int32_t row, column, previous_source_row = -1;
	uint32_t *previous_line = NULL;
	for (row = 0; row < frame_height; row++) {
		int32_t source_row = (int32_t)((int64_t)row * FRAME_HEIGHT / frame_height);
		uint32_t *line = window.pixels + (size_t)(frame_top + row) * window.width + frame_left;
		if (source_row == previous_source_row) {
			memcpy(line, previous_line, (size_t)frame_width * sizeof(*line));
		} else {
			const uint32_t *source = (const uint32_t *)DG_ScreenBuffer + (size_t)source_row * FRAME_WIDTH;
			for (column = 0; column < frame_width; column++)
				line[column] = source[source_column_of[column]] | OPAQUE_BLACK;
		}
		previous_source_row = source_row;
		previous_line = line;
	}
}

/* --- Events ------------------------------------------------------------- */

static void handle_window_events(void)
{
	struct fpos_window_message message;
	while (fpos_display_next_event(&display, &message)) {
		if (message.window != window.number)
			continue;
		switch (message.kind) {
		case FPOS_EVENT_CLOSE_REQUESTED:
			I_Quit();
			break;
		case FPOS_EVENT_RESIZED:
			resize_surface(message.surface_width, message.surface_height);
			break;
		case FPOS_EVENT_SCALE_CHANGED:
			if (window.scale != 0 && message.code != 0 && message.code != window.scale) {
				int32_t width = (int32_t)((int64_t)window.width * message.code / window.scale);
				int32_t height = (int32_t)((int64_t)window.height * message.code / window.scale);
				window.scale = message.code;
				resize_surface(width, height);
			}
			break;
		case FPOS_EVENT_KEY:
			queue_key(doom_key_of_scan_code(message.code), message.value != 0);
			break;
		case FPOS_EVENT_ACTIVATED:
			if (message.value == 0)
				release_held_keys();
			break;
		default:
			break;
		}
	}
	if (display.broken) {
		fprintf(stderr, "doom: lost the connection to the display server\n");
		I_Quit();
	}
}

/* --- doomgeneric's platform functions ------------------------------ */

/* The window's first size: the largest whole multiple of 320x240 logical
   units (up to LARGEST_START_MULTIPLE) that fits the screen. */
static int32_t starting_multiple(void)
{
	int32_t scale = display.scale ? (int32_t)display.scale : 100;
	int32_t screen_width = display.screen_width * 100 / scale - SCREEN_MARGIN;
	int32_t screen_height = display.screen_height * 100 / scale - SCREEN_MARGIN;
	int32_t multiple = LARGEST_START_MULTIPLE;
	while (multiple > 1 &&
	       (BASE_WINDOW_WIDTH * multiple > screen_width || BASE_WINDOW_HEIGHT * multiple > screen_height))
		multiple--;
	return multiple;
}

void DG_Init(void)
{
	int32_t multiple, logical_width, logical_height, left, top, scale;
	clock_gettime(CLOCK_MONOTONIC, &clock_start);
	if (fpos_display_connect(&display) != 0) {
		fprintf(stderr, "doom: no display server to show a window on\n");
		exit(1);
	}
	multiple = starting_multiple();
	logical_width = BASE_WINDOW_WIDTH * multiple;
	logical_height = BASE_WINDOW_HEIGHT * multiple;
	scale = display.scale ? (int32_t)display.scale : 100;
	left = (display.screen_width * 100 / scale - logical_width) / 2;
	top = (display.screen_height * 100 / scale - logical_height) / 2;
	if (left < 0)
		left = 0;
	if (top < 0)
		top = 0;
	if (fpos_window_create(&display, left, top, fpos_logical_to_pixels(logical_width, (uint32_t)scale),
			       fpos_logical_to_pixels(logical_height, (uint32_t)scale), WINDOW_TITLE,
			       FPOS_WINDOW_FRAMED | FPOS_WINDOW_RESIZABLE, &window) != 0) {
		fprintf(stderr, "doom: cannot make a window\n");
		exit(1);
	}
	lay_out_frame();
	fpos_window_damage(&window, 0, 0, window.width, window.height);
	fpos_window_show(&window, 1);
}

void DG_DrawFrame(void)
{
	int whole_surface;
	handle_window_events();
	whole_surface = layout_stale;
	if (layout_stale)
		lay_out_frame();
	draw_scaled_frame();
	if (whole_surface)
		fpos_window_damage(&window, 0, 0, window.width, window.height);
	else
		fpos_window_damage(&window, frame_left, frame_top, frame_width, frame_height);
}

/* Waits on the display's channel rather than a plain sleep, so a key
   pressed meanwhile ends the wait (DG_GetKey then reads it). Doom waits
   here between tics and through screen wipes, which do not update the
   sound: the audio stream is topped up first, so the music plays on. */
void DG_SleepMs(uint32_t milliseconds)
{
	audio_output_update();
	if (display.broken) {
		struct timespec pause = {.tv_sec = milliseconds / 1000, .tv_nsec = (long)(milliseconds % 1000) * 1000000L};
		nanosleep(&pause, NULL);
		return;
	}
	fpos_display_wait(&display, (int64_t)milliseconds);
}

uint32_t DG_GetTicksMs(void)
{
	struct timespec now;
	int64_t milliseconds;
	clock_gettime(CLOCK_MONOTONIC, &now);
	milliseconds = (int64_t)(now.tv_sec - clock_start.tv_sec) * 1000 +
		       (now.tv_nsec - clock_start.tv_nsec) / 1000000L;
	return (uint32_t)milliseconds;
}

int DG_GetKey(int *pressed, unsigned char *doom_key)
{
	if (key_queue_count == 0)
		handle_window_events();
	if (key_queue_count == 0)
		return 0;
	*pressed = key_queue[key_queue_first].pressed;
	*doom_key = key_queue[key_queue_first].doom_key;
	key_queue_first = (key_queue_first + 1) % KEY_QUEUE_CAPACITY;
	key_queue_count--;
	return 1;
}

/* Doom names the game it found ("Freedoom: Phase 1"): the window says
   which, after its own name. */
void DG_SetWindowTitle(const char *title)
{
	char text[FPOS_WINDOW_TITLE_CAPACITY];
	if (!title || !*title || !window.number)
		return;
	snprintf(text, sizeof(text), "%s - %s", WINDOW_TITLE, title);
	fpos_window_set_title(&window, text);
}

int main(int argc, char **argv)
{
	doomgeneric_Create(argc, argv);
	for (;;)
		doomgeneric_Tick();
	return 0;
}
