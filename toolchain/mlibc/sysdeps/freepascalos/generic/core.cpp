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

// What both the dynamic linker and libc need: logging, ending the
// process, the thread pointer, futexes (the kernel's WaitOnAddress and
// WakeAddress) and the clocks (CLOCK_REALTIME and CLOCK_MONOTONIC from
// the clock page when it offers the counter, clockpage.cpp).

#include "kernel.hpp"
#ifndef MLIBC_BUILDING_RTLD
#include "clockpage.hpp"
#endif

#include <errno.h>
#include <string.h>
#include <time.h>
#include <mlibc/all-sysdeps.hpp>
#include <mlibc/tcb.hpp>

namespace fpos {

#ifndef MLIBC_BUILDING_RTLD
// The clocks the page can give, without a system call.
bool clock_from_page(int clock, time_t *secs, long *nanos) {
	int64_t value;
	switch (clock) {
		case CLOCK_REALTIME:
		case CLOCK_REALTIME_COARSE:
			if (!clock_page_wall_clock(&value))
				return false;
			break;
		case CLOCK_MONOTONIC:
		case CLOCK_MONOTONIC_RAW:
		case CLOCK_MONOTONIC_COARSE:
		case CLOCK_BOOTTIME: {
			uint64_t uptime;
			if (!clock_page_uptime(&uptime))
				return false;
			value = static_cast<int64_t>(uptime);
			break;
		}
		default:
			return false;
	}
	int64_t seconds = value / 1000000000;
	int64_t rest = value % 1000000000;
	if (rest < 0) {
		rest += 1000000000;
		seconds--;
	}
	*secs = seconds;
	*nanos = rest;
	return true;
}
#endif

long milliseconds_of(const struct timespec *timeout) {
	if (!timeout)
		return FPOS_INFINITE_WAIT;
	if (timeout->tv_sec < 0)
		return 0;
	long milliseconds = timeout->tv_sec * 1000 + (timeout->tv_nsec + 999999) / 1000000;
	return milliseconds;
}

} // namespace fpos

namespace mlibc {

void Sysdeps<LibcLog>::operator()(const char *message) {
	fpos::call(FPOS_CALL_WRITE, 2, message, strlen(message));
	fpos::call(FPOS_CALL_WRITE, 2, "\n", 1);
}

void Sysdeps<LibcPanic>::operator()() {
	Sysdeps<LibcLog>::operator()("mlibc: panic");
	fpos::call(FPOS_CALL_EXIT, 134);
	__builtin_trap();
}

void Sysdeps<Exit>::operator()(int status) {
	fpos::call(FPOS_CALL_EXIT, status & 0xFF);
	__builtin_unreachable();
}

int Sysdeps<TcbSet>::operator()(void *pointer) {
#if defined(__aarch64__)
	// Variant I: the thread pointer is 16 bytes before the end of the
	// TCB, where the TLS blocks start.
	uintptr_t thread_pointer = reinterpret_cast<uintptr_t>(pointer) + sizeof(Tcb) - TP_TCB_OFFSET;
#else
	uintptr_t thread_pointer = reinterpret_cast<uintptr_t>(pointer);
#endif
	return fpos::call_checked(FPOS_CALL_SET_THREAD_POINTER, thread_pointer);
}

pid_t Sysdeps<FutexTid>::operator()() {
	return static_cast<pid_t>(fpos::call(FPOS_CALL_GET_THREAD_ID, FPOS_CURRENT_THREAD_HANDLE));
}

int Sysdeps<FutexWait>::operator()(int *pointer, int expected, const struct timespec *time) {
	long result = fpos::call(FPOS_CALL_WAIT_ON_ADDRESS, pointer, (unsigned int)expected,
		fpos::milliseconds_of(time));
	switch (fpos::error_of(result)) {
		case 0:
			return 0;
		case FPOS_ERROR_BUSY:
			return EAGAIN;
		case FPOS_ERROR_TIMED_OUT:
			return ETIMEDOUT;
		default:
			return fpos::error_of(result);
	}
}

int Sysdeps<FutexWake>::operator()(int *pointer, bool all) {
	long count = all ? 0x7FFFFFFF : 1;
	return fpos::call_checked(FPOS_CALL_WAKE_ADDRESS, pointer, count);
}

int Sysdeps<ClockGet>::operator()(int clock, time_t *secs, long *nanos) {
#ifndef MLIBC_BUILDING_RTLD
	if (fpos::clock_from_page(clock, secs, nanos))
		return 0;
#endif
	long which;
	struct fpos_precise_time now;
	switch (clock) {
		case CLOCK_REALTIME:
		case CLOCK_REALTIME_COARSE:
			which = FPOS_TIME_WALL_CLOCK;
			break;
		case CLOCK_MONOTONIC:
		case CLOCK_MONOTONIC_RAW:
		case CLOCK_MONOTONIC_COARSE:
		case CLOCK_BOOTTIME:
			which = FPOS_TIME_UPTIME_NANOSECONDS;
			break;
		default:
			// The processor-time clocks: the calling process's or thread's,
			// or one clock_getcpuclockid made (negative).
			if (clock != CLOCK_PROCESS_CPUTIME_ID && clock != CLOCK_THREAD_CPUTIME_ID && clock >= 0)
				return EINVAL;
			if (int e = fpos::call_checked(FPOS_CALL_GET_PROCESSOR_CLOCK, clock, &now, nullptr))
				return e == ENOENT ? EINVAL : e;
			*secs = now.seconds;
			*nanos = now.nanoseconds;
			return 0;
	}
	if (int e = fpos::call_checked(FPOS_CALL_GET_PRECISE_TIME, which, &now))
		return e;
	*secs = now.seconds;
	*nanos = now.nanoseconds;
	return 0;
}

} // namespace mlibc
