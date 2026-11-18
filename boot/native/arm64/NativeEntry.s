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
// Entry point of the native boot image (build/arm64/native/fpos.img).
//
// The image starts with the Linux arm64 Image header, so the Raspberry
// Pi's firmware (config.txt kernel=fpos.img, arm_64bit=1) and QEMU
// (-kernel) load it as they would load Linux: anywhere in RAM, entered
// at its first byte with x0 = the device tree's physical address, the
// MMU and the data cache off, at EL2 (the Pi) or EL1 (QEMU without
// virtualization=on).
//
// The stub is linked at address 0 as a position independent executable
// (native.ld) and relocates itself here, as the UEFI loader does: code
// reaches everything PC-relative, but data holding addresses needs the
// R_AARCH64_RELATIVE relocations applied for the address it runs at.
// It then turns the instruction cache on (fetches are cached even with
// the MMU off; data accesses stay uncached, so nothing needs cleaning
// before the hand-off), lets floating point and SIMD instructions run
// (the compiler may use them for copies), takes its own stack and calls
// NativeMain (NativeBoot.pas) with the tree and the image's bounds.

    .section .head, "ax"
    .balign 4

    .set DT_RELA, 7
    .set DT_RELASZ, 8
    .set DT_RELAENT, 9
    .set R_AARCH64_RELATIVE, 1027
    .set SCTLR_INSTRUCTION_CACHE, (1 << 12)
    .set CPACR_NO_FP_TRAPS, (3 << 20)
    .set CPTR_EL2_NO_TRAPS, 0x33FF
    // Little endian, 4 KiB pages, may be placed anywhere in memory.
    .set IMAGE_FLAGS, 0xA

// The Linux arm64 Image header (Documentation/arch/arm64/booting.rst).
    .global _start
_start:
    b       NativeStart                   // code0
    .long   0                             // code1
    .quad   0                             // text_offset
    .quad   NativeImageSize               // image_size: the whole file, no .bss beyond it
    .quad   IMAGE_FLAGS                   // flags
    .quad   0                             // res2
    .quad   0                             // res3
    .quad   0                             // res4
    .ascii  "ARM\x64"                     // magic
    .long   0                             // res5: no PE header

    .text
    .balign 4
NativeStart:
    mov     x19, x0                       // the device tree

    ic      iallu
    dsb     sy
    isb
    mrs     x9, CurrentEL
    ubfx    x9, x9, #2, #2
    cmp     x9, #2
    b.ne    1f
    mrs     x9, sctlr_el2
    orr     x9, x9, #SCTLR_INSTRUCTION_CACHE
    msr     sctlr_el2, x9
    mov     x9, #CPTR_EL2_NO_TRAPS
    msr     cptr_el2, x9
    b       2f
1:  mrs     x9, sctlr_el1
    orr     x9, x9, #SCTLR_INSTRUCTION_CACHE
    msr     sctlr_el1, x9
    mov     x9, #CPACR_NO_FP_TRAPS
    msr     cpacr_el1, x9
2:  isb

    adrp    x9, NativeStackTop
    add     x9, x9, #:lo12:NativeStackTop
    mov     sp, x9

    adrp    x2, ImageBase
    add     x2, x2, #:lo12:ImageBase      // where the image really is
    adrp    x3, _DYNAMIC
    add     x3, x3, #:lo12:_DYNAMIC

    // Find the relocation table and its size in the dynamic section.
    mov     x4, xzr                       // table
    mov     x5, xzr                       // size in bytes
    mov     x6, #24                       // entry size
3:  ldp     x7, x8, [x3], #16
    cbz     x7, 6f
    cmp     x7, #DT_RELA
    b.ne    4f
    add     x4, x8, x2
    b       3b
4:  cmp     x7, #DT_RELASZ
    b.ne    5f
    mov     x5, x8
    b       3b
5:  cmp     x7, #DT_RELAENT
    b.ne    3b
    mov     x6, x8
    b       3b

    // Apply each R_AARCH64_RELATIVE: *(base + offset) = base + addend.
6:  cbz     x4, 8f
7:  cbz     x5, 8f
    ldr     x7, [x4]                      // r_offset
    ldr     x8, [x4, #8]                  // r_info
    ldr     x9, [x4, #16]                 // r_addend
    and     x8, x8, #0xFFFFFFFF
    cbz     x8, 9f                        // R_AARCH64_NONE (the linker leaves one)
    cmp     x8, #R_AARCH64_RELATIVE
    b.ne    NativeHalt                    // another kind: the image cannot run
    add     x9, x9, x2
    str     x9, [x2, x7]
9:  add     x4, x4, x6
    sub     x5, x5, x6
    b       7b

8:  mov     x0, x19
    adrp    x1, ImageBase
    add     x1, x1, #:lo12:ImageBase
    adrp    x2, NativeImageEnd
    add     x2, x2, #:lo12:NativeImageEnd
    bl      NativeMain                    // NativeBoot.pas; returns only on failure

    .global NativeHalt
NativeHalt:
    wfe
    b       NativeHalt

// The stub's stack, inside the image (the image has no .bss beyond its
// file, so an initial RAM disk placed right after it is safe).
    .data
    .balign 16
NativeStack:
    .skip   64 * 1024
NativeStackTop:
