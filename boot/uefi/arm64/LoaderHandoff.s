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
// The last steps from the loader to the kernel on AArch64, after
// ExitBootServices: leave EL2 if the firmware ran there (the Raspberry
// Pi's UEFI firmware does, QEMU's virt machine without virtualization
// does not), turn the firmware's translation off, load the kernel's
// memory attributes, translation control and both table roots, turn
// translation and the caches on again and jump to the kernel.
//
// The code runs on the firmware's identity mapping and, once the new
// tables are on, on the loader's identity mapping of the same memory.
// Between the two the MMU is off: nothing here touches memory then.

    .text
    .balign 4

// Constants shared with shared/arm64/Boot.TranslationTableFormat.pas.
    .set MEMORY_ATTRIBUTES,     0x004404FF
    .set TRANSLATION_CONTROL,   0x00000000B5103510
    .set SCTLR_EL1_RES1,        0x30D00800
    .set SCTLR_MMU,             (1 << 0)
    .set SCTLR_DATA_CACHE,      (1 << 2)
    .set SCTLR_STACK_ALIGNMENT, (1 << 3)
    .set SCTLR_INSTRUCTION_CACHE, (1 << 12)
    .set SCTLR_KERNEL, SCTLR_EL1_RES1 | SCTLR_MMU | SCTLR_DATA_CACHE | SCTLR_STACK_ALIGNMENT | SCTLR_INSTRUCTION_CACHE
    .set HCR_EL1_IS_AARCH64,    (1 << 31)
    .set SPSR_EL1H_MASKED,      0x3C5
    .set CPACR_NO_FP_TRAPS,     (3 << 20)

// void ArchCleanDataCacheRange(QWord Start, QWord Size)
// Writes the lines of [Start, Start + Size) back to the point of
// coherency, so they are in memory while the MMU and caches are off.
    .global ArchCleanDataCacheRange
ArchCleanDataCacheRange:
    cbz     x1, 2f
    mrs     x3, ctr_el0
    ubfx    x3, x3, #16, #4         // DminLine: log2 of words per line
    mov     x2, #4
    lsl     x2, x2, x3              // line size in bytes
    sub     x3, x2, #1
    add     x1, x0, x1
    bic     x0, x0, x3
1:  dc      cvac, x0
    add     x0, x0, x2
    cmp     x0, x1
    b.lo    1b
    dsb     sy
2:  ret

// void ArchEnterKernel(QWord KernelRoot, QWord IdentityRoot,
//                      QWord StackTop, QWord BootInformation, QWord EntryPoint)
    .global ArchEnterKernel
    .global ArchEnterKernelEnd
ArchEnterKernel:
    msr     daifset, #0xf
    mrs     x9, CurrentEL
    ubfx    x9, x9, #2, #2
    cmp     x9, #2
    b.ne    .Lat_el1

    // At EL2: the firmware's EL2 translation off, EL1 set up to run
    // AArch64 untrapped (the counter and timer, floating point), then
    // into EL1 with everything masked and its MMU off.
    mrs     x9, sctlr_el2
    bic     x9, x9, #SCTLR_MMU
    bic     x9, x9, #SCTLR_DATA_CACHE
    bic     x9, x9, #SCTLR_INSTRUCTION_CACHE
    msr     sctlr_el2, x9
    isb
    mov     x9, #HCR_EL1_IS_AARCH64
    msr     hcr_el2, x9
    mrs     x9, cnthctl_el2
    orr     x9, x9, #3              // EL1PCTEN, EL1PCEN
    msr     cnthctl_el2, x9
    msr     cntvoff_el2, xzr
    mov     x9, #0x33FF             // CPTR_EL2: RES1 bits, no traps
    msr     cptr_el2, x9
    msr     hstr_el2, xzr
    mrs     x9, midr_el1
    msr     vpidr_el2, x9
    mrs     x9, mpidr_el1
    msr     vmpidr_el2, x9
    ldr     x9, =SCTLR_EL1_RES1
    msr     sctlr_el1, x9
    mov     x9, #SPSR_EL1H_MASKED
    msr     spsr_el2, x9
    adr     x9, .Lat_el1
    msr     elr_el2, x9
    eret

.Lat_el1:
    mrs     x9, sctlr_el1
    bic     x9, x9, #SCTLR_MMU
    bic     x9, x9, #SCTLR_DATA_CACHE
    bic     x9, x9, #SCTLR_INSTRUCTION_CACHE
    msr     sctlr_el1, x9
    isb
    tlbi    vmalle1
    ic      iallu
    dsb     sy
    isb

    ldr     x9, =MEMORY_ATTRIBUTES
    msr     mair_el1, x9
    ldr     x9, =TRANSLATION_CONTROL
    mrs     x10, id_aa64mmfr0_el1
    and     x10, x10, #7            // PARange
    orr     x9, x9, x10, lsl #32    // IPS
    msr     tcr_el1, x9
    msr     ttbr0_el1, x1
    msr     ttbr1_el1, x0
    mov     x9, #CPACR_NO_FP_TRAPS
    msr     cpacr_el1, x9
    isb
    ldr     x9, =SCTLR_KERNEL
    msr     sctlr_el1, x9
    isb

    mov     sp, x2
    mov     x0, x3
    mov     x29, xzr
    mov     x30, xzr
    br      x4
    .ltorg
ArchEnterKernelEnd:
