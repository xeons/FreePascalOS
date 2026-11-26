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

// eventfd, timerfd and signalfd over the kernel's event descriptors
// (calls 260-264). The kernel keeps their non-blocking flag itself
// (FPOS_CONTROL_SET_NON_BLOCKING follows fcntl); reads and writes are the
// ordinary FPOS_CALL_READ and FPOS_CALL_WRITE, whose records are Linux's
// (8-byte counts, struct signalfd_siginfo).

#include "kernel.hpp"
#include "descriptors.hpp"
#include "event-descriptors.hpp"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>
#include <time.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

// The kernel's flag for O_NONBLOCK.
unsigned long kernel_non_blocking(int flags) {
	return (flags & O_NONBLOCK) ? FPOS_EVENT_DESCRIPTOR_NON_BLOCKING : 0;
}

// A new descriptor's close-on-exec and non-blocking flags.
void remember_new_descriptor(int fd, int flags) {
	forget_descriptor(fd);
	unsigned char descriptor = 0;
	if (flags & O_CLOEXEC)
		descriptor |= descriptor_close_on_exec;
	if (flags & O_NONBLOCK)
		descriptor |= descriptor_non_blocking;
	set_descriptor_flags(fd, descriptor);
}

bool is_event_descriptor_kind(long kind) {
	return kind == FPOS_HANDLE_KIND_EVENT_COUNTER || kind == FPOS_HANDLE_KIND_TIMER_DESCRIPTOR
		|| kind == FPOS_HANDLE_KIND_SIGNAL_DESCRIPTOR || kind == FPOS_HANDLE_KIND_EVENT_POLL
		|| kind == FPOS_HANDLE_KIND_WATCH_GROUP;
}

namespace {

int created(long result, int flags, int *fd) {
	if (int e = error_of(result))
		return e;
	*fd = (int)result;
	remember_new_descriptor(*fd, flags);
	return 0;
}

void to_kernel(const struct itimerspec *value, struct fpos_timer_specification *specification) {
	specification->interval_seconds = value->it_interval.tv_sec;
	specification->interval_nanoseconds = value->it_interval.tv_nsec;
	specification->value_seconds = value->it_value.tv_sec;
	specification->value_nanoseconds = value->it_value.tv_nsec;
}

void from_kernel(const struct fpos_timer_specification *specification, struct itimerspec *value) {
	value->it_interval.tv_sec = specification->interval_seconds;
	value->it_interval.tv_nsec = specification->interval_nanoseconds;
	value->it_value.tv_sec = specification->value_seconds;
	value->it_value.tv_nsec = specification->value_nanoseconds;
}

} // namespace

} // namespace fpos

namespace mlibc {

int Sysdeps<EventfdCreate>::operator()(unsigned int initval, int flags, int *fd) {
	if (flags & ~(EFD_SEMAPHORE | EFD_CLOEXEC | EFD_NONBLOCK))
		return EINVAL;
	unsigned long kernel_flags = fpos::kernel_non_blocking(flags);
	if (flags & EFD_SEMAPHORE)
		kernel_flags |= FPOS_EVENT_COUNTER_SEMAPHORE;
	return fpos::created(fpos::call(FPOS_CALL_CREATE_EVENT_COUNTER, (unsigned long)initval, kernel_flags),
		flags, fd);
}

int Sysdeps<TimerfdCreate>::operator()(int clockid, int flags, int *fd) {
	if (flags & ~(TFD_CLOEXEC | TFD_NONBLOCK))
		return EINVAL;
	if (clockid != CLOCK_REALTIME && clockid != CLOCK_MONOTONIC && clockid != CLOCK_BOOTTIME)
		return EINVAL;
	return fpos::created(fpos::call(FPOS_CALL_CREATE_TIMER_DESCRIPTOR, clockid, fpos::kernel_non_blocking(flags)),
		flags, fd);
}

int Sysdeps<TimerfdSettime>::operator()(int fd, int flags, const struct itimerspec *value,
		struct itimerspec *oldvalue) {
	if (!value)
		return EFAULT;
	struct fpos_timer_specification setting;
	struct fpos_timer_specification previous = {};
	fpos::to_kernel(value, &setting);
	unsigned long kernel_flags = 0;
	if (flags & TFD_TIMER_ABSTIME)
		kernel_flags |= FPOS_TIMER_ABSOLUTE;
	if (flags & TFD_TIMER_CANCEL_ON_SET)
		kernel_flags |= FPOS_TIMER_CANCEL_ON_SET;
	if (flags & ~(TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET))
		return EINVAL;
	if (int e = fpos::call_checked(FPOS_CALL_SET_TIMER_DESCRIPTOR, fd, kernel_flags, &setting,
			oldvalue ? &previous : nullptr))
		return e;
	if (oldvalue)
		fpos::from_kernel(&previous, oldvalue);
	return 0;
}

int Sysdeps<TimerfdGettime>::operator()(int fd, struct itimerspec *its) {
	struct fpos_timer_specification current = {};
	if (int e = fpos::call_checked(FPOS_CALL_SET_TIMER_DESCRIPTOR, fd, 0, nullptr, &current))
		return e;
	fpos::from_kernel(&current, its);
	return 0;
}

int Sysdeps<SignalfdCreate>::operator()(const sigset_t *mask, int flags, int *fd) {
	if (flags & ~(SFD_CLOEXEC | SFD_NONBLOCK))
		return EINVAL;
	if (!mask)
		return EFAULT;
	uint64_t bits = (uint64_t)mask->__sig[0];
	long result = fpos::call(FPOS_CALL_SET_SIGNAL_DESCRIPTOR, *fd < 0 ? -1L : (long)*fd, bits,
		fpos::kernel_non_blocking(flags));
	if (int e = fpos::error_of(result))
		return e;
	if (*fd < 0) {
		*fd = (int)result;
		fpos::remember_new_descriptor(*fd, flags);
	}
	return 0;
}

} // namespace mlibc
