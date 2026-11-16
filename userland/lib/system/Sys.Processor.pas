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

{$mode objfpc}{$H+}
{$asmmode intel}

interface

{ "GenuineIntel", "AuthenticAMD", ... (12 characters). }
function ProcessorVendor: string;
{ The model name, such as "AMD Ryzen 7 5800X 8-Core Processor", with
  the spaces some processors pad it with taken away; empty if the
  processor does not tell it. }
function ProcessorModel: string;

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

function ProcessorVendor: string;
var
  Registers: TCpuidRegisters;
begin
  RunCpuid(0, Registers);
  SetLength(Result, 12);
  Move(Registers.Ebx, Result[1], 4);
  Move(Registers.Edx, Result[5], 4);
  Move(Registers.Ecx, Result[9], 4);
  { A processor that leaves bytes zero ends the name there. }
  SetLength(Result, StrLen(PChar(Result)));
end;

{ Text without the spaces before and after it, and with runs of spaces
  inside it made one. }
function TidySpaces(const Text: string): string;
var
  Character: Char;
begin
  Result := '';
  for Character in Text do
    if (Character <> ' ') or ((Result <> '') and (Result[Length(Result)] <> ' ')) then
      Result := Result + Character;
  if (Result <> '') and (Result[Length(Result)] = ' ') then
    SetLength(Result, Length(Result) - 1);
end;

function ProcessorModel: string;
var
  Registers: TCpuidRegisters;
  Leaf: LongWord;
  Name: string;
begin
  Result := '';
  RunCpuid(FirstExtendedLeaf, Registers);
  if Registers.Eax < LastModelLeaf then
    Exit;
  Name := '';
  for Leaf := FirstModelLeaf to LastModelLeaf do
  begin
    RunCpuid(Leaf, Registers);
    SetLength(Name, Length(Name) + SizeOf(Registers));
    Move(Registers, Name[Length(Name) - SizeOf(Registers) + 1], SizeOf(Registers));
  end;
  { The name ends at its first zero byte. }
  SetLength(Name, StrLen(PChar(Name)));
  Result := TidySpaces(Name);
end;

end.
