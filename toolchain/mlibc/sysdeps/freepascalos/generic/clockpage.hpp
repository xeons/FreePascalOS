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

// The clock page: CLOCK_REALTIME and CLOCK_MONOTONIC read from the page
// the kernel maps into every program (FPOS_AUXILIARY_CLOCK_PAGE) and the
// processor's counter, without a system call - when the page's mode
// says the counter may be used. The arithmetic is the kernel's
// (shared/ClockPageMath.inc), to the nanosecond.

#pragma once

#include <freepascalos/syscall.h>
#include <stdint.h>

namespace fpos {

// Nanoseconds since start (uptime) or since 1970 (wall clock) from the
// page; false if the page cannot give it (no page, or the system call
// mode), then the caller makes the call.
bool clock_page_uptime(uint64_t *nanoseconds);
bool clock_page_wall_clock(int64_t *nanoseconds);

// The page's arithmetic, for a copy of the page and a counter value.
uint64_t clock_page_uptime_at(const struct fpos_clock_page &page, uint64_t counter);
int64_t clock_page_wall_clock_at(const struct fpos_clock_page &page, uint64_t uptime);

} // namespace fpos
