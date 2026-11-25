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

// Descriptors: openat, positioned and vectored I/O, dup, fcntl, pipes,
// locks, access checks and the working directory.

#include "kernel.hpp"
#include "event-descriptors.hpp"
#include "files.hpp"
#include "descriptors.hpp"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>
#include <mlibc/all-sysdeps.hpp>
#include <mlibc/allocator.hpp>

namespace fpos {

int wait_if_non_blocking(int fd, bool for_reading) {
	(void)for_reading;
	if (!(descriptor_flags(fd) & descriptor_non_blocking))
		return 0;
	long kind = call(FPOS_CALL_GET_HANDLE_KIND, fd);
	if (kind != FPOS_HANDLE_KIND_PIPE && kind != FPOS_HANDLE_KIND_CONSOLE)
		return 0;
	int64_t handle = fd;
	long result = call(FPOS_CALL_WAIT_FOR_HANDLES, &handle, 1, 0, 0);
	if (error_of(result) == FPOS_ERROR_TIMED_OUT)
		return EAGAIN;
	return 0;
}

namespace {

bool is_socket(int fd) {
	return call(FPOS_CALL_GET_HANDLE_KIND, fd) == FPOS_HANDLE_KIND_SOCKET;
}

bool handle_is_open(int fd) {
	return error_of(call(FPOS_CALL_GET_HANDLE_KIND, fd)) == 0;
}

// The lowest closed descriptor at or above first.
int lowest_free_at_or_above(int first) {
	for (int candidate = first; candidate < descriptor_limit; candidate++) {
		if (!handle_is_open(candidate))
			return candidate;
	}
	return -1;
}

int duplicate_onto(int fd, int target, bool close_on_exec, int *newfd) {
	long result = call(FPOS_CALL_DUPLICATE_HANDLE, fd, target);
	if (int e = error_of(result))
		return e;
	*newfd = (int)result;
	if (*newfd != fd) {
		copy_descriptor(fd, *newfd);
		if (close_on_exec)
			change_descriptor_flags(*newfd, descriptor_close_on_exec, 0);
	}
	return 0;
}

int lock_whole_file(int fd, int kind, bool wait) {
	long argument = kind;
	if (!wait)
		argument |= FPOS_FILE_LOCK_NO_WAIT;
	long result = call(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_LOCK_FILE, argument);
	int e = error_of(result);
	return e == FPOS_ERROR_WOULD_BLOCK ? EWOULDBLOCK : e;
}

int unlock_whole_file(int fd) {
	return call_checked(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_UNLOCK_FILE, 0);
}

// fcntl record locks, taken on the whole file (what the kernel has).
int record_lock(int fd, int request, struct flock *lock) {
	if (request == F_GETLK) {
		lock->l_type = F_UNLCK;
		return 0;
	}
	bool wait = request == F_SETLKW;
	switch (lock->l_type) {
		case F_RDLCK:
			return lock_whole_file(fd, FPOS_FILE_LOCK_SHARED, wait);
		case F_WRLCK:
			return lock_whole_file(fd, FPOS_FILE_LOCK_EXCLUSIVE, wait);
		case F_UNLCK:
			return unlock_whole_file(fd);
		default:
			return EINVAL;
	}
}

int set_status_flags(int fd, int flags) {
	if (flags & O_NONBLOCK)
		change_descriptor_flags(fd, descriptor_non_blocking, 0);
	else
		change_descriptor_flags(fd, 0, descriptor_non_blocking);
	if (is_socket(fd))
		call(FPOS_CALL_SET_SOCKET_OPTION, fd, FPOS_SOCKET_OPTION_NON_BLOCKING, (flags & O_NONBLOCK) ? 1 : 0);
	else if (is_event_descriptor_kind(call(FPOS_CALL_GET_HANDLE_KIND, fd)))
		call(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_SET_NON_BLOCKING, (flags & O_NONBLOCK) ? 1 : 0);
	return 0;
}

int status_flags(int fd) {
	int flags = O_RDWR;
	if (descriptor_flags(fd) & descriptor_non_blocking)
		flags |= O_NONBLOCK;
	return flags;
}

bool may_access(const struct stat &status, int mode) {
	struct fpos_credentials credentials;
	if (error_of(call(FPOS_CALL_GET_CREDENTIALS, &credentials)))
		return true;
	if (credentials.real_user_id == 0) {
		if (mode & X_OK)
			return (status.st_mode & 0111) || S_ISDIR(status.st_mode);
		return true;
	}
	unsigned int shift = 0;
	if (credentials.real_user_id == status.st_uid) {
		shift = 6;
	} else {
		bool in_group = credentials.real_group_id == status.st_gid;
		for (uint32_t i = 0; i < credentials.group_count && !in_group; i++)
			in_group = credentials.groups[i] == status.st_gid;
		shift = in_group ? 3 : 0;
	}
	unsigned int allowed = (status.st_mode >> shift) & 7;
	if ((mode & R_OK) && !(allowed & 4))
		return false;
	if ((mode & W_OK) && !(allowed & 2))
		return false;
	if ((mode & X_OK) && !(allowed & 1))
		return false;
	return true;
}

int attributes_at(int dirfd, const char *path, int flags, struct fpos_attribute_changes *changes) {
	if (!path || (path[0] == '\0' && (flags & AT_EMPTY_PATH)))
		return call_checked(FPOS_CALL_SET_HANDLE_ATTRIBUTES, dirfd, changes);
	char resolved[PATH_MAX];
	if (int e = resolve_at(dirfd, path, resolved, sizeof(resolved)))
		return e;
	long follow = (flags & AT_SYMLINK_NOFOLLOW) ? 0 : 1;
	return call_checked(FPOS_CALL_SET_PATH_ATTRIBUTES, resolved, changes, follow);
}

} // namespace

} // namespace fpos

namespace mlibc {

int Sysdeps<Openat>::operator()(int dirfd, const char *path, int flags, mode_t mode, int *fd) {
	return fpos::open_at(dirfd, path, flags, mode, fd);
}

int Sysdeps<Pread>::operator()(int fd, void *buf, size_t n, off_t off, ssize_t *bytes_read) {
	long position = fpos::call(FPOS_CALL_SEEK, fd, 0, SEEK_CUR);
	if (int e = fpos::error_of(position))
		return e;
	if (int e = fpos::call_checked(FPOS_CALL_SEEK, fd, off, SEEK_SET))
		return e;
	int e = fpos::call_into(bytes_read, FPOS_CALL_READ, fd, buf, n);
	fpos::call(FPOS_CALL_SEEK, fd, position, SEEK_SET);
	return e;
}

int Sysdeps<Pwrite>::operator()(int fd, const void *buf, size_t n, off_t off, ssize_t *bytes_written) {
	long position = fpos::call(FPOS_CALL_SEEK, fd, 0, SEEK_CUR);
	if (int e = fpos::error_of(position))
		return e;
	if (int e = fpos::call_checked(FPOS_CALL_SEEK, fd, off, SEEK_SET))
		return e;
	int e = fpos::call_into(bytes_written, FPOS_CALL_WRITE, fd, buf, n);
	fpos::call(FPOS_CALL_SEEK, fd, position, SEEK_SET);
	return e;
}

int Sysdeps<Readv>::operator()(int fd, const struct iovec *iovs, int iovc, ssize_t *bytes_read) {
	ssize_t total = 0;
	for (int i = 0; i < iovc; i++) {
		if (!iovs[i].iov_len)
			continue;
		ssize_t count;
		if (int e = Sysdeps<Read>::operator()(fd, iovs[i].iov_base, iovs[i].iov_len, &count)) {
			if (total)
				break;
			return e;
		}
		total += count;
		if ((size_t)count < iovs[i].iov_len)
			break;
	}
	*bytes_read = total;
	return 0;
}

int Sysdeps<Writev>::operator()(int fd, const struct iovec *iovs, int iovc, ssize_t *bytes_written) {
	ssize_t total = 0;
	for (int i = 0; i < iovc; i++) {
		if (!iovs[i].iov_len)
			continue;
		ssize_t count;
		if (int e = Sysdeps<Write>::operator()(fd, iovs[i].iov_base, iovs[i].iov_len, &count)) {
			if (total)
				break;
			return e;
		}
		total += count;
		if ((size_t)count < iovs[i].iov_len)
			break;
	}
	*bytes_written = total;
	return 0;
}

int Sysdeps<Dup>::operator()(int fd, int flags, int *newfd) {
	return fpos::duplicate_onto(fd, -1, flags & O_CLOEXEC, newfd);
}

int Sysdeps<Dup2>::operator()(int fd, int flags, int newfd) {
	if (fd == newfd)
		return fpos::handle_is_open(fd) ? 0 : EBADF;
	int result;
	return fpos::duplicate_onto(fd, newfd, flags & O_CLOEXEC, &result);
}

int Sysdeps<Fcntl>::operator()(int fd, int request, va_list args, int *result) {
	switch (request) {
		case F_DUPFD:
		case F_DUPFD_CLOEXEC: {
			int first = va_arg(args, int);
			int target = fpos::lowest_free_at_or_above(first < 0 ? 0 : first);
			if (target < 0)
				return EMFILE;
			return fpos::duplicate_onto(fd, target, request == F_DUPFD_CLOEXEC, result);
		}
		case F_GETFD:
			if (!fpos::handle_is_open(fd))
				return EBADF;
			*result = (fpos::descriptor_flags(fd) & fpos::descriptor_close_on_exec) ? FD_CLOEXEC : 0;
			return 0;
		case F_SETFD:
			if (!fpos::handle_is_open(fd))
				return EBADF;
			if (va_arg(args, int) & FD_CLOEXEC)
				fpos::change_descriptor_flags(fd, fpos::descriptor_close_on_exec, 0);
			else
				fpos::change_descriptor_flags(fd, 0, fpos::descriptor_close_on_exec);
			*result = 0;
			return 0;
		case F_GETFL:
			if (!fpos::handle_is_open(fd))
				return EBADF;
			*result = fpos::status_flags(fd);
			return 0;
		case F_SETFL:
			if (!fpos::handle_is_open(fd))
				return EBADF;
			*result = 0;
			return fpos::set_status_flags(fd, va_arg(args, int));
		case F_GETLK:
		case F_SETLK:
		case F_SETLKW:
			*result = 0;
			return fpos::record_lock(fd, request, va_arg(args, struct flock *));
		default:
			return EINVAL;
	}
}

int Sysdeps<Pipe>::operator()(int *fds, int flags) {
	int64_t handles[2];
	if (int e = fpos::call_checked(FPOS_CALL_CREATE_PIPE, handles))
		return e;
	unsigned char descriptor = 0;
	if (flags & O_CLOEXEC)
		descriptor |= fpos::descriptor_close_on_exec;
	if (flags & O_NONBLOCK)
		descriptor |= fpos::descriptor_non_blocking;
	for (int i = 0; i < 2; i++) {
		fds[i] = (int)handles[i];
		fpos::forget_descriptor(fds[i]);
		fpos::set_descriptor_flags(fds[i], descriptor);
	}
	return 0;
}

int Sysdeps<Access>::operator()(const char *path, int mode) {
	return Sysdeps<Faccessat>::operator()(AT_FDCWD, path, mode, 0);
}

int Sysdeps<Faccessat>::operator()(int dirfd, const char *pathname, int mode, int flags) {
	struct stat status;
	if (int e = Sysdeps<Stat>::operator()(fsfd_target::fd_path, dirfd, pathname,
			flags & (AT_SYMLINK_NOFOLLOW | AT_EMPTY_PATH), &status))
		return e;
	if (mode == F_OK)
		return 0;
	return fpos::may_access(status, mode) ? 0 : EACCES;
}

int Sysdeps<Ftruncate>::operator()(int fd, size_t size) {
	return fpos::call_checked(FPOS_CALL_SET_FILE_SIZE, fd, size);
}

int Sysdeps<Truncate>::operator()(const char *path, off_t length) {
	int fd;
	if (int e = fpos::open_at(AT_FDCWD, path, O_WRONLY, 0, &fd))
		return e;
	int e = fpos::call_checked(FPOS_CALL_SET_FILE_SIZE, fd, length);
	Sysdeps<Close>::operator()(fd);
	return e;
}

int Sysdeps<Fsync>::operator()(int fd) {
	if (!fpos::handle_is_open(fd))
		return EBADF;
	return fpos::call_checked(FPOS_CALL_SYNC);
}

int Sysdeps<Fdatasync>::operator()(int fd) {
	return Sysdeps<Fsync>::operator()(fd);
}

void Sysdeps<Sync>::operator()() {
	fpos::call(FPOS_CALL_SYNC);
}

int Sysdeps<Flock>::operator()(int fd, int options) {
	bool wait = !(options & LOCK_NB);
	switch (options & ~LOCK_NB) {
		case LOCK_SH:
			return fpos::lock_whole_file(fd, FPOS_FILE_LOCK_SHARED, wait);
		case LOCK_EX:
			return fpos::lock_whole_file(fd, FPOS_FILE_LOCK_EXCLUSIVE, wait);
		case LOCK_UN:
			return fpos::unlock_whole_file(fd);
		default:
			return EINVAL;
	}
}

int Sysdeps<Umask>::operator()(mode_t mode, mode_t *old) {
	return fpos::call_into(old, FPOS_CALL_SET_UMASK, mode & 0777);
}

int Sysdeps<GetCwd>::operator()(char *buffer, size_t size) {
	long result = fpos::call(FPOS_CALL_GET_CURRENT_DIRECTORY, buffer, size);
	int e = fpos::error_of(result);
	return e == ENAMETOOLONG ? ERANGE : e;
}

int Sysdeps<Chdir>::operator()(const char *path) {
	return fpos::call_checked(FPOS_CALL_SET_CURRENT_DIRECTORY, path);
}

int Sysdeps<Fchdir>::operator()(int fd) {
	const char *path = fpos::descriptor_path(fd);
	if (!path)
		return fpos::handle_is_open(fd) ? ENOTDIR : EBADF;
	char copy[PATH_MAX];
	strncpy(copy, path, sizeof(copy) - 1);
	copy[sizeof(copy) - 1] = '\0';
	return fpos::call_checked(FPOS_CALL_SET_CURRENT_DIRECTORY, copy);
}

int Sysdeps<Chroot>::operator()(const char *path) {
	return fpos::call_checked(FPOS_CALL_SET_ROOT_DIRECTORY, path);
}

int Sysdeps<FdToPath>::operator()(int fd, char **out) {
	const char *path = fpos::descriptor_path(fd);
	if (!path)
		return EBADF;
	size_t length = strlen(path) + 1;
	*out = static_cast<char *>(getAllocator().allocate(length));
	if (!*out)
		return ENOMEM;
	memcpy(*out, path, length);
	return 0;
}

int Sysdeps<Chmod>::operator()(const char *pathname, mode_t mode) {
	return Sysdeps<Fchmodat>::operator()(AT_FDCWD, pathname, mode, 0);
}

int Sysdeps<Fchmod>::operator()(int fd, mode_t mode) {
	struct fpos_attribute_changes changes = {};
	changes.fields = FPOS_CHANGE_MODE;
	changes.mode = mode & 07777;
	return fpos::call_checked(FPOS_CALL_SET_HANDLE_ATTRIBUTES, fd, &changes);
}

int Sysdeps<Fchmodat>::operator()(int fd, const char *pathname, mode_t mode, int flags) {
	struct fpos_attribute_changes changes = {};
	changes.fields = FPOS_CHANGE_MODE;
	changes.mode = mode & 07777;
	return fpos::attributes_at(fd, pathname, flags, &changes);
}

int Sysdeps<Fchownat>::operator()(int dirfd, const char *pathname, uid_t owner, gid_t group, int flags) {
	struct fpos_attribute_changes changes = {};
	if (owner != (uid_t)-1) {
		changes.fields |= FPOS_CHANGE_OWNER;
		changes.owner_id = owner;
	}
	if (group != (gid_t)-1) {
		changes.fields |= FPOS_CHANGE_GROUP;
		changes.group_id = group;
	}
	if (!changes.fields)
		return 0;
	return fpos::attributes_at(dirfd, pathname, flags, &changes);
}

int Sysdeps<Utimensat>::operator()(int dirfd, const char *pathname, const struct timespec times[2],
		int flags) {
	struct fpos_attribute_changes changes = {};
	if (!times) {
		changes.fields = FPOS_CHANGE_ACCESS_TIME | FPOS_CHANGE_MODIFICATION_TIME | FPOS_CHANGE_TIMES_ARE_NOW;
	} else {
		bool now = false;
		if (times[0].tv_nsec != UTIME_OMIT) {
			changes.fields |= FPOS_CHANGE_ACCESS_TIME;
			changes.access_time = times[0].tv_sec;
			now = now || times[0].tv_nsec == UTIME_NOW;
		}
		if (times[1].tv_nsec != UTIME_OMIT) {
			changes.fields |= FPOS_CHANGE_MODIFICATION_TIME;
			changes.modification_time = times[1].tv_sec;
			now = now || times[1].tv_nsec == UTIME_NOW;
		}
		if (now)
			changes.fields |= FPOS_CHANGE_TIMES_ARE_NOW;
		if (!changes.fields)
			return 0;
	}
	return fpos::attributes_at(dirfd, pathname, pathname ? flags : (flags | AT_EMPTY_PATH), &changes);
}

int Sysdeps<Isatty>::operator()(int fd) {
	long kind = fpos::call(FPOS_CALL_GET_HANDLE_KIND, fd);
	if (int e = fpos::error_of(kind))
		return e;
	return kind == FPOS_HANDLE_KIND_CONSOLE ? 0 : ENOTTY;
}

int Sysdeps<Ttyname>::operator()(int fd, char *buf, size_t size) {
	if (int e = Sysdeps<Isatty>::operator()(fd))
		return e;
	long number = fpos::call(FPOS_CALL_CONTROL_HANDLE, fd, FPOS_CONTROL_GET_TERMINAL_NUMBER, 0);
	char name[32];
	if (fpos::error_of(number)) {
		strcpy(name, "/dev/console");
	} else {
		char digits[24];
		int count = 0;
		unsigned long value = (unsigned long)number;
		do {
			digits[count++] = (char)('0' + value % 10);
			value /= 10;
		} while (value);
		strcpy(name, "/dev/pts");
		size_t position = strlen(name);
		while (count)
			name[position++] = digits[--count];
		name[position] = '\0';
	}
	if (strlen(name) + 1 > size)
		return ERANGE;
	strcpy(buf, name);
	return 0;
}

} // namespace mlibc
