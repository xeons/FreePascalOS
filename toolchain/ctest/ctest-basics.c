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

/* stdio, memory, strings, math, time, files and the environment. */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include "ctest.h"

void test_stdio(void) {
	char buffer[128];
	snprintf(buffer, sizeof(buffer), "%d %5.2f %s %x %c", 42, 3.14159, "text", 255, 'z');
	CHECK(strcmp(buffer, "42  3.14 text ff z") == 0, "snprintf gave '%s'", buffer);

	FILE *file = fopen("/tmp/ctest-stdio.txt", "w+");
	CHECK(file != NULL, "fopen: %s", strerror(errno));
	if (!file)
		return;
	for (int i = 0; i < 100; i++)
		fprintf(file, "line %d\n", i);
	CHECK(ftell(file) > 600, "ftell %ld", ftell(file));
	rewind(file);
	int count = 0;
	char line[64];
	while (fgets(line, sizeof(line), file))
		count++;
	CHECK(count == 100, "read %d lines", count);
	fseek(file, 5, SEEK_SET);
	CHECK(fgetc(file) == '0', "fseek/fgetc");
	fclose(file);
	CHECK(remove("/tmp/ctest-stdio.txt") == 0, "remove: %s", strerror(errno));

	int value = 0;
	char word[16];
	CHECK(sscanf("17 apples", "%d %15s", &value, word) == 2 && value == 17 && strcmp(word, "apples") == 0,
		"sscanf");
}

void test_memory(void) {
	void *blocks[256];
	for (int i = 0; i < 256; i++) {
		blocks[i] = malloc((size_t)(i * 37 + 1));
		CHECK(blocks[i] != NULL, "malloc %d", i);
		if (blocks[i])
			memset(blocks[i], i, (size_t)(i * 37 + 1));
	}
	for (int i = 0; i < 256; i++)
		free(blocks[i]);
	int *zeros = calloc(1000, sizeof(int));
	int all_zero = 1;
	for (int i = 0; zeros && i < 1000; i++)
		all_zero = all_zero && zeros[i] == 0;
	CHECK(zeros && all_zero, "calloc gives zeros");
	zeros = realloc(zeros, 100000 * sizeof(int));
	CHECK(zeros != NULL, "realloc");
	free(zeros);

	/* Large: mmap'd. */
	size_t large = 16 * 1024 * 1024;
	char *big = malloc(large);
	CHECK(big != NULL, "malloc 16 MiB");
	if (big) {
		big[0] = 1;
		big[large - 1] = 2;
		CHECK(big[0] + big[large - 1] == 3, "large block");
		free(big);
	}

	char *mapping = mmap(NULL, 3 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(mapping != MAP_FAILED, "mmap: %s", strerror(errno));
	if (mapping != MAP_FAILED) {
		mapping[4096] = 'x';
		CHECK(mprotect(mapping, 4096, PROT_READ) == 0, "mprotect: %s", strerror(errno));
		CHECK(munmap(mapping + 4096, 4096) == 0, "munmap middle: %s", strerror(errno));
		CHECK(munmap(mapping, 3 * 4096) == 0, "munmap: %s", strerror(errno));
	}

	/* A file mapped read-only. */
	int fd = open("/tmp/ctest-map.bin", O_RDWR | O_CREAT | O_TRUNC, 0644);
	CHECK(fd >= 0, "open: %s", strerror(errno));
	if (fd >= 0) {
		char data[8192];
		for (int i = 0; i < 8192; i++)
			data[i] = (char)(i * 7);
		CHECK(write(fd, data, sizeof(data)) == (ssize_t)sizeof(data), "write");
		char *view = mmap(NULL, sizeof(data), PROT_READ, MAP_PRIVATE, fd, 0);
		CHECK(view != MAP_FAILED, "mmap file: %s", strerror(errno));
		if (view != MAP_FAILED) {
			CHECK(memcmp(view, data, sizeof(data)) == 0, "mapped file contents");
			munmap(view, sizeof(data));
		}
		close(fd);
		unlink("/tmp/ctest-map.bin");
	}
}

static int compare_ints(const void *a, const void *b) {
	return *(const int *)a - *(const int *)b;
}

void test_strings(void) {
	char text[] = "alpha,beta,,gamma";
	char *save = NULL;
	int tokens = 0;
	for (char *token = strtok_r(text, ",", &save); token; token = strtok_r(NULL, ",", &save))
		tokens++;
	CHECK(tokens == 3, "strtok_r gave %d", tokens);
	CHECK(strstr("haystack with needle", "needle") != NULL, "strstr");
	CHECK(strtol("-0x1f", NULL, 16) == -31, "strtol");
	CHECK(strtoull("18446744073709551615", NULL, 10) == UINT64_MAX, "strtoull");
	CHECK(fabs(strtod("2.5e3", NULL) - 2500.0) < 1e-9, "strtod");
	char overlap[16] = "0123456789";
	memmove(overlap + 2, overlap, 8);
	CHECK(strcmp(overlap, "0101234567") == 0, "memmove gave %s", overlap);
	int numbers[] = {5, 3, 9, 1, 7};
	qsort(numbers, 5, sizeof(int), compare_ints);
	CHECK(numbers[0] == 1 && numbers[4] == 9, "qsort");
	int key = 7;
	CHECK(bsearch(&key, numbers, 5, sizeof(int), compare_ints) != NULL, "bsearch");
	char *copy = strdup("duplicate");
	CHECK(copy && strcmp(copy, "duplicate") == 0, "strdup");
	free(copy);
	CHECK(strcasecmp("HeLLo", "hello") == 0, "strcasecmp");
}

void test_math(void) {
	CHECK(fabs(sqrt(2.0) - 1.41421356237) < 1e-9, "sqrt");
	CHECK(fabs(sin(M_PI / 2) - 1.0) < 1e-12, "sin");
	CHECK(fabs(cos(0.0) - 1.0) < 1e-12, "cos");
	CHECK(fabs(pow(2.0, 10.0) - 1024.0) < 1e-9, "pow");
	CHECK(fabs(exp(1.0) - 2.718281828459) < 1e-9, "exp");
	CHECK(fabs(log(100.0) / log(10.0) - 2.0) < 1e-12, "log");
	CHECK(floor(-2.5) == -3.0 && ceil(-2.5) == -2.0, "floor/ceil");
	CHECK(fabs(fmod(10.5, 3.0) - 1.5) < 1e-12, "fmod");
	CHECK(isnan(NAN) && isinf(INFINITY), "isnan/isinf");
	CHECK(fabs(atan2(1.0, 1.0) - M_PI / 4) < 1e-12, "atan2");
	char text[32];
	snprintf(text, sizeof(text), "%.3e", 12345.678);
	CHECK(strcmp(text, "1.235e+04") == 0, "printf %%e gave %s", text);
}

void test_time(void) {
	struct timespec start, end;
	CHECK(clock_gettime(CLOCK_MONOTONIC, &start) == 0, "clock_gettime");
	struct timespec pause = {0, 20 * 1000 * 1000};
	CHECK(nanosleep(&pause, NULL) == 0, "nanosleep");
	clock_gettime(CLOCK_MONOTONIC, &end);
	long elapsed = (end.tv_sec - start.tv_sec) * 1000 + (end.tv_nsec - start.tv_nsec) / 1000000;
	CHECK(elapsed >= 15 && elapsed < 2000, "slept %ld ms", elapsed);
	time_t now = time(NULL);
	CHECK(now > 1700000000, "time() is %lld", (long long)now);
	struct tm broken;
	CHECK(gmtime_r(&now, &broken) != NULL && broken.tm_year >= 123, "gmtime_r");
}

void test_files(void) {
	rmdir("/tmp/ctest-dir/inner");
	unlink("/tmp/ctest-dir/file.txt");
	unlink("/tmp/ctest-dir/renamed.txt");
	rmdir("/tmp/ctest-dir");
	CHECK(mkdir("/tmp/ctest-dir", 0755) == 0, "mkdir: %s", strerror(errno));
	int fd = open("/tmp/ctest-dir/file.txt", O_WRONLY | O_CREAT | O_EXCL, 0600);
	CHECK(fd >= 0, "open O_CREAT: %s", strerror(errno));
	CHECK(write(fd, "hello", 5) == 5, "write");
	close(fd);
	CHECK(open("/tmp/ctest-dir/file.txt", O_WRONLY | O_CREAT | O_EXCL, 0600) < 0 && errno == EEXIST,
		"O_EXCL on an existing file");
	struct stat status;
	CHECK(stat("/tmp/ctest-dir/file.txt", &status) == 0 && S_ISREG(status.st_mode) && status.st_size == 5,
		"stat");
	CHECK((status.st_mode & 0777) == 0600, "mode %o", (unsigned)(status.st_mode & 0777));
	CHECK(mkdir("/tmp/ctest-dir/inner", 0755) == 0, "mkdir inner");

	int dirfd = open("/tmp/ctest-dir", O_RDONLY | O_DIRECTORY);
	CHECK(dirfd >= 0, "open directory: %s", strerror(errno));
	if (dirfd >= 0) {
		int inner = openat(dirfd, "file.txt", O_RDONLY);
		CHECK(inner >= 0, "openat: %s", strerror(errno));
		char text[8] = {0};
		CHECK(inner >= 0 && read(inner, text, 5) == 5 && strcmp(text, "hello") == 0, "read through openat");
		if (inner >= 0)
			close(inner);
		CHECK(fstatat(dirfd, "inner", &status, 0) == 0 && S_ISDIR(status.st_mode), "fstatat");
		close(dirfd);
	}

	DIR *directory = opendir("/tmp/ctest-dir");
	CHECK(directory != NULL, "opendir: %s", strerror(errno));
	int seen = 0;
	if (directory) {
		struct dirent *entry;
		while ((entry = readdir(directory)) != NULL) {
			if (strcmp(entry->d_name, "file.txt") == 0 && entry->d_type == DT_REG)
				seen |= 1;
			if (strcmp(entry->d_name, "inner") == 0 && entry->d_type == DT_DIR)
				seen |= 2;
		}
		closedir(directory);
	}
	CHECK(seen == 3, "readdir found %d", seen);
	CHECK(rename("/tmp/ctest-dir/file.txt", "/tmp/ctest-dir/renamed.txt") == 0, "rename");
	CHECK(access("/tmp/ctest-dir/renamed.txt", R_OK) == 0, "access");
	CHECK(symlink("renamed.txt", "/tmp/ctest-dir/link") == 0, "symlink: %s", strerror(errno));
	char target[64] = {0};
	CHECK(readlink("/tmp/ctest-dir/link", target, sizeof(target) - 1) == 11 && strcmp(target, "renamed.txt") == 0,
		"readlink gave %s", target);
	CHECK(unlink("/tmp/ctest-dir/link") == 0, "unlink link");
	CHECK(rmdir("/tmp/ctest-dir/renamed.txt") != 0 && errno == ENOTDIR, "rmdir of a file");
	CHECK(unlink("/tmp/ctest-dir/renamed.txt") == 0, "unlink");
	CHECK(rmdir("/tmp/ctest-dir/inner") == 0, "rmdir inner");
	CHECK(rmdir("/tmp/ctest-dir") == 0, "rmdir");
	CHECK(open("/tmp/ctest-dir/none", O_RDONLY) < 0 && errno == ENOENT, "ENOENT");

	int duplicate = dup(1);
	CHECK(duplicate > 2, "dup gave %d", duplicate);
	CHECK(fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0 && fcntl(duplicate, F_GETFD) == FD_CLOEXEC, "FD_CLOEXEC");
	close(duplicate);
}

void test_environment(void) {
	CHECK(setenv("CTEST_VARIABLE", "value", 1) == 0, "setenv");
	CHECK(getenv("CTEST_VARIABLE") && strcmp(getenv("CTEST_VARIABLE"), "value") == 0, "getenv");
	char directory[PATH_MAX];
	CHECK(chdir("/tmp") == 0, "chdir");
	CHECK(getcwd(directory, sizeof(directory)) && strcmp(directory, "/tmp") == 0, "getcwd gave %s", directory);
	chdir("/");
	struct utsname names;
	CHECK(uname(&names) == 0 && strcmp(names.sysname, "FreePascalOS") == 0, "uname: %s", names.sysname);
	CHECK(sysconf(_SC_PAGESIZE) == 4096, "page size");
	CHECK(sysconf(_SC_NPROCESSORS_ONLN) >= 1, "processors");
	CHECK(getpid() > 0 && getppid() >= 0, "getpid");
}
