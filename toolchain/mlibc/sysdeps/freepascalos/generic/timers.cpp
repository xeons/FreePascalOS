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

// setitimer(ITIMER_REAL) and so alarm(): a kernel thread of the process,
// started the first time a timer is set, sleeps on a word
// (WaitOnAddress) until the timer is due or changed and then sends the
// process SIGALRM. The thread runs with the kernel's thread data, not
// mlibc's TCB, so it makes system calls only and touches no C library
// state but the timer's. A child of fork has no timer (its state is
// cleared there).

#include "kernel.hpp"
#include "timers.hpp"

#include <errno.h>
#include <signal.h>
#include <string.h>
#include <sys/time.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

namespace {

constexpr long helper_stack_size = 64 * 1024;

struct AlarmTimer {
	// Changed whenever the timer is set; the helper sleeps on it.
	int generation;
	int helper_started;
	// Uptime in milliseconds when it is due (0: not armed), and the
	// period after that (0: once).
	long due;
	long interval;
};

AlarmTimer timer;

long uptime_milliseconds() {
	struct fpos_precise_time now;
	call(FPOS_CALL_GET_PRECISE_TIME, FPOS_TIME_UPTIME_NANOSECONDS, &now);
	return (long)(now.seconds * 1000 + now.nanoseconds / 1000000);
}

long milliseconds_of_timeval(const struct timeval &value) {
	return value.tv_sec * 1000 + (value.tv_usec + 999) / 1000;
}

void timeval_of_milliseconds(long milliseconds, struct timeval *value) {
	value->tv_sec = milliseconds / 1000;
	value->tv_usec = (milliseconds % 1000) * 1000;
}

[[noreturn]] __attribute__((no_stack_protector)) void alarm_helper(void *) {
	// Signals are for the program's own threads.
	uint64_t all = ~uint64_t(0);
	call(FPOS_CALL_SET_SIGNAL_MASK, SIG_SETMASK, &all, nullptr);
	for (;;) {
		int generation = __atomic_load_n(&timer.generation, __ATOMIC_ACQUIRE);
		long due = __atomic_load_n(&timer.due, __ATOMIC_ACQUIRE);
		long wait = FPOS_INFINITE_WAIT;
		if (due != 0) {
			long now = uptime_milliseconds();
			if (now >= due) {
				long interval = __atomic_load_n(&timer.interval, __ATOMIC_RELAXED);
				long next = interval ? due + interval : 0;
				if (__atomic_compare_exchange_n(&timer.due, &due, next, false, __ATOMIC_ACQ_REL,
						__ATOMIC_RELAXED))
					call(FPOS_CALL_SEND_SIGNAL, call(FPOS_CALL_GET_PROCESS_ID, -1), SIGALRM);
				continue;
			}
			wait = due - now;
		}
		call(FPOS_CALL_WAIT_ON_ADDRESS, &timer.generation, (unsigned int)generation, wait);
	}
}

int start_helper() {
	if (__atomic_exchange_n(&timer.helper_started, 1, __ATOMIC_ACQ_REL))
		return 0;
	long handle = call(FPOS_CALL_CREATE_THREAD, reinterpret_cast<void *>(&alarm_helper), 0,
		helper_stack_size);
	if (int e = error_of(handle)) {
		__atomic_store_n(&timer.helper_started, 0, __ATOMIC_RELEASE);
		return e;
	}
	call(FPOS_CALL_SET_THREAD_NAME, call(FPOS_CALL_GET_THREAD_ID, handle), "alarm");
	call(FPOS_CALL_CLOSE, handle);
	return 0;
}

} // namespace

void forget_timers_after_fork() {
	memset(&timer, 0, sizeof(timer));
}

} // namespace fpos

namespace mlibc {

int Sysdeps<GetItimer>::operator()(int which, struct itimerval *curr_value) {
	if (which != ITIMER_REAL)
		return EINVAL;
	memset(curr_value, 0, sizeof(*curr_value));
	long due = __atomic_load_n(&fpos::timer.due, __ATOMIC_ACQUIRE);
	if (due != 0) {
		long remaining = due - fpos::uptime_milliseconds();
		fpos::timeval_of_milliseconds(remaining > 0 ? remaining : 1, &curr_value->it_value);
	}
	fpos::timeval_of_milliseconds(__atomic_load_n(&fpos::timer.interval, __ATOMIC_RELAXED),
		&curr_value->it_interval);
	return 0;
}

int Sysdeps<SetItimer>::operator()(int which, const struct itimerval *new_value,
		struct itimerval *old_value) {
	if (which != ITIMER_REAL)
		return EINVAL;
	if (old_value)
		Sysdeps<GetItimer>::operator()(which, old_value);
	long value = fpos::milliseconds_of_timeval(new_value->it_value);
	long interval = fpos::milliseconds_of_timeval(new_value->it_interval);
	if (value != 0) {
		if (int e = fpos::start_helper())
			return e;
	}
	__atomic_store_n(&fpos::timer.interval, interval, __ATOMIC_RELAXED);
	__atomic_store_n(&fpos::timer.due, value ? fpos::uptime_milliseconds() + value : 0, __ATOMIC_RELEASE);
	__atomic_fetch_add(&fpos::timer.generation, 1, __ATOMIC_ACQ_REL);
	fpos::call(FPOS_CALL_WAKE_ADDRESS, &fpos::timer.generation, 1);
	return 0;
}

} // namespace mlibc
