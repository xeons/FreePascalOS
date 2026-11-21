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
// Saving and resuming a processor's kernel state across suspend to RAM
// (Kernel.Arch.Suspend): like setjmp and longjmp. The context holds
// X19-X30 (offsets 0-88), SP (96), DAIF (104), the priority level (112,
// noted by ArchNoteSuspendLevel in Pascal) and TPIDR_EL0 (120).

    .text
    .balign 4

// QWord ArchSaveSuspendRegisters(Context): 0 now, 1 when resumed.
    .global ArchSaveSuspendRegisters
    .type ArchSaveSuspendRegisters, %function
ArchSaveSuspendRegisters:
    stp     x19, x20, [x0, #0]
    stp     x21, x22, [x0, #16]
    stp     x23, x24, [x0, #32]
    stp     x25, x26, [x0, #48]
    stp     x27, x28, [x0, #64]
    stp     x29, x30, [x0, #80]
    mov     x9, sp
    str     x9, [x0, #96]
    mrs     x9, daif
    str     x9, [x0, #104]
    mrs     x9, tpidr_el0
    str     x9, [x0, #120]
    // The priority level, in Pascal (GICv2 keeps it in memory, GICv3 in
    // a system register); X19 is the callee's to keep.
    mov     x19, x0
    bl      ArchNoteSuspendLevel
    ldr     x30, [x19, #88]
    ldr     x19, [x19, #0]
    mov     x0, #0
    ret

// ArchResumeSuspendRegisters(Context): returns from the saving call
// again, with 1.
    .global ArchResumeSuspendRegisters
    .type ArchResumeSuspendRegisters, %function
ArchResumeSuspendRegisters:
    ldp     x19, x20, [x0, #0]
    ldp     x21, x22, [x0, #16]
    ldp     x23, x24, [x0, #32]
    ldp     x25, x26, [x0, #48]
    ldp     x27, x28, [x0, #64]
    ldp     x29, x30, [x0, #80]
    ldr     x9, [x0, #96]
    mov     sp, x9
    ldr     x9, [x0, #120]
    msr     tpidr_el0, x9
    ldr     x9, [x0, #104]
    msr     daif, x9
    mov     x0, #1
    ret
