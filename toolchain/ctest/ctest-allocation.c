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

/* Allocations that cannot be satisfied fail cleanly: malloc, calloc,
   realloc and posix_memalign return null (or ENOMEM) with errno ENOMEM,
   and the program goes on - the C library does not panic when the
   kernel refuses the memory (toolchain/patches/mlibc/0005). */

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "ctest.h"

/* Sizes read through volatile, and results stored through it, so the
   compiler neither warns about nor folds away the impossible calls. */
static volatile size_t impossible_size = SIZE_MAX;
static volatile size_t beyond_address_space = SIZE_MAX / 2;
/* 1 TiB: more than the machine's RAM, so refused by the kernel's commit
   policy (a single commitment larger than RAM can never be backed). */
static volatile size_t beyond_memory = (size_t)1 << 40;
static void *volatile allocation_sink;

static void check_malloc_refused(size_t size, const char *what) {
	errno = 0;
	void *pointer = malloc(size);
	allocation_sink = pointer;
	CHECK(pointer == NULL, "malloc %s returned %p", what, pointer);
	CHECK(pointer != NULL || errno == ENOMEM, "malloc %s: errno %d (%s)", what, errno, strerror(errno));
	free(pointer);
}

void test_allocation_failure(void) {
	check_malloc_refused(impossible_size, "of SIZE_MAX");
	check_malloc_refused(beyond_address_space, "of half the address space");
	check_malloc_refused(beyond_memory, "of 1 TiB");

	errno = 0;
	void *zeros = calloc(beyond_memory / 16, 16);
	allocation_sink = zeros;
	CHECK(zeros == NULL && errno == ENOMEM, "calloc of 1 TiB: %p, errno %d", zeros, errno);
	free(zeros);

	char *block = malloc(64);
	CHECK(block != NULL, "a small block before the failed realloc");
	if (block) {
		memset(block, 'k', 64);
		errno = 0;
		char *grown = realloc(block, beyond_memory);
		allocation_sink = grown;
		CHECK(grown == NULL && errno == ENOMEM, "realloc to 1 TiB: %p, errno %d", (void *)grown, errno);
		if (grown)
			block = grown;
		CHECK(block[0] == 'k' && block[63] == 'k', "the block survives a failed realloc");
		free(block);
	}

	void *aligned = NULL;
	CHECK(posix_memalign(&aligned, 64, beyond_memory) == ENOMEM, "posix_memalign of 1 TiB");
	free(aligned);

	/* And the heap still works afterwards. */
	char *after = malloc(1 << 20);
	CHECK(after != NULL, "malloc of 1 MiB after the refusals");
	if (after) {
		memset(after, 1, 1 << 20);
		free(after);
	}
}
