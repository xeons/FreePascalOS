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

/* Sockets: a TCP connection over loopback between two threads, UDP to
   oneself, poll and select. */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include "ctest.h"

static unsigned short server_port;

static void *client(void *argument) {
	(void)argument;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_port = htons(server_port);
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0)
		return (void *)1;
	const char *message = "hello over TCP";
	send(fd, message, strlen(message), 0);
	char reply[64] = {0};
	ssize_t count = recv(fd, reply, sizeof(reply) - 1, 0);
	close(fd);
	return (count > 0 && strcmp(reply, "HELLO OVER TCP") == 0) ? NULL : (void *)2;
}

static void serve_one(int connection) {
	char buffer[64] = {0};
	ssize_t count = recv(connection, buffer, sizeof(buffer) - 1, 0);
	CHECK(count == 14, "received %zd", count);
	for (ssize_t i = 0; i < count; i++)
		if (buffer[i] >= 'a' && buffer[i] <= 'z')
			buffer[i] = (char)(buffer[i] - 32);
	if (count > 0)
		send(connection, buffer, (size_t)count, 0);
	close(connection);
}

static void test_udp(void) {
	int udp = socket(AF_INET, SOCK_DGRAM, 0);
	CHECK(udp >= 0, "UDP socket");
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	bind(udp, (struct sockaddr *)&address, sizeof(address));
	socklen_t length = sizeof(address);
	getsockname(udp, (struct sockaddr *)&address, &length);
	CHECK(sendto(udp, "datagram", 8, 0, (struct sockaddr *)&address, sizeof(address)) == 8, "sendto");
	fd_set readable;
	FD_ZERO(&readable);
	FD_SET(udp, &readable);
	struct timeval timeout = {5, 0};
	CHECK(select(udp + 1, &readable, NULL, NULL, &timeout) == 1, "select");
	char datagram[16] = {0};
	CHECK(recvfrom(udp, datagram, sizeof(datagram), 0, NULL, NULL) == 8 && strcmp(datagram, "datagram") == 0,
		"recvfrom");
	close(udp);
}

void test_sockets(void) {
	int server = socket(AF_INET, SOCK_STREAM, 0);
	CHECK(server >= 0, "socket: %s", strerror(errno));
	if (server < 0)
		return;
	int on = 1;
	setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	CHECK(bind(server, (struct sockaddr *)&address, sizeof(address)) == 0, "bind: %s", strerror(errno));
	CHECK(listen(server, 4) == 0, "listen");
	socklen_t length = sizeof(address);
	CHECK(getsockname(server, (struct sockaddr *)&address, &length) == 0 && address.sin_port != 0, "getsockname");
	server_port = ntohs(address.sin_port);

	pthread_t thread;
	pthread_create(&thread, NULL, client, NULL);
	struct pollfd waiting = {server, POLLIN, 0};
	CHECK(poll(&waiting, 1, 5000) == 1 && (waiting.revents & POLLIN), "poll for the connection");
	struct sockaddr_in peer;
	socklen_t peer_length = sizeof(peer);
	int connection = accept(server, (struct sockaddr *)&peer, &peer_length);
	CHECK(connection >= 0, "accept: %s", strerror(errno));
	if (connection >= 0) {
		CHECK(peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK), "peer address");
		serve_one(connection);
	}
	void *result = (void *)3;
	pthread_join(thread, &result);
	CHECK(result == NULL, "client result %p", result);
	close(server);
	test_udp();
}
