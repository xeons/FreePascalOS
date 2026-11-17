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

//
// The EL1 exception vector table, the trap frame save and restore, and
// the way into user mode.
//
// Every exception the kernel takes - from the kernel itself (EL1 with
// SP_EL1) or from a program (EL0) - builds a TTrapFrame
// (Kernel.Arch.TrapFrame) on SP_EL1 and calls
// ArchHandleException(Frame, Kind) (Kernel.Arch.Exceptions), then
// restores the frame (which the handler may have changed) and returns
// with ERET. A thread switch inside the handler simply leaves the frame
// on that thread's stack until it runs again.
//
// Kinds: 0 synchronous, 1 IRQ, 2 FIQ, 3 SError, 4 an exception the
// kernel never expects (taken with SP_EL0 at EL1, or from AArch32).

    .set FRAME_SIZE, 304
    .set FRAME_SP, 248
    .set FRAME_ELR, 256
    .set FRAME_SPSR, 264
    .set FRAME_ESR, 272
    .set FRAME_FAR, 280
    .set FRAME_VECTOR, 288

    .set KIND_SYNCHRONOUS, 0
    .set KIND_IRQ, 1
    .set KIND_FIQ, 2
    .set KIND_SERROR, 3
    .set KIND_UNEXPECTED, 4

.macro VECTOR kind, from_user
    .balign 0x80
    sub     sp, sp, #FRAME_SIZE
    stp     x0, x1, [sp, #0]
    mov     x1, #\kind
    .if \from_user
    b       ArchSaveFrameFromUser
    .else
    b       ArchSaveFrameFromKernel
    .endif
.endm

    .text
    .balign 0x800
    .global ArchExceptionVectors
ArchExceptionVectors:
    // Current EL with SP_EL0: never used by the kernel.
    VECTOR KIND_UNEXPECTED, 0
    VECTOR KIND_UNEXPECTED, 0
    VECTOR KIND_UNEXPECTED, 0
    VECTOR KIND_UNEXPECTED, 0
    // Current EL with SP_EL1: the kernel.
    VECTOR KIND_SYNCHRONOUS, 0
    VECTOR KIND_IRQ, 0
    VECTOR KIND_FIQ, 0
    VECTOR KIND_SERROR, 0
    // Lower EL in AArch64: programs.
    VECTOR KIND_SYNCHRONOUS, 1
    VECTOR KIND_IRQ, 1
    VECTOR KIND_FIQ, 1
    VECTOR KIND_SERROR, 1
    // Lower EL in AArch32: not supported.
    VECTOR KIND_UNEXPECTED, 1
    VECTOR KIND_UNEXPECTED, 1
    VECTOR KIND_UNEXPECTED, 1
    VECTOR KIND_UNEXPECTED, 1

// x0 and x1 are saved, x1 holds the kind.
.macro SAVE_REMAINING_REGISTERS
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30, [sp, #240]
.endm

.macro SAVE_SYSTEM_REGISTERS
    mrs     x10, elr_el1
    mrs     x11, spsr_el1
    stp     x9, x10, [sp, #FRAME_SP]
    mrs     x12, esr_el1
    stp     x11, x12, [sp, #FRAME_SPSR]
    mrs     x13, far_el1
    stp     x13, xzr, [sp, #FRAME_FAR]
    str     xzr, [sp, #FRAME_VECTOR + 8]
.endm

    .balign 4
ArchSaveFrameFromKernel:
    SAVE_REMAINING_REGISTERS
    add     x9, sp, #FRAME_SIZE
    SAVE_SYSTEM_REGISTERS
    b       ArchCallHandler

ArchSaveFrameFromUser:
    SAVE_REMAINING_REGISTERS
    mrs     x9, sp_el0
    SAVE_SYSTEM_REGISTERS

ArchCallHandler:
    // A frame record pointing at the interrupted code, for stack traces.
    add     x29, sp, #232
    mov     x0, sp
    bl      ArchHandleException
    // Fall through: return from the exception with the (changed) frame.

    .global ArchExceptionReturn
ArchExceptionReturn:
    msr     daifset, #2
    ldp     x9, x10, [sp, #FRAME_SP]
    ldr     x11, [sp, #FRAME_SPSR]
    msr     elr_el1, x10
    msr     spsr_el1, x11
    tst     x11, #0xF                     // M[3:0] = 0: back to EL0
    b.ne    1f
    msr     sp_el0, x9
1:  ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldp     x8, x9, [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30, [sp, #240]
    add     sp, sp, #FRAME_SIZE
    eret

// void ArchEnterUserModeAt(QWord EntryPoint, QWord UserStack,
//                          QWord Argument, QWord KernelStackTop)
// Starts user code at EntryPoint (EL0, interrupts enabled) with X0 =
// Argument and every other register zero. The kernel stack starts over
// at KernelStackTop: the next exception from user mode builds its frame
// there.
    .global ArchEnterUserModeAt
ArchEnterUserModeAt:
    msr     daifset, #2
    mov     sp, x3
    msr     sp_el0, x1
    msr     elr_el1, x0
    msr     spsr_el1, xzr                 // EL0t, nothing masked
    mov     x0, x2
    mov     x1, xzr
    mov     x2, xzr
    mov     x3, xzr
    mov     x4, xzr
    mov     x5, xzr
    mov     x6, xzr
    mov     x7, xzr
    mov     x8, xzr
    mov     x9, xzr
    mov     x10, xzr
    mov     x11, xzr
    mov     x12, xzr
    mov     x13, xzr
    mov     x14, xzr
    mov     x15, xzr
    mov     x16, xzr
    mov     x17, xzr
    mov     x18, xzr
    mov     x19, xzr
    mov     x20, xzr
    mov     x21, xzr
    mov     x22, xzr
    mov     x23, xzr
    mov     x24, xzr
    mov     x25, xzr
    mov     x26, xzr
    mov     x27, xzr
    mov     x28, xzr
    mov     x29, xzr
    mov     x30, xzr
    eret
