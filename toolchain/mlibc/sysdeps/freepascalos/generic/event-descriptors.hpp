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

// What the event descriptor sysdeps (eventfd, timerfd, signalfd, epoll,
// inotify) share with each other and with fcntl and poll.

#pragma once

namespace fpos {

// FPOS_EVENT_DESCRIPTOR_NON_BLOCKING for O_NONBLOCK in flags, else 0.
unsigned long kernel_non_blocking(int flags);
// Records a new descriptor's O_CLOEXEC and O_NONBLOCK.
void remember_new_descriptor(int fd, int flags);
// Whether a handle kind (FPOS_CALL_GET_HANDLE_KIND) is an event descriptor,
// whose non-blocking flag the kernel keeps and whose readiness
// FPOS_CALL_QUERY_HANDLE_READINESS tells.
bool is_event_descriptor_kind(long kind);

} // namespace fpos
