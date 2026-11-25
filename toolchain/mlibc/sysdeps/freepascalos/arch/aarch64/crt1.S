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
 * The program's entry point: the kernel (or the dynamic linker) starts
 * here with the stack pointer at the argument count.
 */
.section .text
.global _start
.type _start, %function
_start:
	mov x29, #0
	mov x30, #0
	adrp x0, main
	add x0, x0, :lo12:main
	mov x1, sp
	bl __mlibc_entry
	brk #0
.size _start, . - _start
.section .note.GNU-stack,"",%progbits
