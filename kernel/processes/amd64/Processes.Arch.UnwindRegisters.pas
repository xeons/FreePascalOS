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
  The x86-64 registers as the user back trace unwinds them
  (Processes.UserBackTrace): DWARF's numbering (RAX, RDX, RCX, RBX, RSI,
  RDI, RBP, RSP, R8-R15, then the return address column 16, which holds
  the program counter).
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
  RegisterCount = 17;
  ReturnAddressColumn = 16;

procedure GetUnwindArchitecture(out Architecture: TCfiArchitecture);
begin
  Architecture.RegisterCount := RegisterCount;
  Architecture.ReturnAddressColumn := ReturnAddressColumn;
  Architecture.StackPointerIndex := 7;
  Architecture.FramePointerIndex := 6;
  Architecture.ProgramCounterIndex := ReturnAddressColumn;
  Architecture.FramePointerAlignment := 8;
end;

procedure TakeUnwindRegisters(Frame: PTrapFrame; out Registers: TUnwindRegisters);
begin
  ZeroMemory(@Registers, SizeOf(Registers));
  SetRegister(Registers, 0, Frame^.Rax);
  SetRegister(Registers, 1, Frame^.Rdx);
  SetRegister(Registers, 2, Frame^.Rcx);
  SetRegister(Registers, 3, Frame^.Rbx);
  SetRegister(Registers, 4, Frame^.Rsi);
  SetRegister(Registers, 5, Frame^.Rdi);
  SetRegister(Registers, 6, Frame^.Rbp);
  SetRegister(Registers, 7, Frame^.Rsp);
  SetRegister(Registers, 8, Frame^.R8);
  SetRegister(Registers, 9, Frame^.R9);
  SetRegister(Registers, 10, Frame^.R10);
  SetRegister(Registers, 11, Frame^.R11);
  SetRegister(Registers, 12, Frame^.R12);
  SetRegister(Registers, 13, Frame^.R13);
  SetRegister(Registers, 14, Frame^.R14);
  SetRegister(Registers, 15, Frame^.R15);
  SetRegister(Registers, ReturnAddressColumn, Frame^.Rip);
end;

end.
