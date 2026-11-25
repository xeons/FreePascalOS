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

/* inotify: a folder's names created, written, renamed (a cookie pairing
   the halves), changed and removed, a folder made, a file's own removal,
   removing a watch, the same path twice, one shot, poll and epoll. */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

#include "ctest.h"

#define DIRECTORY "/tmp/ctest-inotify"

struct seen {
	int wd;
	uint32_t mask;
	uint32_t cookie;
	char name[64];
};

/* Reads what is queued (waiting up to a second for the first) into
   events; returns how many. */
static int read_events(int fd, struct seen *events, int capacity) {
	struct pollfd item = {fd, POLLIN, 0};
	if (poll(&item, 1, 1000) != 1)
		return 0;
	char buffer[4096] __attribute__((aligned(8)));
	ssize_t length = read(fd, buffer, sizeof(buffer));
	int count = 0;
	ssize_t position = 0;
	while (length > 0 && position < length && count < capacity) {
		struct inotify_event *event = (struct inotify_event *)(buffer + position);
		events[count].wd = event->wd;
		events[count].mask = event->mask;
		events[count].cookie = event->cookie;
		events[count].name[0] = 0;
		if (event->len > 0)
			strncpy(events[count].name, event->name, sizeof(events[count].name) - 1);
		count++;
		position += (ssize_t)sizeof(struct inotify_event) + event->len;
	}
	return count;
}

static int find(struct seen *events, int count, uint32_t mask, const char *name) {
	for (int i = 0; i < count; i++)
		if ((events[i].mask & mask) == mask && strcmp(events[i].name, name) == 0)
			return i;
	return -1;
}

static void test_folder(int fd, int wd) {
	struct seen events[16];
	int file = open(DIRECTORY "/a.txt", O_WRONLY | O_CREAT, 0644);
	int count = read_events(fd, events, 16);
	int created = find(events, count, IN_CREATE, "a.txt");
	CHECK(created >= 0 && events[created].wd == wd, "created (%d events)", count);
	CHECK(write(file, "hello", 5) == 5, "written");
	close(file);
	count = read_events(fd, events, 16);
	CHECK(find(events, count, IN_MODIFY, "a.txt") >= 0, "modified (%d events)", count);
	CHECK(rename(DIRECTORY "/a.txt", DIRECTORY "/b.txt") == 0, "rename: %s", strerror(errno));
	count = read_events(fd, events, 16);
	int from = find(events, count, IN_MOVED_FROM, "a.txt");
	int to = find(events, count, IN_MOVED_TO, "b.txt");
	CHECK(from >= 0 && to >= 0, "moved from and to (%d events)", count);
	CHECK(from >= 0 && to >= 0 && events[from].cookie != 0 && events[from].cookie == events[to].cookie,
		"one cookie for both halves");
	CHECK(chmod(DIRECTORY "/b.txt", 0600) == 0, "chmod");
	count = read_events(fd, events, 16);
	CHECK(find(events, count, IN_ATTRIB, "b.txt") >= 0, "attributes (%d events)", count);
	CHECK(mkdir(DIRECTORY "/sub", 0755) == 0, "mkdir");
	count = read_events(fd, events, 16);
	CHECK(find(events, count, IN_CREATE | IN_ISDIR, "sub") >= 0, "a folder created (%d events)", count);
	rmdir(DIRECTORY "/sub");
	unlink(DIRECTORY "/b.txt");
	count = read_events(fd, events, 16);
	CHECK(find(events, count, IN_DELETE, "b.txt") >= 0, "removed (%d events)", count);
	CHECK(find(events, count, IN_DELETE | IN_ISDIR, "sub") >= 0, "a folder removed");
}

static void test_file(int fd) {
	struct seen events[16];
	int file = open(DIRECTORY "/c.txt", O_WRONLY | O_CREAT, 0644);
	close(file);
	read_events(fd, events, 16);
	int wd = inotify_add_watch(fd, DIRECTORY "/c.txt", IN_DELETE_SELF | IN_MODIFY);
	CHECK(wd > 0, "a file watched: %s", strerror(errno));
	CHECK(inotify_add_watch(fd, DIRECTORY "/c.txt", IN_DELETE_SELF | IN_MODIFY) == wd, "the same path, the same wd");
	CHECK(inotify_add_watch(fd, DIRECTORY "/c.txt", IN_MODIFY | IN_MASK_CREATE) == -1 && errno == EEXIST,
		"IN_MASK_CREATE on a watched path");
	CHECK(inotify_add_watch(fd, DIRECTORY "/c.txt", IN_MODIFY | IN_ONLYDIR) == -1 && errno == ENOTDIR,
		"IN_ONLYDIR on a file");
	unlink(DIRECTORY "/c.txt");
	int count = read_events(fd, events, 16);
	int self = -1;
	int ignored = -1;
	for (int i = 0; i < count; i++) {
		if (events[i].wd == wd && (events[i].mask & IN_DELETE_SELF))
			self = i;
		if (events[i].wd == wd && (events[i].mask & IN_IGNORED))
			ignored = i;
	}
	CHECK(self >= 0 && ignored > self, "deleted itself, then ignored (%d events)", count);
	CHECK(inotify_rm_watch(fd, wd) == -1 && errno == EINVAL, "an ended watch cannot be removed");
}

static void test_removing(int fd, int wd) {
	struct seen events[8];
	CHECK(inotify_rm_watch(fd, wd) == 0, "removed: %s", strerror(errno));
	int count = read_events(fd, events, 8);
	CHECK(count >= 1 && events[count - 1].wd == wd && (events[count - 1].mask & IN_IGNORED), "ignored follows");
	int file = open(DIRECTORY "/d.txt", O_WRONLY | O_CREAT, 0644);
	close(file);
	char buffer[256];
	CHECK(read(fd, buffer, sizeof(buffer)) == -1 && errno == EAGAIN, "nothing after removing");
	unlink(DIRECTORY "/d.txt");

	int once = inotify_add_watch(fd, DIRECTORY, IN_CREATE | IN_ONESHOT);
	file = open(DIRECTORY "/e.txt", O_WRONLY | O_CREAT, 0644);
	close(file);
	unlink(DIRECTORY "/e.txt");
	count = read_events(fd, events, 8);
	CHECK(count == 2 && (events[0].mask & IN_CREATE) && (events[1].mask & IN_IGNORED) && events[1].wd == once,
		"one shot: created, then ignored (%d events)", count);
}

void test_inotify(void) {
	unlink(DIRECTORY "/a.txt");
	unlink(DIRECTORY "/b.txt");
	rmdir(DIRECTORY "/sub");
	rmdir(DIRECTORY);
	CHECK(mkdir(DIRECTORY, 0755) == 0, "mkdir: %s", strerror(errno));
	int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	CHECK(fd >= 0, "inotify_init1: %s", strerror(errno));
	char buffer[256];
	CHECK(read(fd, buffer, sizeof(buffer)) == -1 && errno == EAGAIN, "nothing yet");
	CHECK(inotify_add_watch(fd, "/tmp/ctest-no-such-folder", IN_CREATE) == -1 && errno == ENOENT, "missing path");
	CHECK(inotify_add_watch(fd, DIRECTORY, 0) == -1 && errno == EINVAL, "no events asked for");
	int wd = inotify_add_watch(fd, DIRECTORY,
		IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB);
	CHECK(wd > 0, "inotify_add_watch: %s", strerror(errno));
	int epfd = epoll_create1(0);
	struct epoll_event registration = {EPOLLIN, {.u64 = 1}};
	CHECK(epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &registration) == 0, "inotify in epoll");
	test_folder(fd, wd);
	int file = open(DIRECTORY "/f.txt", O_WRONLY | O_CREAT, 0644);
	close(file);
	struct epoll_event event;
	CHECK(epoll_wait(epfd, &event, 1, 1000) == 1 && event.data.u64 == 1, "epoll sees records");
	struct seen events[8];
	read_events(fd, events, 8);
	unlink(DIRECTORY "/f.txt");
	read_events(fd, events, 8);
	test_file(fd);
	test_removing(fd, wd);
	close(epfd);
	close(fd);
	rmdir(DIRECTORY);
}
