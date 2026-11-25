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

// Small helpers every part of the FreePascalOS sysdeps uses: making a
// system call and turning its result into an errno and a value.

#pragma once

#include <freepascalos/syscall.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

namespace fpos {

template<typename... Args>
inline long call(long number, Args... args) {
	long values[6] = {(long)args...};
	static_assert(sizeof...(Args) <= 6, "at most six arguments");
	return fpos_syscall6(number, values[0], values[1], values[2], values[3], values[4], values[5]);
}

inline long call(long number) {
	return fpos_syscall0(number);
}

// The errno of a call's result, 0 for success.
inline int error_of(long result) {
	return fpos_error_of(result);
}

// Makes a call; on success stores its result in *value (if given).
template<typename T, typename... Args>
inline int call_into(T *value, long number, Args... args) {
	long result = call(number, args...);
	if (int e = error_of(result))
		return e;
	if (value)
		*value = (T)result;
	return 0;
}

template<typename... Args>
inline int call_checked(long number, Args... args) {
	return error_of(call(number, args...));
}

// Milliseconds for a relative timeout, rounded up; FPOS_INFINITE_WAIT
// for none.
long milliseconds_of(const struct timespec *timeout);

} // namespace fpos
