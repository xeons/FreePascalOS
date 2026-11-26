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

// inotify over the kernel's watch groups (calls 268-269), defined here
// rather than through mlibc's sysdeps (its inotify belongs to the linux
// option). A relative path is made absolute against the working
// directory by the kernel; the records read are struct inotify_event.

#include "kernel.hpp"
#include "event-descriptors.hpp"

#include <errno.h>
#include <fcntl.h>
#include <sys/inotify.h>

namespace {

int failed(int e) {
	errno = e;
	return -1;
}

} // namespace

extern "C" {

int inotify_init1(int flags) {
	if (flags & ~(IN_CLOEXEC | IN_NONBLOCK))
		return failed(EINVAL);
	long result = fpos::call(FPOS_CALL_CREATE_WATCH_GROUP, fpos::kernel_non_blocking(flags));
	if (int e = fpos::error_of(result))
		return failed(e);
	int fd = (int)result;
	fpos::remember_new_descriptor(fd, flags);
	return fd;
}

int inotify_init(void) {
	return inotify_init1(0);
}

int inotify_add_watch(int fd, const char *path, uint32_t mask) {
	if (!path)
		return failed(EFAULT);
	long result = fpos::call(FPOS_CALL_CHANGE_GROUP_WATCH, fd, FPOS_GROUP_WATCH_ADD, path, (unsigned long)mask);
	if (int e = fpos::error_of(result))
		return failed(e);
	return (int)result;
}

int inotify_rm_watch(int fd, int wd) {
	long result = fpos::call(FPOS_CALL_CHANGE_GROUP_WATCH, fd, FPOS_GROUP_WATCH_REMOVE, (long)wd, 0L);
	if (int e = fpos::error_of(result))
		return failed(e);
	return 0;
}

} // extern "C"
