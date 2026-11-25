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

// BSD sockets over the kernel's IPv4 and IPv6 sockets (Abi.Networking):
// addresses are translated between struct sockaddr_in/_in6 and the
// kernel's TAbiSocketAddress (ports in the machine's byte order there),
// and the common options to the kernel's SocketOption*. Unix domain
// sockets (AF_UNIX) go to localsockets.cpp; the calls that take either
// kind of socket (listen, accept, shutdown, the options, send and
// receive without names) are the same kernel calls for both.

#include "kernel.hpp"
#include "descriptors.hpp"
#include "localsockets.hpp"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <mlibc/all-sysdeps.hpp>
#include <mlibc/allocator.hpp>

namespace fpos {

namespace {

int to_kernel_address(const struct sockaddr *address, socklen_t length, struct fpos_socket_address *out) {
	memset(out, 0, sizeof(*out));
	if (!address)
		return EINVAL;
	if (address->sa_family == AF_INET) {
		if (length < sizeof(struct sockaddr_in))
			return EINVAL;
		auto in = reinterpret_cast<const struct sockaddr_in *>(address);
		out->family = FPOS_ADDRESS_FAMILY_IPV4;
		out->port = ntohs(in->sin_port);
		memcpy(out->address, &in->sin_addr, 4);
		return 0;
	}
	if (address->sa_family == AF_INET6) {
		if (length < sizeof(struct sockaddr_in6))
			return EINVAL;
		auto in6 = reinterpret_cast<const struct sockaddr_in6 *>(address);
		out->family = FPOS_ADDRESS_FAMILY_IPV6;
		out->port = ntohs(in6->sin6_port);
		out->scope_id = in6->sin6_scope_id;
		memcpy(out->address, &in6->sin6_addr, 16);
		return 0;
	}
	return EAFNOSUPPORT;
}

// Writes the kernel's address as a sockaddr (cut to max_length) and its
// full length.
void from_kernel_address(const struct fpos_socket_address &address, struct sockaddr *out,
		socklen_t max_length, socklen_t *actual_length) {
	struct sockaddr_storage storage;
	memset(&storage, 0, sizeof(storage));
	socklen_t length;
	if (address.family == FPOS_ADDRESS_FAMILY_IPV6) {
		auto in6 = reinterpret_cast<struct sockaddr_in6 *>(&storage);
		in6->sin6_family = AF_INET6;
		in6->sin6_port = htons(address.port);
		in6->sin6_scope_id = address.scope_id;
		memcpy(&in6->sin6_addr, address.address, 16);
		length = sizeof(struct sockaddr_in6);
	} else {
		auto in = reinterpret_cast<struct sockaddr_in *>(&storage);
		in->sin_family = AF_INET;
		in->sin_port = htons(address.port);
		memcpy(&in->sin_addr, address.address, 4);
		length = sizeof(struct sockaddr_in);
	}
	if (out)
		memcpy(out, &storage, length < max_length ? length : max_length);
	if (actual_length)
		*actual_length = length;
}

long kernel_send_flags(int flags) {
	long result = 0;
	if (flags & MSG_DONTWAIT)
		result |= FPOS_SOCKET_FLAG_DONT_WAIT;
	if (flags & MSG_PEEK)
		result |= FPOS_SOCKET_FLAG_PEEK;
	return result;
}

struct OptionMapping {
	int layer;
	int number;
	long kernel_option;
	bool is_time;
};

const OptionMapping option_mappings[] = {
	{SOL_SOCKET, SO_REUSEADDR, FPOS_SOCKET_OPTION_REUSE_ADDRESS, false},
	{SOL_SOCKET, SO_REUSEPORT, FPOS_SOCKET_OPTION_REUSE_ADDRESS, false},
	{SOL_SOCKET, SO_BROADCAST, FPOS_SOCKET_OPTION_BROADCAST, false},
	{SOL_SOCKET, SO_KEEPALIVE, FPOS_SOCKET_OPTION_KEEP_ALIVE, false},
	{SOL_SOCKET, SO_ERROR, FPOS_SOCKET_OPTION_ERROR, false},
	{SOL_SOCKET, SO_TYPE, FPOS_SOCKET_OPTION_KIND, false},
	{SOL_SOCKET, SO_RCVBUF, FPOS_SOCKET_OPTION_RECEIVE_BUFFER, false},
	{SOL_SOCKET, SO_SNDBUF, FPOS_SOCKET_OPTION_SEND_BUFFER, false},
	{SOL_SOCKET, SO_RCVTIMEO, FPOS_SOCKET_OPTION_RECEIVE_TIMEOUT, true},
	{SOL_SOCKET, SO_SNDTIMEO, FPOS_SOCKET_OPTION_SEND_TIMEOUT, true},
	{IPPROTO_TCP, TCP_NODELAY, FPOS_SOCKET_OPTION_NO_DELAY, false},
	{IPPROTO_TCP, TCP_KEEPIDLE, FPOS_SOCKET_OPTION_KEEP_IDLE, false},
	{IPPROTO_TCP, TCP_KEEPINTVL, FPOS_SOCKET_OPTION_KEEP_INTERVAL, false},
	{IPPROTO_TCP, TCP_KEEPCNT, FPOS_SOCKET_OPTION_KEEP_COUNT, false},
	{IPPROTO_IP, IP_TTL, FPOS_SOCKET_OPTION_TIME_TO_LIVE, false},
	{IPPROTO_IPV6, IPV6_UNICAST_HOPS, FPOS_SOCKET_OPTION_TIME_TO_LIVE, false},
	{IPPROTO_IPV6, IPV6_V6ONLY, FPOS_SOCKET_OPTION_IPV6_ONLY, false},
};

const OptionMapping *find_option(int layer, int number) {
	for (const auto &mapping : option_mappings) {
		if (mapping.layer == layer && mapping.number == number)
			return &mapping;
	}
	return nullptr;
}

// A message's pieces gathered into one buffer (datagrams go whole).
void *gather(const struct msghdr *hdr, size_t *length) {
	size_t total = 0;
	for (size_t i = 0; i < (size_t)hdr->msg_iovlen; i++)
		total += hdr->msg_iov[i].iov_len;
	*length = total;
	auto buffer = static_cast<char *>(getAllocator().allocate(total ? total : 1));
	if (!buffer)
		return nullptr;
	size_t position = 0;
	for (size_t i = 0; i < (size_t)hdr->msg_iovlen; i++) {
		memcpy(buffer + position, hdr->msg_iov[i].iov_base, hdr->msg_iov[i].iov_len);
		position += hdr->msg_iov[i].iov_len;
	}
	return buffer;
}

} // namespace

} // namespace fpos

namespace mlibc {

int Sysdeps<Socket>::operator()(int family, int type, int protocol, int *fd) {
	if (family == AF_UNIX) {
		if (protocol != 0)
			return EPROTONOSUPPORT;
		return fpos::local_socket(type, fd);
	}
	long kernel_family;
	switch (family) {
		case AF_INET: kernel_family = FPOS_ADDRESS_FAMILY_IPV4; break;
		case AF_INET6: kernel_family = FPOS_ADDRESS_FAMILY_IPV6; break;
		default: return EAFNOSUPPORT;
	}
	long kind;
	switch (type & 0xFF) {
		case SOCK_STREAM: kind = FPOS_SOCKET_KIND_STREAM; break;
		case SOCK_DGRAM: kind = FPOS_SOCKET_KIND_DATAGRAM; break;
		case SOCK_RAW: kind = FPOS_SOCKET_KIND_RAW; break;
		default: return EPROTONOSUPPORT;
	}
	if (type & SOCK_NONBLOCK)
		kind |= FPOS_SOCKET_KIND_NON_BLOCKING;
	if (int e = fpos::call_into(fd, FPOS_CALL_CREATE_SOCKET, kernel_family, kind, protocol))
		return e;
	fpos::forget_descriptor(*fd);
	unsigned char flags = 0;
	if (type & SOCK_CLOEXEC)
		flags |= fpos::descriptor_close_on_exec;
	if (type & SOCK_NONBLOCK)
		flags |= fpos::descriptor_non_blocking;
	fpos::set_descriptor_flags(*fd, flags);
	return 0;
}

int Sysdeps<Socketpair>::operator()(int domain, int type_and_flags, int proto, int *fds) {
	if (domain != AF_UNIX)
		return EOPNOTSUPP;
	if (proto != 0)
		return EPROTONOSUPPORT;
	return fpos::local_socketpair(type_and_flags, fds);
}

int Sysdeps<Bind>::operator()(int fd, const struct sockaddr *addr_ptr, socklen_t addr_length) {
	if (addr_ptr && addr_ptr->sa_family == AF_UNIX)
		return fpos::local_bind(fd, addr_ptr, addr_length);
	struct fpos_socket_address address;
	if (int e = fpos::to_kernel_address(addr_ptr, addr_length, &address))
		return e;
	return fpos::call_checked(FPOS_CALL_BIND_SOCKET, fd, &address);
}

int Sysdeps<Connect>::operator()(int fd, const struct sockaddr *addr_ptr, socklen_t addr_length) {
	if (addr_ptr && addr_ptr->sa_family == AF_UNIX)
		return fpos::local_connect(fd, addr_ptr, addr_length);
	struct fpos_socket_address address;
	if (int e = fpos::to_kernel_address(addr_ptr, addr_length, &address))
		return e;
	return fpos::call_checked(FPOS_CALL_CONNECT_SOCKET, fd, &address);
}

int Sysdeps<Listen>::operator()(int fd, int backlog) {
	if (backlog < 1)
		backlog = 1;
	if (backlog > 64)
		backlog = 64;
	return fpos::call_checked(FPOS_CALL_LISTEN_SOCKET, fd, backlog);
}

int Sysdeps<Accept>::operator()(int fd, int *newfd, struct sockaddr *addr_ptr, socklen_t *addr_length,
		int flags) {
	struct fpos_socket_address address;
	memset(&address, 0, sizeof(address));
	if (int e = fpos::call_into(newfd, FPOS_CALL_ACCEPT_SOCKET, fd, &address))
		return e;
	if (address.family == AF_UNIX)
		fpos::local_accepted(*newfd, addr_ptr, addr_length);
	else if (addr_ptr && addr_length)
		fpos::from_kernel_address(address, addr_ptr, *addr_length, addr_length);
	fpos::forget_descriptor(*newfd);
	unsigned char descriptor = 0;
	if (flags & SOCK_CLOEXEC)
		descriptor |= fpos::descriptor_close_on_exec;
	if (flags & SOCK_NONBLOCK) {
		descriptor |= fpos::descriptor_non_blocking;
		fpos::call(FPOS_CALL_SET_SOCKET_OPTION, *newfd, FPOS_SOCKET_OPTION_NON_BLOCKING, 1);
	}
	fpos::set_descriptor_flags(*newfd, descriptor);
	return 0;
}

int Sysdeps<Sendto>::operator()(int fd, const void *buffer, size_t size, int flags,
		const struct sockaddr *sock_addr, socklen_t addr_length, ssize_t *length) {
	if (sock_addr && sock_addr->sa_family == AF_UNIX) {
		struct iovec piece = {const_cast<void *>(buffer), size};
		struct msghdr message = {};
		message.msg_name = const_cast<struct sockaddr *>(sock_addr);
		message.msg_namelen = addr_length;
		message.msg_iov = &piece;
		message.msg_iovlen = 1;
		return fpos::local_sendmsg(fd, &message, flags, length);
	}
	struct fpos_socket_address address;
	struct fpos_socket_address *target = nullptr;
	if (sock_addr) {
		if (int e = fpos::to_kernel_address(sock_addr, addr_length, &address))
			return e;
		target = &address;
	}
	long result = fpos::call(FPOS_CALL_SEND_SOCKET, fd, buffer, size, fpos::kernel_send_flags(flags), target);
	if (int e = fpos::error_of(result)) {
		if (e == EPIPE && !(flags & MSG_NOSIGNAL))
			sysdep<Kill>(sysdep<GetPid>(), SIGPIPE);
		return e;
	}
	*length = result;
	return 0;
}

int Sysdeps<Recvfrom>::operator()(int fd, void *buffer, size_t size, int flags, struct sockaddr *sock_addr,
		socklen_t *addr_length, ssize_t *length) {
	if (sock_addr && fpos::is_local_socket(fd)) {
		struct iovec piece = {buffer, size};
		struct msghdr message = {};
		message.msg_name = sock_addr;
		message.msg_namelen = addr_length ? *addr_length : 0;
		message.msg_iov = &piece;
		message.msg_iovlen = 1;
		if (int e = fpos::local_recvmsg(fd, &message, flags, length))
			return e;
		if (addr_length)
			*addr_length = message.msg_namelen;
		return 0;
	}
	if ((flags & MSG_WAITALL) && fpos::is_local_socket(fd)) {
		struct iovec piece = {buffer, size};
		struct msghdr message = {};
		message.msg_iov = &piece;
		message.msg_iovlen = 1;
		return fpos::local_recvmsg(fd, &message, flags, length);
	}
	struct fpos_socket_address address;
	memset(&address, 0, sizeof(address));
	long result = fpos::call(FPOS_CALL_RECEIVE_SOCKET, fd, buffer, size, fpos::kernel_send_flags(flags),
		sock_addr ? &address : nullptr);
	if (int e = fpos::error_of(result))
		return e;
	if (sock_addr && addr_length)
		fpos::from_kernel_address(address, sock_addr, *addr_length, addr_length);
	*length = result;
	return 0;
}

int Sysdeps<MsgSend>::operator()(int fd, const struct msghdr *hdr, int flags, ssize_t *length) {
	if (fpos::is_local_socket(fd))
		return fpos::local_sendmsg(fd, hdr, flags, length);
	size_t total;
	void *buffer = fpos::gather(hdr, &total);
	if (!buffer)
		return ENOMEM;
	int e = Sysdeps<Sendto>::operator()(fd, buffer, total, flags,
		static_cast<const struct sockaddr *>(hdr->msg_name), hdr->msg_namelen, length);
	getAllocator().free(buffer);
	return e;
}

int Sysdeps<MsgRecv>::operator()(int fd, struct msghdr *hdr, int flags, ssize_t *length) {
	if (fpos::is_local_socket(fd))
		return fpos::local_recvmsg(fd, hdr, flags, length);
	size_t total = 0;
	for (size_t i = 0; i < (size_t)hdr->msg_iovlen; i++)
		total += hdr->msg_iov[i].iov_len;
	auto buffer = static_cast<char *>(getAllocator().allocate(total ? total : 1));
	if (!buffer)
		return ENOMEM;
	socklen_t name_length = hdr->msg_namelen;
	ssize_t received;
	int e = Sysdeps<Recvfrom>::operator()(fd, buffer, total, flags,
		static_cast<struct sockaddr *>(hdr->msg_name), hdr->msg_name ? &name_length : nullptr, &received);
	if (!e) {
		size_t position = 0;
		for (size_t i = 0; i < (size_t)hdr->msg_iovlen && position < (size_t)received; i++) {
			size_t count = hdr->msg_iov[i].iov_len;
			if (count > (size_t)received - position)
				count = (size_t)received - position;
			memcpy(hdr->msg_iov[i].iov_base, buffer + position, count);
			position += count;
		}
		if (hdr->msg_name)
			hdr->msg_namelen = name_length;
		hdr->msg_controllen = 0;
		hdr->msg_flags = 0;
		*length = received;
	}
	getAllocator().free(buffer);
	return e;
}

int Sysdeps<Shutdown>::operator()(int sockfd, int how) {
	long kernel_how;
	switch (how) {
		case SHUT_RD: kernel_how = 1; break;
		case SHUT_WR: kernel_how = 2; break;
		case SHUT_RDWR: kernel_how = 3; break;
		default: return EINVAL;
	}
	return fpos::call_checked(FPOS_CALL_SHUTDOWN_SOCKET, sockfd, kernel_how);
}

int Sysdeps<GetSockopt>::operator()(int fd, int layer, int number, void *__restrict buffer,
		socklen_t *__restrict size) {
	bool local = layer == SOL_SOCKET && fpos::is_local_socket(fd);
	if (local) {
		int e;
		if (fpos::local_getsockopt(fd, layer, number, buffer, size, &e))
			return e;
	}
	const fpos::OptionMapping *mapping = fpos::find_option(layer, number);
	if (!mapping)
		return ENOPROTOOPT;
	long value = fpos::call(FPOS_CALL_GET_SOCKET_OPTION, fd, mapping->kernel_option);
	if (int e = fpos::error_of(value))
		return e;
	if (mapping->is_time) {
		struct timeval time;
		time.tv_sec = value / 1000;
		time.tv_usec = (value % 1000) * 1000;
		size_t count = *size < sizeof(time) ? *size : sizeof(time);
		memcpy(buffer, &time, count);
		*size = count;
		return 0;
	}
	if (mapping->kernel_option == FPOS_SOCKET_OPTION_KIND && local)
		value = value == FPOS_LOCAL_SOCKET_DATAGRAM ? SOCK_DGRAM
			: value == FPOS_LOCAL_SOCKET_PACKETS ? SOCK_SEQPACKET : SOCK_STREAM;
	else if (mapping->kernel_option == FPOS_SOCKET_OPTION_KIND)
		value = value == FPOS_SOCKET_KIND_STREAM ? SOCK_STREAM
			: value == FPOS_SOCKET_KIND_DATAGRAM ? SOCK_DGRAM : SOCK_RAW;
	int result = (int)value;
	size_t count = *size < sizeof(result) ? *size : sizeof(result);
	memcpy(buffer, &result, count);
	*size = count;
	return 0;
}

int Sysdeps<SetSockopt>::operator()(int fd, int layer, int number, const void *buffer, socklen_t size) {
	bool local = layer == SOL_SOCKET && fpos::is_local_socket(fd);
	if (local) {
		int e;
		if (fpos::local_setsockopt(fd, layer, number, buffer, size, &e))
			return e;
	}
	const fpos::OptionMapping *mapping = fpos::find_option(layer, number);
	// Options the kernel does not have (SO_LINGER, IP_TOS...) are taken
	// and have no effect, as programs rarely depend on them.
	if (!mapping)
		return 0;
	long value = 0;
	if (mapping->is_time) {
		if (size < sizeof(struct timeval))
			return EINVAL;
		auto time = static_cast<const struct timeval *>(buffer);
		value = time->tv_sec * 1000 + (time->tv_usec + 999) / 1000;
	} else {
		if (size < sizeof(int))
			return EINVAL;
		value = *static_cast<const int *>(buffer);
	}
	int e = fpos::call_checked(FPOS_CALL_SET_SOCKET_OPTION, fd, mapping->kernel_option, value);
	// Options a local socket has no use for (SO_REUSEADDR, SO_BROADCAST)
	// are taken, as on Linux.
	if (local && e == EOPNOTSUPP)
		return 0;
	return e;
}

int Sysdeps<Sockname>::operator()(int fd, struct sockaddr *addr_ptr, socklen_t max_addr_length,
		socklen_t *actual_length) {
	if (fpos::is_local_socket(fd))
		return fpos::local_name(fd, false, addr_ptr, max_addr_length, actual_length);
	struct fpos_socket_address address;
	if (int e = fpos::call_checked(FPOS_CALL_GET_SOCKET_ADDRESS, fd, FPOS_SOCKET_ADDRESS_LOCAL, &address))
		return e;
	fpos::from_kernel_address(address, addr_ptr, max_addr_length, actual_length);
	return 0;
}

int Sysdeps<Peername>::operator()(int fd, struct sockaddr *addr_ptr, socklen_t max_addr_length,
		socklen_t *actual_length) {
	if (fpos::is_local_socket(fd))
		return fpos::local_name(fd, true, addr_ptr, max_addr_length, actual_length);
	struct fpos_socket_address address;
	if (int e = fpos::call_checked(FPOS_CALL_GET_SOCKET_ADDRESS, fd, FPOS_SOCKET_ADDRESS_PEER, &address))
		return e;
	fpos::from_kernel_address(address, addr_ptr, max_addr_length, actual_length);
	return 0;
}

int Sysdeps<InetConfigured>::operator()(bool *ipv4, bool *ipv6) {
	*ipv4 = true;
	*ipv6 = true;
	return 0;
}

} // namespace mlibc
