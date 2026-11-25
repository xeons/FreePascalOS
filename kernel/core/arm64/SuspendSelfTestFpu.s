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
// For the suspend to RAM self test (Kernel.Arch.SuspendSelfTest): a
// thread holds distinctive values in every floating point and SIMD
// register, and in FPCR and FPSR, while its processor is frozen, turned
// off and started again, then checks they are all still there. The
// kernel saves these registers only at a thread switch, so a frozen
// processor must keep them in its suspend context.
//
// The Makefile's check that kernel code uses no SIMD registers skips
// this routine by name (KERNEL_FPU_ROUTINES).

    .text
    .balign 4

// Fills V<n> with (Seed + n, not (Seed + n)). X9 = Seed.
.macro FILL_REGISTER n
    add     x10, x9, #\n
    mvn     x11, x10
    fmov    d\n, x10
    mov     v\n\().d[1], x11
.endm

// Adds 1 to X0 for each half of V<n> that changed.
.macro CHECK_REGISTER n
    add     x10, x9, #\n
    mvn     x11, x10
    fmov    x12, d\n
    cmp     x12, x10
    cinc    x0, x0, ne
    mov     x12, v\n\().d[1]
    cmp     x12, x11
    cinc    x0, x0, ne
.endm

// FPCR: round toward zero (RMode 11), flush to zero, default NaN.
    .set TEST_FPCR, (3 << 22) | (1 << 24) | (1 << 25)
// FPSR: the invalid operation and saturation flags.
    .set TEST_FPSR, (1 << 0) | (1 << 27)

// QWord ArchSuspendTestHoldFpuValues(Flags, Seed): fills the registers,
// sets Flags[1] (a QWord: "holding"), waits until Flags[0] ("let go")
// is set, and returns how many registers (halves of a V register, FPCR,
// FPSR) changed meanwhile. Leaves FPCR and FPSR zero again.
    .global ArchSuspendTestHoldFpuValues
    .type ArchSuspendTestHoldFpuValues, %function
ArchSuspendTestHoldFpuValues:
    mov     x9, x1
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    FILL_REGISTER \n
    .endr
    ldr     x10, =TEST_FPCR
    msr     fpcr, x10
    ldr     x10, =TEST_FPSR
    msr     fpsr, x10
    mov     x10, #1
    add     x13, x0, #8
    stlr    x10, [x13]
1:  yield
    ldar    x10, [x0]
    cbz     x10, 1b
    mov     x0, xzr
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    CHECK_REGISTER \n
    .endr
    mrs     x12, fpcr
    ldr     x10, =TEST_FPCR
    cmp     x12, x10
    cinc    x0, x0, ne
    mrs     x12, fpsr
    ldr     x10, =TEST_FPSR
    cmp     x12, x10
    cinc    x0, x0, ne
    msr     fpcr, xzr
    msr     fpsr, xzr
    ret
    .ltorg
