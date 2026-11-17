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
// Data cache maintenance by virtual address for DMA with devices that do
// not snoop the processors' caches (Hal.DmaCoherency). Every routine
// takes x0 = start, x1 = length in bytes, works on whole cache lines (the
// smallest data cache line, CTR_EL0.DminLine) to the point of coherency
// and ends with a DSB, so the maintenance is complete when it returns.

    .text
    .balign 4

.macro ROUTINE name
    .global \name
    .type \name, %function
\name:
.endm

// x2 = the smallest data cache line size in bytes, x3 = x2 - 1.
.macro DATA_LINE_SIZE
    mrs     x3, ctr_el0
    ubfx    x3, x3, #16, #4
    mov     x2, #4
    lsl     x2, x2, x3
    sub     x3, x2, #1
.endm

// Writes dirty lines back (the device is about to read the memory).
ROUTINE ArchCleanDataCacheRange
    cbz     x1, 2f
    DATA_LINE_SIZE
    add     x1, x0, x1
    bic     x0, x0, x3
1:  dc      cvac, x0
    add     x0, x0, x2
    cmp     x0, x1
    b.lo    1b
2:  dsb     sy
    ret

// Writes dirty lines back and drops them (before a device writes the
// memory, so no dirty line is evicted over what it wrote).
ROUTINE ArchCleanAndInvalidateDataCacheRange
    cbz     x1, 2f
    DATA_LINE_SIZE
    add     x1, x0, x1
    bic     x0, x0, x3
1:  dc      civac, x0
    add     x0, x0, x2
    cmp     x0, x1
    b.lo    1b
2:  dsb     sy
    ret

// Drops the lines (a device wrote the memory; what the caches hold is
// stale). A line only partly inside the range also holds bytes that are
// not the device's, so the first and last lines are cleaned and
// invalidated instead of thrown away.
ROUTINE ArchInvalidateDataCacheRange
    cbz     x1, 4f
    DATA_LINE_SIZE
    add     x1, x0, x1              // x1 = end
    tst     x0, x3
    b.eq    1f
    bic     x0, x0, x3              // partial first line
    dc      civac, x0
    add     x0, x0, x2
1:  tst     x1, x3
    b.eq    2f
    bic     x4, x1, x3              // partial last line
    cmp     x4, x0
    b.lo    4f                      // the range ended inside the first line
    dc      civac, x4
    mov     x1, x4
2:  cmp     x0, x1
    b.hs    4f
3:  dc      ivac, x0
    add     x0, x0, x2
    cmp     x0, x1
    b.lo    3b
4:  dsb     sy
    ret
