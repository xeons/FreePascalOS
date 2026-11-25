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
# Copying from and to user memory (Kernel.Arch.UserCopy). The routines
# push nothing, so a fault inside one is recovered by continuing at
# ArchUserCopyFault with the stack pointer still at the return address:
# it returns UserCopyFaulted (-1) to their caller. Only a fault whose
# instruction pointer lies between a routine's start and end label is
# recovered (RecoverFromUserCopyFault), so a fault anywhere else - an
# interrupt handler running in the middle of a copy, say - is not taken
# for one.
#
# With SMAP (supervisor mode access prevention) on, the processor refuses
# every kernel access to user pages; the routines allow it for their own
# duration (STAC / CLAC), when ArchSmapEnabled says SMAP is on (STAC and
# CLAC do not exist without it). The interrupt entry closes the window
# again (CLAC) for the handler; the interrupted copy gets it back with
# its flags at IRETQ.

    .text

# Int64 ArchUserCopyBytes(Destination = RDI, Source = RSI, Length = RDX): 0
    .global ArchUserCopyBytes
    .global ArchUserCopyBytesEnd
    .type ArchUserCopyBytes, @function
ArchUserCopyBytes:
    cmpb    $0, ArchSmapEnabled(%rip)
    je      1f
    stac
1:  movq    %rdx, %rcx
    rep movsb
    cmpb    $0, ArchSmapEnabled(%rip)
    je      2f
    clac
2:  xorl    %eax, %eax
    ret
ArchUserCopyBytesEnd:

# Int64 ArchUserCopyString(Destination = RDI, Source = RSI, Capacity =
# RDX): the length, or -2 (UserCopyTooLong) when Capacity bytes held no
# terminator.
    .global ArchUserCopyString
    .global ArchUserCopyStringEnd
    .type ArchUserCopyString, @function
ArchUserCopyString:
    cmpb    $0, ArchSmapEnabled(%rip)
    je      1f
    stac
1:  xorl    %ecx, %ecx
2:  cmpq    %rdx, %rcx
    je      3f
    movb    (%rsi,%rcx), %al
    movb    %al, (%rdi,%rcx)
    testb   %al, %al
    jz      4f
    incq    %rcx
    jmp     2b
3:  movq    $-2, %rcx
4:  cmpb    $0, ArchSmapEnabled(%rip)
    je      5f
    clac
5:  movq    %rcx, %rax
    ret
ArchUserCopyStringEnd:

# A fault inside a copy continues here (RecoverFromUserCopyFault cleared
# RFLAGS.AC in the saved state, so user accesses are forbidden again).
    .global ArchUserCopyFault
    .type ArchUserCopyFault, @function
ArchUserCopyFault:
    movq    $-1, %rax
    ret

    .data
    .global ArchSmapEnabled
ArchSmapEnabled:
    .byte   0
