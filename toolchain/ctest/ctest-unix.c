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

/* Unix domain sockets: socketpair of each kind, a stream server on a
   path and one in the abstract namespace, datagrams with sender names,
   message boundaries of packet sockets, descriptors passed with
   SCM_RIGHTS (across fork), SO_PEERCRED and SCM_CREDENTIALS,
   getsockname/getpeername, shutdown, poll, non-blocking sockets and the
   end of a connection. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include "ctest.h"

#define SOCKET_PATH "/tmp/ctest-unix.sock"

static socklen_t path_address(struct sockaddr_un *address, const char *path) {
	memset(address, 0, sizeof(*address));
	address->sun_family = AF_UNIX;
	strcpy(address->sun_path, path);
	return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1);
}

static socklen_t abstract_address(struct sockaddr_un *address, const char *name) {
	memset(address, 0, sizeof(*address));
	address->sun_family = AF_UNIX;
	memcpy(address->sun_path + 1, name, strlen(name));
	return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(name));
}

static void test_pairs(void) {
	int pair[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, "socketpair stream: %s", strerror(errno));
	CHECK(write(pair[0], "ping", 4) == 4, "write");
	char buffer[16] = {0};
	CHECK(read(pair[1], buffer, sizeof(buffer)) == 4 && memcmp(buffer, "ping", 4) == 0, "read");
	CHECK(send(pair[1], "pong!", 5, 0) == 5, "send back");
	memset(buffer, 0, sizeof(buffer));
	CHECK(recv(pair[0], buffer, sizeof(buffer), 0) == 5 && strcmp(buffer, "pong!") == 0, "recv back");
	struct stat status;
	CHECK(fstat(pair[0], &status) == 0 && S_ISSOCK(status.st_mode), "fstat says socket");
	int type = 0;
	socklen_t length = sizeof(type);
	CHECK(getsockopt(pair[0], SOL_SOCKET, SO_TYPE, &type, &length) == 0 && type == SOCK_STREAM, "SO_TYPE %d", type);
	/* A stream joins writes. */
	write(pair[0], "ab", 2);
	write(pair[0], "cd", 2);
	char joined[8] = {0};
	ssize_t got = recv(pair[1], joined, 4, MSG_WAITALL);
	CHECK(got == 4 && memcmp(joined, "abcd", 4) == 0, "stream joins writes: %zd", got);
	/* The end of the stream once the other end is closed. */
	close(pair[0]);
	CHECK(read(pair[1], buffer, sizeof(buffer)) == 0, "end of stream");
	signal(SIGPIPE, SIG_IGN);
	errno = 0;
	CHECK(write(pair[1], "x", 1) == -1 && errno == EPIPE, "EPIPE after close: %s", strerror(errno));
	signal(SIGPIPE, SIG_DFL);
	close(pair[1]);

	CHECK(socketpair(AF_UNIX, SOCK_SEQPACKET, 0, pair) == 0, "socketpair seqpacket");
	send(pair[0], "one", 3, 0);
	send(pair[0], "second", 6, 0);
	memset(buffer, 0, sizeof(buffer));
	CHECK(recv(pair[1], buffer, sizeof(buffer), 0) == 3, "packet boundaries (1)");
	CHECK(recv(pair[1], buffer, sizeof(buffer), 0) == 6 && memcmp(buffer, "second", 6) == 0, "packet boundaries (2)");
	length = sizeof(type);
	getsockopt(pair[0], SOL_SOCKET, SO_TYPE, &type, &length);
	CHECK(type == SOCK_SEQPACKET, "SO_TYPE seqpacket %d", type);
	close(pair[0]);
	close(pair[1]);

	CHECK(socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, pair) == 0, "socketpair datagram");
	CHECK((fcntl(pair[0], F_GETFD) & FD_CLOEXEC) != 0, "SOCK_CLOEXEC");
	errno = 0;
	CHECK(recv(pair[0], buffer, sizeof(buffer), 0) == -1 && errno == EAGAIN, "non-blocking recv: %s",
		strerror(errno));
	send(pair[1], "0123456789", 10, 0);
	struct iovec piece = {buffer, 4};
	struct msghdr message = {0};
	message.msg_iov = &piece;
	message.msg_iovlen = 1;
	CHECK(recvmsg(pair[0], &message, 0) == 4 && (message.msg_flags & MSG_TRUNC), "datagram cut: MSG_TRUNC");
	struct pollfd waiting = {pair[0], POLLIN, 0};
	CHECK(poll(&waiting, 1, 0) == 0, "nothing left after the cut datagram");
	send(pair[1], "z", 1, 0);
	CHECK(poll(&waiting, 1, 1000) == 1 && (waiting.revents & POLLIN), "poll readable");
	close(pair[0]);
	close(pair[1]);
}

static void *path_client(void *argument) {
	(void)argument;
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	struct sockaddr_un address;
	socklen_t length = path_address(&address, SOCKET_PATH);
	if (connect(fd, (struct sockaddr *)&address, length) != 0)
		return (void *)1;
	char reply[32] = {0};
	write(fd, "hello server", 12);
	ssize_t count = read(fd, reply, sizeof(reply) - 1);
	close(fd);
	return (count == 12 && strcmp(reply, "HELLO SERVER") == 0) ? NULL : (void *)2;
}

static void test_path_server(void) {
	unlink(SOCKET_PATH);
	int server = socket(AF_UNIX, SOCK_STREAM, 0);
	CHECK(server >= 0, "socket: %s", strerror(errno));
	struct sockaddr_un address;
	socklen_t length = path_address(&address, SOCKET_PATH);
	CHECK(bind(server, (struct sockaddr *)&address, length) == 0, "bind %s: %s", SOCKET_PATH, strerror(errno));
	struct stat status;
	CHECK(stat(SOCKET_PATH, &status) == 0 && S_ISSOCK(status.st_mode), "the socket node: mode %o",
		(unsigned)status.st_mode);
	int second = socket(AF_UNIX, SOCK_STREAM, 0);
	errno = 0;
	CHECK(bind(second, (struct sockaddr *)&address, length) == -1 && errno == EADDRINUSE, "EADDRINUSE: %s",
		strerror(errno));
	close(second);
	CHECK(listen(server, 4) == 0, "listen: %s", strerror(errno));
	int listening = 0;
	socklen_t option_length = sizeof(listening);
	CHECK(getsockopt(server, SOL_SOCKET, SO_ACCEPTCONN, &listening, &option_length) == 0 && listening == 1,
		"SO_ACCEPTCONN");
	struct sockaddr_un name;
	socklen_t name_length = sizeof(name);
	CHECK(getsockname(server, (struct sockaddr *)&name, &name_length) == 0 &&
		strcmp(name.sun_path, SOCKET_PATH) == 0, "getsockname: %s", name.sun_path);

	pthread_t thread;
	pthread_create(&thread, NULL, path_client, NULL);
	struct pollfd waiting = {server, POLLIN, 0};
	CHECK(poll(&waiting, 1, 5000) == 1, "poll for the connection");
	int connection = accept(server, NULL, NULL);
	CHECK(connection >= 0, "accept: %s", strerror(errno));
	if (connection >= 0) {
		struct ucred credentials;
		socklen_t credentials_length = sizeof(credentials);
		CHECK(getsockopt(connection, SOL_SOCKET, SO_PEERCRED, &credentials, &credentials_length) == 0 &&
			credentials.pid == getpid() && credentials.uid == geteuid(), "SO_PEERCRED pid %d uid %d",
			(int)credentials.pid, (int)credentials.uid);
		name_length = sizeof(name);
		CHECK(getsockname(connection, (struct sockaddr *)&name, &name_length) == 0 &&
			strcmp(name.sun_path, SOCKET_PATH) == 0, "accepted socket's name");
		char buffer[32] = {0};
		ssize_t count = read(connection, buffer, sizeof(buffer) - 1);
		CHECK(count == 12, "server read %zd", count);
		for (ssize_t i = 0; i < count; i++)
			if (buffer[i] >= 'a' && buffer[i] <= 'z')
				buffer[i] = (char)(buffer[i] - 32);
		write(connection, buffer, (size_t)count);
		close(connection);
	}
	void *result = (void *)3;
	pthread_join(thread, &result);
	CHECK(result == NULL, "client result %p", result);
	close(server);
	/* The node stays after close; nobody listens there any more. */
	int late = socket(AF_UNIX, SOCK_STREAM, 0);
	errno = 0;
	CHECK(connect(late, (struct sockaddr *)&address, length) == -1 && errno == ECONNREFUSED,
		"ECONNREFUSED once closed: %s", strerror(errno));
	close(late);
	CHECK(unlink(SOCKET_PATH) == 0, "unlink the node");
	int missing = socket(AF_UNIX, SOCK_STREAM, 0);
	errno = 0;
	CHECK(connect(missing, (struct sockaddr *)&address, length) == -1 && errno == ENOENT, "ENOENT: %s",
		strerror(errno));
	close(missing);
}

static void test_abstract_and_datagrams(void) {
	int server = socket(AF_UNIX, SOCK_DGRAM, 0);
	struct sockaddr_un address;
	socklen_t length = abstract_address(&address, "ctest-abstract");
	CHECK(bind(server, (struct sockaddr *)&address, length) == 0, "bind abstract: %s", strerror(errno));
	int client = socket(AF_UNIX, SOCK_DGRAM, 0);
	struct sockaddr_un client_address;
	socklen_t client_length = abstract_address(&client_address, "ctest-client");
	CHECK(bind(client, (struct sockaddr *)&client_address, client_length) == 0, "bind client");
	CHECK(sendto(client, "datagram", 8, 0, (struct sockaddr *)&address, length) == 8, "sendto: %s",
		strerror(errno));
	char buffer[32] = {0};
	struct sockaddr_un from;
	socklen_t from_length = sizeof(from);
	CHECK(recvfrom(server, buffer, sizeof(buffer), 0, (struct sockaddr *)&from, &from_length) == 8 &&
		memcmp(buffer, "datagram", 8) == 0, "recvfrom");
	CHECK(from_length == client_length && from.sun_path[0] == '\0' &&
		memcmp(from.sun_path + 1, "ctest-client", 12) == 0, "the sender's abstract name (%u)", from_length);
	/* Answering the name received. */
	CHECK(sendto(server, "reply", 5, 0, (struct sockaddr *)&from, from_length) == 5, "reply");
	CHECK(recv(client, buffer, sizeof(buffer), 0) == 5, "reply received");
	/* A connected datagram socket. */
	CHECK(connect(client, (struct sockaddr *)&address, length) == 0, "connect datagram");
	CHECK(send(client, "c", 1, 0) == 1 && recv(server, buffer, sizeof(buffer), 0) == 1, "send after connect");
	close(client);
	close(server);
	/* The abstract name is gone with its socket. */
	int again = socket(AF_UNIX, SOCK_DGRAM, 0);
	CHECK(bind(again, (struct sockaddr *)&address, length) == 0, "abstract name free again");
	close(again);

	/* Autobind: an unnamed bind picks an abstract name. */
	int unnamed = socket(AF_UNIX, SOCK_DGRAM, 0);
	struct sockaddr_un family_only;
	memset(&family_only, 0, sizeof(family_only));
	family_only.sun_family = AF_UNIX;
	CHECK(bind(unnamed, (struct sockaddr *)&family_only, sizeof(sa_family_t)) == 0, "autobind");
	struct sockaddr_un picked;
	socklen_t picked_length = sizeof(picked);
	getsockname(unnamed, (struct sockaddr *)&picked, &picked_length);
	CHECK(picked_length > sizeof(sa_family_t) + 1 && picked.sun_path[0] == '\0', "autobound name (%u)",
		picked_length);
	close(unnamed);
}

/* Sends fd over socket with SCM_RIGHTS. */
static int send_descriptor(int socket_fd, int fd) {
	char byte = 'F';
	struct iovec piece = {&byte, 1};
	char control[CMSG_SPACE(sizeof(int))];
	memset(control, 0, sizeof(control));
	struct msghdr message = {0};
	message.msg_iov = &piece;
	message.msg_iovlen = 1;
	message.msg_control = control;
	message.msg_controllen = sizeof(control);
	struct cmsghdr *header = CMSG_FIRSTHDR(&message);
	header->cmsg_level = SOL_SOCKET;
	header->cmsg_type = SCM_RIGHTS;
	header->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(header), &fd, sizeof(int));
	return sendmsg(socket_fd, &message, 0) == 1 ? 0 : -1;
}

static int receive_descriptor(int socket_fd) {
	char byte = 0;
	struct iovec piece = {&byte, 1};
	char control[CMSG_SPACE(sizeof(int))];
	struct msghdr message = {0};
	message.msg_iov = &piece;
	message.msg_iovlen = 1;
	message.msg_control = control;
	message.msg_controllen = sizeof(control);
	if (recvmsg(socket_fd, &message, MSG_CMSG_CLOEXEC) != 1 || byte != 'F')
		return -1;
	struct cmsghdr *header = CMSG_FIRSTHDR(&message);
	if (!header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS)
		return -1;
	int fd;
	memcpy(&fd, CMSG_DATA(header), sizeof(int));
	return fd;
}

static void test_passing(void) {
	int pair[2];
	CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, "socketpair");
	int pipe_ends[2];
	CHECK(pipe(pipe_ends) == 0, "pipe");
	pid_t child = fork();
	if (child == 0) {
		close(pair[0]);
		int received = receive_descriptor(pair[1]);
		if (received < 0)
			_exit(2);
		if (!(fcntl(received, F_GETFD) & FD_CLOEXEC))
			_exit(3);
		/* The pipe's write end, passed over: the parent reads this. */
		if (write(received, "via fd", 6) != 6)
			_exit(4);
		_exit(0);
	}
	close(pair[1]);
	CHECK(send_descriptor(pair[0], pipe_ends[1]) == 0, "sendmsg SCM_RIGHTS: %s", strerror(errno));
	close(pipe_ends[1]);
	char buffer[16] = {0};
	CHECK(read(pipe_ends[0], buffer, sizeof(buffer)) == 6 && strcmp(buffer, "via fd") == 0,
		"the child wrote through the passed descriptor");
	int status = -1;
	waitpid(child, &status, 0);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "child status %#x", status);
	/* Every write end is closed now (ours, the child's, the one in
	   flight is installed): end of file. */
	CHECK(read(pipe_ends[0], buffer, sizeof(buffer)) == 0, "end of file on the pipe");
	close(pipe_ends[0]);
	close(pair[0]);

	/* SCM_CREDENTIALS with SO_PASSCRED. */
	CHECK(socketpair(AF_UNIX, SOCK_DGRAM, 0, pair) == 0, "socketpair for credentials");
	int on = 1;
	CHECK(setsockopt(pair[1], SOL_SOCKET, SO_PASSCRED, &on, sizeof(on)) == 0, "SO_PASSCRED");
	send(pair[0], "c", 1, 0);
	char byte;
	struct iovec piece = {&byte, 1};
	char control[CMSG_SPACE(sizeof(struct ucred))];
	struct msghdr message = {0};
	message.msg_iov = &piece;
	message.msg_iovlen = 1;
	message.msg_control = control;
	message.msg_controllen = sizeof(control);
	CHECK(recvmsg(pair[1], &message, 0) == 1, "recvmsg credentials");
	struct cmsghdr *header = CMSG_FIRSTHDR(&message);
	struct ucred credentials = {0, 0, 0};
	if (header && header->cmsg_type == SCM_CREDENTIALS)
		memcpy(&credentials, CMSG_DATA(header), sizeof(credentials));
	CHECK(header && header->cmsg_type == SCM_CREDENTIALS && credentials.pid == getpid() &&
		credentials.uid == geteuid() && credentials.gid == getegid(), "SCM_CREDENTIALS pid %d",
		(int)credentials.pid);
	close(pair[0]);
	close(pair[1]);
}

static void test_shutdown_and_names(void) {
	int pair[2];
	socketpair(AF_UNIX, SOCK_STREAM, 0, pair);
	CHECK(shutdown(pair[0], SHUT_WR) == 0, "shutdown");
	char buffer[4];
	CHECK(read(pair[1], buffer, sizeof(buffer)) == 0, "end of stream after SHUT_WR");
	CHECK(write(pair[1], "ok", 2) == 2 && read(pair[0], buffer, sizeof(buffer)) == 2, "the other way still works");
	struct sockaddr_un name;
	socklen_t length = sizeof(name);
	CHECK(getpeername(pair[0], (struct sockaddr *)&name, &length) == 0 && name.sun_family == AF_UNIX &&
		length == sizeof(sa_family_t), "getpeername of an unnamed peer (%u)", length);
	close(pair[0]);
	close(pair[1]);
	int lone = socket(AF_UNIX, SOCK_STREAM, 0);
	length = sizeof(name);
	errno = 0;
	CHECK(getpeername(lone, (struct sockaddr *)&name, &length) == -1 && errno == ENOTCONN, "ENOTCONN");
	close(lone);
}

/* Local sockets in an event poll: readable once data comes, writable,
   hang-up once the peer is gone. */
static void test_epoll_readiness(void) {
	int pair[2];
	socketpair(AF_UNIX, SOCK_STREAM, 0, pair);
	int poll_fd = epoll_create1(0);
	CHECK(poll_fd >= 0, "epoll_create1: %s", strerror(errno));
	struct epoll_event event = {0};
	event.events = EPOLLIN;
	event.data.fd = pair[1];
	CHECK(epoll_ctl(poll_fd, EPOLL_CTL_ADD, pair[1], &event) == 0, "epoll_ctl a local socket: %s", strerror(errno));
	struct epoll_event ready[2];
	CHECK(epoll_wait(poll_fd, ready, 2, 0) == 0, "nothing to read yet");
	write(pair[0], "e", 1);
	CHECK(epoll_wait(poll_fd, ready, 2, 1000) == 1 && ready[0].data.fd == pair[1] && (ready[0].events & EPOLLIN),
		"readable in the poll");
	event.events = EPOLLOUT;
	CHECK(epoll_ctl(poll_fd, EPOLL_CTL_MOD, pair[1], &event) == 0, "modify");
	CHECK(epoll_wait(poll_fd, ready, 2, 1000) == 1 && (ready[0].events & EPOLLOUT), "writable in the poll");
	close(pair[0]);
	event.events = EPOLLIN;
	epoll_ctl(poll_fd, EPOLL_CTL_MOD, pair[1], &event);
	CHECK(epoll_wait(poll_fd, ready, 2, 1000) == 1 && (ready[0].events & EPOLLHUP), "hang-up once the peer is gone (%#x)",
		ready[0].events);
	close(pair[1]);
	close(poll_fd);
}

void test_unix_sockets(void) {
	test_pairs();
	test_path_server();
	test_abstract_and_datagrams();
	test_passing();
	test_shutdown_and_names();
	test_epoll_readiness();
}
