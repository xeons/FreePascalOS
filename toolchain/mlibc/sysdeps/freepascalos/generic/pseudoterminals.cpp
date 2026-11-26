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

// Pseudo-terminal masters: posix_openpt opens /dev/ptmx (mlibc does
// that itself), which gives the master side of a new pseudo-terminal as
// one descriptor; ptsname asks it for the terminal's number
// (ControlGetTerminalNumber: /dev/pts/N); grantpt and unlockpt have
// nothing to do (the terminal side is rw for everyone and never
// locked), so openpty and forkpty work through them too.

#include "kernel.hpp"
#include "pseudoterminals.hpp"

#include <errno.h>
#include <string.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

int terminal_number_of(int fd, unsigned int *number) {
	long result = call(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_GET_TERMINAL_NUMBER, 0);
	if (int e = error_of(result))
		return (e == EOPNOTSUPP || e == EINVAL) ? ENOTTY : e;
	*number = (unsigned int)result;
	return 0;
}

} // namespace fpos

namespace mlibc {

int Sysdeps<Ptsname>::operator()(int fd, char *buffer, size_t length) {
	unsigned int number;
	if (int e = fpos::terminal_number_of(fd, &number))
		return e;
	char digits[16];
	int count = 0;
	do {
		digits[count++] = (char)('0' + number % 10);
		number /= 10;
	} while (number);
	const char prefix[] = "/dev/pts/";
	size_t needed = sizeof(prefix) - 1 + count + 1;
	if (needed > length)
		return ERANGE;
	memcpy(buffer, prefix, sizeof(prefix) - 1);
	size_t position = sizeof(prefix) - 1;
	while (count)
		buffer[position++] = digits[--count];
	buffer[position] = '\0';
	return 0;
}

int Sysdeps<Unlockpt>::operator()(int fd) {
	unsigned int number;
	return fpos::terminal_number_of(fd, &number);
}

} // namespace mlibc
