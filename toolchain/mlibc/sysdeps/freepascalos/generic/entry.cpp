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

// Where crt1.o's _start goes: the dynamic linker (or, in a static
// program, its built-in part) sets up the thread, TLS and the
// initializers, then main runs and its result ends the process.

#include <stdint.h>
#include <stdlib.h>
#include <mlibc/elf/startup.h>

extern "C" void __dlapi_enter(uintptr_t *);

extern char **environ;

namespace fpos {
void initialize_process();
}

extern "C" void __mlibc_entry(int (*main_function)(int argc, char *argv[], char *env[]),
		uintptr_t *entry_stack) {
	__dlapi_enter(entry_stack);
	fpos::initialize_process();
	int result = main_function(mlibc::entry_stack.argc, mlibc::entry_stack.argv, environ);
	exit(result);
}
