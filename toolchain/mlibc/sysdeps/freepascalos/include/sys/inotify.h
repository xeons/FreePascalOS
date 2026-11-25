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

/*
 * inotify over the kernel's watch groups (calls 268-269). mlibc keeps
 * inotify in its linux option, which needs Linux's own headers; this is
 * the same interface, with Linux's values (the kernel's GroupWatch*
 * constants are the IN_* values and its records struct inotify_event).
 * The file systems report no opening, closing or reading, so IN_OPEN,
 * IN_ACCESS, IN_CLOSE_WRITE and IN_CLOSE_NOWRITE are accepted and never
 * come.
 */
#ifndef _SYS_INOTIFY_H
#define _SYS_INOTIFY_H

#include <stdint.h>
#include <abi-bits/fcntl.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IN_CLOEXEC O_CLOEXEC
#define IN_NONBLOCK O_NONBLOCK

#define IN_ACCESS 0x1
#define IN_MODIFY 0x2
#define IN_ATTRIB 0x4
#define IN_CLOSE_WRITE 0x8
#define IN_CLOSE_NOWRITE 0x10
#define IN_OPEN 0x20
#define IN_MOVED_FROM 0x40
#define IN_MOVED_TO 0x80
#define IN_CREATE 0x100
#define IN_DELETE 0x200
#define IN_DELETE_SELF 0x400
#define IN_MOVE_SELF 0x800
#define IN_UNMOUNT 0x2000
#define IN_Q_OVERFLOW 0x4000
#define IN_IGNORED 0x8000
#define IN_MOVE (IN_MOVED_FROM | IN_MOVED_TO)
#define IN_CLOSE (IN_CLOSE_WRITE | IN_CLOSE_NOWRITE)
#define IN_ONLYDIR 0x1000000
#define IN_DONT_FOLLOW 0x2000000
#define IN_EXCL_UNLINK 0x4000000
#define IN_MASK_CREATE 0x10000000
#define IN_MASK_ADD 0x20000000
#define IN_ISDIR 0x40000000
#define IN_ONESHOT 0x80000000

#define IN_ALL_EVENTS (IN_ACCESS | IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | \
			 IN_CLOSE_NOWRITE | IN_OPEN | IN_MOVED_FROM | \
			 IN_MOVED_TO | IN_DELETE | IN_CREATE | IN_DELETE_SELF | \
			 IN_MOVE_SELF)

struct inotify_event {
	int wd;
	uint32_t mask;
	uint32_t cookie;
	uint32_t len;
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic"
	char name[];
#pragma GCC diagnostic pop
};

#ifndef __MLIBC_ABI_ONLY

int inotify_init(void);
int inotify_init1(int __flags);
int inotify_add_watch(int __fd, const char *__path, uint32_t __mask);
int inotify_rm_watch(int __fd, int __wd);

#endif /* !__MLIBC_ABI_ONLY */

#ifdef __cplusplus
}
#endif

#endif /* _SYS_INOTIFY_H */
