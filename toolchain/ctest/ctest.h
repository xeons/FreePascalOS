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

/* The C test suite's checks: each group is a function that counts its
   checks and failures through CHECK; ctest.c runs the groups. */

#ifndef CTEST_H
#define CTEST_H

#include <stdio.h>

extern int ctest_checks;
extern int ctest_failures;

#define CHECK(condition, ...)                                                  \
	do {                                                                       \
		ctest_checks++;                                                        \
		if (!(condition)) {                                                    \
			ctest_failures++;                                                  \
			printf("ctest: FAILED %s:%d: %s: ", __FILE__, __LINE__, #condition); \
			printf(__VA_ARGS__);                                               \
			printf("\n");                                                      \
			fflush(stdout);                                                    \
		}                                                                      \
	} while (0)

void test_stdio(void);
void test_memory(void);
void test_strings(void);
void test_math(void);
void test_time(void);
void test_files(void);
void test_environment(void);
void test_threads(void);
void test_processes(void);
void test_pipes(void);
void test_signals(void);
void test_sockets(void);
void test_dlopen(void);
void test_security(void);

/* ctest's helper modes (ctest-security.c), chosen by its first argument. */
int ctest_report_effective_user(void);
int ctest_check_pending_usr1(void);
int ctest_exec_loop(const char *rounds_text);

#endif
