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

// Helpers shared by the file sysdeps.

#pragma once

#include <freepascalos/syscall.h>
#include <sys/stat.h>
#include <sys/types.h>

namespace fpos {

void fill_stat(const struct fpos_file_information &information, struct stat *statbuf);
int stat_path(const char *path, bool follow_links, struct stat *statbuf);
int stat_handle(int fd, struct stat *statbuf);
int open_at(int dirfd, const char *path, int flags, mode_t mode, int *fd);

// The process's umask (the kernel keeps it with the credentials).
mode_t current_umask();

// path made absolute against the working directory.
int absolute_path_of(const char *path, char *buffer, size_t size);

// For a descriptor marked non-blocking that is a pipe or a terminal:
// EAGAIN if a read (or write) would wait now, else 0.
int wait_if_non_blocking(int fd, bool for_reading);

} // namespace fpos
