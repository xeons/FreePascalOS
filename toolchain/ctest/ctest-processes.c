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

/* fork, exec, waitpid, posix_spawn, exit statuses, pipes between
   processes. */

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "ctest.h"

extern char **environ;

/* Reads everything from fd into buffer (a string). */
static void read_all(int fd, char *buffer, size_t size) {
	size_t total = 0;
	ssize_t count;
	memset(buffer, 0, size);
	while (total + 1 < size && (count = read(fd, buffer + total, size - 1 - total)) > 0)
		total += (size_t)count;
}

static void *keep_sleeping(void *argument) {
	(void)argument;
	for (;;)
		usleep(1000);
	return NULL;
}

/* exec from a process with another thread running: the thread ends. */
static void test_exec_with_threads(void) {
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		pthread_t thread;
		pthread_create(&thread, NULL, keep_sleeping, NULL);
		usleep(5000);
		execl("/usr/bin/hello", "/usr/bin/hello", "threaded", (char *)NULL);
		_exit(127);
	}
	int status = 0;
	CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
		"exec with a thread running: status %#x", status);
}

void test_processes(void) {
	int shared = 1;
	fflush(stdout);
	pid_t child = fork();
	CHECK(child >= 0, "fork: %s", strerror(errno));
	if (child == 0) {
		/* The child's memory is its own copy. */
		shared = 2;
		_exit(shared == 2 && getppid() > 0 ? 42 : 1);
	}
	int status = 0;
	CHECK(waitpid(child, &status, 0) == child, "waitpid");
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 42, "child status %#x", status);
	CHECK(shared == 1, "the parent's memory changed");

	fflush(stdout);
	child = fork();
	if (child == 0) {
		char *arguments[] = {"/usr/bin/hello", "from-exec", NULL};
		execve("/usr/bin/hello", arguments, environ);
		_exit(127);
	}
	CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
		"fork and exec: status %#x", status);

	fflush(stdout);
	child = fork();
	if (child == 0) {
		execl("/usr/bin/does-not-exist", "does-not-exist", (char *)NULL);
		_exit(errno == ENOENT ? 33 : 34);
	}
	CHECK(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 33,
		"exec of a missing program: status %#x", status);

	fflush(stdout);
	child = fork();
	if (child == 0) {
		kill(getpid(), SIGKILL);
		_exit(0);
	}
	CHECK(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL,
		"killed child: status %#x", status);

	pid_t spawned;
	char *arguments[] = {"/usr/bin/hello", "spawned", NULL};
	CHECK(posix_spawn(&spawned, "/usr/bin/hello", NULL, NULL, arguments, environ) == 0, "posix_spawn");
	CHECK(waitpid(spawned, &status, 0) == spawned && WIFEXITED(status) && WEXITSTATUS(status) == 0,
		"posix_spawn status %#x", status);

	CHECK(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD, "no children left");

	/* Several children at once, reaped in any order. */
	for (int i = 0; i < 5; i++) {
		fflush(stdout);
		if (fork() == 0)
			_exit(10 + i);
	}
	int sum = 0;
	for (int i = 0; i < 5; i++) {
		if (wait(&status) > 0 && WIFEXITED(status))
			sum += WEXITSTATUS(status);
	}
	CHECK(sum == 10 + 11 + 12 + 13 + 14, "five children summed to %d", sum);

	fflush(stdout);
	pid_t group_child = fork();
	if (group_child == 0)
		_exit(setpgid(0, 0) == 0 && getpgrp() == getpid() ? 0 : 1);
	CHECK(waitpid(group_child, &status, 0) == group_child && WEXITSTATUS(status) == 0, "setpgid");
	test_exec_with_threads();
}

void test_pipes(void) {
	int ends[2];
	char buffer[128];
	CHECK(pipe(ends) == 0, "pipe: %s", strerror(errno));
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		close(ends[0]);
		const char *message = "ping through a pipe";
		write(ends[1], message, strlen(message));
		_exit(0);
	}
	close(ends[1]);
	read_all(ends[0], buffer, sizeof(buffer));
	close(ends[0]);
	waitpid(child, NULL, 0);
	CHECK(strcmp(buffer, "ping through a pipe") == 0, "read '%s'", buffer);

	/* A child's standard output into a pipe (dup2 before exec). */
	CHECK(pipe(ends) == 0, "pipe");
	fflush(stdout);
	child = fork();
	if (child == 0) {
		dup2(ends[1], 1);
		close(ends[0]);
		close(ends[1]);
		execl("/usr/bin/hello", "/usr/bin/hello", "piped", (char *)NULL);
		_exit(127);
	}
	close(ends[1]);
	read_all(ends[0], buffer, sizeof(buffer));
	close(ends[0]);
	waitpid(child, NULL, 0);
	CHECK(strstr(buffer, "hello from C") != NULL, "piped output '%s'", buffer);

	/* A program of the system's own runtime (Free Pascal), exec'd from C. */
	CHECK(pipe(ends) == 0, "pipe");
	fflush(stdout);
	child = fork();
	if (child == 0) {
		dup2(ends[1], 1);
		close(ends[0]);
		close(ends[1]);
		execl("/bin/echo", "echo", "from", "pascal", (char *)NULL);
		_exit(127);
	}
	close(ends[1]);
	read_all(ends[0], buffer, sizeof(buffer));
	close(ends[0]);
	int status = 0;
	waitpid(child, &status, 0);
	CHECK(strcmp(buffer, "from pascal\n") == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0,
		"/bin/echo said '%s', status %#x", buffer, status);

	FILE *output = popen("/usr/bin/hello", "r");
	CHECK(output != NULL, "popen: %s", strerror(errno));
	if (output) {
		char line[128] = {0};
		CHECK(fgets(line, sizeof(line), output) && strstr(line, "hello from C"), "popen read '%s'", line);
		pclose(output);
	}
}
