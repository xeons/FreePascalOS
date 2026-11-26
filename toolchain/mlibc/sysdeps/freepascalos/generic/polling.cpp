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

// poll and select over CallWaitForHandles (pipes, terminals, sockets
// becoming readable, pipe write ends with room, event descriptors
// becoming readable) and CallWaitForSocket (sockets becoming writable);
// event descriptors (eventfd, timerfd, signalfd, epoll, inotify) say
// what they are ready for through CallQueryHandleReadiness. Files are always ready. A wait for what
// CallWaitForHandles cannot wait for (a socket's room to write) looks
// again every few milliseconds.

#include "kernel.hpp"

#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

namespace {

constexpr int maximum_wait_handles = 64;
constexpr long recheck_milliseconds = 10;

bool handle_signaled_now(int fd) {
	int64_t handle = fd;
	return call(FPOS_CALL_WAIT_FOR_HANDLES, &handle, 1, 0, 0) == 0;
}

// What of the requested events holds for fd now.
short ready_events(int fd, short requested, bool *waitable, bool *needs_recheck) {
	*waitable = false;
	if (fd < 0)
		return 0;
	long kind = call(FPOS_CALL_GET_HANDLE_KIND, fd);
	if (error_of(kind))
		return POLLNVAL;
	switch (kind) {
		case FPOS_HANDLE_KIND_FILE:
		case FPOS_HANDLE_KIND_NULL_DEVICE:
			return requested & (POLLIN | POLLOUT | POLLRDNORM | POLLWRNORM);
		case FPOS_HANDLE_KIND_SOCKET: {
			long conditions = 0;
			if (requested & (POLLIN | POLLRDNORM))
				conditions |= FPOS_SOCKET_READABLE;
			if (requested & (POLLOUT | POLLWRNORM))
				conditions |= FPOS_SOCKET_WRITABLE;
			long held = call(FPOS_CALL_WAIT_FOR_SOCKET, fd, conditions, 0);
			short result = 0;
			if (!error_of(held)) {
				if (held & FPOS_SOCKET_READABLE)
					result |= requested & (POLLIN | POLLRDNORM);
				if (held & FPOS_SOCKET_WRITABLE)
					result |= requested & (POLLOUT | POLLWRNORM);
			}
			*waitable = (requested & (POLLIN | POLLRDNORM)) != 0;
			if (requested & (POLLOUT | POLLWRNORM))
				*needs_recheck = true;
			return result;
		}
		case FPOS_HANDLE_KIND_EVENT_COUNTER:
		case FPOS_HANDLE_KIND_TIMER_DESCRIPTOR:
		case FPOS_HANDLE_KIND_SIGNAL_DESCRIPTOR:
		case FPOS_HANDLE_KIND_EVENT_POLL:
		case FPOS_HANDLE_KIND_WATCH_GROUP: {
			// The kernel says what they are ready for; waiting on the
			// handle waits until one is readable.
			long readiness = call(FPOS_CALL_QUERY_HANDLE_READINESS, fd);
			short result = 0;
			if (!error_of(readiness)) {
				if (readiness & POLLIN)
					result |= requested & (POLLIN | POLLRDNORM);
				if (readiness & POLLOUT)
					result |= requested & (POLLOUT | POLLWRNORM);
				result |= readiness & (POLLERR | POLLHUP);
			}
			*waitable = (requested & (POLLIN | POLLRDNORM)) != 0;
			if ((requested & (POLLOUT | POLLWRNORM)) && !(result & POLLOUT))
				*needs_recheck = true;
			return result;
		}
		default: {
			*waitable = true;
			if (!handle_signaled_now(fd))
				return 0;
			if (requested & (POLLIN | POLLRDNORM))
				return requested & (POLLIN | POLLRDNORM);
			return requested & (POLLOUT | POLLWRNORM);
		}
	}
}

int scan(struct pollfd *fds, nfds_t count, int64_t *handles, int *handle_count, bool *needs_recheck) {
	int ready = 0;
	*handle_count = 0;
	*needs_recheck = false;
	for (nfds_t i = 0; i < count; i++) {
		bool waitable;
		fds[i].revents = ready_events(fds[i].fd, fds[i].events, &waitable, needs_recheck);
		if (fds[i].revents)
			ready++;
		else if (waitable && *handle_count < maximum_wait_handles)
			handles[(*handle_count)++] = fds[i].fd;
		else if (fds[i].fd >= 0)
			*needs_recheck = true;
	}
	return ready;
}

long now_milliseconds() {
	struct fpos_precise_time now;
	call(FPOS_CALL_GET_PRECISE_TIME, FPOS_TIME_UPTIME_NANOSECONDS, &now);
	return (long)(now.seconds * 1000 + now.nanoseconds / 1000000);
}

} // namespace

int poll_descriptors(struct pollfd *fds, nfds_t count, long timeout, int *num_events) {
	long deadline = timeout < 0 ? -1 : now_milliseconds() + timeout;
	int64_t handles[maximum_wait_handles];
	while (true) {
		int handle_count;
		bool needs_recheck;
		int ready = scan(fds, count, handles, &handle_count, &needs_recheck);
		if (ready || timeout == 0) {
			*num_events = ready;
			return 0;
		}
		long remaining = -1;
		if (deadline >= 0) {
			remaining = deadline - now_milliseconds();
			if (remaining <= 0) {
				*num_events = 0;
				return 0;
			}
		}
		long slice = remaining;
		if (needs_recheck && (slice < 0 || slice > recheck_milliseconds))
			slice = recheck_milliseconds;
		long result;
		if (handle_count)
			result = call(FPOS_CALL_WAIT_FOR_HANDLES, handles, handle_count, slice, 0);
		else
			result = call(FPOS_CALL_SLEEP, slice < 0 ? 1000 : slice);
		int e = error_of(result);
		if (e && e != FPOS_ERROR_TIMED_OUT)
			return e;
	}
}

} // namespace fpos

namespace mlibc {

int Sysdeps<Poll>::operator()(struct pollfd *fds, nfds_t count, int timeout, int *num_events) {
	return fpos::poll_descriptors(fds, count, timeout, num_events);
}

int Sysdeps<Ppoll>::operator()(struct pollfd *fds, nfds_t count, const struct timespec *ts,
		const sigset_t *mask, int *num_events) {
	sigset_t previous;
	if (mask)
		sysdep<Sigprocmask>(SIG_SETMASK, mask, &previous);
	int e = fpos::poll_descriptors(fds, count, ts ? fpos::milliseconds_of(ts) : -1, num_events);
	if (mask)
		sysdep<Sigprocmask>(SIG_SETMASK, &previous, nullptr);
	return e;
}

int Sysdeps<Pselect>::operator()(int num_fds, fd_set *read_set, fd_set *write_set, fd_set *except_set,
		const struct timespec *timeout, const sigset_t *sigmask, int *num_events) {
	if (num_fds < 0 || num_fds > FD_SETSIZE)
		return EINVAL;
	struct pollfd fds[FD_SETSIZE];
	nfds_t count = 0;
	for (int fd = 0; fd < num_fds; fd++) {
		short events = 0;
		if (read_set && FD_ISSET(fd, read_set))
			events |= POLLIN;
		if (write_set && FD_ISSET(fd, write_set))
			events |= POLLOUT;
		if (except_set && FD_ISSET(fd, except_set))
			events |= POLLPRI;
		if (!events)
			continue;
		fds[count].fd = fd;
		fds[count].events = events;
		fds[count].revents = 0;
		count++;
	}
	int ready;
	if (int e = Sysdeps<Ppoll>::operator()(fds, count, timeout, sigmask, &ready))
		return e;
	if (read_set)
		FD_ZERO(read_set);
	if (write_set)
		FD_ZERO(write_set);
	if (except_set)
		FD_ZERO(except_set);
	int total = 0;
	for (nfds_t i = 0; i < count; i++) {
		if (fds[i].revents & POLLNVAL)
			return EBADF;
		if (read_set && (fds[i].revents & (POLLIN | POLLHUP))) {
			FD_SET(fds[i].fd, read_set);
			total++;
		}
		if (write_set && (fds[i].revents & POLLOUT)) {
			FD_SET(fds[i].fd, write_set);
			total++;
		}
	}
	*num_events = total;
	return 0;
}

} // namespace mlibc
