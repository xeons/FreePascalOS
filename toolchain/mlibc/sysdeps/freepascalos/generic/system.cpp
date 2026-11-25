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

// The system: uname, the host name, sysconf, random bytes, resource
// limits and usage.

#include "kernel.hpp"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/times.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

namespace {

int system_information(struct fpos_system_information *information) {
	return call_checked(FPOS_CALL_GET_SYSTEM_INFORMATION, information);
}

void copy_field(char *destination, size_t capacity, const char *source) {
	strncpy(destination, source, capacity - 1);
	destination[capacity - 1] = '\0';
}

long processor_count() {
	struct fpos_system_information information;
	if (system_information(&information) || !information.processor_count)
		return 1;
	return information.processor_count;
}

} // namespace

} // namespace fpos

namespace mlibc {

int Sysdeps<Uname>::operator()(struct utsname *buf) {
	struct fpos_system_information information;
	if (int e = fpos::system_information(&information))
		return e;
	memset(buf, 0, sizeof(*buf));
	fpos::copy_field(buf->sysname, sizeof(buf->sysname), information.system_name);
	fpos::copy_field(buf->nodename, sizeof(buf->nodename), information.node_name);
	fpos::copy_field(buf->release, sizeof(buf->release), information.release);
	fpos::copy_field(buf->version, sizeof(buf->version), information.version);
#if defined(__x86_64__)
	fpos::copy_field(buf->machine, sizeof(buf->machine), "x86_64");
#else
	fpos::copy_field(buf->machine, sizeof(buf->machine), "aarch64");
#endif
	return 0;
}

int Sysdeps<GetHostname>::operator()(char *buffer, size_t bufsize) {
	struct fpos_system_information information;
	if (int e = fpos::system_information(&information))
		return e;
	if (strlen(information.node_name) + 1 > bufsize)
		return ENAMETOOLONG;
	strcpy(buffer, information.node_name);
	return 0;
}

int Sysdeps<SetHostname>::operator()(const char *buffer, size_t bufsize) {
	char name[FPOS_TEXT_CAPACITY];
	if (bufsize >= sizeof(name))
		return EINVAL;
	memcpy(name, buffer, bufsize);
	name[bufsize] = '\0';
	return fpos::call_checked(FPOS_CALL_SET_NODE_NAME, name);
}

int Sysdeps<Sysconf>::operator()(int num, long *ret) {
	switch (num) {
		case _SC_PAGESIZE:
			*ret = 4096;
			return 0;
		case _SC_NPROCESSORS_CONF:
		case _SC_NPROCESSORS_ONLN:
			*ret = fpos::processor_count();
			return 0;
		case _SC_OPEN_MAX:
			*ret = 16384;
			return 0;
		case _SC_CHILD_MAX:
			*ret = 4096;
			return 0;
		case _SC_CLK_TCK:
			*ret = 100;
			return 0;
		case _SC_PHYS_PAGES: {
			struct fpos_system_information information;
			if (int e = fpos::system_information(&information))
				return e;
			*ret = (long)(information.total_memory / 4096);
			return 0;
		}
		case _SC_AVPHYS_PAGES: {
			struct fpos_system_information information;
			if (int e = fpos::system_information(&information))
				return e;
			*ret = (long)(information.free_memory / 4096);
			return 0;
		}
		case _SC_HOST_NAME_MAX:
			*ret = FPOS_TEXT_CAPACITY - 1;
			return 0;
		case _SC_LINE_MAX:
			*ret = 2048;
			return 0;
		case _SC_GETPW_R_SIZE_MAX:
		case _SC_GETGR_R_SIZE_MAX:
			*ret = 1024;
			return 0;
		default:
			return EINVAL;
	}
}

int Sysdeps<GetEntropy>::operator()(void *buffer, size_t length) {
	int fd;
	if (int e = sysdep<Open>("/dev/urandom", O_RDONLY, 0, &fd))
		return e;
	auto bytes = static_cast<char *>(buffer);
	size_t done = 0;
	int error = 0;
	while (done < length) {
		ssize_t count;
		error = sysdep<Read>(fd, bytes + done, length - done, &count);
		if (error)
			break;
		if (count <= 0) {
			error = EIO;
			break;
		}
		done += count;
	}
	sysdep<Close>(fd);
	return error;
}

int Sysdeps<GetRlimit>::operator()(int resource, struct rlimit *limit) {
	switch (resource) {
		case RLIMIT_NOFILE:
			limit->rlim_cur = 16384;
			limit->rlim_max = 65536;
			return 0;
		case RLIMIT_STACK:
			limit->rlim_cur = 8 * 1024 * 1024;
			limit->rlim_max = 8 * 1024 * 1024;
			return 0;
		case RLIMIT_NPROC:
			limit->rlim_cur = 4096;
			limit->rlim_max = 65536;
			return 0;
		default:
			limit->rlim_cur = RLIM_INFINITY;
			limit->rlim_max = RLIM_INFINITY;
			return 0;
	}
}

int Sysdeps<SetRlimit>::operator()(int resource, const struct rlimit *limit) {
	(void)resource;
	(void)limit;
	return 0;
}

int Sysdeps<GetRusage>::operator()(int scope, struct rusage *usage) {
	(void)scope;
	memset(usage, 0, sizeof(*usage));
	time_t secs;
	long nanos;
	if (sysdep<ClockGet>(CLOCK_PROCESS_CPUTIME_ID, &secs, &nanos) == 0) {
		usage->ru_utime.tv_sec = secs;
		usage->ru_utime.tv_usec = nanos / 1000;
	}
	return 0;
}

int Sysdeps<Times>::operator()(struct tms *tms, clock_t *out) {
	time_t secs;
	long nanos;
	if (int e = sysdep<ClockGet>(CLOCK_MONOTONIC, &secs, &nanos))
		return e;
	clock_t ticks = (clock_t)(secs * 100 + nanos / 10000000);
	if (tms) {
		memset(tms, 0, sizeof(*tms));
		tms->tms_utime = ticks;
	}
	*out = ticks;
	return 0;
}

} // namespace mlibc
