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

// Timers: setitimer/getitimer (ITIMER_REAL, ITIMER_VIRTUAL, ITIMER_PROF)
// and the POSIX timers (timer_create and friends) are the kernel's
// (FPOS_CALL_SET_INTERVAL_TIMER, FPOS_CALL_CREATE_POSIX_TIMER ..): they
// count on the uptime, the wall clock or the processor time of the
// process or a thread, and send their signal with SI_TIMER, the value
// and the overrun. SIGEV_THREAD is made here: the kernel timer signals
// an event, and a thread of the timer's own waits for it and calls the
// function each time (timer_getoverrun then gives the expiries that
// call stood for, less one). A child of fork has no timers.

#include "kernel.hpp"
#include "timers.hpp"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

namespace {

constexpr long nanoseconds_per_second = 1000000000;

// A SIGEV_THREAD timer: its event and the thread that waits for it.
struct ThreadTimer {
	long timer_id;
	long event_handle;
	void (*function)(union sigval);
	union sigval value;
	int deleted;
	int overrun;
};

ThreadTimer *thread_timers[FPOS_MAXIMUM_POSIX_TIMERS];

uint64_t nanoseconds_of(const struct timespec &value) {
	return (uint64_t)value.tv_sec * nanoseconds_per_second + (uint64_t)value.tv_nsec;
}

void timespec_of(uint64_t nanoseconds, struct timespec *value) {
	value->tv_sec = (time_t)(nanoseconds / nanoseconds_per_second);
	value->tv_nsec = (long)(nanoseconds % nanoseconds_per_second);
}

uint64_t nanoseconds_of(const struct timeval &value) {
	return (uint64_t)value.tv_sec * nanoseconds_per_second + (uint64_t)value.tv_usec * 1000;
}

// Rounded up, so a timer that is armed never reads as zero.
void timeval_of(uint64_t nanoseconds, struct timeval *value) {
	uint64_t microseconds = (nanoseconds + 999) / 1000;
	value->tv_sec = (time_t)(microseconds / 1000000);
	value->tv_usec = (suseconds_t)(microseconds % 1000000);
}

bool valid_timespec(const struct timespec &value) {
	return value.tv_sec >= 0 && value.tv_nsec >= 0 && value.tv_nsec < nanoseconds_per_second;
}

bool valid_timeval(const struct timeval &value) {
	return value.tv_sec >= 0 && value.tv_usec >= 0 && value.tv_usec < 1000000;
}

long timer_id_of(timer_t timer) {
	return reinterpret_cast<long>(timer);
}

ThreadTimer *thread_timer_of(long timer_id) {
	if (timer_id < 0 || timer_id >= FPOS_MAXIMUM_POSIX_TIMERS)
		return nullptr;
	return __atomic_load_n(&thread_timers[timer_id], __ATOMIC_ACQUIRE);
}

void *run_thread_timer(void *argument) {
	auto timer = static_cast<ThreadTimer *>(argument);
	// The program's signals are for its own threads.
	sigset_t all;
	sigfillset(&all);
	pthread_sigmask(SIG_SETMASK, &all, nullptr);
	for (;;) {
		long result = call(FPOS_CALL_WAIT_FOR_HANDLES, &timer->event_handle, 1, FPOS_INFINITE_WAIT, 0);
		if (__atomic_load_n(&timer->deleted, __ATOMIC_ACQUIRE))
			break;
		if (error_of(result))
			continue;
		long overrun = call(FPOS_CALL_GET_TIMER_OVERRUN, timer->timer_id);
		timer->overrun = error_of(overrun) ? 0 : (int)overrun;
		timer->function(timer->value);
	}
	call(FPOS_CALL_CLOSE, timer->event_handle);
	free(timer);
	return nullptr;
}

// Makes the event and the thread of a SIGEV_THREAD timer.
int start_thread_timer(const struct sigevent *event, ThreadTimer **made, struct fpos_timer_event *kernel_event) {
	auto timer = static_cast<ThreadTimer *>(calloc(1, sizeof(ThreadTimer)));
	if (!timer)
		return EAGAIN;
	long handle = call(FPOS_CALL_CREATE_EVENT, 0);
	if (int e = error_of(handle)) {
		free(timer);
		return e == ENOMEM ? EAGAIN : e;
	}
	timer->event_handle = handle;
	timer->timer_id = -1;
	timer->function = event->sigev_notify_function;
	timer->value = event->sigev_value;
	kernel_event->notify = FPOS_TIMER_NOTIFY_EVENT;
	kernel_event->event_handle = handle;
	*made = timer;
	return 0;
}

int launch_thread_timer(ThreadTimer *timer, const struct sigevent *event) {
	pthread_attr_t attributes;
	if (event->sigev_notify_attributes)
		attributes = *event->sigev_notify_attributes;
	else
		pthread_attr_init(&attributes);
	pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
	pthread_t thread;
	int e = pthread_create(&thread, &attributes, run_thread_timer, timer);
	if (!event->sigev_notify_attributes)
		pthread_attr_destroy(&attributes);
	return e;
}

void stop_thread_timer(ThreadTimer *timer) {
	__atomic_store_n(&timer->deleted, 1, __ATOMIC_RELEASE);
	call(FPOS_CALL_SET_EVENT, timer->event_handle);
}

} // namespace

void forget_timers_after_fork() {
	// The threads stayed in the parent; their events were copied here.
	for (int i = 0; i < FPOS_MAXIMUM_POSIX_TIMERS; i++) {
		ThreadTimer *timer = thread_timers[i];
		if (!timer)
			continue;
		call(FPOS_CALL_CLOSE, timer->event_handle);
		free(timer);
		thread_timers[i] = nullptr;
	}
}

} // namespace fpos

namespace mlibc {

int Sysdeps<GetItimer>::operator()(int which, struct itimerval *curr_value) {
	struct fpos_timer_spec current;
	if (int e = fpos::call_checked(FPOS_CALL_SET_INTERVAL_TIMER, which, nullptr, &current))
		return e;
	fpos::timeval_of(current.value_nanoseconds, &curr_value->it_value);
	fpos::timeval_of(current.interval_nanoseconds, &curr_value->it_interval);
	return 0;
}

int Sysdeps<SetItimer>::operator()(int which, const struct itimerval *new_value,
		struct itimerval *old_value) {
	if (!fpos::valid_timeval(new_value->it_value) || !fpos::valid_timeval(new_value->it_interval))
		return EINVAL;
	struct fpos_timer_spec requested;
	struct fpos_timer_spec previous;
	requested.value_nanoseconds = fpos::nanoseconds_of(new_value->it_value);
	requested.interval_nanoseconds = fpos::nanoseconds_of(new_value->it_interval);
	if (int e = fpos::call_checked(FPOS_CALL_SET_INTERVAL_TIMER, which, &requested, &previous))
		return e;
	if (old_value) {
		fpos::timeval_of(previous.value_nanoseconds, &old_value->it_value);
		fpos::timeval_of(previous.interval_nanoseconds, &old_value->it_interval);
	}
	return 0;
}

int Sysdeps<TimerCreate>::operator()(clockid_t clk, struct sigevent *__restrict evp, timer_t *__restrict res) {
	struct fpos_timer_event kernel_event;
	memset(&kernel_event, 0, sizeof(kernel_event));
	fpos::ThreadTimer *thread_timer = nullptr;
	if (evp) {
		switch (evp->sigev_notify) {
			case SIGEV_SIGNAL:
				kernel_event.notify = FPOS_TIMER_NOTIFY_SIGNAL;
				kernel_event.signal = (uint32_t)evp->sigev_signo;
				kernel_event.value = reinterpret_cast<long>(evp->sigev_value.sival_ptr);
				break;
			case SIGEV_NONE:
				kernel_event.notify = FPOS_TIMER_NOTIFY_NONE;
				break;
			case SIGEV_THREAD:
				if (!evp->sigev_notify_function)
					return EINVAL;
				if (int e = fpos::start_thread_timer(evp, &thread_timer, &kernel_event))
					return e;
				break;
			default:
				return EINVAL;
		}
	}
	long id = fpos::call(FPOS_CALL_CREATE_POSIX_TIMER, clk, evp ? &kernel_event : nullptr);
	if (int e = fpos::error_of(id)) {
		if (thread_timer) {
			fpos::call(FPOS_CALL_CLOSE, thread_timer->event_handle);
			free(thread_timer);
		}
		return e;
	}
	if (thread_timer) {
		thread_timer->timer_id = id;
		if (int e = fpos::launch_thread_timer(thread_timer, evp)) {
			fpos::call(FPOS_CALL_DELETE_POSIX_TIMER, id);
			fpos::call(FPOS_CALL_CLOSE, thread_timer->event_handle);
			free(thread_timer);
			return e;
		}
		__atomic_store_n(&fpos::thread_timers[id], thread_timer, __ATOMIC_RELEASE);
	}
	*res = reinterpret_cast<timer_t>(id);
	return 0;
}

int Sysdeps<TimerSettime>::operator()(timer_t t, int flags, const struct itimerspec *__restrict val,
		struct itimerspec *__restrict old) {
	if (!fpos::valid_timespec(val->it_value) || !fpos::valid_timespec(val->it_interval))
		return EINVAL;
	struct fpos_timer_spec requested;
	struct fpos_timer_spec previous;
	requested.value_nanoseconds = fpos::nanoseconds_of(val->it_value);
	requested.interval_nanoseconds = fpos::nanoseconds_of(val->it_interval);
	// An absolute time already past expires at once.
	long kernel_flags = (flags & TIMER_ABSTIME) ? FPOS_TIMER_ABSOLUTE : 0;
	if (int e = fpos::call_checked(FPOS_CALL_SET_POSIX_TIMER, fpos::timer_id_of(t), kernel_flags, &requested,
			&previous))
		return e;
	if (old) {
		fpos::timespec_of(previous.value_nanoseconds, &old->it_value);
		fpos::timespec_of(previous.interval_nanoseconds, &old->it_interval);
	}
	return 0;
}

int Sysdeps<TimerGettime>::operator()(timer_t t, struct itimerspec *val) {
	struct fpos_timer_spec current;
	if (int e = fpos::call_checked(FPOS_CALL_GET_POSIX_TIMER, fpos::timer_id_of(t), &current))
		return e;
	fpos::timespec_of(current.value_nanoseconds, &val->it_value);
	fpos::timespec_of(current.interval_nanoseconds, &val->it_interval);
	return 0;
}

int Sysdeps<TimerDelete>::operator()(timer_t t) {
	long id = fpos::timer_id_of(t);
	fpos::ThreadTimer *thread_timer = fpos::thread_timer_of(id);
	if (thread_timer) {
		__atomic_store_n(&fpos::thread_timers[id], nullptr, __ATOMIC_RELEASE);
		__atomic_store_n(&thread_timer->deleted, 1, __ATOMIC_RELEASE);
	}
	int e = fpos::call_checked(FPOS_CALL_DELETE_POSIX_TIMER, id);
	// Its thread ends (and frees it) once it sees it was deleted.
	if (thread_timer)
		fpos::stop_thread_timer(thread_timer);
	return e;
}

int Sysdeps<TimerGetoverrun>::operator()(timer_t t, int *out) {
	long id = fpos::timer_id_of(t);
	if (fpos::ThreadTimer *thread_timer = fpos::thread_timer_of(id)) {
		*out = thread_timer->overrun;
		return 0;
	}
	long overrun = fpos::call(FPOS_CALL_GET_TIMER_OVERRUN, id);
	if (int e = fpos::error_of(overrun))
		return e;
	*out = (int)overrun;
	return 0;
}

} // namespace mlibc
