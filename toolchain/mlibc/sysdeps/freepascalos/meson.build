# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# The FreePascalOS sysdeps of mlibc (copied into mlibc's sysdeps/ by
# toolchain/build-toolchain.sh; mlibc's meson.build is patched to come
# here for host_machine.system() == 'freepascalos').

sysdep_supported_options = {
	'posix': true,
	'linux': false,
	'glibc': true,
	'bsd': true,
	# The kernel's event descriptors (generic/event-descriptors.cpp,
	# generic/event-polls.cpp); inotify is ours too (generic/inotify.cpp,
	# include/sys/inotify.h), as mlibc keeps it in the linux option.
	'linux-epoll': true,
	'linux-eventfd': true,
	'linux-timerfd': true,
	'linux-signalfd': true,
}

arch = host_machine.cpu_family()

rtld_sources += files(
	'generic/core.cpp',
	'generic/memory.cpp',
	'generic/files-core.cpp',
)

libc_sources += files(
	'generic/core.cpp',
	'generic/memory.cpp',
	'generic/files-core.cpp',
	'generic/entry.cpp',
	'generic/descriptors.cpp',
	'generic/files.cpp',
	'generic/directories.cpp',
	'generic/threads.cpp',
	'generic/process.cpp',
	'generic/system.cpp',
	'generic/polling.cpp',
	'generic/sockets.cpp',
	'generic/terminal.cpp',
	'generic/signals.cpp',
	'generic/timers.cpp',
	'generic/event-descriptors.cpp',
	'generic/event-polls.cpp',
	'generic/inotify.cpp',
	'arch' / arch / 'thread-entry.S',
)

if not no_headers
	install_headers(
		'include/abi-bits/access.h',
		'include/abi-bits/aio.h',
		'include/abi-bits/auxv.h',
		'include/abi-bits/blkcnt_t.h',
		'include/abi-bits/blksize_t.h',
		'include/abi-bits/clockid_t.h',
		'include/abi-bits/clone-flags.h',
		'include/abi-bits/dev_t.h',
		'include/abi-bits/epoll.h',
		'include/abi-bits/errno.h',
		'include/abi-bits/fcntl.h',
		'include/abi-bits/fd_set.h',
		'include/abi-bits/fsblkcnt_t.h',
		'include/abi-bits/fsfilcnt_t.h',
		'include/abi-bits/gid_t.h',
		'include/abi-bits/in.h',
		'include/abi-bits/ino_t.h',
		'include/abi-bits/inotify.h',
		'include/abi-bits/ioctls.h',
		'include/abi-bits/ipc.h',
		'include/abi-bits/limits.h',
		'include/abi-bits/mode_t.h',
		'include/abi-bits/mqueue.h',
		'include/abi-bits/msg.h',
		'include/abi-bits/nlink_t.h',
		'include/abi-bits/packet.h',
		'include/abi-bits/pid_t.h',
		'include/abi-bits/poll.h',
		'include/abi-bits/ptrace.h',
		'include/abi-bits/random.h',
		'include/abi-bits/reboot.h',
		'include/abi-bits/resource.h',
		'include/abi-bits/rlim_t.h',
		'include/abi-bits/route.h',
		'include/abi-bits/sa_family_t.h',
		'include/abi-bits/sched_param.h',
		'include/abi-bits/seek-whence.h',
		'include/abi-bits/sem.h',
		'include/abi-bits/shm.h',
		'include/abi-bits/sig-limits.h',
		'include/abi-bits/sigevent.h',
		'include/abi-bits/signal.h',
		'include/abi-bits/sigset_t.h',
		'include/abi-bits/sigval.h',
		'include/abi-bits/sockaddr_storage.h',
		'include/abi-bits/socket.h',
		'include/abi-bits/socklen_t.h',
		'include/abi-bits/stat.h',
		'include/abi-bits/statfs.h',
		'include/abi-bits/statvfs.h',
		'include/abi-bits/statx.h',
		'include/abi-bits/suseconds_t.h',
		'include/abi-bits/termios.h',
		'include/abi-bits/time.h',
		'include/abi-bits/uid_t.h',
		'include/abi-bits/utmp-defines.h',
		'include/abi-bits/utmpx.h',
		'include/abi-bits/utsname.h',
		'include/abi-bits/vm-flags.h',
		'include/abi-bits/vt.h',
		'include/abi-bits/wait.h',
		'include/abi-bits/xattr.h',
		subdir: 'abi-bits',
		follow_symlinks: true,
	)
	install_headers(
		'include/freepascalos/syscall.h',
		subdir: 'freepascalos',
	)
	install_headers(
		'include/sys/inotify.h',
		subdir: 'sys',
	)
endif

if not headers_only
	foreach crt : ['crt1', 'crti', 'crtn']
		custom_target(crt,
			build_by_default: true,
			command: c_compiler.cmd_array() + ['-c', '-o', '@OUTPUT@', '@INPUT@'],
			input: 'arch' / arch / crt + '.S',
			output: crt + '.o',
			install: true,
			install_dir: get_option('libdir'),
		)
	endforeach
endif
