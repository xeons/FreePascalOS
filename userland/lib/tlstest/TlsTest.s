# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# libtlstest.so: a library for the thread tests (userland/bin/threadtest).
#
# Free Pascal 3.2.2 never emits ELF thread-local storage or initializer
# arrays, so this library is written in assembly to exercise what C
# compiled code would use:
#
#   * a PT_TLS segment with an initialized variable (.tdata) and a zeroed
#     one (.tbss),
#   * the general dynamic access model (__tls_get_addr, relocations
#     R_X86_64_DTPMOD64 and R_X86_64_DTPOFF64),
#   * the initial exec model (relocation R_X86_64_TPOFF64 in the GOT),
#   * an initializer (.init_array) and a finalizer (.fini_array).

        .text

# int64_t *tlstest_counter_address(void): the calling thread's counter,
# found through __tls_get_addr.
        .globl  tlstest_counter_address
        .type   tlstest_counter_address, @function
tlstest_counter_address:
        subq    $8, %rsp
        .byte   0x66
        leaq    tlstest_counter@tlsgd(%rip), %rdi
        .value  0x6666
        rex64
        call    __tls_get_addr@PLT
        addq    $8, %rsp
        ret
        .size   tlstest_counter_address, . - tlstest_counter_address

# int64_t *tlstest_initial_address(void): the calling thread's copy of a
# variable that starts out as 42, found through the thread pointer.
        .globl  tlstest_initial_address
        .type   tlstest_initial_address, @function
tlstest_initial_address:
        movq    tlstest_initial@gottpoff(%rip), %rax
        addq    %fs:0, %rax
        ret
        .size   tlstest_initial_address, . - tlstest_initial_address

# Runs from the user runtime before the program's units are initialized.
        .type   tlstest_initialize, @function
tlstest_initialize:
        incl    .Linit_calls(%rip)
        ret
        .size   tlstest_initialize, . - tlstest_initialize

# Runs when the program exits, after its output has been flushed.
        .type   tlstest_finalize, @function
tlstest_finalize:
        movl    $1, %eax                # CallWrite
        movl    $1, %edi                # StandardOutputHandle
        leaq    .Lfinal_message(%rip), %rsi
        movl    $.Lfinal_message_end - .Lfinal_message, %edx
        syscall
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
        .type   tlstest_init_calls, @object
        .size   tlstest_init_calls, 4
tlstest_init_calls:
.Linit_calls:
        .long   0

        .section .tdata, "awT", @progbits
        .balign 8
        .globl  tlstest_initial
        .type   tlstest_initial, @object
        .size   tlstest_initial, 8
tlstest_initial:
        .quad   42

        .section .tbss, "awT", @nobits
        .balign 16
        .globl  tlstest_counter
        .type   tlstest_counter, @object
        .size   tlstest_counter, 8
tlstest_counter:
        .zero   8

        .section .note.GNU-stack, "", @progbits
