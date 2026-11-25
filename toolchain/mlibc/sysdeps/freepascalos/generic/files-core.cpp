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

// The file calls the dynamic linker needs too: open, read, write, seek,
// close and stat. A descriptor is the kernel handle of the same number.

#include "kernel.hpp"
#include "files.hpp"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <mlibc/all-sysdeps.hpp>

#ifndef MLIBC_BUILDING_RTLD
#include "descriptors.hpp"
#endif

namespace fpos {

namespace {

constexpr size_t path_capacity = 4096;

unsigned long kernel_open_flags(int flags) {
	unsigned long result = 0;
	switch (flags & O_ACCMODE) {
		case O_WRONLY:
			result = FPOS_OPEN_WRITE;
			break;
		case O_RDWR:
			result = FPOS_OPEN_READ | FPOS_OPEN_WRITE;
			break;
		default:
			result = FPOS_OPEN_READ;
			break;
	}
	if (flags & O_CREAT)
		result |= FPOS_OPEN_CREATE;
	if (flags & O_EXCL)
		result |= FPOS_OPEN_EXCLUSIVE;
	if (flags & O_TRUNC)
		result |= FPOS_OPEN_TRUNCATE;
	if (flags & O_APPEND)
		result |= FPOS_OPEN_APPEND;
	return result;
}

// Opens a path (absolute, or relative to the working directory). A file
// O_CREAT makes gets mode less the umask: it is looked for first, and
// only made (exclusively) when it is not there.
int open_resolved(const char *path, int flags, mode_t mode, int *fd) {
	unsigned long kernel_flags = kernel_open_flags(flags);
	long handle;
	if ((flags & O_CREAT) && !(flags & O_EXCL)) {
		handle = call(FPOS_CALL_OPEN, path, kernel_flags & ~(unsigned long)FPOS_OPEN_CREATE);
		if (error_of(handle) != ENOENT) {
			if (int e = error_of(handle))
				return e;
			*fd = (int)handle;
			return 0;
		}
		kernel_flags |= FPOS_OPEN_EXCLUSIVE;
	}
	handle = call(FPOS_CALL_OPEN, path, kernel_flags);
	if (int e = error_of(handle))
		return e;
	*fd = (int)handle;
	if (flags & O_CREAT) {
		struct fpos_attribute_changes changes = {};
		changes.fields = FPOS_CHANGE_MODE;
		changes.mode = mode & ~current_umask() & 07777;
		call(FPOS_CALL_SET_HANDLE_ATTRIBUTES, *fd, &changes);
	}
	return 0;
}

mode_t type_bits_of(uint32_t kind) {
	switch (kind) {
		case FPOS_KIND_DIRECTORY: return S_IFDIR;
		case FPOS_KIND_SYMBOLIC_LINK: return S_IFLNK;
		case FPOS_KIND_FIFO: return S_IFIFO;
		case FPOS_KIND_CHARACTER_DEVICE: return S_IFCHR;
		case FPOS_KIND_BLOCK_DEVICE: return S_IFBLK;
		case FPOS_KIND_SOCKET: return S_IFSOCK;
		default: return S_IFREG;
	}
}

} // namespace

mode_t current_umask() {
	struct fpos_credentials credentials;
	if (error_of(call(FPOS_CALL_GET_CREDENTIALS, &credentials)))
		return 022;
	return credentials.umask & 0777;
}

int absolute_path_of(const char *path, char *buffer, size_t size) {
	size_t length = strlen(path);
	if (path[0] == '/') {
		if (length + 1 > size)
			return ENAMETOOLONG;
		memcpy(buffer, path, length + 1);
		return 0;
	}
	if (int e = call_checked(FPOS_CALL_GET_CURRENT_DIRECTORY, buffer, size))
		return e;
	size_t position = strlen(buffer);
	if (position + 1 + length + 1 > size)
		return ENAMETOOLONG;
	if (position == 0 || buffer[position - 1] != '/')
		buffer[position++] = '/';
	memcpy(buffer + position, path, length + 1);
	return 0;
}

void fill_stat(const struct fpos_file_information &information, struct stat *statbuf) {
	memset(statbuf, 0, sizeof(*statbuf));
	statbuf->st_dev = information.volume_number;
	statbuf->st_ino = information.node_number;
	statbuf->st_mode = type_bits_of(information.kind) | (information.mode & 07777);
	statbuf->st_nlink = information.link_count ? information.link_count : 1;
	statbuf->st_uid = information.owner_id;
	statbuf->st_gid = information.group_id;
	statbuf->st_size = information.size_in_bytes;
	statbuf->st_blksize = 4096;
	statbuf->st_blocks = (information.allocated_bytes + 511) / 512;
	statbuf->st_atim.tv_sec = information.access_time;
	statbuf->st_mtim.tv_sec = information.modification_time;
	statbuf->st_ctim.tv_sec = information.change_time;
}

// A handle that is no file (a pipe, a terminal, a socket): what fstat
// says of it.
int stat_of_handle_kind(int fd, struct stat *statbuf) {
	long kind = call(FPOS_CALL_GET_HANDLE_KIND, fd);
	if (int e = error_of(kind))
		return e;
	memset(statbuf, 0, sizeof(*statbuf));
	statbuf->st_nlink = 1;
	statbuf->st_blksize = 4096;
	switch (kind) {
		case FPOS_HANDLE_KIND_CONSOLE:
		case FPOS_HANDLE_KIND_NULL_DEVICE:
		case FPOS_HANDLE_KIND_DEVICE:
			statbuf->st_mode = S_IFCHR | 0620;
			break;
		case FPOS_HANDLE_KIND_PIPE:
			statbuf->st_mode = S_IFIFO | 0600;
			break;
		case FPOS_HANDLE_KIND_SOCKET:
			statbuf->st_mode = S_IFSOCK | 0600;
			break;
		default:
			statbuf->st_mode = S_IFREG | 0600;
			break;
	}
	statbuf->st_ino = fd;
	return 0;
}

// The times to the nanosecond (CallGetFileTimes), where the file
// system has them; the whole seconds stay otherwise.
void fill_precise_times(const struct fpos_file_times &times, struct stat *statbuf) {
	statbuf->st_atim.tv_sec = times.access.seconds;
	statbuf->st_atim.tv_nsec = times.access.nanoseconds;
	statbuf->st_mtim.tv_sec = times.modification.seconds;
	statbuf->st_mtim.tv_nsec = times.modification.nanoseconds;
	statbuf->st_ctim.tv_sec = times.change.seconds;
	statbuf->st_ctim.tv_nsec = times.change.nanoseconds;
}

constexpr long file_times_follow_links = 1;

int stat_path(const char *path, bool follow_links, struct stat *statbuf) {
	struct fpos_file_information information;
	if (int e = call_checked(FPOS_CALL_GET_PATH_INFORMATION, path, &information, follow_links ? 1 : 0))
		return e;
	fill_stat(information, statbuf);
	struct fpos_file_times times;
	if (!error_of(call(FPOS_CALL_GET_FILE_TIMES, path, -1, follow_links ? file_times_follow_links : 0, &times)))
		fill_precise_times(times, statbuf);
	return 0;
}

int stat_handle(int fd, struct stat *statbuf) {
	struct fpos_file_information information;
	long result = call(FPOS_CALL_GET_HANDLE_INFORMATION, fd, &information);
	if (error_of(result))
		return stat_of_handle_kind(fd, statbuf);
	fill_stat(information, statbuf);
	struct fpos_file_times times;
	if (!error_of(call(FPOS_CALL_GET_FILE_TIMES, 0, fd, 0, &times)))
		fill_precise_times(times, statbuf);
	return 0;
}

int open_at(int dirfd, const char *path, int flags, mode_t mode, int *fd) {
#ifdef MLIBC_BUILDING_RTLD
	(void)dirfd;
	return open_resolved(path, flags, mode, fd);
#else
	char resolved[path_capacity];
	if (int e = resolve_at(dirfd, path, resolved, sizeof(resolved)))
		return e;
	if (int e = open_resolved(resolved, flags, mode, fd))
		return e;
	struct fpos_file_information information;
	bool known = error_of(call(FPOS_CALL_GET_HANDLE_INFORMATION, *fd, &information)) == 0;
	bool is_directory = known && information.kind == FPOS_KIND_DIRECTORY;
	if ((flags & O_DIRECTORY) && known && !is_directory) {
		call(FPOS_CALL_CLOSE, *fd);
		return ENOTDIR;
	}
	forget_descriptor(*fd);
	unsigned char descriptor = 0;
	if (flags & O_CLOEXEC)
		descriptor |= descriptor_close_on_exec;
	if (flags & O_NONBLOCK)
		descriptor |= descriptor_non_blocking;
	set_descriptor_flags(*fd, descriptor);
	if (is_directory) {
		char absolute[path_capacity];
		if (absolute_path_of(resolved, absolute, sizeof(absolute)) == 0)
			remember_descriptor_path(*fd, absolute);
	}
	return 0;
#endif
}

} // namespace fpos

namespace mlibc {

int Sysdeps<Open>::operator()(const char *pathname, int flags, mode_t mode, int *fd) {
	return fpos::open_at(AT_FDCWD, pathname, flags, mode, fd);
}

int Sysdeps<Read>::operator()(int fd, void *buf, size_t count, ssize_t *bytes_read) {
#ifndef MLIBC_BUILDING_RTLD
	if (int e = fpos::wait_if_non_blocking(fd, true))
		return e;
#endif
	return fpos::call_into(bytes_read, FPOS_CALL_READ, fd, buf, count);
}

int Sysdeps<Write>::operator()(int fd, const void *buf, size_t count, ssize_t *bytes_written) {
	int e = fpos::call_into(bytes_written, FPOS_CALL_WRITE, fd, buf, count);
#ifndef MLIBC_BUILDING_RTLD
	// Writing to a pipe nobody reads raises SIGPIPE (which ends the
	// process unless it is ignored or handled), then fails with EPIPE.
	if (e == EPIPE)
		fpos::call(FPOS_CALL_SEND_SIGNAL, fpos::call(FPOS_CALL_GET_PROCESS_ID, -1), SIGPIPE);
#endif
	return e;
}

int Sysdeps<Seek>::operator()(int fd, off_t offset, int whence, off_t *new_offset) {
	if (whence < SEEK_SET || whence > SEEK_END)
		return EINVAL;
	return fpos::call_into(new_offset, FPOS_CALL_SEEK, fd, offset, whence);
}

int Sysdeps<Close>::operator()(int fd) {
#ifndef MLIBC_BUILDING_RTLD
	fpos::forget_descriptor(fd);
#endif
	return fpos::call_checked(FPOS_CALL_CLOSE, fd);
}

int Sysdeps<Stat>::operator()(fsfd_target fsfdt, int fd, const char *path, int flags,
		struct stat *statbuf) {
	bool follow = !(flags & AT_SYMLINK_NOFOLLOW);
	switch (fsfdt) {
		case fsfd_target::path:
			return fpos::stat_path(path, follow, statbuf);
		case fsfd_target::fd:
			return fpos::stat_handle(fd, statbuf);
		case fsfd_target::fd_path: {
			if (path[0] == '\0' && (flags & AT_EMPTY_PATH))
				return fpos::stat_handle(fd, statbuf);
#ifdef MLIBC_BUILDING_RTLD
			return fpos::stat_path(path, follow, statbuf);
#else
			char resolved[4096];
			if (int e = fpos::resolve_at(fd, path, resolved, sizeof(resolved)))
				return e;
			return fpos::stat_path(resolved, follow, statbuf);
#endif
		}
		default:
			return EINVAL;
	}
}

} // namespace mlibc
