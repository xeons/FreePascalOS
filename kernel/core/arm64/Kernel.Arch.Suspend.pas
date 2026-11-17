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
  Suspend to RAM on AArch64: not supported yet.

  QEMU's virt machine and the Raspberry Pi 4 have no ACPI S3; on AArch64
  machines that sleep, it is PSCI SYSTEM_SUSPEND, which would save this
  context (X19-X30, SP, the system registers) and resume at an entry
  point much like ArchSecondaryEntry. The ACPI sleep code never finds S3
  here, so these are never called.
}
unit Kernel.Arch.Suspend;

{$mode objfpc}

interface

type
  TArchSuspendContext = record
    Registers: array[0..15] of QWord;
  end;
  PArchSuspendContext = ^TArchSuspendContext;

{ 0 when saving, 1 when resumed. Call with interrupts disabled. }
function ArchSaveSuspendContext(var Context: TArchSuspendContext): QWord;
{ Never returns: the saving call returns again. }
procedure ArchResumeSuspendContext(var Context: TArchSuspendContext);

implementation

uses
  Kernel.Panic;

function ArchSaveSuspendContext(var Context: TArchSuspendContext): QWord;
begin
  Result := 0;
end;

procedure ArchResumeSuspendContext(var Context: TArchSuspendContext);
begin
  KernelPanicWithCode(PanicInitializationFailed, 'suspend to RAM is not supported on AArch64 yet', 0, 0, 0, 0);
end;

end.
