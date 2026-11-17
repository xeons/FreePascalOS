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

    .text
    .balign 4

// Int64 ArchUserCopyBytes(Destination, Source, Length): 0
    .global ArchUserCopyBytes
    .global ArchUserCopyBytesEnd
ArchUserCopyBytes:
    cbz     x2, 2f
1:  ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    x2, x2, #1
    b.ne    1b
2:  mov     x0, xzr
    ret
ArchUserCopyBytesEnd:

// Int64 ArchUserCopyString(Destination, Source, Capacity): the length,
// or -2 (UserCopyTooLong) when Capacity bytes held no terminator.
    .global ArchUserCopyString
    .global ArchUserCopyStringEnd
ArchUserCopyString:
    mov     x4, xzr
1:  cmp     x4, x2
    b.eq    3f
    ldrb    w3, [x1, x4]
    strb    w3, [x0, x4]
    cbz     w3, 2f
    add     x4, x4, #1
    b       1b
2:  mov     x0, x4
    ret
3:  mov     x0, #-2
    ret
ArchUserCopyStringEnd:

    .global ArchUserCopyFault
ArchUserCopyFault:
    mov     x0, #-1
    ret
