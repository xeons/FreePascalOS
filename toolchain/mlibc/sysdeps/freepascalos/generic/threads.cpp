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

// Threads: mlibc's pthreads over kernel threads. mlibc makes the TCB and
// the TLS blocks; PrepareStack maps the stack (with a guard page below
// it) and puts the start routine, the TCB and the argument on it, and
// Clone starts a kernel thread on that stack (FPOS_CALL_CREATE_THREAD_ON_STACK),
// which loads its own thread pointer (TcbSet) and runs the routine.

#include "kernel.hpp"

#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <mlibc/all-sysdeps.hpp>
#include <mlibc/tcb.hpp>
#include <mlibc/thread.hpp>
#include <mlibc/threads.hpp>

extern "C" void __mlibc_thread_entry();

extern "C" void __mlibc_thread_trampoline(void *(*function)(void *), Tcb *tcb, void *argument) {
	if (mlibc::sysdep<TcbSet>(tcb))
		__ensure(!"FreePascalOS: could not set a new thread's TCB");

	while (__atomic_load_n(&tcb->tid, __ATOMIC_RELAXED) == 0)
		mlibc::sysdep<FutexWait>(&tcb->tid, 0, nullptr);

	__atomic_fetch_or(&tcb->cancelBits, tcbCancelEnableBit, __ATOMIC_RELAXED);
	tcb->invokeThreadFunc(reinterpret_cast<void *>(function), argument);
	mlibc::thread_exit(tcb->returnValue);
}

namespace {

constexpr size_t default_stack_size = 2 * 1024 * 1024;
constexpr size_t page_size = 4096;

size_t round_to_pages(size_t size) {
	return (size + page_size - 1) & ~(page_size - 1);
}

} // namespace

namespace mlibc {

int Sysdeps<PrepareStack>::operator()(void **stack, void *entry, void *user_arg, void *tcb,
		size_t *stack_size, size_t *guard_size, void **stack_base) {
	if (!*stack_size)
		*stack_size = default_stack_size;
	if (!*stack) {
		*stack_size = round_to_pages(*stack_size);
		*guard_size = round_to_pages(*guard_size ? *guard_size : page_size);
		void *mapping;
		if (int e = sysdep<VmMap>(nullptr, *stack_size + *guard_size, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0, &mapping))
			return e;
		sysdep<VmProtect>(mapping, *guard_size, PROT_NONE);
		*stack_base = static_cast<char *>(mapping) + *guard_size;
	} else {
		*stack_base = *stack;
		*guard_size = 0;
	}

	uintptr_t top = (reinterpret_cast<uintptr_t>(*stack_base) + *stack_size) & ~uintptr_t(15);
	auto slots = reinterpret_cast<void **>(top);
	*--slots = nullptr;
	*--slots = user_arg;
	*--slots = tcb;
	*--slots = entry;
	*stack = slots;
	return 0;
}

int Sysdeps<Clone>::operator()(void *tcb, pid_t *pid_out, void *stack) {
	(void)tcb;
	long handle = fpos::call(FPOS_CALL_CREATE_THREAD_ON_STACK,
		reinterpret_cast<void *>(&__mlibc_thread_entry), 0, stack);
	if (int e = fpos::error_of(handle))
		return e;
	long thread_id = fpos::call(FPOS_CALL_GET_THREAD_ID, handle);
	fpos::call(FPOS_CALL_CLOSE, handle);
	if (int e = fpos::error_of(thread_id))
		return e;
	*pid_out = static_cast<pid_t>(thread_id);
	return 0;
}

void Sysdeps<ThreadExit>::operator()() {
	fpos::call(FPOS_CALL_EXIT_THREAD, 0);
	__builtin_unreachable();
}

pid_t Sysdeps<GetTid>::operator()() {
	return static_cast<pid_t>(fpos::call(FPOS_CALL_GET_THREAD_ID, FPOS_CURRENT_THREAD_HANDLE));
}

void Sysdeps<Yield>::operator()() {
	fpos::call(FPOS_CALL_SLEEP, 0);
}

int Sysdeps<Sleep>::operator()(time_t *secs, long *nanos) {
	long milliseconds = *secs * 1000 + (*nanos + 999999) / 1000000;
	int e = fpos::call_checked(FPOS_CALL_SLEEP, milliseconds);
	*secs = 0;
	*nanos = 0;
	return e;
}

int Sysdeps<ThreadSetname>::operator()(void *tcb, const char *name) {
	if (strlen(name) > 15)
		return ERANGE;
	auto thread = static_cast<Tcb *>(tcb);
	return fpos::call_checked(FPOS_CALL_SET_THREAD_NAME, thread->tid, name);
}

int Sysdeps<GetCurrentStackInfo>::operator()(void **stack_base, size_t *stack_size) {
	Tcb *tcb = mlibc::get_current_tcb();
	if (!tcb->stackAddr)
		return ENOSYS;
	*stack_base = tcb->stackAddr;
	*stack_size = tcb->stackSize;
	return 0;
}

} // namespace mlibc
