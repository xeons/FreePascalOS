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
  Telling apart the two kinds of general protection fault in user mode.

  The processor raises the same exception (13) for an instruction user
  mode may not run (hlt, cli, in, out, a control register move, ...)
  and for a memory access through a non-canonical address - such as a
  pointer read from freed memory, which heap checking fills with
  $DFDFDFDFDFDFDFDF. The first is a privileged instruction, the second
  an access violation like any bad pointer, so the faulting instruction
  is looked at: only the privileged instructions below are reported as
  such.
}
unit Kernel.Arch.PrivilegedInstructions;

{$mode objfpc}
{$pointermath on}

interface

const
  { The longest x86 instruction. }
  LongestInstruction = 15;

{ True if the Count bytes at Instruction start with an instruction that
  only the kernel may run (or that needs I/O privilege). }
function IsPrivilegedInstruction(Instruction: PByte; Count: Integer): Boolean;

implementation

const
  OpcodeTwoByteEscape = $0F;

function IsPrefix(Value: Byte): Boolean;
begin
  case Value of
    $66, $67, $F0, $F2, $F3, $2E, $36, $3E, $26, $64, $65, $40..$4F:
      Result := True;
  else
    Result := False;
  end;
end;

function IsPrivilegedOneByteOpcode(Opcode: Byte): Boolean;
begin
  case Opcode of
    { hlt, cli, sti }
    $F4, $FA, $FB,
    { in, out, ins, outs }
    $E4..$E7, $EC..$EF, $6C..$6F:
      Result := True;
  else
    Result := False;
  end;
end;

{ Opcode is the byte after $0F; ModRM the byte after it (if any). }
function IsPrivilegedTwoByteOpcode(Opcode: Byte; HasModRM: Boolean; ModRM: Byte): Boolean;
var
  RegisterField: Byte;
begin
  case Opcode of
    { lldt, ltr (and the other descriptor table loads) }
    $00:
      begin
        RegisterField := (ModRM shr 3) and 7;
        Result := HasModRM and (RegisterField in [2, 3]);
      end;
    { lgdt, lidt, lmsw, invlpg, swapgs, monitor, mwait, ... }
    $01:
      begin
        RegisterField := (ModRM shr 3) and 7;
        Result := HasModRM and (RegisterField in [1, 2, 3, 6, 7]);
      end;
    { clts, sysret, invd, wbinvd }
    $06, $07, $08, $09,
    { moves to and from control and debug registers }
    $20..$23,
    { wrmsr, rdmsr, rdpmc, sysexit }
    $30, $32, $33, $35:
      Result := True;
  else
    Result := False;
  end;
end;

function IsPrivilegedInstruction(Instruction: PByte; Count: Integer): Boolean;
var
  Index: Integer;
begin
  Result := False;
  Index := 0;
  while (Index < Count) and IsPrefix(Instruction[Index]) do
    Inc(Index);
  if Index >= Count then
    Exit;
  if Instruction[Index] <> OpcodeTwoByteEscape then
    Exit(IsPrivilegedOneByteOpcode(Instruction[Index]));
  if Index + 1 >= Count then
    Exit;
  if Index + 2 < Count then
    Result := IsPrivilegedTwoByteOpcode(Instruction[Index + 1], True, Instruction[Index + 2])
  else
    Result := IsPrivilegedTwoByteOpcode(Instruction[Index + 1], False, 0);
end;

end.
