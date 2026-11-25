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
  The AArch64 registers as the user back trace unwinds them
  (Processes.UserBackTrace): DWARF's numbering (x0-x30, then sp as 31;
  the return address is x30), with the program counter kept in slot 32.
}
unit Processes.Arch.UnwindRegisters;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame,
  Processes.CallFrameEntries;

procedure GetUnwindArchitecture(out Architecture: TCfiArchitecture);
{ The interrupted program's registers. }
procedure TakeUnwindRegisters(Frame: PTrapFrame; out Registers: TUnwindRegisters);

implementation

uses
  Runtime.Memory,
  Processes.CallFrameRules;

const
  StackPointerIndex = 31;
  ProgramCounterIndex = 32;

procedure GetUnwindArchitecture(out Architecture: TCfiArchitecture);
begin
  Architecture.RegisterCount := 32;
  Architecture.ReturnAddressColumn := 30;
  Architecture.StackPointerIndex := StackPointerIndex;
  Architecture.FramePointerIndex := 29;
  Architecture.ProgramCounterIndex := ProgramCounterIndex;
  Architecture.FramePointerAlignment := 16;
end;

procedure TakeUnwindRegisters(Frame: PTrapFrame; out Registers: TUnwindRegisters);
var
  Index: LongWord;
begin
  ZeroMemory(@Registers, SizeOf(Registers));
  for Index := 0 to 30 do
    SetRegister(Registers, Index, Frame^.X[Index]);
  SetRegister(Registers, StackPointerIndex, Frame^.Sp);
  SetRegister(Registers, ProgramCounterIndex, Frame^.Elr);
end;

end.
