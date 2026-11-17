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
// Atomic operations for Runtime.Atomic on AArch64 (ARMv8.0: exclusive
// load/store loops, so they work on the Cortex-A72 without the LSE
// atomics). Every read-modify-write is a full barrier, as LOCK-prefixed
// instructions are on x86-64: acquire on the load, release on the store
// and a DMB after.

    .text
    .balign 4

.macro ROUTINE name
    .global \name
    .type \name, %function
\name:
.endm

// Int64 ArchAtomicAdd(var Value: Int64; Amount: Int64): the new value
ROUTINE ArchAtomicAdd
1:  ldaxr   x2, [x0]
    add     x2, x2, x1
    stlxr   w3, x2, [x0]
    cbnz    w3, 1b
    dmb     ish
    mov     x0, x2
    ret

// Int64 ArchAtomicFetchAndAdd(var Value: Int64; Amount: Int64): the old value
ROUTINE ArchAtomicFetchAndAdd
1:  ldaxr   x2, [x0]
    add     x4, x2, x1
    stlxr   w3, x4, [x0]
    cbnz    w3, 1b
    dmb     ish
    mov     x0, x2
    ret

// QWord ArchAtomicExchange(var Target: QWord; NewValue: QWord): the old value
ROUTINE ArchAtomicExchange
1:  ldaxr   x2, [x0]
    stlxr   w3, x1, [x0]
    cbnz    w3, 1b
    dmb     ish
    mov     x0, x2
    ret

// QWord ArchAtomicCompareExchange(var Target; NewValue; ExpectedValue): the old value
ROUTINE ArchAtomicCompareExchange
1:  ldaxr   x3, [x0]
    cmp     x3, x2
    b.ne    2f
    stlxr   w4, x1, [x0]
    cbnz    w4, 1b
    dmb     ish
    mov     x0, x3
    ret
2:  clrex
    dmb     ish
    mov     x0, x3
    ret

// ArchAtomicOr(var Target: QWord; Bits: QWord)
ROUTINE ArchAtomicOr
1:  ldaxr   x2, [x0]
    orr     x2, x2, x1
    stlxr   w3, x2, [x0]
    cbnz    w3, 1b
    dmb     ish
    ret

// QWord ArchAtomicLoad(var Target: QWord)
ROUTINE ArchAtomicLoad
    ldar    x0, [x0]
    ret

// ArchAtomicStore(var Target: QWord; Value: QWord)
ROUTINE ArchAtomicStore
    stlr    x1, [x0]
    ret

ROUTINE ArchFullMemoryBarrier
    dmb     ish
    ret
