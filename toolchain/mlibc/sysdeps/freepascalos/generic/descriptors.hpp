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

// What POSIX keeps per file descriptor that FreePascalOS handles do not
// carry: close-on-exec, non-blocking, the path a directory was opened
// with (for openat and friends) and whether the descriptor was opened
// for appending. A descriptor is the kernel handle of the same number.
// The table lives in the process's memory, so fork copies it and exec
// starts afresh, as POSIX wants.

#pragma once

#include <stddef.h>

namespace fpos {

constexpr int descriptor_limit = 16384;

constexpr unsigned char descriptor_close_on_exec = 0x01;
constexpr unsigned char descriptor_non_blocking = 0x02;

unsigned char descriptor_flags(int fd);
void set_descriptor_flags(int fd, unsigned char flags);
void change_descriptor_flags(int fd, unsigned char set, unsigned char clear);

// Forgets everything about fd (it was closed, or replaced by dup2).
void forget_descriptor(int fd);
// fd becomes a copy of source (dup): the same path, no close-on-exec.
void copy_descriptor(int source, int fd);

// The absolute path fd was opened with, or nullptr.
const char *descriptor_path(int fd);
void remember_descriptor_path(int fd, const char *absolute_path);

// Every descriptor marked close-on-exec, into list (at most capacity);
// returns how many there are.
size_t close_on_exec_descriptors(int *list, size_t capacity);

// Makes path absolute against dirfd (AT_FDCWD: the working directory)
// into buffer. Returns 0 or an errno.
int resolve_at(int dirfd, const char *path, char *buffer, size_t size);

} // namespace fpos
