/*
 * FreePascalOS
 * Copyright (C) 2026 Brandon Scott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * Linker script for the native boot image: a position independent ELF
 * linked at address 0, the Linux arm64 Image header first, that objcopy
 * turns into a flat binary (fpos.img). Everything the stub writes is
 * inside the file (uninitialized data is kept in .data), so image_size
 * in the header is the file's size and nothing beyond it is touched;
 * the kernel ELF comes last.
 */

OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

SECTIONS
{
    . = 0;
    ImageBase = .;

    .head : { *(.head) }

    .text :
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(16);
    }

    .dynamic ALIGN(4096) : { *(.dynamic) }

    .data ALIGN(4096) :
    {
        *(.data .data.*)
        *(.fpc .fpc.*)
        *(.got .got.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
    }

    .rela ALIGN(16) :
    {
        *(.rela.dyn)
        *(.rela.*)
    }

    .dynsym : { *(.dynsym) }
    .dynstr : { *(.dynstr) }
    .hash : { *(.hash) }
    .gnu.hash : { *(.gnu.hash) }

    .payload ALIGN(4096) : { *(.payload) }

    . = ALIGN(4096);
    NativeImageEnd = .;
    NativeImageSize = NativeImageEnd - ImageBase;

    /DISCARD/ :
    {
        *(.note .note.*)
        *(.comment)
        *(.eh_frame)
        *(.interp)
    }
}
