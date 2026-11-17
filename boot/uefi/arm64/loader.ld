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
 * Linker script for the AArch64 UEFI loader: a position independent ELF
 * linked at address 0 that objcopy turns into a PE image, each output
 * section becoming a PE section at the same relative address. The first
 * page is left for the PE headers. Uninitialized data is kept inside
 * .data, so the PE image holds it as zeros and needs no special section.
 */

OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

SECTIONS
{
    . = 0;
    ImageBase = .;
    . = 0x1000;

    .text :
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(16);
    }

    .dynamic ALIGN(4096) :
    {
        *(.dynamic)
    }

    .data ALIGN(4096) :
    {
        *(.data .data.*)
        *(.fpc .fpc.*)
        *(.got .got.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
    }

    .rela ALIGN(4096) :
    {
        *(.rela.dyn)
        *(.rela.*)
    }

    .reloc ALIGN(4096) :
    {
        *(.reloc)
    }

    . = ALIGN(4096);
    .dynsym : { *(.dynsym) }
    .dynstr : { *(.dynstr) }
    .hash : { *(.hash) }
    .gnu.hash : { *(.gnu.hash) }

    /DISCARD/ :
    {
        *(.note .note.*)
        *(.comment)
        *(.eh_frame)
        *(.interp)
    }
}
