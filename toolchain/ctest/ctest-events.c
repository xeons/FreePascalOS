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

/* Event descriptors: eventfd (counts, semaphore mode, non-blocking, poll
   and select), timerfd (periodic, stopped, absolute, gettime, the old
   setting, poll) and signalfd (a signal sent to the process, SIGCHLD of
   a child, poll, a changed mask). */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/select.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "ctest.h"

static int poll_one(int fd, short events, int timeout) {
	struct pollfd item = {fd, events, 0};
	int ready = poll(&item, 1, timeout);
	return ready == 1 ? item.revents : (ready == 0 ? 0 : -1);
}

static void *write_later(void *argument) {
	struct timespec pause = {0, 20 * 1000 * 1000};
	nanosleep(&pause, NULL);
	eventfd_write(*(int *)argument, 9);
	return NULL;
}

static void test_eventfd(void) {
	int fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	CHECK(fd >= 0, "eventfd: %s", strerror(errno));
	uint64_t value = 0;
	CHECK(read(fd, &value, 8) == -1 && errno == EAGAIN, "empty non-blocking read: %s", strerror(errno));
	CHECK(poll_one(fd, POLLIN | POLLOUT, 0) == POLLOUT, "zero is only writable");
	CHECK(fcntl(fd, F_GETFD) & FD_CLOEXEC, "close-on-exec");
	value = 5;
	CHECK(write(fd, &value, 8) == 8, "write: %s", strerror(errno));
	CHECK(eventfd_write(fd, 3) == 0, "eventfd_write");
	CHECK(poll_one(fd, POLLIN, 0) == POLLIN, "readable");
	fd_set readable;
	FD_ZERO(&readable);
	FD_SET(fd, &readable);
	struct timeval no_wait = {0, 0};
	CHECK(select(fd + 1, &readable, NULL, NULL, &no_wait) == 1 && FD_ISSET(fd, &readable), "select");
	CHECK(read(fd, &value, 8) == 8 && value == 8, "the whole count: %llu", (unsigned long long)value);
	CHECK(read(fd, &value, 4) == -1 && errno == EINVAL, "a short read");
	value = UINT64_MAX;
	CHECK(write(fd, &value, 8) == -1 && errno == EINVAL, "all ones refused");
	value = UINT64_MAX - 1;
	CHECK(write(fd, &value, 8) == 8, "the largest count");
	value = 1;
	CHECK(write(fd, &value, 8) == -1 && errno == EAGAIN, "full: %s", strerror(errno));
	CHECK(poll_one(fd, POLLOUT, 0) == 0, "full is not writable");
	close(fd);

	fd = eventfd(2, EFD_SEMAPHORE);
	CHECK(eventfd_read(fd, &value) == 0 && value == 1, "semaphore read");
	CHECK(eventfd_read(fd, &value) == 0 && value == 1, "semaphore read again");
	CHECK(fcntl(fd, F_SETFL, O_NONBLOCK) == 0, "made non-blocking");
	CHECK(read(fd, &value, 8) == -1 && errno == EAGAIN, "semaphore empty");
	CHECK(fcntl(fd, F_SETFL, 0) == 0, "made blocking");
	pthread_t writer;
	pthread_create(&writer, NULL, write_later, &fd);
	CHECK(eventfd_read(fd, &value) == 0 && value == 1, "a blocking read woken by a writer");
	pthread_join(writer, NULL);
	close(fd);
}

static long milliseconds_between(const struct timespec *start, const struct timespec *end) {
	return (end->tv_sec - start->tv_sec) * 1000 + (end->tv_nsec - start->tv_nsec) / 1000000;
}

static void test_timerfd(void) {
	CHECK(timerfd_create(12345, 0) == -1 && errno == EINVAL, "a bad clock");
	int fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
	CHECK(fd >= 0, "timerfd_create: %s", strerror(errno));
	struct itimerspec setting = {{0, 10 * 1000 * 1000}, {0, 10 * 1000 * 1000}};
	struct itimerspec old;
	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC, &start);
	CHECK(timerfd_settime(fd, 0, &setting, &old) == 0, "settime: %s", strerror(errno));
	CHECK(old.it_value.tv_sec == 0 && old.it_value.tv_nsec == 0, "nothing before");
	uint64_t expirations = 0;
	CHECK(read(fd, &expirations, 8) == 8 && expirations >= 1, "went off: %llu", (unsigned long long)expirations);
	clock_gettime(CLOCK_MONOTONIC, &end);
	CHECK(milliseconds_between(&start, &end) >= 9, "not early: %ld ms", milliseconds_between(&start, &end));
	struct itimerspec left;
	CHECK(timerfd_gettime(fd, &left) == 0 && left.it_interval.tv_nsec == 10 * 1000 * 1000, "gettime");
	CHECK(poll_one(fd, POLLIN, 1000) == POLLIN, "poll sees it go off");
	struct timespec pause = {0, 35 * 1000 * 1000};
	nanosleep(&pause, NULL);
	CHECK(read(fd, &expirations, 8) == 8 && expirations >= 3, "periods counted: %llu",
		(unsigned long long)expirations);
	struct itimerspec stop = {{0, 0}, {0, 0}};
	CHECK(timerfd_settime(fd, 0, &stop, &old) == 0 && old.it_interval.tv_nsec == 10 * 1000 * 1000,
		"stopped, the old setting returned");
	CHECK(fcntl(fd, F_SETFL, O_NONBLOCK) == 0, "made non-blocking");
	nanosleep(&pause, NULL);
	CHECK(read(fd, &expirations, 8) == -1 && errno == EAGAIN, "quiet when stopped");
	struct itimerspec past = {{0, 0}, {0, 1}};
	CHECK(timerfd_settime(fd, TFD_TIMER_ABSTIME, &past, NULL) == 0, "an absolute time past");
	CHECK(poll_one(fd, POLLIN, 1000) == POLLIN, "a past time goes off at once");
	CHECK(read(fd, &expirations, 8) == 8 && expirations == 1, "once");
	struct itimerspec bad = {{0, 0}, {0, 1000000000}};
	CHECK(timerfd_settime(fd, 0, &bad, NULL) == -1 && errno == EINVAL, "bad nanoseconds");
	close(fd);

	fd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK);
	struct timespec now;
	clock_gettime(CLOCK_REALTIME, &now);
	struct itimerspec soon = {{0, 0}, {now.tv_sec, now.tv_nsec}};
	soon.it_value.tv_nsec += 20 * 1000 * 1000;
	if (soon.it_value.tv_nsec >= 1000000000) {
		soon.it_value.tv_sec++;
		soon.it_value.tv_nsec -= 1000000000;
	}
	CHECK(timerfd_settime(fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET, &soon, NULL) == 0,
		"an absolute real time");
	CHECK(poll_one(fd, POLLIN, 2000) == POLLIN, "the real time timer went off");
	CHECK(read(fd, &expirations, 8) == 8 && expirations == 1, "real time once");
	close(fd);
}

static void test_signalfd(void) {
	sigset_t mask, previous;
	sigemptyset(&mask);
	sigaddset(&mask, SIGUSR1);
	sigaddset(&mask, SIGCHLD);
	sigprocmask(SIG_BLOCK, &mask, &previous);
	int fd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
	CHECK(fd >= 0, "signalfd: %s", strerror(errno));
	struct signalfd_siginfo item;
	CHECK(read(fd, &item, sizeof(item)) == -1 && errno == EAGAIN, "nothing waits");
	CHECK(poll_one(fd, POLLIN, 0) == 0, "not readable");
	kill(getpid(), SIGUSR1);
	CHECK(poll_one(fd, POLLIN, 1000) == POLLIN, "readable once sent");
	CHECK(read(fd, &item, sizeof(item)) == (ssize_t)sizeof(item), "read: %s", strerror(errno));
	CHECK(item.ssi_signo == SIGUSR1, "the signal: %u", item.ssi_signo);
	CHECK(item.ssi_pid == (uint32_t)getpid(), "the sender: %u", item.ssi_pid);
	CHECK(read(fd, &item, 8) == -1 && errno == EINVAL, "a short read");
	sigset_t pending;
	sigpending(&pending);
	CHECK(!sigismember(&pending, SIGUSR1), "taken, no longer pending");

	pid_t child = fork();
	if (child == 0)
		_exit(7);
	CHECK(poll_one(fd, POLLIN, 5000) == POLLIN, "SIGCHLD of a child, blocked, waits for the descriptor");
	CHECK(read(fd, &item, sizeof(item)) == (ssize_t)sizeof(item) && item.ssi_signo == SIGCHLD,
		"SIGCHLD read: %u", item.ssi_signo);
	int status = 0;
	CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 7, "the child");

	sigset_t only_child;
	sigemptyset(&only_child);
	sigaddset(&only_child, SIGCHLD);
	CHECK(signalfd(fd, &only_child, 0) == fd, "a new mask");
	kill(getpid(), SIGUSR1);
	CHECK(poll_one(fd, POLLIN, 0) == 0, "a signal outside the mask is not reported");
	sigpending(&pending);
	CHECK(sigismember(&pending, SIGUSR1), "it waits as before");
	signal(SIGUSR1, SIG_IGN);
	signal(SIGUSR1, SIG_DFL);
	close(fd);
	sigprocmask(SIG_SETMASK, &previous, NULL);
}

void test_event_descriptors(void) {
	test_eventfd();
	test_timerfd();
	test_signalfd();
}
