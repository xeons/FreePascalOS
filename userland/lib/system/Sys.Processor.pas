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
  What the processor is: its maker and its model name, as the processor
  itself tells them (the CPUID instruction, which every program may run).
}
unit Sys.Processor;

{$mode objfpc}
{$asmmode intel}

interface

const
  ProcessorVendorCapacity = 13;
  ProcessorModelCapacity = 49;

{ "GenuineIntel", "AuthenticAMD", ... (12 characters and #0). }
procedure GetProcessorVendor(Buffer: PChar);
{ The model name, such as "AMD Ryzen 7 5800X 8-Core Processor", with
  the spaces some processors pad it with taken away; empty if the
  processor does not tell it. Buffer holds ProcessorModelCapacity. }
procedure GetProcessorModel(Buffer: PChar);

implementation

type
  TCpuidRegisters = record
    Eax: LongWord;
    Ebx: LongWord;
    Ecx: LongWord;
    Edx: LongWord;
  end;

const
  FirstExtendedLeaf = $80000000;
  FirstModelLeaf = $80000002;
  LastModelLeaf = $80000004;

{ Runs CPUID for Leaf (sub-leaf 0) and stores what it gives in Registers. }
procedure RunCpuid(Leaf: LongWord; out Registers: TCpuidRegisters); assembler; nostackframe;
asm
  push rbx
  mov r8, rsi
  mov eax, edi
  xor ecx, ecx
  cpuid
  mov dword ptr [r8], eax
  mov dword ptr [r8 + 4], ebx
  mov dword ptr [r8 + 8], ecx
  mov dword ptr [r8 + 12], edx
  pop rbx
end;

procedure GetProcessorVendor(Buffer: PChar);
var
  Registers: TCpuidRegisters;
begin
  RunCpuid(0, Registers);
  Move(Registers.Ebx, Buffer[0], 4);
  Move(Registers.Edx, Buffer[4], 4);
  Move(Registers.Ecx, Buffer[8], 4);
  Buffer[12] := #0;
end;

{ Takes away the spaces before and after Buffer's text, and runs of
  spaces inside it. }
procedure TidySpaces(Buffer: PChar);
var
  ReadIndex: LongInt;
  WriteIndex: LongInt;
begin
  ReadIndex := 0;
  WriteIndex := 0;
  while Buffer[ReadIndex] <> #0 do
  begin
    if (Buffer[ReadIndex] <> ' ') or ((WriteIndex > 0) and (Buffer[WriteIndex - 1] <> ' ')) then
    begin
      Buffer[WriteIndex] := Buffer[ReadIndex];
      Inc(WriteIndex);
    end;
    Inc(ReadIndex);
  end;
  if (WriteIndex > 0) and (Buffer[WriteIndex - 1] = ' ') then
    Dec(WriteIndex);
  Buffer[WriteIndex] := #0;
end;

procedure GetProcessorModel(Buffer: PChar);
var
  Registers: TCpuidRegisters;
  Leaf: LongWord;
  Offset: LongInt;
begin
  Buffer[0] := #0;
  RunCpuid(FirstExtendedLeaf, Registers);
  if Registers.Eax < LastModelLeaf then
    Exit;
  Offset := 0;
  for Leaf := FirstModelLeaf to LastModelLeaf do
  begin
    RunCpuid(Leaf, Registers);
    Move(Registers, Buffer[Offset], SizeOf(Registers));
    Inc(Offset, SizeOf(Registers));
  end;
  Buffer[Offset] := #0;
  TidySpaces(Buffer);
end;

end.
