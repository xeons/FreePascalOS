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
// Thread context switching and floating point state for AArch64
// (Kernel.Arch.ContextSwitch).
//
// A switch preserves what AAPCS64 says a called routine must preserve
// (X19-X28, the frame pointer X29 and the link register X30) and the
// interrupt mask, so it travels with the thread. The saved state sits on
// top of the thread's stack, from the lowest address up:
//
//   X19 X20 X21 X22 X23 X24 X25 X26 X27 X28 X29 X30 DAIF (padding)
//
// 112 bytes, keeping the stack 16-byte aligned.

    .text
    .balign 4

    .set SWITCH_FRAME_SIZE, 112

// void ArchSwitchContext(QWord *SavedStackPointer, QWord NewStackPointer)
    .global ArchSwitchContext
    .type ArchSwitchContext, %function
ArchSwitchContext:
    sub     sp, sp, #SWITCH_FRAME_SIZE
    stp     x19, x20, [sp, #0]
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    stp     x25, x26, [sp, #48]
    stp     x27, x28, [sp, #64]
    stp     x29, x30, [sp, #80]
    mrs     x9, daif
    str     x9, [sp, #96]
    mov     x9, sp
    str     x9, [x0]

    mov     sp, x1
    ldr     x9, [sp, #96]
    ldp     x19, x20, [sp, #0]
    ldp     x21, x22, [sp, #16]
    ldp     x23, x24, [sp, #32]
    ldp     x25, x26, [sp, #48]
    ldp     x27, x28, [sp, #64]
    ldp     x29, x30, [sp, #80]
    msr     daif, x9
    add     sp, sp, #SWITCH_FRAME_SIZE
    ret

// Floating point and SIMD state: V0-V31 (512 bytes), then FPCR and FPSR.
// x0 = the area (16-byte aligned, 528 bytes).
    .global ArchSaveFpuState
    .type ArchSaveFpuState, %function
ArchSaveFpuState:
    stp     q0, q1, [x0, #0]
    stp     q2, q3, [x0, #32]
    stp     q4, q5, [x0, #64]
    stp     q6, q7, [x0, #96]
    stp     q8, q9, [x0, #128]
    stp     q10, q11, [x0, #160]
    stp     q12, q13, [x0, #192]
    stp     q14, q15, [x0, #224]
    stp     q16, q17, [x0, #256]
    stp     q18, q19, [x0, #288]
    stp     q20, q21, [x0, #320]
    stp     q22, q23, [x0, #352]
    stp     q24, q25, [x0, #384]
    stp     q26, q27, [x0, #416]
    stp     q28, q29, [x0, #448]
    stp     q30, q31, [x0, #480]
    mrs     x1, fpcr
    mrs     x2, fpsr
    add     x3, x0, #512
    stp     x1, x2, [x3]
    ret

    .global ArchRestoreFpuState
    .type ArchRestoreFpuState, %function
ArchRestoreFpuState:
    ldp     q0, q1, [x0, #0]
    ldp     q2, q3, [x0, #32]
    ldp     q4, q5, [x0, #64]
    ldp     q6, q7, [x0, #96]
    ldp     q8, q9, [x0, #128]
    ldp     q10, q11, [x0, #160]
    ldp     q12, q13, [x0, #192]
    ldp     q14, q15, [x0, #224]
    ldp     q16, q17, [x0, #256]
    ldp     q18, q19, [x0, #288]
    ldp     q20, q21, [x0, #320]
    ldp     q22, q23, [x0, #352]
    ldp     q24, q25, [x0, #384]
    ldp     q26, q27, [x0, #416]
    ldp     q28, q29, [x0, #448]
    ldp     q30, q31, [x0, #480]
    add     x3, x0, #512
    ldp     x1, x2, [x3]
    msr     fpcr, x1
    msr     fpsr, x2
    ret
