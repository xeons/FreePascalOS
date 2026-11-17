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
  What the processor is, as it tells it on x86-64: the vendor string of
  CPUID leaf 0, the brand string of leaves 8000_0002h-8000_0004h, and the
  family, model and stepping of leaf 1 (CallGetProcessorDescription).
}
unit Kernel.Arch.ProcessorIdentity;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

procedure DescribeProcessor(out Description: TAbiProcessorDescription);

{ The name of the processor architecture, as uname -m prints it. }
function MachineArchitectureName: PChar;

implementation

uses
  Runtime.Memory,
  Kernel.Arch.Cpu;

const
  FirstExtendedLeaf = $80000000;
  FirstModelLeaf = $80000002;
  LastModelLeaf = $80000004;

procedure DescribeProcessor(out Description: TAbiProcessorDescription);
var
  Registers: TCpuidResult;
  Leaf: LongWord;
  Offset: Integer;
begin
  ZeroMemory(@Description, SizeOf(Description));
  ExecuteCpuid(0, 0, Registers);
  CopyMemory(@Description.Vendor[0], @Registers.Ebx, 4);
  CopyMemory(@Description.Vendor[4], @Registers.Edx, 4);
  CopyMemory(@Description.Vendor[8], @Registers.Ecx, 4);

  ExecuteCpuid(1, 0, Registers);
  Description.Identification := Registers.Eax;

  ExecuteCpuid(FirstExtendedLeaf, 0, Registers);
  if Registers.Eax < LastModelLeaf then
    Exit;
  Offset := 0;
  for Leaf := FirstModelLeaf to LastModelLeaf do
  begin
    ExecuteCpuid(Leaf, 0, Registers);
    CopyMemory(@Description.Model[Offset], @Registers, SizeOf(Registers));
    Inc(Offset, SizeOf(Registers));
  end;
end;

function MachineArchitectureName: PChar;
begin
  Result := 'x86_64';
end;

end.
