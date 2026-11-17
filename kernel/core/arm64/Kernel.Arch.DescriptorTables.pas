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
  The per-processor tables of AArch64.

  AArch64 has no descriptor tables: a processor's only table is its
  exception vector base (VBAR_EL1), which all of them point at the one
  vector table (ExceptionVectors.s). Exceptions always run on SP_EL1,
  the running thread's kernel stack, so there are no separate interrupt
  stacks either; the record and the stack area exist so the
  architecture independent processor code is the same for both.
}
unit Kernel.Arch.DescriptorTables;

{$mode objfpc}

interface

const
  { Unused on AArch64 (kept small, see above). }
  InterruptStackAreaSize = 4096;

type
  TProcessorDescriptorTables = record
    VectorBase: QWord;
  end;

{ Points the boot processor at the exception vectors. }
procedure InitializeBootDescriptorTables(var Tables: TProcessorDescriptorTables);
{ The same for another processor; StackArea is not needed. }
procedure InitializeDescriptorTables(var Tables: TProcessorDescriptorTables; StackArea: Pointer);
procedure ReloadDescriptorTables(var Tables: TProcessorDescriptorTables);
{ Nothing to do: see Kernel.Arch.ContextSwitch.ArchSetThreadInterruptStack. }
procedure SetInterruptKernelStack(StackTop: QWord);

implementation

procedure ArchExceptionVectors; external name 'ArchExceptionVectors';
procedure ArchWriteVectorBase(Base: QWord); external name 'ArchWriteVectorBase';

procedure InitializeBootDescriptorTables(var Tables: TProcessorDescriptorTables);
begin
  Tables.VectorBase := QWord(@ArchExceptionVectors);
  ArchWriteVectorBase(Tables.VectorBase);
end;

procedure InitializeDescriptorTables(var Tables: TProcessorDescriptorTables; StackArea: Pointer);
begin
  InitializeBootDescriptorTables(Tables);
end;

procedure ReloadDescriptorTables(var Tables: TProcessorDescriptorTables);
begin
  ArchWriteVectorBase(Tables.VectorBase);
end;

procedure SetInterruptKernelStack(StackTop: QWord);
begin
end;

end.
