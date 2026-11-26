// FreePascalOS
// Copyright (C) 2026 Brandon Scott
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// AF_UNIX sockets over the kernel's local sockets (calls 253-258):
// sockets.cpp sends the calls for AF_UNIX here.

#pragma once

#include <sys/socket.h>
#include <sys/types.h>

namespace fpos {

// Whether fd is a local socket (one kernel call).
bool is_local_socket(int fd);

int local_socket(int type, int *fd);
int local_socketpair(int type, int *fds);
int local_bind(int fd, const struct sockaddr *address, socklen_t length);
int local_connect(int fd, const struct sockaddr *address, socklen_t length);
// After the kernel accepted a connection on a local listener: the
// peer's name for accept's address.
void local_accepted(int fd, struct sockaddr *address, socklen_t *length);
int local_sendmsg(int fd, const struct msghdr *message, int flags, ssize_t *length);
int local_recvmsg(int fd, struct msghdr *message, int flags, ssize_t *length);
// getsockname (peer false) and getpeername (peer true).
int local_name(int fd, bool peer, struct sockaddr *address, socklen_t max_length, socklen_t *actual_length);
// The options local sockets have; false if the option is not one of
// them (the caller tries the common ones).
bool local_getsockopt(int fd, int layer, int number, void *buffer, socklen_t *size, int *error);
bool local_setsockopt(int fd, int layer, int number, const void *buffer, socklen_t size, int *error);

} // namespace fpos
