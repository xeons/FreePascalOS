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

// POSIX signals. The kernel keeps, per process, what to do with each
// signal (the default, ignore, or hand it to the program) and, per
// thread, the mask and what waits; at the next safe point of a thread
// that does not block it, it writes a fpos_signal_record on the
// thread's stack and continues the thread in signal_dispatcher, which
// calls the handler sigaction installed and goes back with
// FPOS_CALL_RETURN_FROM_SIGNAL. Processor exceptions (an access
// violation, a division by zero, ...) come as exception records
// (CallSetExceptionDispatcher) and become SIGSEGV, SIGFPE, SIGILL,
// SIGBUS or SIGTRAP here.

#include "kernel.hpp"

#include <errno.h>
#include <signal.h>
#include <string.h>
#include <ucontext.h>
#include <mlibc/all-sysdeps.hpp>

namespace fpos {

namespace {

constexpr int highest_signal = 64;

struct sigaction actions[highest_signal + 1];

uint64_t mask_of(const sigset_t *set) {
	return set ? (uint64_t)set->__sig[0] : 0;
}

void set_mask(sigset_t *set, uint64_t mask) {
	memset(set, 0, sizeof(*set));
	set->__sig[0] = mask;
}

uint64_t bit_of(int signal) {
	return uint64_t(1) << (signal - 1);
}

bool is_handler(void (*handler)(int)) {
	return handler != SIG_DFL && handler != SIG_IGN;
}

int tell_kernel(int signal, const struct sigaction &action) {
	long disposition;
	if (action.sa_handler == SIG_DFL)
		disposition = FPOS_SIGNAL_DEFAULT;
	else if (action.sa_handler == SIG_IGN)
		disposition = FPOS_SIGNAL_IGNORE;
	else
		disposition = FPOS_SIGNAL_HANDLE;
	uint64_t handler_mask = mask_of(&action.sa_mask);
	if (!(action.sa_flags & SA_NODEFER))
		handler_mask |= bit_of(signal);
	long flags = (action.sa_flags & SA_RESETHAND) ? 1 : 0;
	return call_checked(FPOS_CALL_SET_SIGNAL_DISPOSITION, signal, disposition, handler_mask, flags);
}

void call_handler(int signal, siginfo_t *info, ucontext_t *context) {
	struct sigaction &action = actions[signal];
	if (!is_handler(action.sa_handler))
		return;
	if (action.sa_flags & SA_SIGINFO) {
		action.sa_sigaction(signal, info, context);
	} else {
		void (*handler)(int) = action.sa_handler;
		if (action.sa_flags & SA_RESETHAND)
			action.sa_handler = SIG_DFL;
		handler(signal);
	}
}

[[noreturn]] void signal_dispatcher(struct fpos_signal_record *record) {
	siginfo_t info;
	memset(&info, 0, sizeof(info));
	info.si_signo = (int)record->signal;
	info.si_code = record->code == FPOS_SIGNAL_FROM_KERNEL ? SI_KERNEL : SI_USER;
	// si_pid and si_addr share their place in siginfo_t.
	if (record->fault_address) {
		info.si_addr = reinterpret_cast<void *>(record->fault_address);
	} else {
		info.si_pid = (pid_t)record->sender_process_id;
		info.si_uid = (uid_t)record->sender_user_id;
	}
	ucontext_t context;
	memset(&context, 0, sizeof(context));
	set_mask(&context.uc_sigmask, record->previous_mask);
	call_handler((int)record->signal, &info, &context);
	call(FPOS_CALL_RETURN_FROM_SIGNAL, record);
	__builtin_trap();
}

int signal_of_exception(uint32_t code) {
	switch (code) {
		case FPOS_EXCEPTION_INTEGER_DIVIDE:
		case FPOS_EXCEPTION_INTEGER_OVERFLOW:
		case FPOS_EXCEPTION_FLOATING_POINT:
		case FPOS_EXCEPTION_SIMD_FLOATING_POINT:
			return SIGFPE;
		case FPOS_EXCEPTION_ILLEGAL_INSTRUCTION:
		case FPOS_EXCEPTION_PRIVILEGED_OPERATION:
			return SIGILL;
		case FPOS_EXCEPTION_BREAKPOINT:
			return SIGTRAP;
		case FPOS_EXCEPTION_ALIGNMENT:
		case FPOS_EXCEPTION_BOUND_RANGE:
			return SIGBUS;
		default:
			return SIGSEGV;
	}
}

// Ends the process as killed by signal (what waitpid sees).
[[noreturn]] void die_of(int signal) {
	call(FPOS_CALL_SET_SIGNAL_DISPOSITION, signal, FPOS_SIGNAL_DEFAULT, 0, 0);
	uint64_t unblock = bit_of(signal);
	call(FPOS_CALL_SET_SIGNAL_MASK, SIG_UNBLOCK, &unblock, nullptr);
	call(FPOS_CALL_SEND_SIGNAL, call(FPOS_CALL_GET_PROCESS_ID, -1), signal);
	call(FPOS_CALL_EXIT, 128 + signal);
	__builtin_unreachable();
}

// Says where a fault that ends the program happened (a C program has no
// other crash report).
void report_fault(int signal, const struct fpos_exception_record *record) {
	char line[160];
	const char *name = signal == SIGSEGV ? "SIGSEGV" : signal == SIGFPE ? "SIGFPE"
		: signal == SIGILL ? "SIGILL" : signal == SIGBUS ? "SIGBUS" : "SIGTRAP";
	static const char digits[] = "0123456789abcdef";
	char instruction[17];
	char address[17];
	for (int i = 0; i < 16; i++) {
		instruction[i] = digits[(record->address >> (60 - 4 * i)) & 15];
		address[i] = digits[(record->fault_address >> (60 - 4 * i)) & 15];
	}
	instruction[16] = '\0';
	address[16] = '\0';
	strcpy(line, "mlibc: ");
	strcat(line, name);
	strcat(line, " at 0x");
	strcat(line, instruction);
	strcat(line, " (address 0x");
	strcat(line, address);
	strcat(line, ")");
	mlibc::sysdep<LibcLog>(line);
}

[[noreturn]] void exception_dispatcher(struct fpos_exception_record *record) {
	call(FPOS_CALL_EXCEPTION_DISPATCHED);
	int signal = signal_of_exception(record->code);
	if (!is_handler(actions[signal].sa_handler)) {
		report_fault(signal, record);
		die_of(signal);
	}
	siginfo_t info;
	memset(&info, 0, sizeof(info));
	info.si_signo = signal;
	info.si_code = SI_KERNEL;
	info.si_addr = reinterpret_cast<void *>(
		signal == SIGSEGV || signal == SIGBUS ? record->fault_address : record->address);
	ucontext_t context;
	memset(&context, 0, sizeof(context));
	call_handler(signal, &info, &context);
	// As on Unix, the faulting instruction runs again.
	call(FPOS_CALL_CONTINUE, &record->context);
	die_of(signal);
}

} // namespace

void initialize_process() {
	call(FPOS_CALL_SET_SIGNAL_DISPATCHER, reinterpret_cast<void *>(&signal_dispatcher));
	call(FPOS_CALL_SET_EXCEPTION_DISPATCHER, reinterpret_cast<void *>(&exception_dispatcher));
}

} // namespace fpos

namespace mlibc {

int Sysdeps<Sigaction>::operator()(int signal, const struct sigaction *__restrict action,
		struct sigaction *__restrict old_action) {
	if (signal < 1 || signal > fpos::highest_signal)
		return EINVAL;
	if (old_action)
		*old_action = fpos::actions[signal];
	if (!action)
		return 0;
	if (signal == SIGKILL || signal == SIGSTOP)
		return EINVAL;
	if (int e = fpos::tell_kernel(signal, *action))
		return e;
	fpos::actions[signal] = *action;
	return 0;
}

int Sysdeps<Sigprocmask>::operator()(int how, const sigset_t *__restrict set, sigset_t *__restrict retrieve) {
	return Sysdeps<ThreadSigmask>::operator()(how, set, retrieve);
}

int Sysdeps<ThreadSigmask>::operator()(int how, const sigset_t *__restrict set, sigset_t *__restrict retrieve) {
	uint64_t mask = fpos::mask_of(set);
	uint64_t previous = 0;
	if (int e = fpos::call_checked(FPOS_CALL_SET_SIGNAL_MASK, how, set ? &mask : nullptr, &previous))
		return e;
	if (retrieve)
		fpos::set_mask(retrieve, previous);
	return 0;
}

int Sysdeps<Sigsuspend>::operator()(const sigset_t *set) {
	uint64_t mask = fpos::mask_of(set);
	return fpos::call_checked(FPOS_CALL_SUSPEND_FOR_SIGNAL, &mask);
}

int Sysdeps<Sigpending>::operator()(sigset_t *set) {
	long pending = fpos::call(FPOS_CALL_PENDING_SIGNALS);
	if (int e = fpos::error_of(pending))
		return e;
	fpos::set_mask(set, (uint64_t)pending);
	return 0;
}

int Sysdeps<Pause>::operator()() {
	sigset_t current;
	if (int e = Sysdeps<ThreadSigmask>::operator()(SIG_BLOCK, nullptr, &current))
		return e;
	return Sysdeps<Sigsuspend>::operator()(&current);
}

int Sysdeps<Kill>::operator()(pid_t pid, int signal) {
	if (signal < 0 || signal > fpos::highest_signal)
		return EINVAL;
	return fpos::call_checked(FPOS_CALL_SEND_SIGNAL, pid, signal);
}

int Sysdeps<Tgkill>::operator()(int tgid, int tid, int signal) {
	(void)tid;
	return Sysdeps<Kill>::operator()(tgid, signal);
}

int Sysdeps<Sigaltstack>::operator()(const stack_t *ss, stack_t *oss) {
	// Handlers run on the thread's own stack.
	(void)ss;
	if (oss) {
		memset(oss, 0, sizeof(*oss));
		oss->ss_flags = SS_DISABLE;
	}
	return 0;
}

} // namespace mlibc
