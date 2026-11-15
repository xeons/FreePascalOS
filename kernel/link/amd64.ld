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
 * Linker script for the x86-64 kernel image.
 *
 * The kernel runs in the top 2 GiB of the address space. Each kind of
 * section gets its own program header so the loader can map code
 * read-only and data writable.
 */

OUTPUT_FORMAT("elf64-x86-64")
OUTPUT_ARCH(i386:x86-64)
ENTRY(KernelEntry)

PHDRS
{
    text    PT_LOAD FLAGS(5);   /* read + execute */
    rodata  PT_LOAD FLAGS(4);   /* read */
    data    PT_LOAD FLAGS(6);   /* read + write */
}

SECTIONS
{
    . = 0xFFFFFFFF80000000;
    KernelImageStart = .;

    .text ALIGN(4K) :
    {
        *(.text .text.*)
        KernelTextEnd = .;
    } :text

    .rodata ALIGN(4K) :
    {
        *(.rodata .rodata.*)
    } :rodata

    .data ALIGN(4K) :
    {
        *(.data .data.*)
        *(.fpc .fpc.*)
    } :data

    .bss ALIGN(4K) :
    {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    . = ALIGN(4K);
    KernelImageEnd = .;

    /DISCARD/ :
    {
        *(.note .note.*)
        *(.comment)
        *(.eh_frame)
    }
}
