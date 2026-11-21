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
  thread pointer (TPIDR_EL0) and the priority level (the GIC's priority
  mask), then returns 0. ArchResumeSuspendContext, on the same
  processor after it was woken through the start-up entry
  (Kernel.Arch.ProcessorStartup: translation, vectors, then
  ReinitializeThisProcessor and the HAL), puts the level back and
  returns from the saving call a second time, with 1. Memory survives,
  so the stack the context points into is still there. As on x86-64 the
  level matters: a secondary processor froze inside its dispatch
  interrupt, at dispatch level, and goes on from there.

  A frozen processor turns itself off (PSCI CPU_OFF) rather than wait:
  SYSTEM_SUSPEND requires every other processor to be off, and they are
  started again with CPU_ON.
}
unit Kernel.Arch.Suspend;

{$mode objfpc}

interface

type
  TArchSuspendContext = record
    { X19-X30, SP, DAIF, the priority level, TPIDR_EL0. }
    Registers: array[0..15] of QWord;
  end;
  PArchSuspendContext = ^TArchSuspendContext;

{ 0 when saving, 1 when resumed. Call with interrupts disabled. }
function ArchSaveSuspendContext(var Context: TArchSuspendContext): QWord; external name 'ArchSaveSuspendRegisters';
{ Never returns: the saving call returns again. }
procedure ArchResumeSuspendContext(var Context: TArchSuspendContext);
{ Where a frozen processor waits for the machine to sleep: off. }
procedure ArchParkFrozenProcessor;

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.Arch.PriorityLevel,
  Hal.Psci;

const
  LevelIndex = 14;

procedure ArchResumeSuspendRegisters(var Context: TArchSuspendContext); external name 'ArchResumeSuspendRegisters';

procedure ArchNoteSuspendLevel(var Context: TArchSuspendContext); [public, alias: 'ArchNoteSuspendLevel'];
begin
  Context.Registers[LevelIndex] := ArchGetPriorityLevel;
end;

procedure ArchResumeSuspendContext(var Context: TArchSuspendContext);
begin
  ArchSetPriorityLevel(Byte(Context.Registers[LevelIndex]));
  ArchResumeSuspendRegisters(Context);
end;

procedure ArchParkFrozenProcessor;
begin
  DataSynchronizationBarrier;
  PsciTurnOffThisProcessor;
  { The firmware refused: wait here until started again. }
  while True do
    HaltProcessor;
end;

end.
