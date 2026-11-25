// FreePascalOS
// Copyright (C) 2026 Brandon Scott
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Terminals: termios and the common ioctls over the console's modes
// (echo, line editing, Ctrl-C), its size and its foreground group. The
// kernel's terminal has three switches; ECHO, ICANON and ISIG map onto
// them and the rest of a struct termios is kept here, so a program gets
// back what it set.

#include "kernel.hpp"
#include "descriptors.hpp"

#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#include <abi-bits/ioctls.h>
#include <termios.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

namespace {

struct termios saved_settings;
bool have_saved_settings = false;

void default_settings(struct termios *attr) {
	memset(attr, 0, sizeof(*attr));
	attr->c_iflag = ICRNL | IXON;
	attr->c_oflag = OPOST | ONLCR;
	attr->c_cflag = CS8 | CREAD | B38400;
	attr->c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | IEXTEN;
	attr->c_cc[VINTR] = 3;
	attr->c_cc[VQUIT] = 28;
	attr->c_cc[VERASE] = 127;
	attr->c_cc[VKILL] = 21;
	attr->c_cc[VEOF] = 4;
	attr->c_cc[VTIME] = 0;
	attr->c_cc[VMIN] = 1;
	attr->c_cc[VSTART] = 17;
	attr->c_cc[VSTOP] = 19;
	attr->c_cc[VSUSP] = 26;
}

int ensure_terminal(int fd) {
	long kind = call(FPOS_CALL_GET_HANDLE_KIND, fd);
	if (int e = error_of(kind))
		return e;
	return kind == FPOS_HANDLE_KIND_CONSOLE ? 0 : ENOTTY;
}

int window_size(int fd, struct winsize *size) {
	long result = call(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_GET_CONSOLE_SIZE, 0);
	if (int e = error_of(result))
		return e == EOPNOTSUPP ? ENOTTY : e;
	memset(size, 0, sizeof(*size));
	size->ws_row = (unsigned short)((result >> 16) & 0xFFFF);
	size->ws_col = (unsigned short)(result & 0xFFFF);
	return 0;
}

} // namespace

} // namespace fpos

namespace mlibc {

int Sysdeps<Tcgetattr>::operator()(int fd, struct termios *attr) {
	if (int e = fpos::ensure_terminal(fd))
		return e;
	long mode = fpos::call(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_GET_CONSOLE_MODE, 0);
	if (int e = fpos::error_of(mode))
		return e;
	if (fpos::have_saved_settings)
		*attr = fpos::saved_settings;
	else
		fpos::default_settings(attr);
	attr->c_lflag &= ~(tcflag_t)(ECHO | ICANON | ISIG);
	if (mode & FPOS_CONSOLE_MODE_ECHO)
		attr->c_lflag |= ECHO;
	if (mode & FPOS_CONSOLE_MODE_LINE_EDITING)
		attr->c_lflag |= ICANON;
	if (mode & FPOS_CONSOLE_MODE_INTERRUPT_KEY)
		attr->c_lflag |= ISIG;
	return 0;
}

int Sysdeps<Tcsetattr>::operator()(int fd, int optional_action, const struct termios *attr) {
	(void)optional_action;
	if (int e = fpos::ensure_terminal(fd))
		return e;
	long mode = 0;
	if (attr->c_lflag & ECHO)
		mode |= FPOS_CONSOLE_MODE_ECHO;
	if (attr->c_lflag & ICANON)
		mode |= FPOS_CONSOLE_MODE_LINE_EDITING;
	if (attr->c_lflag & ISIG)
		mode |= FPOS_CONSOLE_MODE_INTERRUPT_KEY;
	if (int e = fpos::call_checked(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_SET_CONSOLE_MODE, mode))
		return e;
	fpos::saved_settings = *attr;
	fpos::have_saved_settings = true;
	return 0;
}

int Sysdeps<Tcflush>::operator()(int fd, int queue) {
	(void)queue;
	return fpos::ensure_terminal(fd);
}

int Sysdeps<Tcdrain>::operator()(int fd) {
	return fpos::ensure_terminal(fd);
}

int Sysdeps<Tcflow>::operator()(int fd, int action) {
	(void)action;
	return fpos::ensure_terminal(fd);
}

int Sysdeps<Tcsendbreak>::operator()(int fd, int duration) {
	(void)duration;
	return fpos::ensure_terminal(fd);
}

int Sysdeps<Tcgetwinsize>::operator()(int fd, struct winsize *winsz) {
	return fpos::window_size(fd, winsz);
}

int Sysdeps<Tcsetwinsize>::operator()(int fd, const struct winsize *winsz) {
	long size = ((long)winsz->ws_row << 16) | winsz->ws_col;
	return fpos::call_checked(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_SET_CONSOLE_SIZE, size);
}

int Sysdeps<Ioctl>::operator()(int fd, unsigned long request, void *arg, int *result) {
	*result = 0;
	switch (request) {
		case TCGETS:
			return Sysdeps<Tcgetattr>::operator()(fd, static_cast<struct termios *>(arg));
		case TCSETS:
		case TCSETSW:
		case TCSETSF:
			return Sysdeps<Tcsetattr>::operator()(fd, TCSANOW, static_cast<const struct termios *>(arg));
		case TIOCGWINSZ:
			return fpos::window_size(fd, static_cast<struct winsize *>(arg));
		case TIOCSWINSZ:
			return Sysdeps<Tcsetwinsize>::operator()(fd, static_cast<const struct winsize *>(arg));
		case TIOCGPGRP: {
			long group = fpos::call(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_GET_FOREGROUND_GROUP, 0);
			if (int e = fpos::error_of(group))
				return e == EOPNOTSUPP ? ENOTTY : e;
			*static_cast<pid_t *>(arg) = (pid_t)group;
			return 0;
		}
		case TIOCSPGRP: {
			long group = *static_cast<const pid_t *>(arg);
			long r = fpos::call(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_SET_FOREGROUND_GROUP, group);
			int e = fpos::error_of(r);
			return e == EOPNOTSUPP ? ENOTTY : e;
		}
		case FIONBIO: {
			int on = *static_cast<const int *>(arg);
			if (on)
				fpos::change_descriptor_flags(fd, fpos::descriptor_non_blocking, 0);
			else
				fpos::change_descriptor_flags(fd, 0, fpos::descriptor_non_blocking);
			if (fpos::call(FPOS_CALL_GET_HANDLE_KIND, fd) == FPOS_HANDLE_KIND_SOCKET)
				fpos::call(FPOS_CALL_SET_SOCKET_OPTION, fd, FPOS_SOCKET_OPTION_NON_BLOCKING, on ? 1 : 0);
			return 0;
		}
		case FIONREAD: {
			if (fpos::call(FPOS_CALL_GET_HANDLE_KIND, fd) == FPOS_HANDLE_KIND_SOCKET) {
				long bytes = fpos::call(FPOS_CALL_GET_SOCKET_OPTION, fd, FPOS_SOCKET_OPTION_READABLE_BYTES);
				if (int e = fpos::error_of(bytes))
					return e;
				*static_cast<int *>(arg) = (int)bytes;
				return 0;
			}
			*static_cast<int *>(arg) = 0;
			return 0;
		}
		case TIOCSCTTY:
		case TIOCNOTTY:
			return fpos::ensure_terminal(fd);
		default:
			return EINVAL;
	}
}

} // namespace mlibc
