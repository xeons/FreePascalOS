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
 * Linker script for the AArch64 kernel image.
 *
 * The kernel runs in the top 2 GiB of the address space. Each kind of
 * section gets its own program header, starting on a page of its own, so
 * the loader can map code read-only and executable, read-only data
 * read-only and no-execute, and data writable and no-execute (W^X).
 * The boundaries are named for the kernel's own checks
 * (Memory.MappingAudit).
 */

OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(ArchKernelEntry)

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
        KernelTextStart = .;
        *(.text .text.*)
        KernelTextEnd = .;
    } :text

    .rodata ALIGN(4K) :
    {
        KernelReadOnlyDataStart = .;
        *(.rodata .rodata.*)
        KernelReadOnlyDataEnd = .;
    } :rodata

    .data ALIGN(4K) :
    {
        KernelDataStart = .;
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
