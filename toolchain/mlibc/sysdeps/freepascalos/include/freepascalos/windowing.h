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
 * The display server's protocol for C: the part of
 * userland/lib/windowing/Windowing.Protocol.pas a C program needs to
 * show windows and hear their input, and the calls that do it (header
 * only, over <freepascalos/syscall.h>). Mesa's EGL platform and Vulkan
 * window system integration for FreePascalOS are built on it, and so
 * can any C program.
 *
 * A program connects once (fpos_display_connect: the port "display",
 * RequestHello, EventWelcome with the first display's size, DPI and
 * scale). A window's client area is a section (shared memory) of
 * width x height pixels, 32 bits each ($AARRGGBB in a little endian
 * word: blue, green, red, alpha in memory), a line after another
 * (stride width * 4). The program draws into it and names what it
 * changed (fpos_window_damage); the server composes it. When the user
 * resizes the window the program hears EventResized and gives the
 * window a surface of the new size (fpos_window_set_surface); when the
 * window's scale changes, EventScaleChanged.
 *
 * Every message is one struct fpos_window_message, both ways; the fields
 * each kind uses are documented in Windowing.Protocol.pas. Keep this file
 * in step with it.
 */
#ifndef _FREEPASCALOS_WINDOWING_H
#define _FREEPASCALOS_WINDOWING_H

#include <stdint.h>
#include <string.h>
#include <freepascalos/syscall.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FPOS_WINDOWING_PORT_NAME "display"
#define FPOS_WINDOWING_PROTOCOL_VERSION 1
#define FPOS_WINDOW_TITLE_CAPACITY 96

/* Requests: program to server. */
#define FPOS_REQUEST_HELLO 1
#define FPOS_REQUEST_CREATE_WINDOW 2
#define FPOS_REQUEST_DESTROY_WINDOW 3
#define FPOS_REQUEST_SHOW_WINDOW 4
#define FPOS_REQUEST_MOVE_WINDOW 5
#define FPOS_REQUEST_SET_TITLE 6
#define FPOS_REQUEST_SET_SURFACE 7
#define FPOS_REQUEST_DAMAGE 8
#define FPOS_REQUEST_ACTIVATE 9
#define FPOS_REQUEST_SET_POINTER_SHAPE 17
#define FPOS_REQUEST_ANSWER_PING 46

/* Events: server to program. */
#define FPOS_EVENT_WELCOME 101
#define FPOS_EVENT_WINDOW_CREATED 102
#define FPOS_EVENT_KEY 103
#define FPOS_EVENT_POINTER_MOVE 104
#define FPOS_EVENT_POINTER_BUTTON 105
#define FPOS_EVENT_WHEEL 106
#define FPOS_EVENT_POINTER_LEAVE 107
#define FPOS_EVENT_RESIZED 108
#define FPOS_EVENT_ACTIVATED 109
#define FPOS_EVENT_CLOSE_REQUESTED 110
#define FPOS_EVENT_MOVED 111
#define FPOS_EVENT_SCALE_CHANGED 112
#define FPOS_EVENT_VISIBILITY_CHANGED 115
#define FPOS_EVENT_PING 143

/* RequestHello's flags. */
#define FPOS_HELLO_ANSWERS_PINGS 0x01

/* Window flags (RequestCreateWindow). */
#define FPOS_WINDOW_FRAMED 0x01
#define FPOS_WINDOW_RESIZABLE 0x02
#define FPOS_WINDOW_TOPMOST 0x04
#define FPOS_WINDOW_NO_ACTIVATE 0x08

/* EventKey's code: scan code set 1, extended keys with this bit. */
#define FPOS_KEY_CODE_EXTENDED 0x100
#define FPOS_KEY_ESCAPE 0x01

struct fpos_window_message {
	uint32_t kind;
	uint32_t window;
	int32_t left;
	int32_t top;
	int32_t width;
	int32_t height;
	int32_t surface_width;
	int32_t surface_height;
	uint32_t code;
	int32_t value;
	uint32_t character;
	uint32_t modifiers;
	uint32_t flags;
	uint32_t reserved;
	char text[FPOS_WINDOW_TITLE_CAPACITY];
};

/* Events read while waiting for a reply, kept for fpos_display_next_event. */
#define FPOS_DISPLAY_KEPT_EVENTS 64

struct fpos_display {
	int64_t channel;
	int broken;
	/* The first display, from EventWelcome (and EventScaleChanged for
	   window 0): pixels, dots per inch, scale in percent. */
	int32_t screen_width;
	int32_t screen_height;
	uint32_t dpi;
	uint32_t scale;
	unsigned kept_first;
	unsigned kept_count;
	struct fpos_window_message kept[FPOS_DISPLAY_KEPT_EVENTS];
};

struct fpos_window {
	struct fpos_display *display;
	uint32_t number;
	/* The surface: a section of width x height pixels mapped at pixels. */
	int64_t section;
	uint32_t *pixels;
	int32_t width;
	int32_t height;
	/* The window's scale in percent (EventScaleChanged). */
	uint32_t scale;
};

/* A length in logical units (1/96 inch) in pixels at a scale, rounded. */
static inline int32_t fpos_logical_to_pixels(int32_t value, uint32_t scale)
{
	if (value >= 0)
		return (value * (int32_t)scale + 50) / 100;
	return -((-value * (int32_t)scale + 50) / 100);
}

static inline struct fpos_window_message fpos_window_message_new(uint32_t kind, uint32_t window)
{
	struct fpos_window_message message;
	memset(&message, 0, sizeof(message));
	message.kind = kind;
	message.window = window;
	return message;
}

static inline void fpos_window_message_set_text(struct fpos_window_message *message, const char *text)
{
	size_t length = text ? strlen(text) : 0;
	if (length > FPOS_WINDOW_TITLE_CAPACITY - 1)
		length = FPOS_WINDOW_TITLE_CAPACITY - 1;
	memcpy(message->text, text, length);
	message->text[length] = 0;
}

/* Sends a request, with a handle when handle >= 0 (it stays ours). 0 or
   a negative error. */
static inline int fpos_display_send(struct fpos_display *display, const struct fpos_window_message *message,
				    int64_t handle)
{
	struct fpos_message kernel_message;
	long result;
	kernel_message.data = (uint64_t)(uintptr_t)message;
	kernel_message.length = sizeof(*message);
	kernel_message.handles = handle >= 0 ? (uint64_t)(uintptr_t)&handle : 0;
	kernel_message.handle_count = handle >= 0 ? 1 : 0;
	result = fpos_syscall2(FPOS_CALL_SEND_MESSAGE, display->channel, (long)&kernel_message);
	if (result < 0 && result != -FPOS_ERROR_WOULD_BLOCK)
		display->broken = 1;
	return result < 0 ? (int)result : 0;
}

/* One message from the channel without waiting: 1, or 0 if none is
   there (or the connection broke: display->broken). A handle that comes
   with an event is closed: none of the events here carries one. */
static inline int fpos_display_receive(struct fpos_display *display, struct fpos_window_message *message)
{
	for (;;) {
		struct fpos_message kernel_message;
		int64_t handle = -1;
		long result;
		kernel_message.data = (uint64_t)(uintptr_t)message;
		kernel_message.length = sizeof(*message);
		kernel_message.handles = (uint64_t)(uintptr_t)&handle;
		kernel_message.handle_count = 1;
		result = fpos_syscall2(FPOS_CALL_RECEIVE_MESSAGE, display->channel, (long)&kernel_message);
		if (result == -FPOS_ERROR_WOULD_BLOCK)
			return 0;
		if (result < 0) {
			display->broken = 1;
			return 0;
		}
		if (kernel_message.handle_count > 0 && handle >= 0)
			fpos_syscall1(FPOS_CALL_CLOSE, handle);
		if (kernel_message.length != sizeof(*message))
			continue;
		message->reserved = 0;
		if (message->kind == FPOS_EVENT_PING) {
			struct fpos_window_message answer = fpos_window_message_new(FPOS_REQUEST_ANSWER_PING, 0);
			answer.value = message->value;
			fpos_display_send(display, &answer, -1);
			continue;
		}
		return 1;
	}
}

/* Waits up to timeout milliseconds (FPOS_INFINITE_WAIT: for ever) for
   something on the channel. 1 if there is something to read. */
static inline int fpos_display_wait(struct fpos_display *display, int64_t timeout)
{
	int64_t handle = display->channel;
	if (display->kept_count > 0)
		return 1;
	return fpos_syscall4(FPOS_CALL_WAIT_FOR_HANDLES, (long)&handle, 1, (long)timeout, 0) >= 0;
}

static inline void fpos_display_keep(struct fpos_display *display, const struct fpos_window_message *message)
{
	if (display->kept_count == FPOS_DISPLAY_KEPT_EVENTS) {
		display->kept_first = (display->kept_first + 1) % FPOS_DISPLAY_KEPT_EVENTS;
		display->kept_count--;
	}
	display->kept[(display->kept_first + display->kept_count) % FPOS_DISPLAY_KEPT_EVENTS] = *message;
	display->kept_count++;
}

/* The next event, kept or on the channel, without waiting: 1, or 0. */
static inline int fpos_display_next_event(struct fpos_display *display, struct fpos_window_message *message)
{
	if (display->kept_count > 0) {
		*message = display->kept[display->kept_first];
		display->kept_first = (display->kept_first + 1) % FPOS_DISPLAY_KEPT_EVENTS;
		display->kept_count--;
		return 1;
	}
	return fpos_display_receive(display, message);
}

/* The next message of a kind (a reply), waiting up to timeout
   milliseconds; what else comes meanwhile is kept. 1, or 0. */
static inline int fpos_display_wait_for(struct fpos_display *display, uint32_t kind, int64_t timeout,
					struct fpos_window_message *message)
{
	for (;;) {
		int64_t handle = display->channel;
		while (fpos_display_receive(display, message)) {
			if (message->kind == kind)
				return 1;
			fpos_display_keep(display, message);
		}
		if (display->broken)
			return 0;
		if (fpos_syscall4(FPOS_CALL_WAIT_FOR_HANDLES, (long)&handle, 1, (long)timeout, 0) < 0)
			return 0;
	}
}

/* Connects to the display server (waiting up to about five seconds for
   it to start). 0, or a negative error (-FPOS_ERROR_NOT_FOUND: there is
   no display server). */
static inline int fpos_display_connect(struct fpos_display *display)
{
	struct fpos_window_message message;
	int attempt;
	memset(display, 0, sizeof(*display));
	display->channel = -1;
	for (attempt = 0; attempt < 50; attempt++) {
		long channel = fpos_syscall1(FPOS_CALL_CONNECT_PORT, (long)FPOS_WINDOWING_PORT_NAME);
		if (channel >= 0) {
			display->channel = channel;
			break;
		}
		if (attempt == 49)
			return (int)channel;
		fpos_syscall1(FPOS_CALL_SLEEP, 100);
	}
	message = fpos_window_message_new(FPOS_REQUEST_HELLO, 0);
	message.value = FPOS_WINDOWING_PROTOCOL_VERSION;
	message.flags = FPOS_HELLO_ANSWERS_PINGS;
	fpos_display_send(display, &message, -1);
	if (!fpos_display_wait_for(display, FPOS_EVENT_WELCOME, 5000, &message)) {
		fpos_syscall1(FPOS_CALL_CLOSE, display->channel);
		display->channel = -1;
		return -FPOS_ERROR_TIMED_OUT;
	}
	display->screen_width = message.width;
	display->screen_height = message.height;
	display->dpi = (uint32_t)message.value;
	display->scale = message.code;
	return 0;
}

static inline void fpos_display_disconnect(struct fpos_display *display)
{
	if (display->channel >= 0)
		fpos_syscall1(FPOS_CALL_CLOSE, display->channel);
	display->channel = -1;
}

/* A new surface section of width x height pixels, mapped. 0, or a
   negative error. */
static inline int fpos_surface_create(int32_t width, int32_t height, int64_t *section, uint32_t **pixels)
{
	uint64_t length;
	long handle, address;
	if (width < 1)
		width = 1;
	if (height < 1)
		height = 1;
	length = ((uint64_t)width * (uint64_t)height * 4 + 4095) & ~(uint64_t)4095;
	handle = fpos_syscall1(FPOS_CALL_CREATE_SECTION, (long)length);
	if (handle < 0)
		return (int)handle;
	address = fpos_syscall3(FPOS_CALL_MAP_HANDLE, handle, 0, (long)length);
	if (address < 0) {
		fpos_syscall1(FPOS_CALL_CLOSE, handle);
		return (int)address;
	}
	*section = handle;
	*pixels = (uint32_t *)(uintptr_t)address;
	return 0;
}

static inline void fpos_surface_destroy(int64_t section, uint32_t *pixels)
{
	if (pixels)
		fpos_syscall1(FPOS_CALL_FREE_MEMORY, (long)pixels);
	if (section >= 0)
		fpos_syscall1(FPOS_CALL_CLOSE, section);
}

/* A window with a client area of width x height pixels at (left, top)
   in logical units, titled, with FPOS_WINDOW_* flags; hidden until
   fpos_window_show. 0, or a negative error. */
static inline int fpos_window_create(struct fpos_display *display, int32_t left, int32_t top, int32_t width,
				     int32_t height, const char *title, uint32_t flags, struct fpos_window *window)
{
	struct fpos_window_message message;
	int error;
	memset(window, 0, sizeof(*window));
	window->display = display;
	window->section = -1;
	error = fpos_surface_create(width, height, &window->section, &window->pixels);
	if (error < 0)
		return error;
	window->width = width;
	window->height = height;
	window->scale = display->scale;
	message = fpos_window_message_new(FPOS_REQUEST_CREATE_WINDOW, 0);
	message.left = left;
	message.top = top;
	message.surface_width = width;
	message.surface_height = height;
	message.flags = flags;
	fpos_window_message_set_text(&message, title);
	fpos_display_send(display, &message, window->section);
	if (!fpos_display_wait_for(display, FPOS_EVENT_WINDOW_CREATED, 5000, &message)) {
		fpos_surface_destroy(window->section, window->pixels);
		window->section = -1;
		window->pixels = 0;
		return -FPOS_ERROR_TIMED_OUT;
	}
	window->number = message.window;
	return 0;
}

static inline void fpos_window_show(struct fpos_window *window, int visible)
{
	struct fpos_window_message message = fpos_window_message_new(FPOS_REQUEST_SHOW_WINDOW, window->number);
	message.value = visible ? 1 : 0;
	fpos_display_send(window->display, &message, -1);
}

static inline void fpos_window_set_title(struct fpos_window *window, const char *title)
{
	struct fpos_window_message message = fpos_window_message_new(FPOS_REQUEST_SET_TITLE, window->number);
	fpos_window_message_set_text(&message, title);
	fpos_display_send(window->display, &message, -1);
}

/* Gives the window a new surface of width x height pixels (after
   EventResized or EventScaleChanged); the old one is unmapped. 0, or a
   negative error (the old surface then stays). */
static inline int fpos_window_set_surface(struct fpos_window *window, int32_t width, int32_t height)
{
	struct fpos_window_message message;
	int64_t section = -1;
	uint32_t *pixels = 0;
	int error = fpos_surface_create(width, height, &section, &pixels);
	if (error < 0)
		return error;
	message = fpos_window_message_new(FPOS_REQUEST_SET_SURFACE, window->number);
	message.surface_width = width;
	message.surface_height = height;
	fpos_display_send(window->display, &message, section);
	fpos_surface_destroy(window->section, window->pixels);
	window->section = section;
	window->pixels = pixels;
	window->width = width;
	window->height = height;
	return 0;
}

/* Tells the server what changed, in surface pixels. */
static inline void fpos_window_damage(struct fpos_window *window, int32_t left, int32_t top, int32_t width,
				      int32_t height)
{
	struct fpos_window_message message = fpos_window_message_new(FPOS_REQUEST_DAMAGE, window->number);
	message.left = left;
	message.top = top;
	message.width = width;
	message.height = height;
	fpos_display_send(window->display, &message, -1);
}

static inline void fpos_window_destroy(struct fpos_window *window)
{
	struct fpos_window_message message = fpos_window_message_new(FPOS_REQUEST_DESTROY_WINDOW, window->number);
	if (window->number)
		fpos_display_send(window->display, &message, -1);
	fpos_surface_destroy(window->section, window->pixels);
	window->section = -1;
	window->pixels = 0;
	window->number = 0;
}

#ifdef __cplusplus
}
#endif

#endif /* _FREEPASCALOS_WINDOWING_H */
