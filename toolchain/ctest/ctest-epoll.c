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

/* epoll: level and edge triggered and one shot registrations, the
   errors, a hundred pipes (more than poll waits on at once), a wait
   woken by another thread, a registration gone with the descriptor's
   last close, an epoll inside an epoll and in poll, a TCP server over
   loopback, timerfd and eventfd in one set, and fork sharing the set. */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "ctest.h"

#define PIPE_COUNT 100

static int add(int epfd, int fd, uint32_t events, uint64_t data) {
	struct epoll_event event;
	memset(&event, 0, sizeof(event));
	event.events = events;
	event.data.u64 = data;
	return epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &event);
}

static int modify(int epfd, int fd, uint32_t events, uint64_t data) {
	struct epoll_event event;
	memset(&event, 0, sizeof(event));
	event.events = events;
	event.data.u64 = data;
	return epoll_ctl(epfd, EPOLL_CTL_MOD, fd, &event);
}

static int wait_one(int epfd, struct epoll_event *event, int timeout) {
	memset(event, 0, sizeof(*event));
	return epoll_wait(epfd, event, 1, timeout);
}

static void test_triggering(void) {
	int epfd = epoll_create1(EPOLL_CLOEXEC);
	CHECK(epfd >= 0, "epoll_create1: %s", strerror(errno));
	int counter = eventfd(0, EFD_NONBLOCK);
	struct epoll_event event;
	CHECK(add(epfd, counter, EPOLLIN, 77) == 0, "add: %s", strerror(errno));
	CHECK(add(epfd, counter, EPOLLIN, 77) == -1 && errno == EEXIST, "added twice: %s", strerror(errno));
	CHECK(wait_one(epfd, &event, 0) == 0, "nothing ready");
	eventfd_write(counter, 1);
	CHECK(wait_one(epfd, &event, 0) == 1 && event.events == EPOLLIN && event.data.u64 == 77, "level triggered");
	CHECK(wait_one(epfd, &event, 0) == 1, "level triggered, again while ready");
	uint64_t value;
	eventfd_read(counter, &value);
	CHECK(wait_one(epfd, &event, 0) == 0, "not ready once read");

	CHECK(modify(epfd, counter, EPOLLIN | EPOLLET, 78) == 0, "modified to edge triggered");
	eventfd_write(counter, 1);
	CHECK(wait_one(epfd, &event, 0) == 1 && event.data.u64 == 78, "edge triggered");
	CHECK(wait_one(epfd, &event, 0) == 0, "edge triggered, once");
	eventfd_write(counter, 1);
	CHECK(wait_one(epfd, &event, 0) == 1, "edge triggered, a new write");

	CHECK(modify(epfd, counter, EPOLLIN | EPOLLONESHOT, 79) == 0, "modified to one shot");
	CHECK(wait_one(epfd, &event, 0) == 1 && event.data.u64 == 79, "one shot");
	CHECK(wait_one(epfd, &event, 0) == 0, "one shot, once");
	CHECK(modify(epfd, counter, EPOLLIN | EPOLLOUT, 80) == 0, "armed again");
	CHECK(wait_one(epfd, &event, 0) == 1 && event.events == (EPOLLIN | EPOLLOUT), "readable and writable");

	CHECK(epoll_ctl(epfd, EPOLL_CTL_DEL, counter, NULL) == 0, "removed");
	CHECK(epoll_ctl(epfd, EPOLL_CTL_DEL, counter, NULL) == -1 && errno == ENOENT, "removed twice");
	CHECK(modify(epfd, counter, EPOLLIN, 0) == -1 && errno == ENOENT, "modify what is not there");
	CHECK(wait_one(epfd, &event, 0) == 0, "nothing after removing");
	CHECK(add(epfd, epfd, EPOLLIN, 0) == -1 && errno == EINVAL, "itself refused");
	CHECK(add(epfd, 12345, EPOLLIN, 0) == -1 && errno == EBADF, "a bad descriptor");
	int file = open("/tmp/ctest-epoll.txt", O_RDWR | O_CREAT | O_TRUNC, 0600);
	CHECK(add(epfd, file, EPOLLIN, 0) == -1 && errno == EPERM, "a file refused: %s", strerror(errno));
	close(file);
	unlink("/tmp/ctest-epoll.txt");

	CHECK(add(epfd, counter, EPOLLIN, 81) == 0, "added again");
	close(counter);
	CHECK(wait_one(epfd, &event, 0) == 0, "gone with its last close");
	int fresh = eventfd(1, 0);
	CHECK(add(epfd, fresh, EPOLLIN, 82) == 0, "the number used again");
	CHECK(wait_one(epfd, &event, 0) == 1 && event.data.u64 == 82, "the new one reported");
	close(fresh);
	close(epfd);
}

static void test_many_pipes(void) {
	int epfd = epoll_create1(0);
	int pipes[PIPE_COUNT][2];
	int made = 0;
	for (int i = 0; i < PIPE_COUNT; i++) {
		if (pipe(pipes[i]) != 0)
			break;
		add(epfd, pipes[i][0], EPOLLIN, (uint64_t)i);
		made++;
	}
	CHECK(made == PIPE_COUNT, "pipes made: %d", made);
	struct epoll_event events[8];
	CHECK(epoll_wait(epfd, events, 8, 0) == 0, "no pipe ready");
	CHECK(write(pipes[90][1], "x", 1) == 1, "written");
	int count = epoll_wait(epfd, events, 8, 1000);
	CHECK(count == 1 && events[0].data.u64 == 90 && events[0].events == EPOLLIN, "the ninety-first: %d", count);
	close(pipes[3][1]);
	count = epoll_wait(epfd, events, 8, 1000);
	int saw_hang_up = 0;
	for (int i = 0; i < count; i++)
		if (events[i].data.u64 == 3 && (events[i].events & EPOLLHUP))
			saw_hang_up = 1;
	CHECK(saw_hang_up, "a pipe with no writer hangs up");
	for (int i = 0; i < made; i++) {
		close(pipes[i][0]);
		if (i != 3)
			close(pipes[i][1]);
	}
	close(epfd);
}

static void *write_later(void *argument) {
	struct timespec pause = {0, 20 * 1000 * 1000};
	nanosleep(&pause, NULL);
	eventfd_write(*(int *)argument, 1);
	return NULL;
}

static void test_waiting(void) {
	int epfd = epoll_create1(0);
	int counter = eventfd(0, 0);
	add(epfd, counter, EPOLLIN, 5);
	struct epoll_event event;
	CHECK(wait_one(epfd, &event, 20) == 0, "a wait times out");
	pthread_t writer;
	pthread_create(&writer, NULL, write_later, &counter);
	CHECK(wait_one(epfd, &event, 5000) == 1 && event.data.u64 == 5, "a wait woken by another thread");
	pthread_join(writer, NULL);

	int outer = epoll_create1(0);
	CHECK(add(outer, epfd, EPOLLIN, 6) == 0, "an epoll in an epoll");
	CHECK(add(epfd, outer, EPOLLIN, 7) == -1 && errno == ELOOP, "a loop refused: %s", strerror(errno));
	CHECK(wait_one(outer, &event, 0) == 1 && event.data.u64 == 6, "the outer one is ready");
	struct pollfd item = {epfd, POLLIN, 0};
	CHECK(poll(&item, 1, 0) == 1 && (item.revents & POLLIN), "poll on an epoll");
	uint64_t value;
	eventfd_read(counter, &value);
	CHECK(wait_one(epfd, &event, 0) == 0, "nothing once read");

	int timer = timerfd_create(CLOCK_MONOTONIC, 0);
	struct itimerspec soon = {{0, 0}, {0, 5 * 1000 * 1000}};
	timerfd_settime(timer, 0, &soon, NULL);
	add(epfd, timer, EPOLLIN, 8);
	CHECK(wait_one(epfd, &event, 2000) == 1 && event.data.u64 == 8, "a timer in the set");

	pid_t child = fork();
	if (child == 0) {
		eventfd_write(counter, 1);
		_exit(0);
	}
	waitpid(child, NULL, 0);
	struct epoll_event events[4];
	int count = epoll_wait(epfd, events, 4, 1000);
	int saw_counter = 0;
	for (int i = 0; i < count; i++)
		if (events[i].data.u64 == 5)
			saw_counter = 1;
	CHECK(saw_counter, "a child of fork writes to the counter in the set");
	close(timer);
	close(outer);
	close(counter);
	close(epfd);
}

static void test_server(void) {
	int listener = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	bind(listener, (struct sockaddr *)&address, sizeof(address));
	socklen_t length = sizeof(address);
	getsockname(listener, (struct sockaddr *)&address, &length);
	listen(listener, 4);
	int epfd = epoll_create1(0);
	CHECK(add(epfd, listener, EPOLLIN, 1) == 0, "a listening socket: %s", strerror(errno));
	int client = socket(AF_INET, SOCK_STREAM, 0);
	CHECK(connect(client, (struct sockaddr *)&address, sizeof(address)) == 0, "connect: %s", strerror(errno));
	struct epoll_event event;
	CHECK(wait_one(epfd, &event, 5000) == 1 && event.data.u64 == 1, "a connection to accept");
	int connection = accept(listener, NULL, NULL);
	CHECK(connection >= 0, "accept: %s", strerror(errno));
	CHECK(add(epfd, connection, EPOLLIN | EPOLLRDHUP, 2) == 0, "the connection");
	CHECK(add(epfd, client, EPOLLOUT | EPOLLET, 3) == 0, "the client, writable");
	struct epoll_event events[4];
	int count = epoll_wait(epfd, events, 4, 5000);
	int saw_client = 0;
	for (int i = 0; i < count; i++)
		if (events[i].data.u64 == 3 && (events[i].events & EPOLLOUT))
			saw_client = 1;
	CHECK(saw_client, "the client can write");
	send(client, "ping", 4, 0);
	int saw_data = 0;
	for (int round = 0; round < 3 && !saw_data; round++) {
		count = epoll_wait(epfd, events, 4, 5000);
		for (int i = 0; i < count; i++)
			if (events[i].data.u64 == 2 && (events[i].events & EPOLLIN))
				saw_data = 1;
	}
	CHECK(saw_data, "data arrived");
	char buffer[8] = {0};
	CHECK(recv(connection, buffer, sizeof(buffer), 0) == 4 && memcmp(buffer, "ping", 4) == 0, "received");
	close(client);
	close(connection);
	close(listener);
	close(epfd);
}

void test_epoll(void) {
	test_triggering();
	test_many_pipes();
	test_waiting();
	test_server();
}
