{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  Processor control for AArch64: interrupt masking (PSTATE.I), waiting
  for interrupts, TLB maintenance, the counter and system registers.

  The instructions themselves are in ProcessorInstructions.s (Free
  Pascal's AArch64 assembler reader does not know the system registers).
  Debug, SError and FIQ exceptions stay masked all the time; "interrupts"
  are IRQs, which the GIC delivers.
}
unit Kernel.Arch.Cpu;

{$mode objfpc}

interface

const
  { PSTATE.I in DAIF and SPSR: IRQs masked. }
  InterruptMaskBit = QWord(1) shl 7;

procedure DisableInterrupts;
procedure EnableInterrupts;
function InterruptsAreEnabled: Boolean;

{ Disables interrupts and reports whether they were enabled before, so
  the caller can put things back with RestoreInterrupts. }
function SaveAndDisableInterrupts: Boolean;
procedure RestoreInterrupts(WereEnabled: Boolean);

{ Waits for an interrupt (WFI). }
procedure HaltProcessor;

{ Enables interrupts and waits in one step, so an interrupt arriving
  between the two cannot be missed. }
procedure EnableInterruptsAndHalt;

{ Hint to the processor that the caller is in a spin-wait loop. }
procedure CpuRelax;

{ SErrors (asynchronous external aborts) are masked unless a driver
  opens a window around accesses that may raise one: then one is taken,
  and the kernel panics with its syndrome, instead of staying pending.
  Disabling first takes any error still in flight. Per thread (DAIF is
  saved with the thread). }
procedure EnableAsynchronousAborts;
procedure DisableAsynchronousAborts;

{ Invalidates the translation of one page on every processor (TLB
  maintenance is broadcast in hardware on AArch64). }
procedure InvalidateTlbEntry(VirtualAddress: QWord);
procedure FlushEntireTlb;

{ The generic timer's virtual counter (the same on every processor),
  standing in for x86's time stamp counter. }
function ReadTimeStampCounter: QWord;
function ReadCounterFrequency: QWord;
{ True if the processor has a random number instruction (RNDR). }
function HardwareRandomIsAvailable: Boolean;
{ A random number from RNDR; False if it failed (or is not there). }
function ReadHardwareRandom(out Value: QWord): Boolean;
{ A number from the generator just reseeded from its entropy source
  (RNDRRS), for seeding a generator; False if it failed or is not
  there. }
function ReadHardwareSeed(out Value: QWord): Boolean;

{ The caller's stack and frame pointers (the frame pointer leads to the
  frame record: the caller's caller's frame pointer, then its return
  address, as on x86-64). }
function ReadStackPointer: QWord; external name 'ArchReadStackPointer';
function ReadFramePointer: QWord; external name 'ArchReadFramePointer';

{ --- AArch64 specific --- }

procedure DataSynchronizationBarrier;
procedure DataMemoryBarrier;
procedure InstructionSynchronizationBarrier;
function ReadExceptionSyndrome: QWord;
function ReadFaultAddress: QWord;
function ReadProcessorAffinity: QWord;
function ReadMainId: QWord;
function ReadCurrentExceptionLevel: QWord;
procedure CleanDataCache(Address: Pointer; SizeInBytes: QWord);
procedure InvalidateInstructionCache;
{ Makes code just written to memory visible to instruction fetches (user
  code pages before they are mapped executable). }
procedure SynchronizeInstructionCache(Address: Pointer; SizeInBytes: QWord);

{ Firmware calls with the SMC calling convention (PSCI), by HVC or SMC. }
function CallFirmwareHypervisor(FunctionId, Argument1, Argument2, Argument3: QWord): QWord;
function CallFirmwareSecure(FunctionId, Argument1, Argument2, Argument3: QWord): QWord;

implementation

procedure ArchDisableInterrupts; external name 'ArchDisableInterrupts';
procedure ArchEnableInterrupts; external name 'ArchEnableInterrupts';
function ArchReadInterruptMask: QWord; external name 'ArchReadInterruptMask';
procedure ArchEnableInterruptsAndWait; external name 'ArchEnableInterruptsAndWait';
procedure ArchWaitForInterrupt; external name 'ArchWaitForInterrupt';
procedure ArchYield; external name 'ArchYield';
procedure ArchEnableAsynchronousAborts; external name 'ArchEnableAsynchronousAborts';
procedure ArchDisableAsynchronousAborts; external name 'ArchDisableAsynchronousAborts';
procedure ArchInvalidatePage(VirtualAddress: QWord); external name 'ArchInvalidatePage';
procedure ArchInvalidateAllPages; external name 'ArchInvalidateAllPages';
function ArchReadCounter: QWord; external name 'ArchReadCounter';
function ArchReadCounterFrequency: QWord; external name 'ArchReadCounterFrequency';
function ArchReadInstructionSetAttributes0: QWord; external name 'ArchReadInstructionSetAttributes0';
function ArchReadRandomNumber(Value: PQWord): QWord; external name 'ArchReadRandomNumber';
function ArchReadReseededRandomNumber(Value: PQWord): QWord; external name 'ArchReadReseededRandomNumber';
procedure ArchDataSynchronizationBarrier; external name 'ArchDataSynchronizationBarrier';
procedure ArchDataMemoryBarrier; external name 'ArchDataMemoryBarrier';
procedure ArchInstructionBarrier; external name 'ArchInstructionBarrier';
function ArchReadExceptionSyndrome: QWord; external name 'ArchReadExceptionSyndrome';
function ArchReadFaultAddress: QWord; external name 'ArchReadFaultAddress';
function ArchReadProcessorAffinity: QWord; external name 'ArchReadProcessorAffinity';
function ArchReadMainId: QWord; external name 'ArchReadMainId';
function ArchReadCurrentLevel: QWord; external name 'ArchReadCurrentLevel';
procedure ArchCleanDataCache(Address: Pointer; SizeInBytes: QWord); external name 'ArchCleanDataCache';
procedure ArchInvalidateInstructionCache; external name 'ArchInvalidateInstructionCache';
procedure ArchSynchronizeInstructionCache(Address: Pointer; SizeInBytes: QWord);
  external name 'ArchSynchronizeInstructionCache';
function ArchCallFirmwareHypervisor(FunctionId, Argument1, Argument2, Argument3: QWord): QWord;
  external name 'ArchCallFirmwareHypervisor';
function ArchCallFirmwareSecure(FunctionId, Argument1, Argument2, Argument3: QWord): QWord;
  external name 'ArchCallFirmwareSecure';

const
  { ID_AA64ISAR0_EL1.RNDR, bits 63-60. }
  RandomNumberFieldShift = 60;

procedure DisableInterrupts;
begin
  ArchDisableInterrupts;
end;

procedure EnableInterrupts;
begin
  ArchEnableInterrupts;
end;

function InterruptsAreEnabled: Boolean;
begin
  Result := (ArchReadInterruptMask and InterruptMaskBit) = 0;
end;

function SaveAndDisableInterrupts: Boolean;
begin
  Result := (ArchReadInterruptMask and InterruptMaskBit) = 0;
  ArchDisableInterrupts;
end;

procedure RestoreInterrupts(WereEnabled: Boolean);
begin
  if WereEnabled then
    ArchEnableInterrupts;
end;

procedure HaltProcessor;
begin
  ArchWaitForInterrupt;
end;

procedure EnableInterruptsAndHalt;
begin
  ArchEnableInterruptsAndWait;
end;

procedure CpuRelax;
begin
  ArchYield;
end;

procedure EnableAsynchronousAborts;
begin
  ArchEnableAsynchronousAborts;
end;

procedure DisableAsynchronousAborts;
begin
  ArchDisableAsynchronousAborts;
end;

procedure InvalidateTlbEntry(VirtualAddress: QWord);
begin
  ArchInvalidatePage(VirtualAddress);
end;

procedure FlushEntireTlb;
begin
  ArchInvalidateAllPages;
end;

function ReadTimeStampCounter: QWord;
begin
  Result := ArchReadCounter;
end;

function ReadCounterFrequency: QWord;
begin
  Result := ArchReadCounterFrequency;
end;

function HardwareRandomIsAvailable: Boolean;
begin
  Result := ((ArchReadInstructionSetAttributes0 shr RandomNumberFieldShift) and $F) <> 0;
end;

function ReadHardwareRandom(out Value: QWord): Boolean;
begin
  Value := 0;
  if not HardwareRandomIsAvailable then
    Exit(False);
  Result := ArchReadRandomNumber(@Value) <> 0;
end;

function ReadHardwareSeed(out Value: QWord): Boolean;
begin
  Value := 0;
  if not HardwareRandomIsAvailable then
    Exit(False);
  Result := ArchReadReseededRandomNumber(@Value) <> 0;
end;

procedure DataSynchronizationBarrier;
begin
  ArchDataSynchronizationBarrier;
end;

procedure DataMemoryBarrier;
begin
  ArchDataMemoryBarrier;
end;

procedure InstructionSynchronizationBarrier;
begin
  ArchInstructionBarrier;
end;

function ReadExceptionSyndrome: QWord;
begin
  Result := ArchReadExceptionSyndrome;
end;

function ReadFaultAddress: QWord;
begin
  Result := ArchReadFaultAddress;
end;

function ReadProcessorAffinity: QWord;
begin
  Result := ArchReadProcessorAffinity;
end;

function ReadMainId: QWord;
begin
  Result := ArchReadMainId;
end;

function ReadCurrentExceptionLevel: QWord;
begin
  Result := ArchReadCurrentLevel;
end;

procedure CleanDataCache(Address: Pointer; SizeInBytes: QWord);
begin
  ArchCleanDataCache(Address, SizeInBytes);
end;

procedure InvalidateInstructionCache;
begin
  ArchInvalidateInstructionCache;
end;

function CallFirmwareHypervisor(FunctionId, Argument1, Argument2, Argument3: QWord): QWord;
begin
  Result := ArchCallFirmwareHypervisor(FunctionId, Argument1, Argument2, Argument3);
end;

function CallFirmwareSecure(FunctionId, Argument1, Argument2, Argument3: QWord): QWord;
begin
  Result := ArchCallFirmwareSecure(FunctionId, Argument1, Argument2, Argument3);
end;

procedure SynchronizeInstructionCache(Address: Pointer; SizeInBytes: QWord);
begin
  ArchSynchronizeInstructionCache(Address, SizeInBytes);
end;

end.
