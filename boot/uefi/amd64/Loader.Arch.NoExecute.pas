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
  The no-execute bit on x86-64, for the loader's page tables.

  A page table entry's bit 63 forbids instruction fetches, but only
  once EFER.NXE is set; without it the bit is reserved and a page that
  has it set faults on every access. So the loader turns NXE on (if the
  processor has it) before it builds tables that use the bit, and the
  kernel, which keeps running on those tables, finds it already on.
  Firmware that protects its own memory has usually set it already.
}
unit Loader.Arch.NoExecute;

{$mode objfpc}
{$asmmode intel}

interface

{ Turns EFER.NXE on when the processor supports the no-execute bit.
  Returns True if the bit may be used in page table entries. }
function EnableNoExecute: Boolean;

implementation

const
  CpuidExtendedMaximum = $80000000;
  CpuidExtendedFeatures = $80000001;
  CpuidExtendedEdxNoExecute = LongWord(1) shl 20;
  EferNoExecuteEnable = QWord(1) shl 11;

{ The loader uses the Microsoft x64 convention: the first argument is in
  RCX, the result in RAX. CPUID overwrites RBX, which is preserved. }
function CpuidEax(Leaf: LongWord): LongWord; assembler; nostackframe;
asm
  push rbx
  mov eax, ecx
  xor ecx, ecx
  cpuid
  pop rbx
end;

function CpuidEdx(Leaf: LongWord): LongWord; assembler; nostackframe;
asm
  push rbx
  mov eax, ecx
  xor ecx, ecx
  cpuid
  mov eax, edx
  pop rbx
end;

{ EFER is model specific register C0000080h. }
function ReadExtendedFeatureEnable: QWord; assembler; nostackframe;
asm
  mov ecx, $C0000080
  rdmsr
  shl rdx, 32
  or rax, rdx
end;

procedure WriteExtendedFeatureEnable(Value: QWord); assembler; nostackframe;
asm
  mov rax, rcx
  mov rdx, rcx
  shr rdx, 32
  mov ecx, $C0000080
  wrmsr
end;

function EnableNoExecute: Boolean;
var
  Efer: QWord;
begin
  Result := False;
  if CpuidEax(CpuidExtendedMaximum) < CpuidExtendedFeatures then
    Exit;
  if (CpuidEdx(CpuidExtendedFeatures) and CpuidExtendedEdxNoExecute) = 0 then
    Exit;
  Efer := ReadExtendedFeatureEnable;
  if (Efer and EferNoExecuteEnable) = 0 then
    WriteExtendedFeatureEnable(Efer or EferNoExecuteEnable);
  Result := True;
end;

end.
