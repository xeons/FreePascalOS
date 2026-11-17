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
// Entry point of the AArch64 UEFI loader.
//
// Free Pascal 3.2.2 cannot write AArch64 PE images, so the loader is
// linked as a position independent ELF (loader.ld) and converted by
// objcopy. Code reaches everything PC-relative, but data holding
// addresses (typed constants, tables of routines) needs relocating, and
// the firmware only applies PE base relocations, which the conversion
// does not produce. So the image relocates itself here: it applies the
// ELF's R_AARCH64_RELATIVE relocations (found through _DYNAMIC) for the
// address the firmware loaded it at, then calls EfiMain. The PE image
// carries an empty .reloc section so the firmware knows it may load it
// anywhere.

    .text
    .balign 4

    .set DT_NULL, 0
    .set DT_RELA, 7
    .set DT_RELASZ, 8
    .set DT_RELAENT, 9
    .set R_AARCH64_RELATIVE, 1027
    .set EFI_LOAD_ERROR, 0x8000000000000001

// EFI_STATUS _start(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
    .global _start
_start:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x0, x1, [sp, #16]

    adrp    x2, ImageBase
    add     x2, x2, #:lo12:ImageBase      // where the image really is
    adrp    x3, _DYNAMIC
    add     x3, x3, #:lo12:_DYNAMIC

    // Find the relocation table and its size in the dynamic section.
    mov     x4, xzr                       // table
    mov     x5, xzr                       // size in bytes
    mov     x6, #24                       // entry size
1:  ldp     x7, x8, [x3], #16
    cbz     x7, 3f
    cmp     x7, #DT_RELA
    b.ne    2f
    add     x4, x8, x2
    b       1b
2:  cmp     x7, #DT_RELASZ
    b.ne    21f
    mov     x5, x8
    b       1b
21: cmp     x7, #DT_RELAENT
    b.ne    1b
    mov     x6, x8
    b       1b

    // Apply each R_AARCH64_RELATIVE: *(base + offset) = base + addend.
3:  cbz     x4, 6f
4:  cbz     x5, 6f
    ldr     x7, [x4]                      // r_offset
    ldr     x8, [x4, #8]                  // r_info
    ldr     x9, [x4, #16]                 // r_addend
    and     x8, x8, #0xFFFFFFFF
    cmp     x8, #R_AARCH64_RELATIVE
    b.ne    7f
    add     x9, x9, x2
    str     x9, [x2, x7]
    add     x4, x4, x6
    sub     x5, x5, x6
    b       4b

6:  ldp     x0, x1, [sp, #16]
    bl      _mainCRTStartup               // EfiMain (boot/uefi/OsLoader.pas)
    ldp     x29, x30, [sp], #32
    ret

    // A relocation of another kind: the image cannot run.
7:  ldr     x0, =EFI_LOAD_ERROR
    ldp     x29, x30, [sp], #32
    ret
    .ltorg

// The firmware relocates a PE image only if it has base relocations;
// one empty block is enough to say it may be loaded anywhere.
    .section .reloc, "a"
    .balign 4
.Lreloc_block:
    .long   0                             // page RVA
    .long   10                            // block size
    .short  0                             // IMAGE_REL_BASED_ABSOLUTE (padding)
