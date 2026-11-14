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
