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
 * The start of the .init and .fini functions (crtn.S ends them).
 */
.section .init
.global _init
.type _init, %function
_init:
	stp x29, x30, [sp, -16]!
	mov x29, sp

.section .fini
.global _fini
.type _fini, %function
_fini:
	stp x29, x30, [sp, -16]!
	mov x29, sp
.section .note.GNU-stack,"",%progbits
