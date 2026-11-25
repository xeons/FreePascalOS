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
// The AArch64 instructions Free Pascal's built-in assembler does not
// know (system registers, barriers, cache and TLB maintenance), as small
// routines with the standard calling convention. Kernel.Arch.Cpu and the
// other Kernel.Arch units declare them as external.

    .text
    .balign 4

.macro ROUTINE name
    .global \name
    .type \name, %function
\name:
.endm

// --- Interrupt masking (PSTATE.I; debug, SError and FIQ stay masked) ---

ROUTINE ArchDisableInterrupts
    msr     daifset, #2
    ret

ROUTINE ArchEnableInterrupts
    msr     daifclr, #2
    ret

// ISR_EL1: the interrupts pending at this processor (bit 7 an IRQ),
// whether masked or not.
ROUTINE ArchReadPendingInterrupts
    mrs     x0, isr_el1
    ret

ROUTINE ArchReadInterruptMask
    mrs     x0, daif
    ret

ROUTINE ArchWriteInterruptMask
    msr     daif, x0
    ret

// --- Asynchronous aborts (PSTATE.A) ---

// SErrors stay masked in general; a driver that touches a bus able to
// raise one opens a window so it is taken (and panics) instead of
// staying pending for good.
ROUTINE ArchEnableAsynchronousAborts
    msr     daifclr, #4
    isb
    ret

// Anything still pending is taken before the mask goes back: the
// barriers finish outstanding accesses, ESB (a NOP without RAS)
// synchronizes errors, ISB lets the unmasked SError in.
ROUTINE ArchDisableAsynchronousAborts
    dsb     sy
    hint    #16
    isb
    msr     daifset, #4
    ret

// WFI wakes for a pending interrupt even while PSTATE.I masks it, so
// waiting with interrupts masked and unmasking afterwards cannot miss
// one: it is taken right after the unmask.
ROUTINE ArchEnableInterruptsAndWait
    dsb     sy
    wfi
    msr     daifclr, #2
    ret

ROUTINE ArchWaitForInterrupt
    dsb     sy
    wfi
    ret

ROUTINE ArchYield
    yield
    ret

// --- Barriers ---

ROUTINE ArchDataSynchronizationBarrier
    dsb     sy
    ret

ROUTINE ArchDataMemoryBarrier
    dmb     ish
    ret

ROUTINE ArchInstructionBarrier
    isb
    ret

// --- Translation ---

// Invalidates one page of the kernel or the user half on every
// processor of the inner shareable domain (all of them).
ROUTINE ArchInvalidatePage
    dsb     ishst
    lsr     x0, x0, #12
    and     x0, x0, #0xFFFFFFFFFFF
    tlbi    vaae1is, x0
    dsb     ish
    isb
    ret

ROUTINE ArchInvalidateAllPages
    dsb     ishst
    tlbi    vmalle1is
    dsb     ish
    isb
    ret

ROUTINE ArchInvalidateLocalPages
    dsb     nshst
    tlbi    vmalle1
    dsb     nsh
    isb
    ret

// Makes a table entry just written visible to the table walker.
ROUTINE ArchPublishTableEntry
    dsb     ishst
    isb
    ret

ROUTINE ArchReadUserTableRoot
    mrs     x0, ttbr0_el1
    ret

ROUTINE ArchWriteUserTableRoot
    dsb     ish
    msr     ttbr0_el1, x0
    isb
    tlbi    vmalle1
    dsb     nsh
    isb
    ret

// Loads TTBR0_EL1 with a root and its ASID (bits 63-48); entries of
// other ASIDs stay in the TLB (Memory.Arch.AddressSpaceIds).
ROUTINE ArchLoadUserTableRoot
    dsb     ish
    msr     ttbr0_el1, x0
    isb
    ret

ROUTINE ArchReadKernelTableRoot
    mrs     x0, ttbr1_el1
    ret

ROUTINE ArchReadTranslationControl
    mrs     x0, tcr_el1
    ret

// A new translation control (TCR_EL1.AS changed): nothing cached under
// the old one may be used.
ROUTINE ArchWriteTranslationControl
    msr     tcr_el1, x0
    isb
    tlbi    vmalle1
    dsb     nsh
    isb
    ret

ROUTINE ArchReadMemoryModelFeatures0
    mrs     x0, id_aa64mmfr0_el1
    ret

ROUTINE ArchReadMemoryAttributes
    mrs     x0, mair_el1
    ret

ROUTINE ArchReadSystemControl
    mrs     x0, sctlr_el1
    ret

ROUTINE ArchWriteSystemControl
    msr     sctlr_el1, x0
    isb
    ret

// --- Exceptions and processor identity ---

ROUTINE ArchReadExceptionSyndrome
    mrs     x0, esr_el1
    ret

ROUTINE ArchReadFaultAddress
    mrs     x0, far_el1
    ret

ROUTINE ArchWriteVectorBase
    msr     vbar_el1, x0
    isb
    ret

ROUTINE ArchReadProcessorAffinity
    mrs     x0, mpidr_el1
    ret

ROUTINE ArchReadMainId
    mrs     x0, midr_el1
    ret

ROUTINE ArchReadInstructionSetAttributes0
    mrs     x0, id_aa64isar0_el1
    ret

ROUTINE ArchReadProcessorFeatures0
    mrs     x0, id_aa64pfr0_el1
    ret

ROUTINE ArchReadMemoryModelFeatures1
    mrs     x0, id_aa64mmfr1_el1
    ret

ROUTINE ArchReadCurrentLevel
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    ret

// --- The per-processor block (TPIDR_EL1) and the user thread pointer ---

ROUTINE ArchWriteProcessorBlock
    msr     tpidr_el1, x0
    ret

ROUTINE ArchReadProcessorBlock
    mrs     x0, tpidr_el1
    ret

// The running thread: offset 8 of the processor block, read with
// interrupts masked so the thread cannot move to another processor
// between finding the block and reading it.
ROUTINE ArchReadRunningThread
    mrs     x1, daif
    msr     daifset, #2
    mrs     x0, tpidr_el1
    ldr     x0, [x0, #8]
    msr     daif, x1
    ret

ROUTINE ArchWriteUserThreadPointer
    msr     tpidr_el0, x0
    ret

// --- The generic timer (the virtual counter and timer) ---

ROUTINE ArchReadCounter
    isb
    mrs     x0, cntvct_el0
    ret

ROUTINE ArchReadCounterFrequency
    mrs     x0, cntfrq_el0
    ret

ROUTINE ArchWriteTimerCompare
    msr     cntv_cval_el0, x0
    isb
    ret

ROUTINE ArchWriteTimerControl
    msr     cntv_ctl_el0, x0
    isb
    ret

ROUTINE ArchReadTimerControl
    mrs     x0, cntv_ctl_el0
    ret

// --- Random numbers (RNDR, FEAT_RNG; not on the Cortex-A72) ---

// x0 = where the value goes; returns 1 if it worked.
ROUTINE ArchReadRandomNumber
    mrs     x1, s3_3_c2_c4_0          // RNDR
    cset    x2, ne                    // NZCV.Z clear: a valid number
    str     x1, [x0]
    mov     x0, x2
    ret

// x0 = where the value goes; returns 1 if it worked.
ROUTINE ArchReadReseededRandomNumber
    mrs     x1, s3_3_c2_c4_1          // RNDRRS
    cset    x2, ne
    str     x1, [x0]
    mov     x0, x2
    ret

// --- Caches ---

// Cleans [x0, x0 + x1) to the point of coherency.
ROUTINE ArchCleanDataCache
    cbz     x1, 2f
    mrs     x3, ctr_el0
    ubfx    x3, x3, #16, #4
    mov     x2, #4
    lsl     x2, x2, x3
    sub     x3, x2, #1
    add     x1, x0, x1
    bic     x0, x0, x3
1:  dc      cvac, x0
    add     x0, x0, x2
    cmp     x0, x1
    b.lo    1b
    dsb     sy
2:  ret

// Makes code written to [x0, x0 + x1) through the data side visible to
// instruction fetches on every processor: cleans the data cache to the
// point of unification, then invalidates the instruction cache lines
// (by address: the instruction caches are physically indexed, so any
// mapping of the memory does).
ROUTINE ArchSynchronizeInstructionCache
    cbz     x1, 3f
    mrs     x3, ctr_el0
    add     x5, x0, x1
    ubfx    x4, x3, #16, #4               // DminLine: log2 of words
    mov     x2, #4
    lsl     x2, x2, x4
    sub     x6, x2, #1
    bic     x7, x0, x6
1:  dc      cvau, x7
    add     x7, x7, x2
    cmp     x7, x5
    b.lo    1b
    dsb     ish
    and     x4, x3, #0xF                  // IminLine
    mov     x2, #4
    lsl     x2, x2, x4
    sub     x6, x2, #1
    bic     x7, x0, x6
2:  ic      ivau, x7
    add     x7, x7, x2
    cmp     x7, x5
    b.lo    2b
    dsb     ish
    isb
3:  ret

ROUTINE ArchInvalidateInstructionCache
    dsb     ish
    ic      ialluis
    dsb     ish
    isb
    ret

// --- Firmware calls (PSCI, SMC calling convention) ---

// QWord ArchCallFirmwareHypervisor(Function, A1, A2, A3)
ROUTINE ArchCallFirmwareHypervisor
    hvc     #0
    ret

ROUTINE ArchCallFirmwareSecure
    smc     #0
    ret

// --- Semihosting (only when QEMU was started with it) ---

// x0 = operation, x1 = parameter block
ROUTINE ArchSemihostingCall
    hlt     #0xF000
    ret

// --- Registers of the caller ---

ROUTINE ArchReadStackPointer
    mov     x0, sp
    ret

ROUTINE ArchReadFramePointer
    mov     x0, x29
    ret
