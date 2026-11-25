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

#include "clockpage.hpp"

extern "C" uintptr_t *__dlapi_entrystack();

namespace fpos {

namespace {

constexpr uint64_t nanoseconds_per_second = 1000000000;
constexpr uint64_t microseconds_per_second = 1000000;

// The page's address once looked for; 1 while it has not been yet.
const struct fpos_clock_page *const not_looked_for = reinterpret_cast<const struct fpos_clock_page *>(1);
const struct fpos_clock_page *page_address = not_looked_for;

const struct fpos_clock_page *find_page() {
	uintptr_t *entry = __dlapi_entrystack();
	if (!entry)
		return nullptr;
	// argc, the arguments and their end, the environment and its end,
	// then the auxiliary vector.
	entry += *entry + 2;
	while (*entry)
		entry++;
	entry++;
	for (; entry[0] != 0; entry += 2) {
		if (entry[0] == FPOS_AUXILIARY_CLOCK_PAGE)
			return reinterpret_cast<const struct fpos_clock_page *>(entry[1]);
	}
	return nullptr;
}

const struct fpos_clock_page *the_page() {
	const struct fpos_clock_page *page = __atomic_load_n(&page_address, __ATOMIC_ACQUIRE);
	if (page == not_looked_for) {
		page = find_page();
		__atomic_store_n(&page_address, page, __ATOMIC_RELEASE);
	}
	return page;
}

inline uint64_t read_counter() {
#if defined(__x86_64__)
	uint32_t low, high;
	__asm__ volatile("lfence; rdtsc" : "=a"(low), "=d"(high) : : "memory");
	return (static_cast<uint64_t>(high) << 32) | low;
#elif defined(__aarch64__)
	uint64_t value;
	__asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(value) : : "memory");
	return value;
#endif
}

// A consistent copy of the page and the counter read while it held:
// the kernel makes the sequence odd while it changes the page.
bool snapshot(struct fpos_clock_page *copy, uint64_t *counter) {
	const struct fpos_clock_page *page = the_page();
	if (!page)
		return false;
	uint32_t before;
	do {
		before = __atomic_load_n(&page->sequence, __ATOMIC_ACQUIRE);
		copy->mode = page->mode;
		copy->counter_origin = page->counter_origin;
		copy->origin_nanoseconds = page->origin_nanoseconds;
		copy->counter_frequency = page->counter_frequency;
		copy->wall_base_offset = page->wall_base_offset;
		copy->slew_total = page->slew_total;
		copy->slew_start = page->slew_start;
		copy->slew_parts_per_million = page->slew_parts_per_million;
		*counter = read_counter();
		__atomic_thread_fence(__ATOMIC_ACQUIRE);
	} while ((before & 1) || __atomic_load_n(&page->sequence, __ATOMIC_RELAXED) != before);
	return copy->mode == FPOS_CLOCK_PAGE_MODE_COUNTER;
}

int64_t slew_progress(int64_t total, uint64_t start, uint64_t now, uint64_t parts_per_million) {
	if (total == 0 || now <= start)
		return 0;
	uint64_t elapsed = now - start;
	uint64_t moved = (elapsed / microseconds_per_second) * parts_per_million +
		((elapsed % microseconds_per_second) * parts_per_million) / microseconds_per_second;
	uint64_t magnitude = total < 0 ? static_cast<uint64_t>(-total) : static_cast<uint64_t>(total);
	if (moved > magnitude)
		moved = magnitude;
	return total < 0 ? -static_cast<int64_t>(moved) : static_cast<int64_t>(moved);
}

} // namespace

uint64_t clock_page_uptime_at(const struct fpos_clock_page &page, uint64_t counter) {
	uint64_t frequency = page.counter_frequency;
	if (frequency == 0 || counter <= page.counter_origin)
		return page.origin_nanoseconds;
	uint64_t elapsed = counter - page.counter_origin;
	return page.origin_nanoseconds + (elapsed / frequency) * nanoseconds_per_second +
		((elapsed % frequency) * nanoseconds_per_second) / frequency;
}

int64_t clock_page_wall_clock_at(const struct fpos_clock_page &page, uint64_t uptime) {
	return static_cast<int64_t>(uptime) + page.wall_base_offset +
		slew_progress(page.slew_total, page.slew_start, uptime, page.slew_parts_per_million);
}

bool clock_page_uptime(uint64_t *nanoseconds) {
	struct fpos_clock_page copy;
	uint64_t counter;
	if (!snapshot(&copy, &counter))
		return false;
	*nanoseconds = clock_page_uptime_at(copy, counter);
	return true;
}

bool clock_page_wall_clock(int64_t *nanoseconds) {
	struct fpos_clock_page copy;
	uint64_t counter;
	if (!snapshot(&copy, &counter))
		return false;
	*nanoseconds = clock_page_wall_clock_at(copy, clock_page_uptime_at(copy, counter));
	return true;
}

} // namespace fpos
