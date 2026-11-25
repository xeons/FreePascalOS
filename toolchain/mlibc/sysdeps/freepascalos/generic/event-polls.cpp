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

// epoll over the kernel's event polls (calls 265-267). The kernel's
// record (fpos_poll_event) has the events and the data 8-byte aligned;
// struct epoll_event is packed on x86-64, so events are copied over.
// epoll_pwait's signal mask is set around the wait, as ppoll's is. A wait
// returns at most 64 events (the rest stay ready for the next).

#include "kernel.hpp"
#include "event-descriptors.hpp"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/epoll.h>
#include <mlibc/all-sysdeps.hpp>

namespace {

constexpr int batch_size = 64;

} // namespace

namespace mlibc {

int Sysdeps<EpollCreate>::operator()(int flags, int *fd) {
	if (flags & ~EPOLL_CLOEXEC)
		return EINVAL;
	long result = fpos::call(FPOS_CALL_CREATE_EVENT_POLL, 0);
	if (int e = fpos::error_of(result))
		return e;
	*fd = (int)result;
	fpos::remember_new_descriptor(*fd, (flags & EPOLL_CLOEXEC) ? O_CLOEXEC : 0);
	return 0;
}

int Sysdeps<EpollCtl>::operator()(int epfd, int mode, int fd, struct epoll_event *ev) {
	struct fpos_poll_event registration = {};
	long operation;
	switch (mode) {
		case EPOLL_CTL_ADD:
			operation = FPOS_POLL_ADD;
			break;
		case EPOLL_CTL_MOD:
			operation = FPOS_POLL_MODIFY;
			break;
		case EPOLL_CTL_DEL:
			operation = FPOS_POLL_REMOVE;
			break;
		default:
			return EINVAL;
	}
	if (mode != EPOLL_CTL_DEL) {
		if (!ev)
			return EFAULT;
		registration.events = ev->events;
		registration.data = ev->data.u64;
	}
	// The kernel's errors are Linux's: EEXIST, ENOENT, EPERM (files),
	// ELOOP, EBADF, EINVAL.
	return fpos::call_checked(FPOS_CALL_CONTROL_EVENT_POLL, epfd, operation, fd, &registration);
}

int Sysdeps<EpollPwait>::operator()(int epfd, struct epoll_event *ev, int n, int timeout,
		const sigset_t *sigmask, int *raised) {
	if (n <= 0)
		return EINVAL;
	sigset_t previous;
	if (sigmask)
		sysdep<Sigprocmask>(SIG_SETMASK, sigmask, &previous);
	struct fpos_poll_event events[batch_size];
	int capacity = n < batch_size ? n : batch_size;
	long result = fpos::call(FPOS_CALL_WAIT_EVENT_POLL, epfd, events, capacity, timeout < 0 ? -1L : (long)timeout);
	if (sigmask)
		sysdep<Sigprocmask>(SIG_SETMASK, &previous, nullptr);
	if (int e = fpos::error_of(result))
		return e;
	for (long i = 0; i < result; i++) {
		ev[i].events = events[i].events;
		ev[i].data.u64 = events[i].data;
	}
	*raised = (int)result;
	return 0;
}

} // namespace mlibc
