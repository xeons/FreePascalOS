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

// Unix domain sockets: names (struct sockaddr_un, paths and the
// abstract namespace) translate to struct fpos_local_socket_name;
// sendmsg and recvmsg carry SCM_RIGHTS (descriptors, which the kernel
// installs in the receiver) and SCM_CREDENTIALS (the kernel stamps
// every message with the sender's real credentials, so what a program
// puts there is not believed: only that it asked); SO_PEERCRED and
// SO_PASSCRED are the kernel's.

#include "kernel.hpp"
#include "descriptors.hpp"
#include "localsockets.hpp"

#include <errno.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <mlibc/all-sysdeps.hpp>
#include <mlibc/allocator.hpp>

namespace fpos {

namespace {

// struct ucred's layout (it is only declared for _GNU_SOURCE).
struct credentials_record {
	pid_t pid;
	uid_t uid;
	gid_t gid;
};

constexpr size_t path_offset = offsetof(struct sockaddr_un, sun_path);

int to_local_name(const struct sockaddr *address, socklen_t length, struct fpos_local_socket_name *name) {
	memset(name, 0, sizeof(*name));
	if (!address || length < sizeof(sa_family_t))
		return EINVAL;
	if (address->sa_family != AF_UNIX)
		return EAFNOSUPPORT;
	if (length > sizeof(struct sockaddr_un))
		length = sizeof(struct sockaddr_un);
	size_t bytes = length > path_offset ? length - path_offset : 0;
	auto un = reinterpret_cast<const struct sockaddr_un *>(address);
	if (bytes > 0 && un->sun_path[0] != '\0') {
		// A path: up to its end (which need not be counted in length).
		size_t end = 0;
		while (end < bytes && un->sun_path[end] != '\0')
			end++;
		bytes = end;
	}
	memcpy(name->bytes, un->sun_path, bytes);
	name->length = (uint32_t)bytes;
	return 0;
}

void from_local_name(const struct fpos_local_socket_name &name, struct sockaddr *out, socklen_t max_length,
		socklen_t *actual_length) {
	struct sockaddr_un un;
	memset(&un, 0, sizeof(un));
	un.sun_family = AF_UNIX;
	size_t bytes = name.length;
	if (bytes > sizeof(un.sun_path))
		bytes = sizeof(un.sun_path);
	memcpy(un.sun_path, name.bytes, bytes);
	socklen_t length = (socklen_t)(path_offset + bytes);
	// A path is told with its terminating zero.
	if (bytes > 0 && name.bytes[0] != '\0' && bytes < sizeof(un.sun_path))
		length++;
	if (out)
		memcpy(out, &un, length < max_length ? length : max_length);
	if (actual_length)
		*actual_length = length;
}

long kernel_kind(int type) {
	switch (type & 0xFF) {
		case SOCK_STREAM: return FPOS_LOCAL_SOCKET_STREAM;
		case SOCK_DGRAM: return FPOS_LOCAL_SOCKET_DATAGRAM;
		case SOCK_SEQPACKET: return FPOS_LOCAL_SOCKET_PACKETS;
		default: return -1;
	}
}

void note_new_descriptor(int fd, bool close_on_exec, bool non_blocking) {
	forget_descriptor(fd);
	unsigned char flags = 0;
	if (close_on_exec)
		flags |= descriptor_close_on_exec;
	if (non_blocking)
		flags |= descriptor_non_blocking;
	set_descriptor_flags(fd, flags);
}

// The descriptors of SCM_RIGHTS in a message's control data (at most
// FPOS_MAXIMUM_LOCAL_MESSAGE_HANDLES), and whether it had any other
// control message the kernel cannot pass.
int collect_rights(const struct msghdr *message, int64_t *handles, uint32_t *count) {
	*count = 0;
	if (!message->msg_control || message->msg_controllen < sizeof(struct cmsghdr))
		return 0;
	for (struct cmsghdr *header = CMSG_FIRSTHDR(message); header;
			header = CMSG_NXTHDR(const_cast<struct msghdr *>(message), header)) {
		if (header->cmsg_level != SOL_SOCKET)
			continue;
		if (header->cmsg_type == SCM_RIGHTS) {
			size_t bytes = header->cmsg_len - CMSG_LEN(0);
			size_t fds = bytes / sizeof(int);
			auto data = reinterpret_cast<const int *>(CMSG_DATA(header));
			for (size_t i = 0; i < fds; i++) {
				if (*count >= FPOS_MAXIMUM_LOCAL_MESSAGE_HANDLES)
					return ETOOMANYREFS;
				handles[(*count)++] = data[i];
			}
		}
		// SCM_CREDENTIALS: the kernel stamps the real ones anyway.
	}
	return 0;
}

// The pieces of a message gathered into one buffer.
char *gather(const struct msghdr *message, size_t *length) {
	size_t total = 0;
	for (size_t i = 0; i < (size_t)message->msg_iovlen; i++)
		total += message->msg_iov[i].iov_len;
	*length = total;
	auto buffer = static_cast<char *>(getAllocator().allocate(total ? total : 1));
	if (!buffer)
		return nullptr;
	size_t position = 0;
	for (size_t i = 0; i < (size_t)message->msg_iovlen; i++) {
		memcpy(buffer + position, message->msg_iov[i].iov_base, message->msg_iov[i].iov_len);
		position += message->msg_iov[i].iov_len;
	}
	return buffer;
}

void scatter(const struct msghdr *message, const char *buffer, size_t length) {
	size_t position = 0;
	for (size_t i = 0; i < (size_t)message->msg_iovlen && position < length; i++) {
		size_t count = message->msg_iov[i].iov_len;
		if (count > length - position)
			count = length - position;
		memcpy(message->msg_iov[i].iov_base, buffer + position, count);
		position += count;
	}
}

long kernel_message_flags(int flags) {
	long result = 0;
	if (flags & MSG_PEEK)
		result |= FPOS_LOCAL_MESSAGE_PEEK;
	if (flags & MSG_DONTWAIT)
		result |= FPOS_LOCAL_MESSAGE_DONT_WAIT;
	if (flags & MSG_WAITALL)
		result |= FPOS_LOCAL_MESSAGE_WAIT_ALL;
	return result;
}

bool passes_credentials(int fd) {
	return call(FPOS_CALL_GET_SOCKET_OPTION, fd, FPOS_SOCKET_OPTION_PASS_CREDENTIALS) == 1;
}

// Writes the control messages of what was received: SCM_RIGHTS for the
// descriptors, SCM_CREDENTIALS if asked for. Sets MSG_CTRUNC when they
// do not fit (descriptors that do not fit are closed).
void build_control(struct msghdr *message, const int64_t *handles, uint32_t handle_count,
		const struct fpos_local_credentials *sender, bool with_credentials, int flags) {
	size_t capacity = message->msg_control ? message->msg_controllen : 0;
	size_t used = 0;
	auto control = static_cast<char *>(message->msg_control);
	if (handle_count) {
		size_t fits = 0;
		if (capacity >= CMSG_LEN(sizeof(int)))
			fits = (capacity - CMSG_LEN(0)) / sizeof(int);
		if (fits > handle_count)
			fits = handle_count;
		if (fits < handle_count)
			message->msg_flags |= MSG_CTRUNC;
		for (uint32_t i = (uint32_t)fits; i < handle_count; i++) {
			forget_descriptor((int)handles[i]);
			call(FPOS_CALL_CLOSE, handles[i]);
		}
		if (fits) {
			auto header = reinterpret_cast<struct cmsghdr *>(control);
			header->cmsg_level = SOL_SOCKET;
			header->cmsg_type = SCM_RIGHTS;
			header->cmsg_len = CMSG_LEN(fits * sizeof(int));
			auto data = reinterpret_cast<int *>(CMSG_DATA(header));
			for (size_t i = 0; i < fits; i++) {
				data[i] = (int)handles[i];
				note_new_descriptor(data[i], (flags & MSG_CMSG_CLOEXEC) != 0, false);
			}
			used += CMSG_SPACE(fits * sizeof(int));
		}
	}
	if (with_credentials) {
		if (used + CMSG_LEN(sizeof(credentials_record)) <= capacity) {
			auto header = reinterpret_cast<struct cmsghdr *>(control + used);
			header->cmsg_level = SOL_SOCKET;
			header->cmsg_type = SCM_CREDENTIALS;
			header->cmsg_len = CMSG_LEN(sizeof(credentials_record));
			credentials_record record;
			record.pid = (pid_t)sender->process_id;
			record.uid = (uid_t)sender->user_id;
			record.gid = (gid_t)sender->group_id;
			memcpy(CMSG_DATA(header), &record, sizeof(record));
			used += CMSG_SPACE(sizeof(credentials_record));
		} else {
			message->msg_flags |= MSG_CTRUNC;
		}
	}
	if (used > capacity)
		used = capacity;
	message->msg_controllen = used;
}

} // namespace

bool is_local_socket(int fd) {
	return call(FPOS_CALL_QUERY_LOCAL_SOCKET, fd, FPOS_LOCAL_QUERY_KIND, 0) > 0;
}

int local_socket(int type, int *fd) {
	long kind = kernel_kind(type);
	if (kind < 0)
		return EPROTONOSUPPORT;
	long flags = (type & SOCK_NONBLOCK) ? FPOS_LOCAL_SOCKET_NON_BLOCKING : 0;
	if (int e = call_into(fd, FPOS_CALL_CREATE_LOCAL_SOCKET, kind, flags, 0))
		return e;
	note_new_descriptor(*fd, (type & SOCK_CLOEXEC) != 0, (type & SOCK_NONBLOCK) != 0);
	return 0;
}

int local_socketpair(int type, int *fds) {
	long kind = kernel_kind(type);
	if (kind < 0)
		return EPROTONOSUPPORT;
	long flags = (type & SOCK_NONBLOCK) ? FPOS_LOCAL_SOCKET_NON_BLOCKING : 0;
	int64_t handles[2];
	if (int e = call_checked(FPOS_CALL_CREATE_LOCAL_SOCKET, kind, flags, handles))
		return e;
	for (int i = 0; i < 2; i++) {
		fds[i] = (int)handles[i];
		note_new_descriptor(fds[i], (type & SOCK_CLOEXEC) != 0, (type & SOCK_NONBLOCK) != 0);
	}
	return 0;
}

int local_bind(int fd, const struct sockaddr *address, socklen_t length) {
	struct fpos_local_socket_name name;
	if (int e = to_local_name(address, length, &name))
		return e;
	return call_checked(FPOS_CALL_BIND_LOCAL_SOCKET, fd, &name);
}

int local_connect(int fd, const struct sockaddr *address, socklen_t length) {
	struct fpos_local_socket_name name;
	if (int e = to_local_name(address, length, &name))
		return e;
	if (name.length == 0)
		return EINVAL;
	// No such path gives ENOENT; a socket node nobody is bound to (or a
	// path that is no socket) ECONNREFUSED, as on Linux.
	return call_checked(FPOS_CALL_CONNECT_LOCAL_SOCKET, fd, &name);
}

void local_accepted(int fd, struct sockaddr *address, socklen_t *length) {
	if (!address || !length)
		return;
	struct fpos_local_socket_name name;
	memset(&name, 0, sizeof(name));
	// The connecting socket's name (usually it has none).
	call(FPOS_CALL_QUERY_LOCAL_SOCKET, fd, FPOS_LOCAL_QUERY_PEER_NAME, &name);
	from_local_name(name, address, *length, length);
}

int local_sendmsg(int fd, const struct msghdr *message, int flags, ssize_t *length) {
	int64_t handles[FPOS_MAXIMUM_LOCAL_MESSAGE_HANDLES];
	uint32_t handle_count;
	if (int e = collect_rights(message, handles, &handle_count))
		return e;
	struct fpos_local_socket_name name;
	bool has_name = false;
	if (message->msg_name && message->msg_namelen) {
		if (int e = to_local_name(static_cast<const struct sockaddr *>(message->msg_name), message->msg_namelen,
				&name))
			return e;
		has_name = true;
	}
	size_t total;
	char *buffer = gather(message, &total);
	if (!buffer)
		return ENOMEM;
	struct fpos_local_message request;
	memset(&request, 0, sizeof(request));
	request.buffer = buffer;
	request.length = total;
	request.handles = handles;
	request.handle_count = handle_count;
	request.name = has_name ? &name : nullptr;
	long result = call(FPOS_CALL_SEND_LOCAL_MESSAGE, fd, &request, kernel_message_flags(flags));
	getAllocator().free(buffer);
	if (int e = error_of(result)) {
		if (e == EPIPE && !(flags & MSG_NOSIGNAL))
			call(FPOS_CALL_SEND_SIGNAL, call(FPOS_CALL_GET_PROCESS_ID, -1), SIGPIPE);
		return e;
	}
	*length = result;
	return 0;
}

int local_recvmsg(int fd, struct msghdr *message, int flags, ssize_t *length) {
	size_t total = 0;
	for (size_t i = 0; i < (size_t)message->msg_iovlen; i++)
		total += message->msg_iov[i].iov_len;
	auto buffer = static_cast<char *>(getAllocator().allocate(total ? total : 1));
	if (!buffer)
		return ENOMEM;
	int64_t handles[FPOS_MAXIMUM_LOCAL_MESSAGE_HANDLES];
	struct fpos_local_socket_name name;
	memset(&name, 0, sizeof(name));
	struct fpos_local_message request;
	memset(&request, 0, sizeof(request));
	request.buffer = buffer;
	request.length = total;
	request.handles = handles;
	request.handle_count = FPOS_MAXIMUM_LOCAL_MESSAGE_HANDLES;
	request.name = &name;
	long result = call(FPOS_CALL_RECEIVE_LOCAL_MESSAGE, fd, &request, kernel_message_flags(flags));
	if (int e = error_of(result)) {
		getAllocator().free(buffer);
		return e;
	}
	scatter(message, buffer, (size_t)result);
	getAllocator().free(buffer);
	message->msg_flags = 0;
	if (request.flags & FPOS_LOCAL_MESSAGE_TRUNCATED)
		message->msg_flags |= MSG_TRUNC;
	if (request.flags & FPOS_LOCAL_MESSAGE_HANDLES_CUT)
		message->msg_flags |= MSG_CTRUNC;
	if (message->msg_name) {
		socklen_t name_length;
		from_local_name(name, static_cast<struct sockaddr *>(message->msg_name), message->msg_namelen, &name_length);
		message->msg_namelen = name_length;
	}
	bool with_credentials = message->msg_control && passes_credentials(fd);
	build_control(message, handles, request.handle_count, &request.credentials, with_credentials, flags);
	*length = result;
	return 0;
}

int local_name(int fd, bool peer, struct sockaddr *address, socklen_t max_length, socklen_t *actual_length) {
	struct fpos_local_socket_name name;
	memset(&name, 0, sizeof(name));
	long which = peer ? FPOS_LOCAL_QUERY_PEER_NAME : FPOS_LOCAL_QUERY_NAME;
	if (int e = call_checked(FPOS_CALL_QUERY_LOCAL_SOCKET, fd, which, &name))
		return e;
	from_local_name(name, address, max_length, actual_length);
	return 0;
}

namespace {

void store_int(void *buffer, socklen_t *size, int value) {
	size_t count = *size < sizeof(value) ? *size : sizeof(value);
	memcpy(buffer, &value, count);
	*size = (socklen_t)count;
}

int socket_type_of(long kind) {
	switch (kind) {
		case FPOS_LOCAL_SOCKET_DATAGRAM: return SOCK_DGRAM;
		case FPOS_LOCAL_SOCKET_PACKETS: return SOCK_SEQPACKET;
		default: return SOCK_STREAM;
	}
}

} // namespace

bool local_getsockopt(int fd, int layer, int number, void *buffer, socklen_t *size, int *error) {
	*error = 0;
	if (layer != SOL_SOCKET)
		return false;
	switch (number) {
		case SO_PEERCRED: {
			struct fpos_local_credentials credentials;
			if ((*error = call_checked(FPOS_CALL_QUERY_LOCAL_SOCKET, fd, FPOS_LOCAL_QUERY_PEER_CREDENTIALS,
					&credentials)))
				return true;
			credentials_record record;
			record.pid = (pid_t)credentials.process_id;
			record.uid = (uid_t)credentials.user_id;
			record.gid = (gid_t)credentials.group_id;
			size_t count = *size < sizeof(record) ? *size : sizeof(record);
			memcpy(buffer, &record, count);
			*size = (socklen_t)count;
			return true;
		}
		case SO_TYPE: {
			long kind = call(FPOS_CALL_QUERY_LOCAL_SOCKET, fd, FPOS_LOCAL_QUERY_KIND, 0);
			if ((*error = error_of(kind)))
				return true;
			store_int(buffer, size, socket_type_of(kind));
			return true;
		}
		case SO_DOMAIN:
			store_int(buffer, size, AF_UNIX);
			return true;
		case SO_PROTOCOL:
			store_int(buffer, size, 0);
			return true;
		case SO_PASSCRED:
		case SO_ACCEPTCONN: {
			long option = number == SO_PASSCRED ? FPOS_SOCKET_OPTION_PASS_CREDENTIALS : FPOS_SOCKET_OPTION_LISTENING;
			long value = call(FPOS_CALL_GET_SOCKET_OPTION, fd, option);
			if ((*error = error_of(value)))
				return true;
			store_int(buffer, size, (int)value);
			return true;
		}
		default:
			return false;
	}
}

bool local_setsockopt(int fd, int layer, int number, const void *buffer, socklen_t size, int *error) {
	*error = 0;
	if (layer != SOL_SOCKET || number != SO_PASSCRED)
		return false;
	if (size < sizeof(int)) {
		*error = EINVAL;
		return true;
	}
	int value = *static_cast<const int *>(buffer);
	*error = call_checked(FPOS_CALL_SET_SOCKET_OPTION, fd, FPOS_SOCKET_OPTION_PASS_CREDENTIALS, value ? 1 : 0);
	return true;
}

} // namespace fpos
