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
  Saving a processor's state across suspend to RAM on AArch64 (PSCI
  SYSTEM_SUSPEND, Hal.Platform).

  ArchSaveSuspendContext works like setjmp (SuspendContext.s): it saves
  the callee-saved registers X19-X30, the stack pointer, DAIF, the user
  thread pointer (TPIDR_EL0), the priority level (the GIC's priority
  mask) and the floating point and SIMD registers, then returns 0. Those
  last ones belong to the thread the processor froze in the middle of
  (it freezes in its dispatch interrupt, and the kernel saves them only
  at a thread switch); turned off, the processor would lose them. ArchResumeSuspendContext, on the same
  processor after it was woken through the start-up entry
  (Kernel.Arch.ProcessorStartup: translation, vectors, then
  ReinitializeThisProcessor and the HAL), puts the level back and
  returns from the saving call a second time, with 1. Memory survives,
  so the stack the context points into is still there. As on x86-64 the
  level matters: a secondary processor froze inside its dispatch
  interrupt, at dispatch level, and goes on from there.

  A frozen processor turns itself off (PSCI CPU_OFF) rather than wait:
  SYSTEM_SUSPEND requires every other processor to be off, and they are
  started again with CPU_ON. Should the firmware refuse CPU_OFF, the
  processor stays on and ArchParkFrozenProcessor returns: it then waits
  to be let go in place (Kernel.ProcessorPower), and SYSTEM_SUSPEND
  fails, as it must with a processor still on.
}
unit Kernel.Arch.Suspend;

{$mode objfpc}

interface

type
  TArchSuspendContext = record
    { X19-X30, SP, DAIF, the priority level, TPIDR_EL0. }
    Registers: array[0..15] of QWord;
    { V0-V31, FPCR and FPSR (ArchSaveFpuState's 528 bytes, 16-byte
      aligned: the area is found inside). }
    FpuArea: array[0..543] of Byte;
  end;
  PArchSuspendContext = ^TArchSuspendContext;

{ 0 when saving, 1 when resumed. Call with interrupts disabled. }
function ArchSaveSuspendContext(var Context: TArchSuspendContext): QWord; external name 'ArchSaveSuspendRegisters';
{ Never returns: the saving call returns again. }
procedure ArchResumeSuspendContext(var Context: TArchSuspendContext);
{ Where a frozen processor waits for the machine to sleep: off. Returns
  only if the firmware refused to turn it off (it is still on, with its
  state intact). }
procedure ArchParkFrozenProcessor;

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.Arch.PriorityLevel,
  Hal.Psci;

const
  LevelIndex = 14;

procedure ArchResumeSuspendRegisters(var Context: TArchSuspendContext); external name 'ArchResumeSuspendRegisters';
procedure ArchRestoreFpuState(Area: Pointer); external name 'ArchRestoreFpuState';

{ Where SuspendContext.s saved them. }
function FpuAreaOf(var Context: TArchSuspendContext): Pointer;
begin
  Result := Pointer((PtrUInt(@Context.FpuArea[0]) + 15) and not PtrUInt(15));
end;

procedure ArchNoteSuspendLevel(var Context: TArchSuspendContext); [public, alias: 'ArchNoteSuspendLevel'];
begin
  Context.Registers[LevelIndex] := ArchGetPriorityLevel;
end;

procedure ArchResumeSuspendContext(var Context: TArchSuspendContext);
begin
  ArchSetPriorityLevel(Byte(Context.Registers[LevelIndex]));
  ArchRestoreFpuState(FpuAreaOf(Context));
  ArchResumeSuspendRegisters(Context);
end;

procedure ArchParkFrozenProcessor;
begin
  DataSynchronizationBarrier;
  PsciTurnOffThisProcessor;
  { The firmware refused: the caller waits in place. }
end;

end.
