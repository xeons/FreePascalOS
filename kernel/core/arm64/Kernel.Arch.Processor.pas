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
  The boot processor on AArch64: its block, its exception vectors and
  what it is.

  A processor's id (the "APIC id" of the architecture independent code)
  is its affinity from MPIDR_EL1 (Aff2.Aff1.Aff0 in bits 23-0), the value
  the ACPI MADT lists for it and PSCI starts it by.
}
unit Kernel.Arch.Processor;

{$mode objfpc}

interface

procedure InitializeBootProcessor;
procedure WriteProcessorDescription;

{ The affinity of the executing processor (its id). }
function ReadInitialApicId: LongWord;

implementation

uses
  Kernel.Arch.Cpu,
  Kernel.Arch.DescriptorTables,
  Kernel.Arch.ProcessorBlock,
  Kernel.Processors,
  Kernel.Panic,
  Debug.Output;

const
  AffinityMask = $FFFFFF;

function ReadInitialApicId: LongWord;
begin
  Result := LongWord(ReadProcessorAffinity and AffinityMask);
end;

{ AArch64 integer division does not trap: the compiler checks and calls
  the System unit's fpc_divbyzero, which ends here. }
procedure PanicOnDivisionByZero;
begin
  KernelPanicWithCode(PanicUnhandledProcessorException, 'integer division by zero in the kernel', 0, 0, 0, 0);
end;

procedure InitializeBootProcessor;
var
  Processor: PProcessor;
begin
  DivisionByZeroHandler := @PanicOnDivisionByZero;
  Processor := InitializeBootProcessorBlock(ReadInitialApicId);
  InitializeBootDescriptorTables(Processor^.DescriptorTables);
  ArchSetProcessorBlock(Processor);
  MarkProcessorBlocksReady;
end;

function ImplementerName(Implementer: QWord): PChar;
begin
  case Implementer of
    $41: Result := 'ARM';
    $42: Result := 'Broadcom';
    $43: Result := 'Cavium';
    $51: Result := 'Qualcomm';
    $61: Result := 'Apple';
  else
    Result := 'unknown implementer';
  end;
end;

function PartName(Implementer, Part: QWord): PChar;
begin
  Result := nil;
  if Implementer <> $41 then
    Exit;
  case Part of
    $D03: Result := 'Cortex-A53';
    $D04: Result := 'Cortex-A35';
    $D05: Result := 'Cortex-A55';
    $D07: Result := 'Cortex-A57';
    $D08: Result := 'Cortex-A72';
    $D09: Result := 'Cortex-A73';
    $D0B: Result := 'Cortex-A76';
    $D0C: Result := 'Neoverse N1';
    $D40: Result := 'Neoverse V1';
    $D49: Result := 'Neoverse N2';
  end;
end;

procedure WriteProcessorDescription;
var
  MainId: QWord;
  Implementer: QWord;
  Part: QWord;
  Name: PChar;
begin
  MainId := ReadMainId;
  Implementer := (MainId shr 24) and $FF;
  Part := (MainId shr 4) and $FFF;
  Name := PartName(Implementer, Part);

  DebugBeginMessage;
  DebugWriteTag('cpu');
  if Name <> nil then
    DebugWrite(Name)
  else
  begin
    DebugWrite('part 0x');
    DebugWriteHex(Part, 3);
  end;
  DebugWrite(' r');
  DebugWriteDecimal((MainId shr 20) and $F);
  DebugWrite('p');
  DebugWriteDecimal(MainId and $F);
  DebugWrite(' (');
  DebugWrite(ImplementerName(Implementer));
  DebugWrite('), running at EL');
  DebugWriteDecimal(ReadCurrentExceptionLevel);
  DebugWriteLine('');
  DebugEndMessage;
end;

end.
