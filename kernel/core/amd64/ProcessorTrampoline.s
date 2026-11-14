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

#
# Start-up code for the secondary processors of an x86-64 PC.
#
# A processor woken with INIT and STARTUP inter-processor interrupts
# starts in 16-bit real mode at the page named by the STARTUP vector. The
# kernel copies this block to such a page below 1 MiB (see
# Kernel.Arch.ProcessorStartup), fills in the data area and adds the
# page's address to the three addresses marked "base +" below.
#
# The code switches to 32-bit protected mode, loads the control registers
# the boot processor uses (CR4, then CR3, EFER, CR0, which turns paging
# on), enters 64-bit mode and jumps to the kernel's entry point with the
# processor's block in RDI and the stack of its idle thread in RSP. CR3
# here is a small table that maps this page at its own address (needed
# while paging is switched on) next to the kernel half; the kernel loads
# its real one right away.
#
# Layout (offsets from the start of the page):
#     0  jump to the real mode code
#     8  GDT: null, 32-bit code (0x08), data (0x10), 64-bit code (0x18)
#    40  GDT pointer for LGDT          (limit, base + offset)
#    48  far pointer to protected mode (base + offset, selector 0x08)
#    56  far pointer to long mode      (base + offset, selector 0x18)
#    64  CR0, CR3, CR4, EFER           (8 bytes each)
#    96  stack top, processor block, kernel entry point
#   120  set to 1 by the processor once it runs 64-bit code
#   128  real mode code
#
    .section .rodata.processortrampoline, "a"
    .globl ProcessorTrampolineStart
    .globl ProcessorTrampolineEnd

    .code16
ProcessorTrampolineStart:
    jmp RealModeEntry

    .org 8
TrampolineGdt:
    .quad 0
    .quad 0x00CF9A000000FFFF
    .quad 0x00CF92000000FFFF
    .quad 0x00AF9A000000FFFF

    .org 40
    .word 31
    .long TrampolineGdt - ProcessorTrampolineStart

    .org 48
    .long ProtectedModeEntry - ProcessorTrampolineStart
    .word 0x08

    .org 56
    .long LongModeEntry - ProcessorTrampolineStart
    .word 0x18

    .org 64
    .quad 0, 0, 0, 0        # CR0, CR3, CR4, EFER
    .quad 0, 0, 0           # stack top, processor block, entry point
    .quad 0                 # started

    .org 128
RealModeEntry:
    cli
    cld
    movw %cs, %ax
    movw %ax, %ds
    # EBX keeps the page's linear address through the mode switches.
    xorl %ebx, %ebx
    movw %ax, %bx
    shll $4, %ebx
    lgdtl 40
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    ljmpl *48

    .code32
ProtectedModeEntry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl 80(%ebx), %eax
    movl %eax, %cr4
    movl 72(%ebx), %eax
    movl %eax, %cr3
    movl $0xC0000080, %ecx
    movl 88(%ebx), %eax
    movl 92(%ebx), %edx
    wrmsr
    movl 64(%ebx), %eax
    movl %eax, %cr0
    ljmpl *56(%ebx)

    .code64
LongModeEntry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    # The upper half of RBX is undefined after the switch.
    movl %ebx, %ebx
    movq $1, 120(%rbx)
    movq 96(%rbx), %rsp
    movq 104(%rbx), %rdi
    movq 112(%rbx), %rax
    jmpq *%rax
ProcessorTrampolineEnd:
