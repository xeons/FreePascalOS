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

/* Files at the kernel's precision: pread/pwrite leave the offset alone
   and threads sharing a descriptor never see each other's offsets,
   fsync and fdatasync of one file, nanosecond times (utimensat,
   futimens, stat's st_mtim), msync and mincore on a shared mapping, and
   clock_gettime from the clock page against the system call. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#include <freepascalos/syscall.h>

#include "ctest.h"

#define FILE_PATH "/tmp/ctest-fileio.bin"
#define BLOCK 512
#define BLOCKS 64
#define ROUNDS 40

static int shared_fd;

/* Each thread writes and reads back its own blocks with pwrite/pread
   on the shared descriptor, whose offset nobody moves. */
static void *positioned_worker(void *argument) {
	int index = (int)(intptr_t)argument;
	char block[BLOCK];
	char back[BLOCK];
	for (int round = 0; round < ROUNDS; round++) {
		for (int b = index; b < BLOCKS; b += 4) {
			memset(block, 'A' + (b + round) % 26, sizeof(block));
			if (pwrite(shared_fd, block, BLOCK, (off_t)b * BLOCK) != BLOCK)
				return (void *)1;
			if (pread(shared_fd, back, BLOCK, (off_t)b * BLOCK) != BLOCK)
				return (void *)2;
			if (memcmp(block, back, BLOCK) != 0)
				return (void *)3;
		}
	}
	return NULL;
}

static void test_positioned(void) {
	shared_fd = open(FILE_PATH, O_RDWR | O_CREAT | O_TRUNC, 0644);
	CHECK(shared_fd >= 0, "open: %s", strerror(errno));
	if (shared_fd < 0)
		return;
	CHECK(write(shared_fd, "head", 4) == 4, "write");
	CHECK(pwrite(shared_fd, "XYZ", 3, 100) == 3, "pwrite past the end");
	CHECK(lseek(shared_fd, 0, SEEK_CUR) == 4, "pwrite left the offset at 4");
	char buffer[8] = {0};
	CHECK(pread(shared_fd, buffer, 3, 100) == 3 && memcmp(buffer, "XYZ", 3) == 0, "pread");
	CHECK(lseek(shared_fd, 0, SEEK_CUR) == 4, "pread left the offset at 4");
	CHECK(pread(shared_fd, buffer, 8, 200) == 0, "pread past the end gives 0");
	errno = 0;
	CHECK(pread(shared_fd, buffer, 1, -1) == -1 && errno == EINVAL, "negative offset: EINVAL");
	int pipe_ends[2];
	pipe(pipe_ends);
	errno = 0;
	CHECK(pread(pipe_ends[0], buffer, 1, 0) == -1 && errno == ESPIPE, "pread of a pipe: ESPIPE (%s)",
		strerror(errno));
	close(pipe_ends[0]);
	close(pipe_ends[1]);

	pthread_t threads[4];
	for (int i = 0; i < 4; i++)
		pthread_create(&threads[i], NULL, positioned_worker, (void *)(intptr_t)i);
	int failures = 0;
	for (int i = 0; i < 4; i++) {
		void *result = (void *)9;
		pthread_join(threads[i], &result);
		if (result != NULL)
			failures++;
	}
	CHECK(failures == 0, "threads sharing a descriptor with pread/pwrite: %d failed", failures);
	CHECK(lseek(shared_fd, 0, SEEK_CUR) == 4, "the offset is still 4");

	/* preadv and pwritev (mlibc's, over the gathered buffer). */
	char first[3] = {'p', 'q', 'r'};
	char second[2] = {'s', 't'};
	struct iovec pieces[2] = {{first, 3}, {second, 2}};
	CHECK(pwritev(shared_fd, pieces, 2, 300) == 5, "pwritev");
	char got_first[3] = {0};
	char got_second[2] = {0};
	struct iovec into[2] = {{got_first, 3}, {got_second, 2}};
	CHECK(preadv(shared_fd, into, 2, 300) == 5 && memcmp(got_first, "pqr", 3) == 0 &&
		memcmp(got_second, "st", 2) == 0, "preadv");

	CHECK(fsync(shared_fd) == 0, "fsync: %s", strerror(errno));
	CHECK(fdatasync(shared_fd) == 0, "fdatasync: %s", strerror(errno));
	pipe(pipe_ends);
	errno = 0;
	CHECK(fsync(pipe_ends[1]) == -1 && errno == EINVAL, "fsync of a pipe: EINVAL (%s)", strerror(errno));
	close(pipe_ends[0]);
	close(pipe_ends[1]);
	close(shared_fd);
	errno = 0;
	CHECK(fsync(shared_fd) == -1 && errno == EBADF, "fsync of a closed descriptor: EBADF");
}

static void test_nanosecond_times(void) {
	int fd = open(FILE_PATH, O_RDWR | O_CREAT, 0644);
	if (fd < 0)
		return;
	struct timespec times[2];
	times[0].tv_sec = 1700000000;
	times[0].tv_nsec = 123456789;
	times[1].tv_sec = 1700000100;
	times[1].tv_nsec = 987654321;
	CHECK(futimens(fd, times) == 0, "futimens: %s", strerror(errno));
	struct stat status;
	CHECK(fstat(fd, &status) == 0, "fstat");
	CHECK(status.st_atim.tv_sec == 1700000000 && status.st_atim.tv_nsec == 123456789,
		"st_atim %lld.%09ld", (long long)status.st_atim.tv_sec, status.st_atim.tv_nsec);
	CHECK(status.st_mtim.tv_sec == 1700000100 && status.st_mtim.tv_nsec == 987654321,
		"st_mtim %lld.%09ld", (long long)status.st_mtim.tv_sec, status.st_mtim.tv_nsec);
	/* UTIME_OMIT leaves one alone, by path. */
	times[0].tv_nsec = UTIME_OMIT;
	times[1].tv_sec = 1600000000;
	times[1].tv_nsec = 5;
	CHECK(utimensat(AT_FDCWD, FILE_PATH, times, 0) == 0, "utimensat");
	CHECK(stat(FILE_PATH, &status) == 0 && status.st_mtim.tv_sec == 1600000000 && status.st_mtim.tv_nsec == 5 &&
		status.st_atim.tv_nsec == 123456789, "utimensat with UTIME_OMIT: %ld %ld", status.st_mtim.tv_nsec,
		status.st_atim.tv_nsec);
	/* Now: within a second of the clock. */
	struct timespec before;
	clock_gettime(CLOCK_REALTIME, &before);
	CHECK(futimens(fd, NULL) == 0, "futimens now");
	fstat(fd, &status);
	CHECK(status.st_mtim.tv_sec >= before.tv_sec - 1 && status.st_mtim.tv_sec <= before.tv_sec + 2,
		"now: %lld against %lld", (long long)status.st_mtim.tv_sec, (long long)before.tv_sec);
	close(fd);
}

static void test_mapping_sync(void) {
	int fd = open(FILE_PATH, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		return;
	long page = sysconf(_SC_PAGESIZE);
	CHECK(ftruncate(fd, page * 2) == 0, "ftruncate");
	char *mapping = mmap(NULL, (size_t)page * 2, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	CHECK(mapping != MAP_FAILED, "mmap shared: %s", strerror(errno));
	if (mapping == MAP_FAILED) {
		close(fd);
		return;
	}
	memcpy(mapping, "mapped bytes", 12);
	unsigned char residency[2] = {0xFF, 0xFF};
	CHECK(mincore(mapping, (size_t)page * 2, residency) == 0, "mincore: %s", strerror(errno));
	CHECK(residency[0] == 1, "the written page is resident (%u)", residency[0]);
	CHECK(msync(mapping, (size_t)page, MS_SYNC) == 0, "msync: %s", strerror(errno));
	char buffer[16] = {0};
	CHECK(pread(fd, buffer, 12, 0) == 12 && memcmp(buffer, "mapped bytes", 12) == 0, "the file has it");
	errno = 0;
	CHECK(msync(mapping, (size_t)page, MS_SYNC | MS_ASYNC) == -1 && errno == EINVAL, "MS_SYNC|MS_ASYNC: EINVAL");
	munmap(mapping, (size_t)page * 2);
	errno = 0;
	CHECK(mincore(mapping, (size_t)page, residency) == -1 && errno == ENOMEM, "mincore of unmapped memory: ENOMEM");
	close(fd);
}

static int64_t nanoseconds_of(const struct timespec *time) {
	return (int64_t)time->tv_sec * 1000000000 + time->tv_nsec;
}

static void test_clock_page(void) {
	/* clock_gettime against the kernel's own call: the same clock. */
	struct timespec page_time;
	struct fpos_precise_time kernel_time;
	struct timespec after;
	clock_gettime(CLOCK_MONOTONIC, &page_time);
	fpos_syscall2(FPOS_CALL_GET_PRECISE_TIME, FPOS_TIME_UPTIME_NANOSECONDS, (long)&kernel_time);
	clock_gettime(CLOCK_MONOTONIC, &after);
	int64_t kernel = kernel_time.seconds * 1000000000 + kernel_time.nanoseconds;
	CHECK(kernel >= nanoseconds_of(&page_time) && kernel <= nanoseconds_of(&after),
		"monotonic: %lld <= %lld <= %lld", (long long)nanoseconds_of(&page_time), (long long)kernel,
		(long long)nanoseconds_of(&after));
	clock_gettime(CLOCK_REALTIME, &page_time);
	fpos_syscall2(FPOS_CALL_GET_PRECISE_TIME, FPOS_TIME_WALL_CLOCK, (long)&kernel_time);
	clock_gettime(CLOCK_REALTIME, &after);
	kernel = kernel_time.seconds * 1000000000 + kernel_time.nanoseconds;
	/* The wall clock may be stepped meanwhile: a millisecond either way. */
	CHECK(kernel >= nanoseconds_of(&page_time) - 1000000 && kernel <= nanoseconds_of(&after) + 1000000,
		"realtime: %lld %lld %lld", (long long)nanoseconds_of(&page_time), (long long)kernel,
		(long long)nanoseconds_of(&after));
	/* Monotonic never goes back, over many reads. */
	int64_t previous = 0;
	int backwards = 0;
	for (int i = 0; i < 100000; i++) {
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		int64_t value = nanoseconds_of(&now);
		if (value < previous)
			backwards++;
		previous = value;
	}
	CHECK(backwards == 0, "monotonic went back %d times", backwards);
}

void test_file_io(void) {
	test_positioned();
	test_nanosecond_times();
	test_mapping_sync();
	test_clock_page();
	unlink(FILE_PATH);
}
