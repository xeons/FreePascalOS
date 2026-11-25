/*
 * FreePascalOS
 * Copyright (C) 2026 Brandon Scott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/* Timers and processor-time clocks: POSIX timers on the monotonic and
   real-time clocks (SIGEV_SIGNAL with values and overruns, the default
   notification, SIGEV_NONE, SIGEV_THREAD, absolute times), on the
   processor time of the process and of a thread, ITIMER_VIRTUAL and
   ITIMER_PROF, and the processor-time clocks themselves
   (clock_gettime, clock_getres, clock_getcpuclockid,
   pthread_getcpuclockid). */

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "ctest.h"

static long long nanoseconds_of_clock(clockid_t clock) {
	struct timespec now;
	if (clock_gettime(clock, &now) != 0)
		return -1;
	return (long long)now.tv_sec * 1000000000LL + now.tv_nsec;
}

static long long milliseconds_of(const struct timespec *value) {
	return (long long)value->tv_sec * 1000 + value->tv_nsec / 1000000;
}

static void set_timer(timer_t timer, long first_ms, long period_ms, int flags) {
	struct itimerspec spec;
	memset(&spec, 0, sizeof(spec));
	spec.it_value.tv_sec = first_ms / 1000;
	spec.it_value.tv_nsec = (first_ms % 1000) * 1000000L;
	spec.it_interval.tv_sec = period_ms / 1000;
	spec.it_interval.tv_nsec = (period_ms % 1000) * 1000000L;
	CHECK(timer_settime(timer, flags, &spec, NULL) == 0, "timer_settime: %s", strerror(errno));
}

static void block_signal(int signal, sigset_t *set) {
	sigemptyset(set);
	sigaddset(set, signal);
	sigprocmask(SIG_BLOCK, set, NULL);
}

/* SIGEV_SIGNAL with a value; overruns while the signal waits. */
static void test_signal_timer(void) {
	sigset_t set;
	block_signal(SIGRTMIN + 4, &set);
	struct sigevent event;
	memset(&event, 0, sizeof(event));
	event.sigev_notify = SIGEV_SIGNAL;
	event.sigev_signo = SIGRTMIN + 4;
	event.sigev_value.sival_int = 1234;
	timer_t timer;
	CHECK(timer_create(CLOCK_MONOTONIC, &event, &timer) == 0, "timer_create: %s", strerror(errno));
	set_timer(timer, 20, 20, 0);
	for (int i = 0; i < 3; i++) {
		siginfo_t info;
		memset(&info, 0, sizeof(info));
		int signal = sigwaitinfo(&set, &info);
		CHECK(signal == SIGRTMIN + 4 && info.si_code == SI_TIMER && info.si_value.sival_int == 1234,
			"expiry %d: signal %d code %d value %d", i, signal, info.si_code, info.si_value.sival_int);
	}
	struct itimerspec current;
	CHECK(timer_gettime(timer, &current) == 0 && milliseconds_of(&current.it_interval) == 20 &&
		milliseconds_of(&current.it_value) <= 20, "timer_gettime: %lld ms left, period %lld",
		milliseconds_of(&current.it_value), milliseconds_of(&current.it_interval));

	/* Expiries while the signal waits are its overrun. */
	usleep(130000);
	siginfo_t info;
	memset(&info, 0, sizeof(info));
	sigwaitinfo(&set, &info);
	int overrun = timer_getoverrun(timer);
	CHECK(info.si_overrun >= 3 && overrun == info.si_overrun, "overrun %d (si_overrun %d)", overrun,
		info.si_overrun);

	set_timer(timer, 0, 0, 0);
	CHECK(timer_gettime(timer, &current) == 0 && current.it_value.tv_sec == 0 && current.it_value.tv_nsec == 0,
		"disarmed");
	CHECK(timer_delete(timer) == 0, "timer_delete");
	errno = 0;
	CHECK(timer_gettime(timer, &current) < 0 && errno == EINVAL, "a deleted timer: %s", strerror(errno));
	sigprocmask(SIG_UNBLOCK, &set, NULL);
}

/* No sigevent: SIGALRM with the timer's id; an absolute real-time
   expiry. */
static void test_default_and_absolute(void) {
	sigset_t set;
	block_signal(SIGALRM, &set);
	timer_t timer;
	CHECK(timer_create(CLOCK_REALTIME, NULL, &timer) == 0, "timer_create(NULL)");
	struct timespec start;
	clock_gettime(CLOCK_REALTIME, &start);
	long long due = milliseconds_of(&start) + 40;
	struct itimerspec spec;
	memset(&spec, 0, sizeof(spec));
	spec.it_value.tv_sec = due / 1000;
	spec.it_value.tv_nsec = (due % 1000) * 1000000L;
	CHECK(timer_settime(timer, TIMER_ABSTIME, &spec, NULL) == 0, "absolute timer_settime");
	siginfo_t info;
	memset(&info, 0, sizeof(info));
	int signal = sigwaitinfo(&set, &info);
	struct timespec end;
	clock_gettime(CLOCK_REALTIME, &end);
	CHECK(signal == SIGALRM && info.si_value.sival_int == (int)(intptr_t)timer && info.si_code == SI_TIMER,
		"SIGALRM with the id: %d value %d", signal, info.si_value.sival_int);
	CHECK(milliseconds_of(&end) >= due - 1, "not before its time (%lld ms early)", due - milliseconds_of(&end));
	timer_delete(timer);
	sigprocmask(SIG_UNBLOCK, &set, NULL);
}

static void test_no_notification(void) {
	struct sigevent event;
	memset(&event, 0, sizeof(event));
	event.sigev_notify = SIGEV_NONE;
	timer_t timer;
	CHECK(timer_create(CLOCK_MONOTONIC, &event, &timer) == 0, "SIGEV_NONE timer");
	set_timer(timer, 1000, 0, 0);
	struct itimerspec first;
	struct itimerspec later;
	timer_gettime(timer, &first);
	usleep(50000);
	timer_gettime(timer, &later);
	CHECK(milliseconds_of(&first.it_value) <= 1000 && milliseconds_of(&first.it_value) > 900 &&
		milliseconds_of(&later.it_value) < milliseconds_of(&first.it_value),
		"it counts down: %lld then %lld ms", milliseconds_of(&first.it_value), milliseconds_of(&later.it_value));
	timer_delete(timer);
}

static volatile int thread_calls;
static volatile int thread_value;

static void on_thread_timer(union sigval value) {
	thread_value = value.sival_int;
	__atomic_fetch_add(&thread_calls, 1, __ATOMIC_RELAXED);
}

static void test_thread_timer(void) {
	struct sigevent event;
	memset(&event, 0, sizeof(event));
	event.sigev_notify = SIGEV_THREAD;
	event.sigev_notify_function = on_thread_timer;
	event.sigev_value.sival_int = 99;
	timer_t timer;
	CHECK(timer_create(CLOCK_MONOTONIC, &event, &timer) == 0, "SIGEV_THREAD timer: %s", strerror(errno));
	set_timer(timer, 10, 10, 0);
	for (int i = 0; i < 400 && thread_calls < 3; i++)
		usleep(5000);
	CHECK(thread_calls >= 3 && thread_value == 99, "the function ran %d times (value %d)", thread_calls,
		thread_value);
	CHECK(timer_delete(timer) == 0, "SIGEV_THREAD timer deleted");
	usleep(20000);
	int seen = thread_calls;
	usleep(60000);
	CHECK(thread_calls == seen, "no calls after timer_delete");
}

/* --- Processor time ---------------------------------------------------- */

/* Computes until the clock has advanced by Milliseconds or Flag is set
   (at most a few seconds of real time). */
static void spin(clockid_t clock, long milliseconds, volatile sig_atomic_t *flag) {
	long long start = nanoseconds_of_clock(clock);
	long long wall_start = nanoseconds_of_clock(CLOCK_MONOTONIC);
	volatile unsigned long work = 0;
	for (;;) {
		for (int i = 0; i < 10000; i++)
			work += (unsigned long)i;
		if (flag && *flag)
			break;
		if (!flag && nanoseconds_of_clock(clock) - start >= milliseconds * 1000000LL)
			break;
		if (work == 1 || nanoseconds_of_clock(CLOCK_MONOTONIC) - wall_start > 5000000000LL)
			break;
	}
}

static void test_cpu_clocks(void) {
	long long before = nanoseconds_of_clock(CLOCK_PROCESS_CPUTIME_ID);
	usleep(100000);
	long long slept = nanoseconds_of_clock(CLOCK_PROCESS_CPUTIME_ID) - before;
	CHECK(before > 0 && slept >= 0 && slept < 50000000LL, "sleeping costs no processor time (%lld ns)", slept);

	long long wall = nanoseconds_of_clock(CLOCK_MONOTONIC);
	long long thread_before = nanoseconds_of_clock(CLOCK_THREAD_CPUTIME_ID);
	spin(CLOCK_THREAD_CPUTIME_ID, 40, NULL);
	long long thread_used = nanoseconds_of_clock(CLOCK_THREAD_CPUTIME_ID) - thread_before;
	long long wall_used = nanoseconds_of_clock(CLOCK_MONOTONIC) - wall;
	CHECK(thread_used >= 40000000LL && thread_used <= wall_used + 2000000LL,
		"computing counts: %lld ns of %lld ns", thread_used, wall_used);
	CHECK(nanoseconds_of_clock(CLOCK_PROCESS_CPUTIME_ID) >= nanoseconds_of_clock(CLOCK_THREAD_CPUTIME_ID),
		"the process's time holds the thread's");

	clockid_t clock;
	CHECK(clock_getcpuclockid(0, &clock) == 0 && nanoseconds_of_clock(clock) > 0, "clock_getcpuclockid(0)");
	CHECK(clock_getcpuclockid(getpid(), &clock) == 0 && nanoseconds_of_clock(clock) > 0,
		"clock_getcpuclockid(getpid())");
	CHECK(pthread_getcpuclockid(pthread_self(), &clock) == 0 && nanoseconds_of_clock(clock) > 0,
		"pthread_getcpuclockid");
	struct timespec resolution;
	CHECK(clock_getres(CLOCK_PROCESS_CPUTIME_ID, &resolution) == 0 && resolution.tv_sec == 0 &&
		resolution.tv_nsec > 0, "clock_getres");

	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		usleep(300000);
		_exit(0);
	}
	CHECK(clock_getcpuclockid(child, &clock) == 0 && nanoseconds_of_clock(clock) >= 0,
		"another process's clock");
	int status;
	waitpid(child, &status, 0);
	errno = 0;
	CHECK(clock_getcpuclockid(child, &clock) == ESRCH, "an ended process has no clock");
}

static volatile sig_atomic_t cpu_alarm;

static void on_cpu_alarm(int signal) {
	(void)signal;
	cpu_alarm = 1;
}

/* A timer on a processor-time clock expires once that much was used. */
static void check_cpu_timer(clockid_t clock, const char *name) {
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = on_cpu_alarm;
	sigaction(SIGRTMIN + 5, &action, NULL);
	struct sigevent event;
	memset(&event, 0, sizeof(event));
	event.sigev_notify = SIGEV_SIGNAL;
	event.sigev_signo = SIGRTMIN + 5;
	timer_t timer;
	CHECK(timer_create(clock, &event, &timer) == 0, "%s timer: %s", name, strerror(errno));
	cpu_alarm = 0;
	long long start = nanoseconds_of_clock(clock);
	set_timer(timer, 30, 0, 0);
	spin(clock, 0, &cpu_alarm);
	long long used = nanoseconds_of_clock(clock) - start;
	CHECK(cpu_alarm && used >= 29000000LL, "%s timer expired after %lld ns", name, used);
	timer_delete(timer);
	signal(SIGRTMIN + 5, SIG_DFL);
}

static void check_interval_timer(int which, int number, const char *name) {
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = on_cpu_alarm;
	sigaction(number, &action, NULL);
	cpu_alarm = 0;
	struct itimerval timer;
	memset(&timer, 0, sizeof(timer));
	timer.it_value.tv_usec = 30000;
	long long start = nanoseconds_of_clock(CLOCK_PROCESS_CPUTIME_ID);
	CHECK(setitimer(which, &timer, NULL) == 0, "setitimer(%s)", name);
	struct itimerval current;
	CHECK(getitimer(which, &current) == 0 && current.it_value.tv_usec > 0 && current.it_value.tv_usec <= 30000,
		"getitimer(%s): %ld us", name, (long)current.it_value.tv_usec);
	spin(CLOCK_PROCESS_CPUTIME_ID, 0, &cpu_alarm);
	long long used = nanoseconds_of_clock(CLOCK_PROCESS_CPUTIME_ID) - start;
	CHECK(cpu_alarm && used >= 29000000LL, "%s expired after %lld ns of processor time", name, used);
	CHECK(getitimer(which, &current) == 0 && current.it_value.tv_sec == 0 && current.it_value.tv_usec == 0,
		"%s disarmed after its expiry", name);
	signal(number, SIG_DFL);
}

void test_timers(void) {
	test_signal_timer();
	test_default_and_absolute();
	test_no_notification();
	test_thread_timer();
	test_cpu_clocks();
	check_cpu_timer(CLOCK_PROCESS_CPUTIME_ID, "CLOCK_PROCESS_CPUTIME_ID");
	check_cpu_timer(CLOCK_THREAD_CPUTIME_ID, "CLOCK_THREAD_CPUTIME_ID");
	check_interval_timer(ITIMER_VIRTUAL, SIGVTALRM, "ITIMER_VIRTUAL");
	check_interval_timer(ITIMER_PROF, SIGPROF, "ITIMER_PROF");
}
