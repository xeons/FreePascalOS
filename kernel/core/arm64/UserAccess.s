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
// Copying from and to user memory (Kernel.Arch.UserCopy). The routines
// use no stack, so a fault inside them is recovered by continuing at
// ArchUserCopyFault, which returns UserCopyFaulted (-1) to their caller.
//
// With PAN (privileged access never, Kernel.Arch.ProcessorProtection)
// on, the processor refuses every kernel access to user pages; the
// routines clear PSTATE.PAN for the copy alone and set it again after.
// ArchPanEnabled says whether to: MSR PAN does not exist on processors
// without PAN (ARMv8.0, the Cortex-A72). The instructions are written
// as their encodings, which every assembler takes.

    .set MSR_PAN_0, 0xD500409F       // msr pan, #0: allow user accesses
    .set MSR_PAN_1, 0xD500419F       // msr pan, #1: forbid them again

.macro OPEN_USER_ACCESS
    adrp    x9, ArchPanEnabled
    ldrb    w9, [x9, #:lo12:ArchPanEnabled]
    cbz     w9, 9f
    .inst   MSR_PAN_0
9:
.endm

.macro CLOSE_USER_ACCESS
    adrp    x9, ArchPanEnabled
    ldrb    w9, [x9, #:lo12:ArchPanEnabled]
    cbz     w9, 9f
    .inst   MSR_PAN_1
9:
.endm

    .text
    .balign 4

// Int64 ArchUserCopyBytes(Destination, Source, Length): 0
    .global ArchUserCopyBytes
    .global ArchUserCopyBytesEnd
ArchUserCopyBytes:
    OPEN_USER_ACCESS
    cbz     x2, 2f
1:  ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    x2, x2, #1
    b.ne    1b
2:  CLOSE_USER_ACCESS
    mov     x0, xzr
    ret
ArchUserCopyBytesEnd:

// Int64 ArchUserCopyString(Destination, Source, Capacity): the length,
// or -2 (UserCopyTooLong) when Capacity bytes held no terminator.
    .global ArchUserCopyString
    .global ArchUserCopyStringEnd
ArchUserCopyString:
    OPEN_USER_ACCESS
    mov     x4, xzr
1:  cmp     x4, x2
    b.eq    3f
    ldrb    w3, [x1, x4]
    strb    w3, [x0, x4]
    cbz     w3, 2f
    add     x4, x4, #1
    b       1b
2:  mov     x0, x4
    b       4f
3:  mov     x0, #-2
4:  CLOSE_USER_ACCESS
    ret
ArchUserCopyStringEnd:

// A fault inside a copy continues here. The exception return restored
// the PAN of the copy (clear); the recovery set it again in the saved
// state (RecoverFromUserCopyFault), so this only returns.
    .global ArchUserCopyFault
ArchUserCopyFault:
    mov     x0, #-1
    ret

// Sets PSTATE.PAN on this processor (only called where PAN exists).
    .global ArchSetPrivilegedAccessNever
ArchSetPrivilegedAccessNever:
    .inst   MSR_PAN_1
    ret

// Reads PSTATE.PAN (bit 22 of the result; only where PAN exists).
    .global ArchReadPrivilegedAccessNever
ArchReadPrivilegedAccessNever:
    mrs     x0, s3_0_c4_c2_3
    ret

    .data
    .global ArchPanEnabled
ArchPanEnabled:
    .byte   0
