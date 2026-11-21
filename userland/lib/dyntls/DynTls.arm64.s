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

// libdyntls.so for AArch64: a library dynlibtest loads with LoadLibrary
// after it started threads, for dynamic thread-local storage (the x86-64
// one is DynTls.s):
//
//   * a PT_TLS segment with an initialized variable (.tdata, 1234) and a
//     zeroed one (.tbss),
//   * TLS descriptors (R_AARCH64_TLSDESC), which the kernel points at
//     libsystem's dynamic resolver for a library loaded late,
//   * the traditional general dynamic model (__tls_get_addr, relocations
//     R_AARCH64_TLS_DTPMOD64 and R_AARCH64_TLS_DTPREL64),
//   * an initializer (.init_array) and a finalizer (.fini_array).

        .text
        .balign 4

// int64_t *dyntls_counter_address(void): the calling thread's counter,
// through its TLS descriptor. The resolver must keep every register but
// x0: x9 and d16 carry a value across it, checked afterwards (0 if one
// was lost).
        .globl  dyntls_counter_address
        .type   dyntls_counter_address, %function
dyntls_counter_address:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     x9, #0x5A5A
        fmov    d16, x9
        adrp    x0, :tlsdesc:dyntls_counter
        ldr     x1, [x0, #:tlsdesc_lo12:dyntls_counter]
        add     x0, x0, #:tlsdesc_lo12:dyntls_counter
        .tlsdesccall dyntls_counter
        blr     x1
        mrs     x1, tpidr_el0
        add     x0, x0, x1
        mov     x10, #0x5A5A
        cmp     x9, x10
        b.ne    1f
        fmov    x11, d16
        cmp     x11, x10
        b.ne    1f
        ldp     x29, x30, [sp], #16
        ret
1:      mov     x0, #0
        ldp     x29, x30, [sp], #16
        ret
        .size   dyntls_counter_address, . - dyntls_counter_address

// int64_t *dyntls_counter_address_slow(void): the same counter, found
// through __tls_get_addr.
        .globl  dyntls_counter_address_slow
        .type   dyntls_counter_address_slow, %function
dyntls_counter_address_slow:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        adrp    x0, :tlsgd:dyntls_counter
        add     x0, x0, #:tlsgd_lo12:dyntls_counter
        bl      __tls_get_addr
        nop
        ldp     x29, x30, [sp], #16
        ret
        .size   dyntls_counter_address_slow, . - dyntls_counter_address_slow

// int64_t *dyntls_initial_address(void): the calling thread's copy of a
// variable that starts out as 1234, through its TLS descriptor.
        .globl  dyntls_initial_address
        .type   dyntls_initial_address, %function
dyntls_initial_address:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        adrp    x0, :tlsdesc:dyntls_initial
        ldr     x1, [x0, #:tlsdesc_lo12:dyntls_initial]
        add     x0, x0, #:tlsdesc_lo12:dyntls_initial
        .tlsdesccall dyntls_initial
        blr     x1
        mrs     x1, tpidr_el0
        add     x0, x0, x1
        ldp     x29, x30, [sp], #16
        ret
        .size   dyntls_initial_address, . - dyntls_initial_address

        .type   dyntls_initialize, %function
dyntls_initialize:
        adrp    x1, .Linit_calls
        add     x1, x1, :lo12:.Linit_calls
        ldr     w2, [x1]
        add     w2, w2, #1
        str     w2, [x1]
        ret
        .size   dyntls_initialize, . - dyntls_initialize

        .type   dyntls_finalize, %function
dyntls_finalize:
        mov     x8, #1                  // CallWrite
        mov     x0, #1                  // StandardOutputHandle
        adrp    x1, .Lfinal_message
        add     x1, x1, :lo12:.Lfinal_message
        mov     x2, #(.Lfinal_message_end - .Lfinal_message)
        svc     #0
        ret
        .size   dyntls_finalize, . - dyntls_finalize

        .section .rodata
.Lfinal_message:
        .ascii  "dyntls: library finalizer ran\n"
.Lfinal_message_end:

        .section .init_array, "aw"
        .balign 8
        .quad   dyntls_initialize

        .section .fini_array, "aw"
        .balign 8
        .quad   dyntls_finalize

        .data
        .balign 4
        .globl  dyntls_init_calls
        .type   dyntls_init_calls, %object
        .size   dyntls_init_calls, 4
dyntls_init_calls:
.Linit_calls:
        .long   0

        .section .tdata, "awT", %progbits
        .balign 8
        .globl  dyntls_initial
        .type   dyntls_initial, %object
        .size   dyntls_initial, 8
dyntls_initial:
        .quad   1234

        .section .tbss, "awT", %nobits
        .balign 16
        .globl  dyntls_counter
        .type   dyntls_counter, %object
        .size   dyntls_counter, 8
dyntls_counter:
        .zero   8

        .section .note.GNU-stack, "", %progbits
