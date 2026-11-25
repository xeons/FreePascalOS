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
 * Where a new thread starts (FPOS_CALL_CREATE_THREAD_ON_STACK), on the
 * stack PrepareStack made: the thread function, the TCB and the
 * argument lie at the stack pointer.
 */
.section .text
.global __mlibc_thread_entry
.type __mlibc_thread_entry, @function
__mlibc_thread_entry:
	xor %ebp, %ebp
	pop %rdi
	pop %rsi
	pop %rdx
	/* Called with the stack 16-byte aligned, as the ABI wants. */
	and $-16, %rsp
	call __mlibc_thread_trampoline
	ud2
.size __mlibc_thread_entry, . - __mlibc_thread_entry
.section .note.GNU-stack,"",%progbits
