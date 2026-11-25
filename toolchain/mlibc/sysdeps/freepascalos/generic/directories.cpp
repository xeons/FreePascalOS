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

// Names: reading directories, making and removing directories, files,
// links and FIFOs, renaming, and the volume a path is on (statvfs).

#include "kernel.hpp"
#include "files.hpp"
#include "descriptors.hpp"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

namespace {

unsigned char dirent_type_of(uint32_t kind) {
	switch (kind) {
		case FPOS_KIND_FILE: return DT_REG;
		case FPOS_KIND_DIRECTORY: return DT_DIR;
		case FPOS_KIND_SYMBOLIC_LINK: return DT_LNK;
		case FPOS_KIND_FIFO: return DT_FIFO;
		case FPOS_KIND_CHARACTER_DEVICE: return DT_CHR;
		case FPOS_KIND_BLOCK_DEVICE: return DT_BLK;
		default: return DT_UNKNOWN;
	}
}

// Room a struct dirent with this name takes, rounded to 8 bytes.
size_t record_length(size_t name_length) {
	size_t length = offsetof(struct dirent, d_name) + name_length + 1;
	return (length + 7) & ~size_t(7);
}

int resolve(int dirfd, const char *path, char *buffer) {
	return resolve_at(dirfd, path, buffer, PATH_MAX);
}

int lstat_resolved(const char *path, struct stat *status) {
	return stat_path(path, false, status);
}

} // namespace

} // namespace fpos

namespace mlibc {

int Sysdeps<OpenDir>::operator()(const char *path, int *handle) {
	return fpos::open_at(AT_FDCWD, path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0, handle);
}

int Sysdeps<ReadEntries>::operator()(int handle, void *buffer, size_t max_size, size_t *bytes_read) {
	auto bytes = static_cast<char *>(buffer);
	size_t used = 0;
	// Each call gives one entry; stop while any name would still fit.
	while (max_size - used >= fpos::record_length(FPOS_NAME_CAPACITY)) {
		struct fpos_directory_entry entry;
		long result = fpos::call(FPOS_CALL_READ_DIRECTORY, handle, &entry);
		if (int e = fpos::error_of(result)) {
			if (used)
				break;
			return e;
		}
		if (result == 0)
			break;
		size_t name_length = strnlen(entry.name, FPOS_NAME_CAPACITY - 1);
		auto record = reinterpret_cast<struct dirent *>(bytes + used);
		record->d_ino = entry.node_number ? entry.node_number : 1;
		record->d_reclen = (unsigned short)fpos::record_length(name_length);
		record->d_off = (off_t)(used + record->d_reclen);
		record->d_type = fpos::dirent_type_of(entry.kind);
		memcpy(record->d_name, entry.name, name_length);
		record->d_name[name_length] = '\0';
		used += record->d_reclen;
	}
	*bytes_read = used;
	return 0;
}

int Sysdeps<Mkdir>::operator()(const char *path, mode_t mode) {
	return Sysdeps<Mkdirat>::operator()(AT_FDCWD, path, mode);
}

int Sysdeps<Mkdirat>::operator()(int dirfd, const char *path, mode_t mode) {
	char resolved[PATH_MAX];
	if (int e = fpos::resolve(dirfd, path, resolved))
		return e;
	if (int e = fpos::call_checked(FPOS_CALL_CREATE_DIRECTORY, resolved))
		return e;
	struct fpos_attribute_changes changes = {};
	changes.fields = FPOS_CHANGE_MODE;
	changes.mode = mode & ~fpos::current_umask() & 07777;
	fpos::call(FPOS_CALL_SET_PATH_ATTRIBUTES, resolved, &changes, 1);
	return 0;
}

int Sysdeps<Rmdir>::operator()(const char *path) {
	return Sysdeps<Unlinkat>::operator()(AT_FDCWD, path, AT_REMOVEDIR);
}

int Sysdeps<Unlinkat>::operator()(int dirfd, const char *path, int flags) {
	char resolved[PATH_MAX];
	if (int e = fpos::resolve(dirfd, path, resolved))
		return e;
	struct stat status;
	if (int e = fpos::lstat_resolved(resolved, &status))
		return e;
	if (flags & AT_REMOVEDIR) {
		if (!S_ISDIR(status.st_mode))
			return ENOTDIR;
	} else if (S_ISDIR(status.st_mode)) {
		return EISDIR;
	}
	return fpos::call_checked(FPOS_CALL_REMOVE, resolved);
}

int Sysdeps<Rename>::operator()(const char *path, const char *new_path) {
	return Sysdeps<Renameat>::operator()(AT_FDCWD, path, AT_FDCWD, new_path);
}

int Sysdeps<Renameat>::operator()(int olddirfd, const char *old_path, int newdirfd, const char *new_path) {
	char source[PATH_MAX];
	char target[PATH_MAX];
	if (int e = fpos::resolve(olddirfd, old_path, source))
		return e;
	if (int e = fpos::resolve(newdirfd, new_path, target))
		return e;
	return fpos::call_checked(FPOS_CALL_RENAME, source, target);
}

int Sysdeps<Link>::operator()(const char *old_path, const char *new_path) {
	return Sysdeps<Linkat>::operator()(AT_FDCWD, old_path, AT_FDCWD, new_path, 0);
}

int Sysdeps<Linkat>::operator()(int olddirfd, const char *old_path, int newdirfd, const char *new_path,
		int flags) {
	(void)flags;
	char existing[PATH_MAX];
	char created[PATH_MAX];
	if (int e = fpos::resolve(olddirfd, old_path, existing))
		return e;
	if (int e = fpos::resolve(newdirfd, new_path, created))
		return e;
	return fpos::call_checked(FPOS_CALL_CREATE_HARD_LINK, existing, created);
}

int Sysdeps<Symlink>::operator()(const char *target_path, const char *link_path) {
	return Sysdeps<Symlinkat>::operator()(target_path, AT_FDCWD, link_path);
}

int Sysdeps<Symlinkat>::operator()(const char *target_path, int dirfd, const char *link_path) {
	char resolved[PATH_MAX];
	if (int e = fpos::resolve(dirfd, link_path, resolved))
		return e;
	return fpos::call_checked(FPOS_CALL_CREATE_SYMBOLIC_LINK, target_path, resolved);
}

int Sysdeps<Readlink>::operator()(const char *path, void *buffer, size_t max_size, ssize_t *length) {
	return Sysdeps<Readlinkat>::operator()(AT_FDCWD, path, buffer, max_size, length);
}

int Sysdeps<Readlinkat>::operator()(int dirfd, const char *path, void *buffer, size_t max_size,
		ssize_t *length) {
	char resolved[PATH_MAX];
	if (int e = fpos::resolve(dirfd, path, resolved))
		return e;
	char target[PATH_MAX];
	long result = fpos::call(FPOS_CALL_READ_SYMBOLIC_LINK, resolved, target, sizeof(target));
	if (int e = fpos::error_of(result))
		return e;
	size_t count = (size_t)result < max_size ? (size_t)result : max_size;
	memcpy(buffer, target, count);
	*length = (ssize_t)count;
	return 0;
}

int Sysdeps<Mkfifoat>::operator()(int dirfd, const char *path, mode_t mode) {
	char resolved[PATH_MAX];
	if (int e = fpos::resolve(dirfd, path, resolved))
		return e;
	if (int e = fpos::call_checked(FPOS_CALL_CREATE_FIFO, resolved))
		return e;
	struct fpos_attribute_changes changes = {};
	changes.fields = FPOS_CHANGE_MODE;
	changes.mode = mode & ~fpos::current_umask() & 07777;
	fpos::call(FPOS_CALL_SET_PATH_ATTRIBUTES, resolved, &changes, 1);
	return 0;
}

int Sysdeps<Statvfs>::operator()(const char *path, struct statvfs *out) {
	struct fpos_volume_information volume;
	if (int e = fpos::call_checked(FPOS_CALL_GET_VOLUME_INFORMATION, path, &volume))
		return e;
	memset(out, 0, sizeof(*out));
	out->f_bsize = 4096;
	out->f_frsize = 4096;
	out->f_blocks = volume.total_bytes / 4096;
	out->f_bfree = volume.free_bytes / 4096;
	out->f_bavail = volume.free_bytes / 4096;
	out->f_files = out->f_blocks;
	out->f_ffree = out->f_bfree;
	out->f_favail = out->f_bfree;
	out->f_namemax = FPOS_NAME_CAPACITY - 1;
	if (volume.is_read_only)
		out->f_flag |= ST_RDONLY;
	return 0;
}

int Sysdeps<Fstatvfs>::operator()(int fd, struct statvfs *out) {
	const char *path = fpos::descriptor_path(fd);
	char copy[PATH_MAX];
	strncpy(copy, path ? path : "/", sizeof(copy) - 1);
	copy[sizeof(copy) - 1] = '\0';
	return Sysdeps<Statvfs>::operator()(copy, out);
}

} // namespace mlibc
