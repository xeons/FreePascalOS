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
// The GICv3 CPU interface's system registers (ICC_*_EL1), for Hal.GicV3
// and Kernel.Arch.PriorityLevel. They are written by their encodings,
// which every assembler takes:
//
//   ICC_PMR_EL1      S3_0_C4_C6_0     ICC_CTLR_EL1     S3_0_C12_C12_4
//   ICC_IAR1_EL1     S3_0_C12_C12_0   ICC_SRE_EL1      S3_0_C12_C12_5
//   ICC_EOIR1_EL1    S3_0_C12_C12_1   ICC_IGRPEN1_EL1  S3_0_C12_C12_7
//   ICC_BPR1_EL1     S3_0_C12_C12_3   ICC_SGI1R_EL1    S3_0_C12_C11_5

    .text
    .balign 4

.macro ROUTINE name
    .global \name
    .type \name, %function
\name:
.endm

// The system register interface on (SRE), with FIQ and IRQ bypass off.
// Returns ICC_SRE_EL1 as read back: SRE stays 0 where it cannot be
// used (a higher level keeps it off).
ROUTINE ArchEnableGicSystemRegisters
    mrs     x0, S3_0_C12_C12_5
    orr     x0, x0, #7
    msr     S3_0_C12_C12_5, x0
    isb
    mrs     x0, S3_0_C12_C12_5
    ret

ROUTINE ArchReadGicPriorityMask
    mrs     x0, S3_0_C4_C6_0
    ret

// The new mask holds for what follows (interrupts it now masks are not
// taken after the write; ones it unmasks are taken soon).
ROUTINE ArchWriteGicPriorityMask
    msr     S3_0_C4_C6_0, x0
    isb
    dsb     sy
    ret

// The INTID of the highest pending group 1 interrupt, now active.
ROUTINE ArchAcknowledgeGicInterrupt
    mrs     x0, S3_0_C12_C12_0
    dsb     sy
    ret

ROUTINE ArchEndGicInterrupt
    msr     S3_0_C12_C12_1, x0
    isb
    ret

ROUTINE ArchWriteGicBinaryPoint
    msr     S3_0_C12_C12_3, x0
    isb
    ret

ROUTINE ArchWriteGicControl
    msr     S3_0_C12_C12_4, x0
    isb
    ret

ROUTINE ArchWriteGicGroup1Enable
    msr     S3_0_C12_C12_7, x0
    isb
    ret

// Sends a software generated interrupt (the register's layout in
// Hal.GicV3). The barrier before makes the sender's memory writes
// visible to the target first.
ROUTINE ArchSendGicSoftwareInterrupt
    dsb     ishst
    msr     S3_0_C12_C11_5, x0
    isb
    ret
