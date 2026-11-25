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

/* What processes must not be able to do to each other: memory shared by
   fork made writable on one side, a set-user-ID program swapped for
   another while it starts, a set-user-ID program trusting LD_PRELOAD,
   kill(-1) and group stop signals reaching the wrong processes, fork past
   a restriction or a process limit, exec dropping pending signals, and
   another process's details read while it execs again and again. Runs as
   root (make c-test starts ctest first) and drops to other users in
   children. */

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <freepascalos/syscall.h>

#include "ctest.h"

#define SUID_HELPER "/usr/bin/ctest-suid"
#define CTEST_PROGRAM "/usr/bin/ctest"
#define RACE_LINK "/tmp/ctest-race-link"
#define RACE_LINK_SPARE "/tmp/ctest-race-link-new"
#define RACE_ROUNDS 200
#define EXEC_LOOP_ROUNDS 100

/* Kernel calls and values of Abi.SystemCalls not in the C library. */
#define CALL_LIST_PROCESS_DETAILS 96
#define CALL_GET_PROCESS_RESOURCES 130
#define CALL_SET_PROCESS_LIMIT 131
#define PROCESS_LIMIT_PROCESSES 4
#define PROCESS_LIMIT_RESTRICTIONS 6
#define RESTRICT_PROCESS_CREATION 0x08

static int wait_status(pid_t child) {
	int status = -1;
	if (waitpid(child, &status, 0) != child)
		return -1;
	return status;
}

static int exited_with(int status, int code) {
	return status >= 0 && WIFEXITED(status) && WEXITSTATUS(status) == code;
}

static void sleep_milliseconds(long milliseconds) {
	struct timespec pause = {milliseconds / 1000, (milliseconds % 1000) * 1000000};
	nanosleep(&pause, NULL);
}

/* --- fork and memory protection ------------------------------------------- */

/* A page read-only (or inaccessible) at fork, made writable afterwards
   by one side: the other side keeps what it had. */
static void test_fork_protection(int protection, const char *what) {
	char *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(page != MAP_FAILED, "%s: mmap: %s", what, strerror(errno));
	if (page == MAP_FAILED)
		return;
	page[0] = 1;
	CHECK(mprotect(page, 4096, protection) == 0, "%s: mprotect: %s", what, strerror(errno));
	int go[2];
	CHECK(pipe(go) == 0, "pipe");
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		/* The child writes first; then it waits while the parent writes. */
		mprotect(page, 4096, PROT_READ | PROT_WRITE);
		page[0] = 2;
		char byte;
		close(go[1]);
		if (read(go[0], &byte, 1) != 1)
			_exit(3);
		_exit(page[0] == 2 ? 0 : 1);
	}
	close(go[0]);
	sleep_milliseconds(50);
	mprotect(page, 4096, PROT_READ | PROT_WRITE);
	CHECK(page[0] == 1, "%s: the child's write reached the parent (%d)", what, page[0]);
	page[0] = 3;
	CHECK(write(go[1], "x", 1) == 1, "write");
	close(go[1]);
	int status = wait_status(child);
	CHECK(exited_with(status, 0), "%s: the parent's write reached the child (status %#x)", what, status);
	munmap(page, 4096);
}

/* --- Set-user-ID programs ---------------------------------------------------- */

static volatile int race_running;

/* Swaps the race link between the set-user-ID helper and ctest. */
static void *swap_links(void *argument) {
	(void)argument;
	int to_ctest = 0;
	while (race_running) {
		unlink(RACE_LINK_SPARE);
		symlink(to_ctest ? CTEST_PROGRAM : SUID_HELPER, RACE_LINK_SPARE);
		rename(RACE_LINK_SPARE, RACE_LINK);
		to_ctest = !to_ctest;
	}
	return NULL;
}

/* As a user, execs the link while another thread swaps it: ctest run as
   root (exit 66) would be the set-user-ID helper's owner given to
   another program. Exits 0 when that never happened and both ran. */
static void run_exec_race(void) {
	if (setgid(1000) != 0 || setuid(1000) != 0)
		_exit(4);
	unlink(RACE_LINK);
	symlink(SUID_HELPER, RACE_LINK);
	race_running = 1;
	pthread_t thread;
	if (pthread_create(&thread, NULL, swap_links, NULL) != 0)
		_exit(5);
	int as_root = 0, as_user = 0, helper = 0;
	for (int round = 0; round < RACE_ROUNDS; round++) {
		pid_t child = fork();
		if (child == 0) {
			execl(RACE_LINK, RACE_LINK, "--report-euid", (char *)NULL);
			_exit(127);
		}
		int status = wait_status(child);
		if (exited_with(status, 66))
			as_root++;
		else if (exited_with(status, 7))
			as_user++;
		else if (exited_with(status, 0))
			helper++;
	}
	race_running = 0;
	pthread_join(thread, NULL);
	unlink(RACE_LINK);
	unlink(RACE_LINK_SPARE);
	printf("ctest: exec race: %d set-user-ID runs, %d as the user, %d as root\n", helper, as_user, as_root);
	fflush(stdout);
	if (as_root > 0)
		_exit(1);
	_exit(as_user > 0 && helper > 0 ? 0 : 2);
}

static void test_setuid_programs(void) {
	if (access(SUID_HELPER, X_OK) != 0) {
		printf("ctest: %s is not there, set-user-ID checks skipped\n", SUID_HELPER);
		return;
	}
	fflush(stdout);
	pid_t child = fork();
	if (child == 0)
		run_exec_race();
	int status = wait_status(child);
	CHECK(exited_with(status, 0), "a set-user-ID program swapped while it starts (status %#x)", status);

	/* Run by a user, the helper is secure: its dynamic linker ignores
	   LD_PRELOAD and LD_LIBRARY_PATH, and the auxiliary vector has the
	   credentials it runs with. */
	fflush(stdout);
	child = fork();
	if (child == 0) {
		if (setgid(1000) != 0 || setuid(1000) != 0)
			_exit(4);
		setenv("LD_PRELOAD", "/usr/lib/libctestplugin.so", 1);
		setenv("LD_LIBRARY_PATH", "/tmp", 1);
		execl(SUID_HELPER, SUID_HELPER, "--secure", (char *)NULL);
		_exit(127);
	}
	status = wait_status(child);
	CHECK(exited_with(status, 0), "a set-user-ID program run by a user is secure (status %#x)", status);

	/* Run by root (its owner), it is not. */
	fflush(stdout);
	child = fork();
	if (child == 0) {
		execl(SUID_HELPER, SUID_HELPER, "--not-secure", (char *)NULL);
		_exit(127);
	}
	status = wait_status(child);
	CHECK(exited_with(status, 0), "a set-user-ID program run by its owner is not secure (status %#x)", status);
}

/* --- Signals ----------------------------------------------------------------- */

/* Waits up to a second for child to stop or end; its waitpid status. */
static int wait_for_stop(pid_t child) {
	for (int tries = 0; tries < 100; tries++) {
		int status = 0;
		pid_t waited = waitpid(child, &status, WNOHANG | WUNTRACED);
		if (waited == child)
			return status;
		sleep_milliseconds(10);
	}
	return -1;
}

/* kill(-1, SIGSTOP) by a user stops that user's other processes, in
   whatever group they are (not process group 1). */
static void test_kill_everyone_stops(void) {
	fflush(stdout);
	pid_t victim = fork();
	if (victim == 0) {
		setpgid(0, 0);
		if (setgid(2001) != 0 || setuid(2001) != 0)
			_exit(4);
		for (;;)
			sleep_milliseconds(10);
	}
	sleep_milliseconds(50);
	pid_t sender = fork();
	if (sender == 0) {
		if (setgid(2001) != 0 || setuid(2001) != 0)
			_exit(4);
		_exit(kill(-1, SIGSTOP) == 0 ? 0 : 1);
	}
	int status = wait_status(sender);
	CHECK(exited_with(status, 0), "kill(-1, SIGSTOP) by a user (status %#x)", status);
	status = wait_for_stop(victim);
	CHECK(status >= 0 && WIFSTOPPED(status), "kill(-1, SIGSTOP) stops the user's process (status %#x)", status);
	kill(victim, SIGKILL);
	waitpid(victim, NULL, 0);
}

static volatile sig_atomic_t terminal_stop_handled;

static void note_terminal_stop(int signal) {
	(void)signal;
	terminal_stop_handled = 1;
}

/* A stop signal sent to a group is handled by a member that handles it,
   not taken for a stop. */
static void test_group_stop_handled(void) {
	int ready[2];
	CHECK(pipe(ready) == 0, "pipe");
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		setpgid(0, 0);
		signal(SIGTSTP, note_terminal_stop);
		close(ready[0]);
		if (write(ready[1], "x", 1) != 1)
			_exit(3);
		for (int tries = 0; tries < 200 && !terminal_stop_handled; tries++)
			sleep_milliseconds(10);
		_exit(terminal_stop_handled ? 0 : 1);
	}
	close(ready[1]);
	char byte;
	CHECK(read(ready[0], &byte, 1) == 1, "the child is ready");
	close(ready[0]);
	CHECK(kill(-child, SIGTSTP) == 0, "kill(-group, SIGTSTP): %s", strerror(errno));
	int status = wait_for_stop(child);
	if (status >= 0 && WIFSTOPPED(status)) {
		kill(child, SIGKILL);
		waitpid(child, NULL, 0);
	}
	CHECK(exited_with(status, 0), "a handled SIGTSTP sent to a group is delivered (status %#x)", status);
}

/* A signal pending (blocked) at exec is still pending in the new program. */
static void test_exec_keeps_pending(void) {
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		sigset_t set;
		sigemptyset(&set);
		sigaddset(&set, SIGUSR1);
		sigprocmask(SIG_BLOCK, &set, NULL);
		raise(SIGUSR1);
		execl(CTEST_PROGRAM, CTEST_PROGRAM, "--check-pending-usr1", (char *)NULL);
		_exit(127);
	}
	int status = wait_status(child);
	CHECK(exited_with(status, 0), "exec keeps a pending signal (status %#x)", status);
}

/* --- fork's limits ----------------------------------------------------------- */

static void test_fork_limits(void) {
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		fpos_syscall2(CALL_SET_PROCESS_LIMIT, PROCESS_LIMIT_RESTRICTIONS, RESTRICT_PROCESS_CREATION);
		pid_t grandchild = fork();
		if (grandchild == 0)
			_exit(0);
		_exit(grandchild < 0 && errno == EACCES ? 0 : 1);
	}
	int status = wait_status(child);
	CHECK(exited_with(status, 0), "a process restricted from creating processes cannot fork (status %#x)", status);

	fflush(stdout);
	child = fork();
	if (child == 0) {
		if (setgid(2002) != 0 || setuid(2002) != 0)
			_exit(4);
		/* One process for this user: itself. */
		if (fpos_syscall2(CALL_SET_PROCESS_LIMIT, PROCESS_LIMIT_PROCESSES, 1) < 0)
			_exit(5);
		pid_t grandchild = fork();
		if (grandchild == 0)
			_exit(0);
		if (grandchild > 0)
			waitpid(grandchild, NULL, 0);
		_exit(grandchild < 0 && errno == EAGAIN ? 0 : 1);
	}
	status = wait_status(child);
	CHECK(exited_with(status, 0), "fork stops at the user's process limit (status %#x)", status);
}

/* --- Reading a process that execs ------------------------------------------- */

/* Another process's details and resources, read over and over while it
   replaces its program again and again: the kernel must never read an
   address space that exec let go. */
static void test_details_during_exec(void) {
	static unsigned char details[64 * 1024];
	static unsigned char resources[4096];
	char rounds[16];
	snprintf(rounds, sizeof(rounds), "%d", EXEC_LOOP_ROUNDS);
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		execl(CTEST_PROGRAM, CTEST_PROGRAM, "--exec-loop", rounds, (char *)NULL);
		_exit(127);
	}
	int status = -1;
	long reads = 0;
	for (;;) {
		fpos_syscall2(CALL_GET_PROCESS_RESOURCES, child, (long)resources);
		fpos_syscall2(CALL_LIST_PROCESS_DETAILS, (long)details, 16);
		reads++;
		pid_t waited = waitpid(child, &status, WNOHANG);
		if (waited == child)
			break;
	}
	CHECK(exited_with(status, 0), "a process exec'ing %d times while read %ld times (status %#x)",
		EXEC_LOOP_ROUNDS, reads, status);
}

void test_security(void) {
	test_fork_protection(PROT_READ, "read-only");
	test_fork_protection(PROT_NONE, "inaccessible");
	test_setuid_programs();
	test_kill_everyone_stops();
	test_group_stop_handled();
	test_exec_keeps_pending();
	test_fork_limits();
	test_details_during_exec();
}

/* --- Helper modes of ctest (ctest.c) ----------------------------------------- */

int ctest_report_effective_user(void) {
	return geteuid() == 0 ? 66 : 7;
}

int ctest_check_pending_usr1(void) {
	sigset_t pending;
	sigemptyset(&pending);
	if (sigpending(&pending) != 0)
		return 2;
	return sigismember(&pending, SIGUSR1) ? 0 : 1;
}

int ctest_exec_loop(const char *rounds_text) {
	int rounds = atoi(rounds_text);
	if (rounds <= 0)
		return 0;
	char next[16];
	snprintf(next, sizeof(next), "%d", rounds - 1);
	execl(CTEST_PROGRAM, CTEST_PROGRAM, "--exec-loop", next, (char *)NULL);
	return 127;
}
