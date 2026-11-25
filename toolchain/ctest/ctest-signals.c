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

/* Signals: handlers, masks, pending signals, SIGCHLD, SIGPIPE, SIGSEGV
   from a fault, and signals between processes. */

#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#include "ctest.h"

static volatile sig_atomic_t user1_count;
static volatile sig_atomic_t child_signals;
static volatile int user1_sender;
static sigjmp_buf fault_return;
/* Read at run time, so the compiler does not see the bad access. */
static volatile unsigned long unmapped_address = 16;

static void on_user1(int signal, siginfo_t *info, void *context) {
	(void)context;
	if (signal == SIGUSR1)
		user1_count++;
	user1_sender = info ? info->si_pid : -1;
}

static void on_child(int signal) {
	(void)signal;
	child_signals++;
}

static volatile sig_atomic_t alarms;

static void on_alarm(int signal) {
	(void)signal;
	alarms++;
}

/* alarm, setitimer with a period, and cancelling. */
static void test_alarms(void) {
	signal(SIGALRM, on_alarm);
	alarm(1);
	alarm(0);
	struct itimerval timer;
	memset(&timer, 0, sizeof(timer));
	timer.it_value.tv_usec = 20000;
	timer.it_interval.tv_usec = 20000;
	CHECK(setitimer(ITIMER_REAL, &timer, NULL) == 0, "setitimer");
	for (int i = 0; i < 300 && alarms < 3; i++)
		usleep(5000);
	memset(&timer, 0, sizeof(timer));
	setitimer(ITIMER_REAL, &timer, NULL);
	CHECK(alarms >= 3, "a periodic timer fired %d times", (int)alarms);
	int seen = alarms;
	usleep(60000);
	CHECK(alarms == seen, "the timer stopped");
	signal(SIGALRM, SIG_DFL);
}

static void on_fault(int signal) {
	siglongjmp(fault_return, signal);
}

/* A child that waits for SIGTERM while blocking it: exits with 7 once
   the signal is pending. */
static void wait_for_blocked_term(void) {
	sigset_t only_term;
	sigemptyset(&only_term);
	sigaddset(&only_term, SIGTERM);
	sigprocmask(SIG_BLOCK, &only_term, NULL);
	for (int i = 0; i < 2000; i++) {
		sigset_t waiting;
		sigpending(&waiting);
		if (sigismember(&waiting, SIGTERM))
			_exit(7);
		usleep(1000);
	}
	_exit(8);
}

void test_signals(void) {
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_sigaction = on_user1;
	action.sa_flags = SA_SIGINFO;
	sigemptyset(&action.sa_mask);
	CHECK(sigaction(SIGUSR1, &action, NULL) == 0, "sigaction");
	CHECK(raise(SIGUSR1) == 0, "raise");
	CHECK(user1_count == 1, "handler ran %d times", (int)user1_count);
	CHECK(user1_sender == getpid(), "sender %d", user1_sender);

	sigset_t blocked, previous, pending;
	sigemptyset(&blocked);
	sigaddset(&blocked, SIGUSR1);
	CHECK(sigprocmask(SIG_BLOCK, &blocked, &previous) == 0, "sigprocmask");
	kill(getpid(), SIGUSR1);
	CHECK(user1_count == 1, "a blocked signal waits");
	sigpending(&pending);
	CHECK(sigismember(&pending, SIGUSR1), "sigpending");
	sigprocmask(SIG_SETMASK, &previous, NULL);
	CHECK(user1_count == 2, "unblocked, it arrived (%d)", (int)user1_count);

	signal(SIGCHLD, on_child);
	fflush(stdout);
	pid_t child = fork();
	if (child == 0)
		_exit(0);
	int status;
	waitpid(child, &status, 0);
	for (int i = 0; i < 100 && child_signals == 0; i++)
		usleep(1000);
	CHECK(child_signals >= 1, "SIGCHLD");
	signal(SIGCHLD, SIG_DFL);

	/* A pipe nobody reads: SIGPIPE, ignored here, so EPIPE. */
	signal(SIGPIPE, SIG_IGN);
	int ends[2];
	pipe(ends);
	close(ends[0]);
	errno = 0;
	CHECK(write(ends[1], "x", 1) < 0 && errno == EPIPE, "EPIPE (%s)", strerror(errno));
	close(ends[1]);
	signal(SIGPIPE, SIG_DFL);

	/* A fault becomes SIGSEGV. */
	signal(SIGSEGV, on_fault);
	int caught = sigsetjmp(fault_return, 1);
	if (caught == 0) {
		volatile int *nowhere = (volatile int *)unmapped_address;
		*nowhere = 1;
	}
	CHECK(caught == SIGSEGV, "SIGSEGV caught: %d", caught);
	signal(SIGSEGV, SIG_DFL);

	/* A child ended by a signal it does not handle. */
	fflush(stdout);
	child = fork();
	if (child == 0) {
		pause();
		_exit(0);
	}
	usleep(20000);
	kill(child, SIGTERM);
	CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM,
		"SIGTERM ended the child: %#x", status);

	/* One that blocks SIGTERM and sees it pending. */
	fflush(stdout);
	child = fork();
	if (child == 0)
		wait_for_blocked_term();
	usleep(20000);
	kill(child, SIGTERM);
	CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 7,
		"a blocked SIGTERM waited in the child: %#x", status);
	CHECK(kill(999999, 0) < 0 && errno == ESRCH, "kill of nobody");
	test_alarms();
}
