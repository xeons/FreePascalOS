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

// The sysdeps FreePascalOS implements (generic/*.cpp).

#pragma once

#include <mlibc/sysdep-signatures.hpp>

namespace mlibc {

struct FreePascalOsSysdepTags :
	// Both the dynamic linker and libc.
	LibcLog,
	LibcPanic,
	Exit,
	TcbSet,
	FutexTid,
	FutexWait,
	FutexWake,
	ClockGet,
	VmMap,
	VmUnmap,
	VmProtect,
	AnonAllocate,
	AnonFree,
	Open,
	Read,
	Write,
	Seek,
	Close,
	Stat,
	// Descriptors.
	Openat,
	Pread,
	Pwrite,
	Readv,
	Writev,
	Dup,
	Dup2,
	Fcntl,
	Pipe,
	Access,
	Faccessat,
	Ftruncate,
	Truncate,
	Fsync,
	Fdatasync,
	Sync,
	Flock,
	Umask,
	GetCwd,
	Chdir,
	Fchdir,
	Chroot,
	FdToPath,
	Chmod,
	Fchmod,
	Fchmodat,
	Fchownat,
	Utimensat,
	Isatty,
	Ttyname,
	// Names.
	OpenDir,
	ReadEntries,
	Mkdir,
	Mkdirat,
	Rmdir,
	Unlinkat,
	Rename,
	Renameat,
	Link,
	Linkat,
	Symlink,
	Symlinkat,
	Readlink,
	Readlinkat,
	Mkfifoat,
	Statvfs,
	Fstatvfs,
	// Threads.
	PrepareStack,
	Clone,
	ThreadExit,
	GetTid,
	Yield,
	Sleep,
	ThreadSetname,
	GetCurrentStackInfo,
	// Processes.
	GetPid,
	GetPpid,
	Fork,
	Execve,
	Waitpid,
	GetPgid,
	GetSid,
	SetPgid,
	SetSid,
	GetUid,
	GetEuid,
	GetGid,
	GetEgid,
	GetResuid,
	GetResgid,
	SetUid,
	SetEuid,
	SetGid,
	SetEgid,
	SetResuid,
	SetResgid,
	SetReuid,
	SetRegid,
	GetGroups,
	SetGroups,
	GetPriority,
	SetPriority,
	Nice,
	// The system.
	Uname,
	GetHostname,
	SetHostname,
	Sysconf,
	GetEntropy,
	GetRlimit,
	SetRlimit,
	GetRusage,
	Times,
	GetItimer,
	SetItimer,
	// Waiting for descriptors.
	Poll,
	Ppoll,
	Pselect,
	// Sockets.
	Socket,
	Bind,
	Connect,
	Listen,
	Accept,
	Sendto,
	Recvfrom,
	MsgSend,
	MsgRecv,
	Shutdown,
	GetSockopt,
	SetSockopt,
	Sockname,
	Peername,
	InetConfigured,
	// Terminals.
	Tcgetattr,
	Tcsetattr,
	Tcflush,
	Tcdrain,
	Tcflow,
	Tcsendbreak,
	Tcgetwinsize,
	Tcsetwinsize,
	Ioctl,
	// Signals.
	Sigaction,
	Sigprocmask,
	ThreadSigmask,
	Sigsuspend,
	Sigpending,
	Pause,
	Kill,
	Tgkill,
	Sigaltstack
{};

template<typename Tag>
using Sysdeps = SysdepOf<FreePascalOsSysdepTags, Tag>;

struct SysdepTraits {
	static constexpr bool usesRtNetlink = false;
};

} // namespace mlibc
