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

#include "descriptors.hpp"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <mlibc/allocator.hpp>
#include <mlibc/lock.hpp>

namespace fpos {

namespace {

unsigned char flags_table[descriptor_limit];
char *path_table[descriptor_limit];
FutexLock path_lock;

bool in_range(int fd) {
	return fd >= 0 && fd < descriptor_limit;
}

char *copy_text(const char *text) {
	size_t length = strlen(text) + 1;
	auto copy = static_cast<char *>(getAllocator().allocate(length));
	if (copy)
		memcpy(copy, text, length);
	return copy;
}

void set_path_locked(int fd, char *path) {
	if (path_table[fd])
		getAllocator().free(path_table[fd]);
	path_table[fd] = path;
}

} // namespace

unsigned char descriptor_flags(int fd) {
	if (!in_range(fd))
		return 0;
	return __atomic_load_n(&flags_table[fd], __ATOMIC_RELAXED);
}

void set_descriptor_flags(int fd, unsigned char flags) {
	if (in_range(fd))
		__atomic_store_n(&flags_table[fd], flags, __ATOMIC_RELAXED);
}

void change_descriptor_flags(int fd, unsigned char set, unsigned char clear) {
	if (!in_range(fd))
		return;
	__atomic_fetch_or(&flags_table[fd], set, __ATOMIC_RELAXED);
	__atomic_fetch_and(&flags_table[fd], (unsigned char)~clear, __ATOMIC_RELAXED);
}

void forget_descriptor(int fd) {
	if (!in_range(fd))
		return;
	set_descriptor_flags(fd, 0);
	frg::unique_lock guard(path_lock);
	set_path_locked(fd, nullptr);
}

void copy_descriptor(int source, int fd) {
	if (!in_range(source) || !in_range(fd) || source == fd)
		return;
	set_descriptor_flags(fd, descriptor_flags(source) & ~descriptor_close_on_exec);
	frg::unique_lock guard(path_lock);
	set_path_locked(fd, path_table[source] ? copy_text(path_table[source]) : nullptr);
}

const char *descriptor_path(int fd) {
	if (!in_range(fd))
		return nullptr;
	frg::unique_lock guard(path_lock);
	return path_table[fd];
}

void remember_descriptor_path(int fd, const char *absolute_path) {
	if (!in_range(fd))
		return;
	char *copy = absolute_path ? copy_text(absolute_path) : nullptr;
	frg::unique_lock guard(path_lock);
	set_path_locked(fd, copy);
}

size_t close_on_exec_descriptors(int *list, size_t capacity) {
	size_t count = 0;
	for (int fd = 0; fd < descriptor_limit; fd++) {
		if (!(descriptor_flags(fd) & descriptor_close_on_exec))
			continue;
		if (count < capacity)
			list[count] = fd;
		count++;
	}
	return count;
}

int resolve_at(int dirfd, const char *path, char *buffer, size_t size) {
	size_t length = strlen(path);
	if (path[0] == '/' || dirfd == AT_FDCWD) {
		if (length + 1 > size)
			return ENAMETOOLONG;
		memcpy(buffer, path, length + 1);
		return 0;
	}
	frg::unique_lock guard(path_lock);
	if (!in_range(dirfd) || !path_table[dirfd])
		return EBADF;
	const char *directory = path_table[dirfd];
	size_t directory_length = strlen(directory);
	if (directory_length + 1 + length + 1 > size)
		return ENAMETOOLONG;
	memcpy(buffer, directory, directory_length);
	size_t position = directory_length;
	if (position == 0 || buffer[position - 1] != '/')
		buffer[position++] = '/';
	memcpy(buffer + position, path, length + 1);
	return 0;
}

} // namespace fpos
