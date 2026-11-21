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
// Entry points of the AArch64 kernel.
//
// ArchKernelEntry is the ELF entry point the loader jumps to, at EL1 on
// the kernel's translation tables, with x0 = the boot information and SP
// = the boot stack. It remembers the boot information (the HAL reads the
// firmware's tables through it before Kernel.Startup hands it on), points
// the processor at the exception vectors so even the first fault is
// reported, and continues in KernelEntryPoint (Kernel.Startup).
//
// ArchSecondaryEntry is where PSCI CPU_ON starts another processor: at
// its physical address, with the MMU off, at EL2 or EL1, x0 = the
// physical address of its start-up record (Kernel.Arch.ProcessorStartup).

    .text
    .balign 4

    .set SCTLR_EL1_RES1,        0x30D00800
    .set HCR_EL1_IS_AARCH64,    (1 << 31)
    .set SPSR_EL1H_MASKED,      0x3C5

    .global ArchKernelEntry
    .type ArchKernelEntry, %function
ArchKernelEntry:
    adrp    x9, ArchBootInformation
    str     x0, [x9, #:lo12:ArchBootInformation]
    adrp    x9, ArchExceptionVectors
    add     x9, x9, #:lo12:ArchExceptionVectors
    msr     vbar_el1, x9
    isb
    b       KernelEntry

// Start-up record offsets (TSecondaryStartRecord).
    .set START_MEMORY_ATTRIBUTES, 0
    .set START_TRANSLATION_CONTROL, 8
    .set START_IDENTITY_ROOT, 16
    .set START_KERNEL_ROOT, 24
    .set START_SYSTEM_CONTROL, 32
    .set START_STACK_TOP, 40
    .set START_PROCESSOR, 48
    .set START_ENTRY_POINT, 56

    // Only the page this code is on is identity mapped while it turns
    // translation on (Kernel.Arch.ProcessorStartup), so the code and its
    // literal pool (.ltorg below) must not cross into the next page:
    // they start a page of their own.
    .balign 4096
    .global ArchSecondaryEntry
    .type ArchSecondaryEntry, %function
ArchSecondaryEntry:
    msr     daifset, #0xF
    mrs     x9, CurrentEL
    ubfx    x9, x9, #2, #2
    cmp     x9, #2
    b.ne    .Lsecondary_at_el1

    // At EL2 (the Raspberry Pi's firmware starts processors there): set
    // EL1 up as the loader does for the boot processor and go there.
    mov     x9, #HCR_EL1_IS_AARCH64
    msr     hcr_el2, x9
    mrs     x9, cnthctl_el2
    orr     x9, x9, #3
    msr     cnthctl_el2, x9
    msr     cntvoff_el2, xzr
    mov     x9, #0x33FF
    msr     cptr_el2, x9
    msr     hstr_el2, xzr
    // A GICv3's system register interface open to EL1 (ICC_SRE_EL2:
    // SRE and Enable), its virtual interface off (ICH_HCR_EL2).
    mrs     x9, id_aa64pfr0_el1
    ubfx    x9, x9, #24, #4
    cbz     x9, .Lsecondary_gic_open_done
    mrs     x9, S3_4_C12_C9_5
    orr     x9, x9, #1
    orr     x9, x9, #8
    msr     S3_4_C12_C9_5, x9
    isb
    msr     S3_4_C12_C11_0, xzr
.Lsecondary_gic_open_done:
    mrs     x9, midr_el1
    msr     vpidr_el2, x9
    mrs     x9, mpidr_el1
    msr     vmpidr_el2, x9
    ldr     x9, =SCTLR_EL1_RES1
    msr     sctlr_el1, x9
    mov     x9, #SPSR_EL1H_MASKED
    msr     spsr_el2, x9
    adr     x9, .Lsecondary_at_el1
    msr     elr_el2, x9
    eret

.Lsecondary_at_el1:
    // The MMU is off: the record is read from memory (the boot processor
    // cleaned it to the point of coherency).
    ldr     x19, [x0, #START_STACK_TOP]
    ldr     x20, [x0, #START_PROCESSOR]
    ldr     x21, [x0, #START_ENTRY_POINT]
    ldr     x9, [x0, #START_MEMORY_ATTRIBUTES]
    msr     mair_el1, x9
    ldr     x9, [x0, #START_TRANSLATION_CONTROL]
    msr     tcr_el1, x9
    ldr     x9, [x0, #START_IDENTITY_ROOT]
    msr     ttbr0_el1, x9
    ldr     x9, [x0, #START_KERNEL_ROOT]
    msr     ttbr1_el1, x9
    mov     x9, #(3 << 20)                // no floating point traps
    msr     cpacr_el1, x9
    ldr     x22, [x0, #START_SYSTEM_CONTROL]
    tlbi    vmalle1
    ic      iallu
    dsb     nsh
    isb
    msr     sctlr_el1, x22
    isb
    // Translation is on; this page is identity mapped. Continue at the
    // kernel's own address.
    ldr     x9, =.Lsecondary_virtual
    br      x9

.Lsecondary_virtual:
    adrp    x9, ArchExceptionVectors
    add     x9, x9, #:lo12:ArchExceptionVectors
    msr     vbar_el1, x9
    isb
    mov     sp, x19
    mov     x29, xzr
    mov     x30, xzr
    mov     x0, x20
    blr     x21
1:  wfi
    b       1b
    .ltorg

    .bss
    .balign 8
    .global ArchBootInformation
ArchBootInformation:
    .quad   0
