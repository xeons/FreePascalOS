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
// What code compiled with -CE calls when FPSR shows a floating point
// exception (userland.mk): Free Pascal 3.2.2 calls FPC_THROWFPUEXCEPTION
// right after the operation and expects every floating point and vector
// register (and the condition flags) to come back unchanged - the result
// of the operation is still in one - but the RTL's routine
// (rtl/aarch64/aarch64.inc) is ordinary Pascal that may use them. So the
// RTL's is renamed FPC_THROWFPUEXCEPTION_RAISE in system.o (objcopy, at
// the RTL's build) and this one, the name the compiler calls, keeps the
// registers around it. Most calls return (the flag was a masked one, such
// as inexact, which the RTL clears); an unmasked one raises an exception
// and never comes back.

    .text
    .balign 4
    .global FPC_THROWFPUEXCEPTION
    .type FPC_THROWFPUEXCEPTION, %function
FPC_THROWFPUEXCEPTION:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    sub     sp, sp, #688
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    mrs     x9, nzcv
    stp     x18, x9, [sp, #144]
    stp     q0, q1, [sp, #160]
    stp     q2, q3, [sp, #192]
    stp     q4, q5, [sp, #224]
    stp     q6, q7, [sp, #256]
    stp     q8, q9, [sp, #288]
    stp     q10, q11, [sp, #320]
    stp     q12, q13, [sp, #352]
    stp     q14, q15, [sp, #384]
    stp     q16, q17, [sp, #416]
    stp     q18, q19, [sp, #448]
    stp     q20, q21, [sp, #480]
    stp     q22, q23, [sp, #512]
    stp     q24, q25, [sp, #544]
    stp     q26, q27, [sp, #576]
    stp     q28, q29, [sp, #608]
    stp     q30, q31, [sp, #640]
    bl      FPC_THROWFPUEXCEPTION_RAISE
    ldp     q0, q1, [sp, #160]
    ldp     q2, q3, [sp, #192]
    ldp     q4, q5, [sp, #224]
    ldp     q6, q7, [sp, #256]
    ldp     q8, q9, [sp, #288]
    ldp     q10, q11, [sp, #320]
    ldp     q12, q13, [sp, #352]
    ldp     q14, q15, [sp, #384]
    ldp     q16, q17, [sp, #416]
    ldp     q18, q19, [sp, #448]
    ldp     q20, q21, [sp, #480]
    ldp     q22, q23, [sp, #512]
    ldp     q24, q25, [sp, #544]
    ldp     q26, q27, [sp, #576]
    ldp     q28, q29, [sp, #608]
    ldp     q30, q31, [sp, #640]
    ldp     x18, x9, [sp, #144]
    msr     nzcv, x9
    ldp     x16, x17, [sp, #128]
    ldp     x14, x15, [sp, #112]
    ldp     x12, x13, [sp, #96]
    ldp     x10, x11, [sp, #80]
    ldp     x8, x9, [sp, #64]
    ldp     x6, x7, [sp, #48]
    ldp     x4, x5, [sp, #32]
    ldp     x2, x3, [sp, #16]
    ldp     x0, x1, [sp, #0]
    add     sp, sp, #688
    ldp     x29, x30, [sp], #16
    ret
    .size FPC_THROWFPUEXCEPTION, . - FPC_THROWFPUEXCEPTION
