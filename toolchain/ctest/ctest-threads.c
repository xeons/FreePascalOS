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

/* pthreads: mutexes, condition variables, joining, thread-local
   variables, once. */

#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include "ctest.h"

enum { thread_count = 4, increments = 20000 };

static pthread_mutex_t counter_lock = PTHREAD_MUTEX_INITIALIZER;
static long counter;
static __thread int thread_local_value;

static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t queue_ready = PTHREAD_COND_INITIALIZER;
static int queue_items;

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int once_runs;

static void run_once(void) {
	once_runs++;
}

static void *count_up(void *argument) {
	thread_local_value = (int)(intptr_t)argument;
	for (int i = 0; i < increments; i++) {
		pthread_mutex_lock(&counter_lock);
		counter++;
		pthread_mutex_unlock(&counter_lock);
	}
	pthread_once(&once, run_once);
	/* Each thread kept its own value. */
	return (void *)(intptr_t)(thread_local_value * 10);
}

static void *produce(void *argument) {
	(void)argument;
	for (int i = 0; i < 100; i++) {
		pthread_mutex_lock(&queue_lock);
		queue_items++;
		pthread_cond_signal(&queue_ready);
		pthread_mutex_unlock(&queue_lock);
	}
	return NULL;
}

void test_threads(void) {
	pthread_t threads[thread_count];
	thread_local_value = 99;
	for (int i = 0; i < thread_count; i++)
		CHECK(pthread_create(&threads[i], NULL, count_up, (void *)(intptr_t)(i + 1)) == 0, "pthread_create");
	int results_right = 1;
	for (int i = 0; i < thread_count; i++) {
		void *result = NULL;
		CHECK(pthread_join(threads[i], &result) == 0, "pthread_join");
		results_right = results_right && (intptr_t)result == (i + 1) * 10;
	}
	CHECK(results_right, "thread results (thread-local values)");
	CHECK(counter == (long)thread_count * increments, "counter %ld", counter);
	CHECK(thread_local_value == 99, "the main thread's thread-local value is %d", thread_local_value);
	CHECK(once_runs == 1, "pthread_once ran %d times", once_runs);

	pthread_t producer;
	CHECK(pthread_create(&producer, NULL, produce, NULL) == 0, "producer");
	int taken = 0;
	while (taken < 100) {
		pthread_mutex_lock(&queue_lock);
		while (queue_items == 0)
			pthread_cond_wait(&queue_ready, &queue_lock);
		taken += queue_items;
		queue_items = 0;
		pthread_mutex_unlock(&queue_lock);
	}
	pthread_join(producer, NULL);
	CHECK(taken == 100, "condition variable: %d items", taken);

	pthread_attr_t attributes;
	pthread_attr_init(&attributes);
	pthread_attr_setstacksize(&attributes, 256 * 1024);
	pthread_t small;
	CHECK(pthread_create(&small, &attributes, produce, NULL) == 0, "thread with a set stack size");
	pthread_join(small, NULL);
	pthread_attr_destroy(&attributes);
	CHECK(pthread_self() != 0, "pthread_self");
}
