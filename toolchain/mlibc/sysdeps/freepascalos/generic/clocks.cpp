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

// Clock resolutions and the processor-time clocks of a given process or
// thread. clock_gettime itself is core.cpp's (the dynamic linker has it
// too). A processor-time clock id has the Linux encoding the kernel
// reads: not (id << 3), plus FPOS_CLOCK_CPU_SCHEDULED, plus
// FPOS_CLOCK_CPU_PER_THREAD for a thread.

#include "kernel.hpp"

#include <errno.h>
#include <time.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

namespace {

clockid_t processor_clock_of(pid_t id, bool per_thread) {
	long clock = (~(long)id) * 8 + FPOS_CLOCK_CPU_SCHEDULED;
	if (per_thread)
		clock += FPOS_CLOCK_CPU_PER_THREAD;
	return (clockid_t)clock;
}

} // namespace

} // namespace fpos

namespace mlibc {

int Sysdeps<ClockGetres>::operator()(int clock, time_t *secs, long *nanos) {
	switch (clock) {
		case CLOCK_REALTIME:
		case CLOCK_MONOTONIC:
		case CLOCK_MONOTONIC_RAW:
		case CLOCK_BOOTTIME:
		case CLOCK_REALTIME_COARSE:
		case CLOCK_MONOTONIC_COARSE:
			// The kernel counts in nanoseconds of a fine counter.
			*secs = 0;
			*nanos = 1;
			return 0;
		default: {
			if (clock != CLOCK_PROCESS_CPUTIME_ID && clock != CLOCK_THREAD_CPUTIME_ID && clock >= 0)
				return EINVAL;
			struct fpos_precise_time resolution;
			if (int e = fpos::call_checked(FPOS_CALL_GET_PROCESSOR_CLOCK, clock, nullptr, &resolution))
				return e == ENOENT ? EINVAL : e;
			*secs = resolution.seconds;
			*nanos = resolution.nanoseconds;
			return 0;
		}
	}
}

int Sysdeps<ClockGetcpuclockid>::operator()(pid_t pid, clockid_t *clock) {
	if (pid < 0)
		return ESRCH;
	clockid_t made = fpos::processor_clock_of(pid, false);
	// The process must be there (ESRCH otherwise).
	if (pid != 0 && fpos::call_checked(FPOS_CALL_GET_PROCESSOR_CLOCK, made, nullptr, nullptr) != 0)
		return ESRCH;
	*clock = made;
	return 0;
}

int Sysdeps<ThreadGetcpuclockid>::operator()(pid_t tid, clockid_t *clock) {
	*clock = fpos::processor_clock_of(tid, true);
	return 0;
}

} // namespace mlibc
