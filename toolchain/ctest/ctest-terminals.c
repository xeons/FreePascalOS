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

/* Pseudo-terminals: posix_openpt gives the master as one descriptor
   (read and write), grantpt/unlockpt/ptsname name /dev/pts/N, the
   terminal side is a terminal (termios, window size), bytes go both
   ways, poll sees the master readable, closing the terminal side gives
   the master end of file; openpty does it all at once. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#include "ctest.h"

/* Reads from fd until count bytes came or a second passed. */
static ssize_t read_some(int fd, char *buffer, size_t count) {
	size_t total = 0;
	while (total < count) {
		struct pollfd waiting = {fd, POLLIN, 0};
		if (poll(&waiting, 1, 1000) != 1)
			break;
		ssize_t got = read(fd, buffer + total, count - total);
		if (got <= 0)
			break;
		total += (size_t)got;
	}
	return (ssize_t)total;
}

static void make_raw(int fd) {
	struct termios settings;
	tcgetattr(fd, &settings);
	settings.c_lflag &= ~(tcflag_t)(ICANON | ECHO | ISIG);
	tcsetattr(fd, TCSANOW, &settings);
}

static void test_openpt(void) {
	int master = posix_openpt(O_RDWR | O_NOCTTY);
	CHECK(master >= 0, "posix_openpt: %s", strerror(errno));
	if (master < 0)
		return;
	CHECK(grantpt(master) == 0 && unlockpt(master) == 0, "grantpt and unlockpt");
	char *name = ptsname(master);
	CHECK(name && strncmp(name, "/dev/pts/", 9) == 0, "ptsname: %s", name ? name : "(null)");
	unsigned int number = 9999;
	CHECK(ioctl(master, TIOCGPTN, &number) == 0 && name && (unsigned)atoi(name + 9) == number,
		"TIOCGPTN %u", number);
	int terminal = name ? open(name, O_RDWR | O_NOCTTY) : -1;
	CHECK(terminal >= 0, "open %s: %s", name ? name : "", strerror(errno));
	if (terminal < 0) {
		close(master);
		return;
	}
	CHECK(isatty(terminal) == 1, "the terminal side is a terminal");
	char terminal_name[64] = {0};
	CHECK(ttyname_r(terminal, terminal_name, sizeof(terminal_name)) == 0 && strcmp(terminal_name, name) == 0,
		"ttyname %s", terminal_name);
	struct winsize size = {40, 100, 0, 0};
	CHECK(ioctl(master, TIOCSWINSZ, &size) == 0, "TIOCSWINSZ on the master");
	struct winsize seen = {0, 0, 0, 0};
	CHECK(ioctl(terminal, TIOCGWINSZ, &seen) == 0 && seen.ws_row == 40 && seen.ws_col == 100,
		"window size seen on the terminal: %ux%u", seen.ws_row, seen.ws_col);
	make_raw(terminal);

	/* A program's output reaches the master... */
	CHECK(write(terminal, "output\n", 7) == 7, "write to the terminal");
	struct pollfd waiting = {master, POLLIN, 0};
	CHECK(poll(&waiting, 1, 2000) == 1 && (waiting.revents & POLLIN), "poll: the master is readable");
	char buffer[32] = {0};
	CHECK(read_some(master, buffer, 7) == 7 && memcmp(buffer, "output\n", 7) == 0, "the master reads it: %s",
		buffer);
	/* ...and what the master writes is typed into the terminal. */
	CHECK(write(master, "typed", 5) == 5, "write to the master (the same descriptor)");
	memset(buffer, 0, sizeof(buffer));
	CHECK(read_some(terminal, buffer, 5) == 5 && memcmp(buffer, "typed", 5) == 0, "the terminal reads it: %s",
		buffer);
	close(terminal);
	CHECK(read(master, buffer, sizeof(buffer)) == 0, "end of file once the terminal side is closed");
	close(master);
}

static void test_openpty(void) {
	int master = -1;
	int terminal = -1;
	char name[64] = {0};
	struct winsize size = {30, 90, 0, 0};
	CHECK(openpty(&master, &terminal, name, NULL, &size) == 0, "openpty: %s", strerror(errno));
	if (master < 0 || terminal < 0)
		return;
	CHECK(strncmp(name, "/dev/pts/", 9) == 0, "openpty's name %s", name);
	struct winsize seen = {0, 0, 0, 0};
	ioctl(terminal, TIOCGWINSZ, &seen);
	CHECK(seen.ws_row == 30 && seen.ws_col == 90, "openpty's window size %ux%u", seen.ws_row, seen.ws_col);
	/* In line editing mode a line comes whole, with its echo. */
	CHECK(write(master, "line\n", 5) == 5, "type a line");
	char buffer[32] = {0};
	CHECK(read_some(terminal, buffer, 5) == 5 && memcmp(buffer, "line\n", 5) == 0, "the edited line: %s", buffer);
	memset(buffer, 0, sizeof(buffer));
	CHECK(read_some(master, buffer, 4) >= 4 && memcmp(buffer, "line", 4) == 0, "its echo: %s", buffer);
	close(terminal);
	close(master);
}

void test_terminals(void) {
	test_openpt();
	test_openpty();
}
