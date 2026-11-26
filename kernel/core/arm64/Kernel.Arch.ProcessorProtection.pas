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
  The processor's own protection of the kernel on AArch64.

  User pages are always privileged execute-never (PXN, set for every
  user mapping by Memory.Arch.PageTables): the kernel never runs user
  code, as SMEP gives on x86-64, on every processor.

  PAN (privileged access never, ARMv8.1; ID_AA64MMFR1_EL1.PAN) makes
  the processor refuse every kernel access to user pages, as SMAP does
  on x86-64: the user copy routines (UserAccess.s) clear PSTATE.PAN for
  the copy alone, so any other place that touched user memory faults at
  once. SCTLR_EL1.SPAN is cleared so every exception taken to EL1 sets
  PAN again, whatever the interrupted code had; the exception return
  restores the interrupted state. The Cortex-A72 (ARMv8.0: QEMU's
  default, the Raspberry Pi 4) has no PAN; the Cortex-A76 (Raspberry Pi
  5) and QEMU's "max" processor have it.
}
unit Kernel.Arch.ProcessorProtection;

{$mode objfpc}

interface

{ Turns the protections on (boot processor, once), and lets user mode
  do the cache maintenance code generated at run time needs. }
procedure EnableProcessorProtection;
{ The same on a processor that started (or woke) later. }
procedure EnableProcessorProtectionOnThisProcessor;

{ PAN is on (on every processor). }
function PrivilegedAccessNeverIsOn: Boolean;

implementation

uses
  Debug.Output;

const
  MemoryModelPanShift = 20;
  MemoryModelPanMask = QWord($F);
  { SCTLR_EL1.SPAN: when set, exceptions leave PSTATE.PAN alone. }
  SystemControlSetPanUnchanged = QWord(1) shl 23;
  { SCTLR_EL1.DZE, UCT and UCI: user mode may zero cache lines (DC ZVA),
    read the cache geometry (CTR_EL0) and clean and invalidate caches by
    address (DC CVAU, DC CIVAC, IC IVAU) - what a compiler at run time
    does to make freshly written code visible to instruction fetch (GCC's
    __clear_cache, LLVM's JIT for Mesa's llvmpipe), as Linux allows.
    Without them those instructions trap and the program dies of SIGILL. }
  SystemControlUserCacheZero = QWord(1) shl 14;
  SystemControlUserCacheType = QWord(1) shl 15;
  SystemControlUserCacheMaintenance = QWord(1) shl 26;
  SystemControlUserCacheAccess = SystemControlUserCacheZero or SystemControlUserCacheType or
    SystemControlUserCacheMaintenance;

var
  ArchPanEnabled: Byte; external name 'ArchPanEnabled';

function ArchReadMemoryModelFeatures1: QWord; external name 'ArchReadMemoryModelFeatures1';
function ArchReadSystemControl: QWord; external name 'ArchReadSystemControl';
procedure ArchWriteSystemControl(Value: QWord); external name 'ArchWriteSystemControl';
procedure ArchSetPrivilegedAccessNever; external name 'ArchSetPrivilegedAccessNever';

function ProcessorHasPrivilegedAccessNever: Boolean;
begin
  Result := ((ArchReadMemoryModelFeatures1 shr MemoryModelPanShift) and MemoryModelPanMask) <> 0;
end;

procedure SetPrivilegedAccessNeverHere;
begin
  ArchWriteSystemControl(ArchReadSystemControl and not SystemControlSetPanUnchanged);
  ArchSetPrivilegedAccessNever;
end;

procedure AllowUserCacheMaintenanceHere;
begin
  ArchWriteSystemControl(ArchReadSystemControl or SystemControlUserCacheAccess);
end;

procedure WriteProtectionSummary;
begin
  DebugBeginMessage;
  DebugWriteTag('cpu');
  DebugWrite('User pages never executable by the kernel (PXN)');
  if ArchPanEnabled <> 0 then
    DebugWriteLine(', PAN on: the kernel reaches user memory only through checked copies')
  else
    DebugWriteLine(', no PAN');
  DebugEndMessage;
end;

procedure EnableProcessorProtection;
begin
  AllowUserCacheMaintenanceHere;
  if ProcessorHasPrivilegedAccessNever then
  begin
    SetPrivilegedAccessNeverHere;
    ArchPanEnabled := 1;
  end;
  WriteProtectionSummary;
end;

procedure EnableProcessorProtectionOnThisProcessor;
begin
  AllowUserCacheMaintenanceHere;
  if ArchPanEnabled <> 0 then
    SetPrivilegedAccessNeverHere;
end;

function PrivilegedAccessNeverIsOn: Boolean;
begin
  Result := ArchPanEnabled <> 0;
end;

end.
