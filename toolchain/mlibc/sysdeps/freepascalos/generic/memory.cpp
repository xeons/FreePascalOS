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

// Memory: mmap, munmap and mprotect over the kernel's POSIX mapping
// calls (180, 181) and CallProtectMemory. PROT_* and MAP_* have the
// kernel's values (the Linux ones), so they pass straight through.

#include "kernel.hpp"

#include <errno.h>
#include <sys/mman.h>
#include <mlibc/all-sysdeps.hpp>

namespace mlibc {

int Sysdeps<VmMap>::operator()(void *hint, size_t size, int prot, int flags, int fd, off_t offset,
		void **window) {
	long result = fpos::call(FPOS_CALL_MAP_MEMORY, hint, size, prot, flags, fd, offset);
	if (int e = fpos::error_of(result))
		return e;
	*window = reinterpret_cast<void *>(result);
	return 0;
}

int Sysdeps<VmUnmap>::operator()(void *pointer, size_t size) {
	return fpos::call_checked(FPOS_CALL_UNMAP_MEMORY, pointer, size);
}

int Sysdeps<VmProtect>::operator()(void *pointer, size_t size, int prot) {
	return fpos::call_checked(FPOS_CALL_PROTECT_MEMORY, pointer, size, prot);
}

int Sysdeps<AnonAllocate>::operator()(size_t size, void **pointer) {
	return Sysdeps<VmMap>::operator()(nullptr, size, PROT_READ | PROT_WRITE,
		MAP_PRIVATE | MAP_ANONYMOUS, -1, 0, pointer);
}

int Sysdeps<AnonFree>::operator()(void *pointer, size_t size) {
	return Sysdeps<VmUnmap>::operator()(pointer, size);
}

} // namespace mlibc
