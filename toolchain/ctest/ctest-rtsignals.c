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

/* Real-time signals and the rest of the signal calls: sigqueue and the
   order queued signals arrive in, sigtimedwait/sigwaitinfo (timeouts, a
   sending from another thread or process), the alternate signal stack
   (a handler on it, SS_ONSTACK, a stack overflow handled on it, in the
   main thread and in another one) and SA_RESTART (a read made again
   after the handler; the calls POSIX never restarts). */

/* SS_ONSTACK and SS_DISABLE are X/Open names. */
#define _GNU_SOURCE

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/signalfd.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "ctest.h"

static long milliseconds_since(const struct timespec *start) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (now.tv_sec - start->tv_sec) * 1000 + (now.tv_nsec - start->tv_nsec) / 1000000;
}

static void block_only(int first, int second, int third, sigset_t *set) {
	sigemptyset(set);
	sigaddset(set, first);
	if (second)
		sigaddset(set, second);
	if (third)
		sigaddset(set, third);
	sigprocmask(SIG_BLOCK, set, NULL);
}

/* --- Queued signals ---------------------------------------------------- */

static volatile sig_atomic_t taken_count;
static int taken_signals[8];
static int taken_values[8];
static int taken_codes[8];

static void on_queued(int signal, siginfo_t *info, void *context) {
	(void)context;
	if (taken_count < 8) {
		taken_signals[taken_count] = signal;
		taken_values[taken_count] = info->si_value.sival_int;
		taken_codes[taken_count] = info->si_code;
	}
	taken_count++;
}

static void queue_value(int signal, int value) {
	union sigval sent;
	sent.sival_ptr = NULL;
	sent.sival_int = value;
	CHECK(sigqueue(getpid(), signal, sent) == 0, "sigqueue %d: %s", signal, strerror(errno));
}

/* Real-time signals wait once per sending and come lowest first, in the
   order sent; a standard one waits once. */
static void test_queue_order(void) {
	sigset_t set;
	block_only(SIGRTMIN, SIGRTMIN + 1, SIGUSR2, &set);
	queue_value(SIGRTMIN + 1, 10);
	queue_value(SIGRTMIN, 20);
	queue_value(SIGRTMIN, 21);
	queue_value(SIGRTMIN + 1, 11);
	queue_value(SIGUSR2, 30);
	queue_value(SIGUSR2, 31);
	sigset_t pending;
	sigpending(&pending);
	CHECK(sigismember(&pending, SIGRTMIN) && sigismember(&pending, SIGRTMIN + 1) &&
		sigismember(&pending, SIGUSR2), "the queued signals are pending");

	static const int expected_signals[5] = {SIGUSR2, SIGRTMIN, SIGRTMIN, SIGRTMIN + 1, SIGRTMIN + 1};
	static const int expected_values[5] = {30, 20, 21, 10, 11};
	for (int i = 0; i < 5; i++) {
		siginfo_t info;
		memset(&info, 0, sizeof(info));
		int signal = sigwaitinfo(&set, &info);
		CHECK(signal == expected_signals[i] && info.si_value.sival_int == expected_values[i] &&
			info.si_code == SI_QUEUE && info.si_pid == getpid(),
			"taken %d: signal %d value %d code %d (wanted %d, %d)", i, signal, info.si_value.sival_int,
			info.si_code, expected_signals[i], expected_values[i]);
	}
	struct timespec none = {0, 0};
	errno = 0;
	CHECK(sigtimedwait(&set, NULL, &none) < 0 && errno == EAGAIN, "nothing left: %s", strerror(errno));

	/* kill queues a real-time signal too, once per sending. */
	kill(getpid(), SIGRTMIN);
	kill(getpid(), SIGRTMIN);
	int first = sigtimedwait(&set, NULL, &none);
	int second = sigtimedwait(&set, NULL, &none);
	CHECK(first == SIGRTMIN && second == SIGRTMIN, "two kills, two signals: %d %d", first, second);

	/* Handlers take them in the same order once unblocked. */
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_sigaction = on_queued;
	action.sa_flags = SA_SIGINFO;
	action.sa_mask = set;
	sigaction(SIGRTMIN, &action, NULL);
	sigaction(SIGRTMIN + 1, &action, NULL);
	taken_count = 0;
	queue_value(SIGRTMIN + 1, 40);
	queue_value(SIGRTMIN, 50);
	queue_value(SIGRTMIN, 51);
	sigprocmask(SIG_UNBLOCK, &set, NULL);
	CHECK(taken_count == 3, "three handled: %d", (int)taken_count);
	CHECK(taken_signals[0] == SIGRTMIN && taken_values[0] == 50 && taken_codes[0] == SI_QUEUE &&
		taken_signals[1] == SIGRTMIN && taken_values[1] == 51 &&
		taken_signals[2] == SIGRTMIN + 1 && taken_values[2] == 40,
		"handled in order: %d/%d %d/%d %d/%d", taken_signals[0], taken_values[0], taken_signals[1],
		taken_values[1], taken_signals[2], taken_values[2]);
	signal(SIGRTMIN, SIG_DFL);
	signal(SIGRTMIN + 1, SIG_DFL);
}

/* A signal descriptor reads real-time signals from their queue, in
   order, with their values. */
static void test_signalfd_queue(void) {
	sigset_t set;
	block_only(SIGRTMIN + 6, 0, 0, &set);
	int fd = signalfd(-1, &set, SFD_NONBLOCK);
	CHECK(fd >= 0, "signalfd: %s", strerror(errno));
	queue_value(SIGRTMIN + 6, 61);
	queue_value(SIGRTMIN + 6, 62);
	struct signalfd_siginfo items[2];
	memset(items, 0, sizeof(items));
	ssize_t got = read(fd, items, sizeof(items));
	CHECK(got == (ssize_t)sizeof(items) && items[0].ssi_signo == (uint32_t)(SIGRTMIN + 6) &&
		items[0].ssi_int == 61 && items[1].ssi_int == 62 && items[0].ssi_code == SI_QUEUE &&
		items[0].ssi_pid == (uint32_t)getpid(), "signalfd: %zd bytes, values %d %d, code %d", got,
		items[0].ssi_int, items[1].ssi_int, items[0].ssi_code);
	errno = 0;
	CHECK(read(fd, items, sizeof(items)) < 0 && errno == EAGAIN, "signalfd emptied the queue");
	close(fd);
	sigprocmask(SIG_UNBLOCK, &set, NULL);
}

static void *send_later(void *argument) {
	(void)argument;
	usleep(30000);
	union sigval value;
	value.sival_ptr = NULL;
	value.sival_int = 77;
	sigqueue(getpid(), SIGRTMIN + 2, value);
	return NULL;
}

/* sigtimedwait: a timeout, a signal from another thread, one from
   another process. */
static void test_timed_waits(void) {
	sigset_t set;
	block_only(SIGRTMIN + 2, SIGRTMIN + 3, 0, &set);

	struct timespec start;
	clock_gettime(CLOCK_MONOTONIC, &start);
	struct timespec timeout = {0, 50000000};
	errno = 0;
	int signal = sigtimedwait(&set, NULL, &timeout);
	long waited = milliseconds_since(&start);
	CHECK(signal < 0 && errno == EAGAIN && waited >= 45, "the timeout passed: %d %s after %ld ms", signal,
		strerror(errno), waited);

	pthread_t sender;
	pthread_create(&sender, NULL, send_later, NULL);
	siginfo_t info;
	memset(&info, 0, sizeof(info));
	signal = sigwaitinfo(&set, &info);
	pthread_join(sender, NULL);
	CHECK(signal == SIGRTMIN + 2 && info.si_value.sival_int == 77, "from a thread: %d value %d", signal,
		info.si_value.sival_int);

	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		union sigval value;
		value.sival_ptr = NULL;
		value.sival_int = 5;
		usleep(20000);
		sigqueue(getppid(), SIGRTMIN + 3, value);
		_exit(0);
	}
	timeout.tv_sec = 5;
	timeout.tv_nsec = 0;
	memset(&info, 0, sizeof(info));
	signal = sigtimedwait(&set, &info, &timeout);
	int status;
	waitpid(child, &status, 0);
	CHECK(signal == SIGRTMIN + 3 && info.si_pid == child && info.si_code == SI_QUEUE &&
		info.si_value.sival_int == 5, "from a child: %d pid %d (child %d) code %d", signal, (int)info.si_pid,
		(int)child, info.si_code);
	sigprocmask(SIG_UNBLOCK, &set, NULL);
}

/* --- The alternate signal stack --------------------------------------- */

static char *alternate_stack;
static size_t alternate_size;
static volatile uintptr_t handler_local;
static volatile int handler_saw_on_stack;
static volatile int change_refused;

static void on_alternate(int signal) {
	(void)signal;
	int local = 0;
	handler_local = (uintptr_t)&local;
	stack_t now;
	sigaltstack(NULL, &now);
	handler_saw_on_stack = (now.ss_flags & SS_ONSTACK) != 0;
	stack_t other;
	memset(&other, 0, sizeof(other));
	other.ss_sp = alternate_stack;
	other.ss_size = alternate_size;
	change_refused = sigaltstack(&other, NULL) < 0 && errno == EPERM;
}

static int on_alternate_stack(uintptr_t address) {
	return address >= (uintptr_t)alternate_stack && address < (uintptr_t)alternate_stack + alternate_size;
}

static void test_alternate_stack(void) {
	alternate_size = 64 * 1024;
	alternate_stack = malloc(alternate_size);
	stack_t stack;
	stack_t previous;
	memset(&stack, 0, sizeof(stack));
	stack.ss_sp = alternate_stack;
	stack.ss_size = alternate_size;
	CHECK(sigaltstack(&stack, &previous) == 0 && (previous.ss_flags & SS_DISABLE), "sigaltstack set");
	stack_t now;
	CHECK(sigaltstack(NULL, &now) == 0 && now.ss_sp == alternate_stack && now.ss_size == alternate_size &&
		now.ss_flags == 0, "sigaltstack read back: flags %d", now.ss_flags);

	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = on_alternate;
	action.sa_flags = SA_ONSTACK;
	sigaction(SIGUSR1, &action, NULL);
	raise(SIGUSR1);
	CHECK(on_alternate_stack(handler_local), "the handler ran on the alternate stack (%#lx)",
		(unsigned long)handler_local);
	CHECK(handler_saw_on_stack, "SS_ONSTACK in the handler");
	CHECK(change_refused, "no change while on it");

	/* Without SA_ONSTACK, the thread's own stack. */
	action.sa_flags = 0;
	sigaction(SIGUSR1, &action, NULL);
	raise(SIGUSR1);
	CHECK(!on_alternate_stack(handler_local), "without SA_ONSTACK, the thread's stack");
	signal(SIGUSR1, SIG_DFL);

	stack.ss_size = 100;
	errno = 0;
	CHECK(sigaltstack(&stack, NULL) < 0 && errno == ENOMEM, "too small: %s", strerror(errno));
	memset(&stack, 0, sizeof(stack));
	stack.ss_flags = SS_DISABLE;
	CHECK(sigaltstack(&stack, NULL) == 0, "disabled");
	CHECK(sigaltstack(NULL, &now) == 0 && (now.ss_flags & SS_DISABLE), "reads as disabled");
	free(alternate_stack);
}

/* It never returns: it runs into the end of the stack on purpose. */
#pragma GCC diagnostic ignored "-Winfinite-recursion"
__attribute__((noinline)) static int recurse(int depth) {
	volatile char frame[1024];
	frame[0] = (char)depth;
	frame[sizeof(frame) - 1] = (char)depth;
	return recurse(depth + 1) + frame[0] + frame[sizeof(frame) - 1];
}

static void on_overflow(int signal) {
	_exit(signal == SIGSEGV ? 42 : 43);
}

/* Sets an alternate stack and a SIGSEGV handler on it, then overflows
   the stack: the handler exits with 42. */
static void overflow_with_handler(void) {
	stack_t stack;
	memset(&stack, 0, sizeof(stack));
	stack.ss_size = 64 * 1024;
	stack.ss_sp = malloc(stack.ss_size);
	sigaltstack(&stack, NULL);
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = on_overflow;
	action.sa_flags = SA_ONSTACK;
	sigaction(SIGSEGV, &action, NULL);
	recurse(0);
	_exit(1);
}

static void *overflow_thread(void *argument) {
	(void)argument;
	overflow_with_handler();
	return NULL;
}

static void check_overflow_child(int in_thread) {
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		if (in_thread) {
			pthread_attr_t attributes;
			pthread_attr_init(&attributes);
			pthread_attr_setstacksize(&attributes, 128 * 1024);
			pthread_t thread;
			pthread_create(&thread, &attributes, overflow_thread, NULL);
			pthread_join(thread, NULL);
			_exit(2);
		}
		overflow_with_handler();
	}
	int status = 0;
	waitpid(child, &status, 0);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 42, "a stack overflow (%s) handled on the alternate stack: %#x",
		in_thread ? "thread" : "main thread", status);
}

/* --- SA_RESTART ---------------------------------------------------------- */

static volatile sig_atomic_t restart_alarms;

static void on_restart_alarm(int signal) {
	(void)signal;
	restart_alarms++;
}

static int writer_end;

static void *write_later(void *argument) {
	(void)argument;
	usleep(150000);
	write(writer_end, "r", 1);
	return NULL;
}

/* A read waiting on a pipe, an alarm in the middle; returns read's
   result and its errno. */
static int read_through_alarm(int flags, int *read_errno) {
	int ends[2];
	pipe(ends);
	writer_end = ends[1];
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = on_restart_alarm;
	action.sa_flags = flags;
	sigaction(SIGALRM, &action, NULL);
	/* The writer does not take the alarm. */
	sigset_t alarm_only;
	block_only(SIGALRM, 0, 0, &alarm_only);
	pthread_t writer;
	pthread_create(&writer, NULL, write_later, NULL);
	sigprocmask(SIG_UNBLOCK, &alarm_only, NULL);
	restart_alarms = 0;
	struct itimerval timer;
	memset(&timer, 0, sizeof(timer));
	timer.it_value.tv_usec = 40000;
	setitimer(ITIMER_REAL, &timer, NULL);
	char byte = 0;
	errno = 0;
	int result = (int)read(ends[0], &byte, 1);
	*read_errno = errno;
	pthread_join(writer, NULL);
	close(ends[0]);
	close(ends[1]);
	return result;
}

static void test_restart(void) {
	int read_errno = 0;
	int result = read_through_alarm(SA_RESTART, &read_errno);
	CHECK(result == 1 && restart_alarms == 1, "SA_RESTART: read made again (%d, %s, %d alarms)", result,
		strerror(read_errno), (int)restart_alarms);
	result = read_through_alarm(0, &read_errno);
	CHECK(result < 0 && read_errno == EINTR && restart_alarms == 1, "no SA_RESTART: EINTR (%d, %s)", result,
		strerror(read_errno));

	/* Sleeps are never made again. */
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = on_restart_alarm;
	action.sa_flags = SA_RESTART;
	sigaction(SIGALRM, &action, NULL);
	struct itimerval timer;
	memset(&timer, 0, sizeof(timer));
	timer.it_value.tv_usec = 30000;
	setitimer(ITIMER_REAL, &timer, NULL);
	struct timespec nap = {2, 0};
	errno = 0;
	result = nanosleep(&nap, NULL);
	CHECK(result < 0 && errno == EINTR, "nanosleep is not restarted: %d %s", result, strerror(errno));
	signal(SIGALRM, SIG_DFL);
}

void test_realtime_signals(void) {
	CHECK(SIGRTMAX - SIGRTMIN >= 8, "real-time signals %d..%d", SIGRTMIN, SIGRTMAX);
	test_queue_order();
	test_signalfd_queue();
	test_timed_waits();
	test_alternate_stack();
	check_overflow_child(0);
	check_overflow_child(1);
	test_restart();
}
