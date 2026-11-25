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

// libstatictls.so: a library latelibtest loads with LoadLibrary after it
// started threads, whose thread-local storage is reached with the
// initial exec model: an R_AARCH64_TLS_TPREL64 relocation in the GOT
// holds the variable's offset from the thread pointer (TPIDR_EL0), so
// its block must be at a fixed distance from every thread's thread
// pointer - in the static TLS surplus the kernel keeps for such
// libraries (the linker marks it DF_STATIC_TLS).
//
//   * an initialized variable (.tdata, 4321) and a zeroed one (.tbss),
//     both 64-byte aligned.
//
// The AArch64 source; StaticTls.s is the x86-64 one.

        .text
        .balign 4

// int64_t *statictls_initial_address(void)
        .globl  statictls_initial_address
        .type   statictls_initial_address, %function
statictls_initial_address:
        adrp    x0, :gottprel:statictls_initial
        ldr     x0, [x0, #:gottprel_lo12:statictls_initial]
        mrs     x1, tpidr_el0
        add     x0, x0, x1
        ret
        .size   statictls_initial_address, . - statictls_initial_address

// int64_t *statictls_counter_address(void)
        .globl  statictls_counter_address
        .type   statictls_counter_address, %function
statictls_counter_address:
        adrp    x0, :gottprel:statictls_counter
        ldr     x0, [x0, #:gottprel_lo12:statictls_counter]
        mrs     x1, tpidr_el0
        add     x0, x0, x1
        ret
        .size   statictls_counter_address, . - statictls_counter_address

        .section .tdata, "awT", %progbits
        .balign 64
        .globl  statictls_initial
        .type   statictls_initial, %object
        .size   statictls_initial, 8
statictls_initial:
        .quad   4321

        .section .tbss, "awT", %nobits
        .balign 64
        .globl  statictls_counter
        .type   statictls_counter, %object
        .size   statictls_counter, 8
statictls_counter:
        .zero   8

        .section .note.GNU-stack, "", %progbits
