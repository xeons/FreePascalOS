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

# libdyntls.so: a library dynlibtest loads with LoadLibrary after it
# started threads, for dynamic thread-local storage: the library's TLS
# blocks cannot be part of the static layout made when the program
# started, so the runtime makes one per thread when the thread first
# touches it. Written in assembly, as Free Pascal emits no ELF TLS:
#
#   * a PT_TLS segment with an initialized variable (.tdata, 1234) and a
#     zeroed one (.tbss),
#   * the general dynamic access model (__tls_get_addr, relocations
#     R_X86_64_DTPMOD64 and R_X86_64_DTPOFF64 against this library,
#     whose module id is then a dynamic one),
#   * an initializer (.init_array), which the runtime calls before
#     LoadLibrary returns, and a finalizer (.fini_array), called when
#     the program ends.
#
# The x86-64 source; DynTls.arm64.s is the AArch64 one.

        .text

# int64_t *dyntls_counter_address(void): the calling thread's counter.
        .globl  dyntls_counter_address
        .type   dyntls_counter_address, @function
dyntls_counter_address:
        subq    $8, %rsp
        .byte   0x66
        leaq    dyntls_counter@tlsgd(%rip), %rdi
        .value  0x6666
        rex64
        call    __tls_get_addr@PLT
        addq    $8, %rsp
        ret
        .size   dyntls_counter_address, . - dyntls_counter_address

# int64_t *dyntls_initial_address(void): the calling thread's copy of a
# variable that starts out as 1234.
        .globl  dyntls_initial_address
        .type   dyntls_initial_address, @function
dyntls_initial_address:
        subq    $8, %rsp
        .byte   0x66
        leaq    dyntls_initial@tlsgd(%rip), %rdi
        .value  0x6666
        rex64
        call    __tls_get_addr@PLT
        addq    $8, %rsp
        ret
        .size   dyntls_initial_address, . - dyntls_initial_address

# int64_t *dyntls_counter_address_slow(void): the same counter (a second
# access path on AArch64; the same one here).
        .globl  dyntls_counter_address_slow
        .type   dyntls_counter_address_slow, @function
dyntls_counter_address_slow:
        jmp     dyntls_counter_address
        .size   dyntls_counter_address_slow, . - dyntls_counter_address_slow

        .type   dyntls_initialize, @function
dyntls_initialize:
        incl    .Linit_calls(%rip)
        ret
        .size   dyntls_initialize, . - dyntls_initialize

        .type   dyntls_finalize, @function
dyntls_finalize:
        movl    $1, %eax                # CallWrite
        movl    $1, %edi                # StandardOutputHandle
        leaq    .Lfinal_message(%rip), %rsi
        movl    $.Lfinal_message_end - .Lfinal_message, %edx
        syscall
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
        .type   dyntls_init_calls, @object
        .size   dyntls_init_calls, 4
dyntls_init_calls:
.Linit_calls:
        .long   0

        .section .tdata, "awT", @progbits
        .balign 8
        .globl  dyntls_initial
        .type   dyntls_initial, @object
        .size   dyntls_initial, 8
dyntls_initial:
        .quad   1234

        .section .tbss, "awT", @nobits
        .balign 16
        .globl  dyntls_counter
        .type   dyntls_counter, @object
        .size   dyntls_counter, 8
dyntls_counter:
        .zero   8

        .section .note.GNU-stack, "", @progbits
