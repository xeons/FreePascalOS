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

// libtlstest.so for AArch64: a library for the thread tests
// (userland/bin/threadtest); the x86-64 one is TlsTest.s.
//
// Free Pascal 3.2.2 never emits ELF thread-local storage or initializer
// arrays, so this library is written in assembly to exercise what C
// compiled code would use:
//
//   * a PT_TLS segment with an initialized variable (.tdata) and a zeroed
//     one (.tbss),
//   * the general dynamic access model with TLS descriptors, what C
//     compilers use on AArch64 (relocation R_AARCH64_TLSDESC; the
//     kernel points the descriptor at libsystem's static resolver),
//   * the traditional general dynamic model (__tls_get_addr, relocations
//     R_AARCH64_TLS_DTPMOD64 and R_AARCH64_TLS_DTPREL64),
//   * the initial exec model (relocation R_AARCH64_TLS_TPREL64 in the
//     GOT),
//   * an initializer (.init_array) and a finalizer (.fini_array).

        .text
        .balign 4

// int64_t *tlstest_counter_address(void): the calling thread's counter,
// found through its TLS descriptor.
        .globl  tlstest_counter_address
        .type   tlstest_counter_address, %function
tlstest_counter_address:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        adrp    x0, :tlsdesc:tlstest_counter
        ldr     x1, [x0, #:tlsdesc_lo12:tlstest_counter]
        add     x0, x0, #:tlsdesc_lo12:tlstest_counter
        .tlsdesccall tlstest_counter
        blr     x1
        mrs     x1, tpidr_el0
        add     x0, x0, x1
        ldp     x29, x30, [sp], #16
        ret
        .size   tlstest_counter_address, . - tlstest_counter_address

// int64_t *tlstest_counter_address_slow(void): the same counter, found
// through __tls_get_addr.
        .globl  tlstest_counter_address_slow
        .type   tlstest_counter_address_slow, %function
tlstest_counter_address_slow:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        adrp    x0, :tlsgd:tlstest_counter
        add     x0, x0, #:tlsgd_lo12:tlstest_counter
        bl      __tls_get_addr
        nop
        ldp     x29, x30, [sp], #16
        ret
        .size   tlstest_counter_address_slow, . - tlstest_counter_address_slow

// int64_t *tlstest_initial_address(void): the calling thread's copy of a
// variable that starts out as 42, found through the thread pointer.
        .globl  tlstest_initial_address
        .type   tlstest_initial_address, %function
tlstest_initial_address:
        adrp    x0, :gottprel:tlstest_initial
        ldr     x0, [x0, #:gottprel_lo12:tlstest_initial]
        mrs     x1, tpidr_el0
        add     x0, x0, x1
        ret
        .size   tlstest_initial_address, . - tlstest_initial_address

// Runs from the user runtime before the program's units are initialized.
        .type   tlstest_initialize, %function
tlstest_initialize:
        adrp    x1, .Linit_calls
        add     x1, x1, :lo12:.Linit_calls
        ldr     w2, [x1]
        add     w2, w2, #1
        str     w2, [x1]
        ret
        .size   tlstest_initialize, . - tlstest_initialize

// Runs when the program exits, after its output has been flushed.
        .type   tlstest_finalize, %function
tlstest_finalize:
        mov     x8, #1                  // CallWrite
        mov     x0, #1                  // StandardOutputHandle
        adrp    x1, .Lfinal_message
        add     x1, x1, :lo12:.Lfinal_message
        mov     x2, #(.Lfinal_message_end - .Lfinal_message)
        svc     #0
        ret
        .size   tlstest_finalize, . - tlstest_finalize

        .section .rodata
.Lfinal_message:
        .ascii  "tlstest: library finalizer ran\n"
.Lfinal_message_end:

        .section .init_array, "aw"
        .balign 8
        .quad   tlstest_initialize

        .section .fini_array, "aw"
        .balign 8
        .quad   tlstest_finalize

        .data
        .balign 4
        .globl  tlstest_init_calls
        .type   tlstest_init_calls, %object
        .size   tlstest_init_calls, 4
tlstest_init_calls:
.Linit_calls:
        .long   0

        .section .tdata, "awT", %progbits
        .balign 8
        .globl  tlstest_initial
        .type   tlstest_initial, %object
        .size   tlstest_initial, 8
tlstest_initial:
        .quad   42

        .section .tbss, "awT", %nobits
        .balign 16
        .globl  tlstest_counter
        .type   tlstest_counter, %object
        .size   tlstest_counter, 8
tlstest_counter:
        .zero   8

        .section .note.GNU-stack, "", %progbits
