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

/* The C test suite (/usr/bin/ctest): the C library and the kernel's POSIX
   calls, group by group, then the C++ test (/usr/bin/cxxtest) and the
   static hello world as programs of their own. Exits with 0 when every
   check passed. make c-test boots with it as the first program; a
   coretest line runs it when the system disk has it. */

#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "ctest.h"

int ctest_checks;
int ctest_failures;

struct test_group {
	const char *name;
	void (*run)(void);
};

static const struct test_group groups[] = {
	{"stdio", test_stdio},
	{"memory", test_memory},
	{"strings", test_strings},
	{"math", test_math},
	{"time", test_time},
	{"files", test_files},
	{"environment", test_environment},
	{"threads", test_threads},
	{"processes", test_processes},
	{"pipes", test_pipes},
	{"signals", test_signals},
	{"sockets", test_sockets},
	{"dlopen", test_dlopen},
	{"security", test_security},
};

/* Runs a program of the suite; its exit code 0 is a pass. */
static void run_program(const char *path, const char *argument) {
	if (access(path, X_OK) != 0) {
		printf("ctest: %s is not there, skipped\n", path);
		return;
	}
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		execl(path, path, argument, (char *)NULL);
		_exit(127);
	}
	int status = -1;
	pid_t waited = waitpid(child, &status, 0);
	CHECK(waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
		"%s: status %#x", path, status);
}

int main(int argc, char **argv) {
	const char *only = argc > 1 ? argv[1] : NULL;
	/* What the security group runs this program for. */
	if (only && strcmp(only, "--report-euid") == 0)
		return ctest_report_effective_user();
	if (only && strcmp(only, "--check-pending-usr1") == 0)
		return ctest_check_pending_usr1();
	if (only && strcmp(only, "--exec-loop") == 0)
		return ctest_exec_loop(argc > 2 ? argv[2] : "0");
	setvbuf(stdout, NULL, _IOLBF, 0);
	printf("ctest: the C library on FreePascalOS\n");
	for (size_t i = 0; i < sizeof(groups) / sizeof(groups[0]); i++) {
		if (only && strcmp(only, groups[i].name) != 0)
			continue;
		int failures_before = ctest_failures;
		int checks_before = ctest_checks;
		groups[i].run();
		printf("ctest: %s: %d checks, %s\n", groups[i].name, ctest_checks - checks_before,
			ctest_failures == failures_before ? "passed" : "FAILED");
	}
	if (!only) {
		run_program("/usr/bin/hello-static", "static");
		run_program("/usr/bin/cxxtest", NULL);
	}
	if (ctest_failures == 0)
		printf("ctest: all %d checks passed\n", ctest_checks);
	else
		printf("ctest: %d of %d checks FAILED\n", ctest_failures, ctest_checks);
	return ctest_failures == 0 ? 0 : 1;
}
