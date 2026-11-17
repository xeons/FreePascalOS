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
  What the processor is, as it tells it on AArch64: the Main ID Register
  (MIDR_EL1: implementer, variant, part number, revision), which user
  mode cannot read, decoded into the implementer's name and the part's
  (CallGetProcessorDescription). Parts not in the table are given by
  number.
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
  Runtime.Text,
  Kernel.Arch.Cpu;

type
  TNamedPart = record
    Part: Word;
    Name: PChar;
  end;

const
  ImplementerArm = $41;

  Implementers: array[0..9] of TNamedPart = (
    (Part: $41; Name: 'ARM'),
    (Part: $42; Name: 'Broadcom'),
    (Part: $43; Name: 'Cavium'),
    (Part: $46; Name: 'Fujitsu'),
    (Part: $48; Name: 'HiSilicon'),
    (Part: $4E; Name: 'NVIDIA'),
    (Part: $51; Name: 'Qualcomm'),
    (Part: $61; Name: 'Apple'),
    (Part: $6D; Name: 'Microsoft'),
    (Part: $C0; Name: 'Ampere'));

  { ARM's own designs. }
  ArmParts: array[0..19] of TNamedPart = (
    (Part: $D03; Name: 'Cortex-A53'),
    (Part: $D04; Name: 'Cortex-A35'),
    (Part: $D05; Name: 'Cortex-A55'),
    (Part: $D07; Name: 'Cortex-A57'),
    (Part: $D08; Name: 'Cortex-A72'),
    (Part: $D09; Name: 'Cortex-A73'),
    (Part: $D0A; Name: 'Cortex-A75'),
    (Part: $D0B; Name: 'Cortex-A76'),
    (Part: $D0C; Name: 'Neoverse-N1'),
    (Part: $D0D; Name: 'Cortex-A77'),
    (Part: $D40; Name: 'Neoverse-V1'),
    (Part: $D41; Name: 'Cortex-A78'),
    (Part: $D44; Name: 'Cortex-X1'),
    (Part: $D46; Name: 'Cortex-A510'),
    (Part: $D47; Name: 'Cortex-A710'),
    (Part: $D48; Name: 'Cortex-X2'),
    (Part: $D49; Name: 'Neoverse-N2'),
    (Part: $D4B; Name: 'Cortex-A78C'),
    (Part: $D4D; Name: 'Cortex-A715'),
    (Part: $D4E; Name: 'Cortex-X3'));

function FindName(const Table: array of TNamedPart; Part: Word): PChar;
var
  Index: Integer;
begin
  for Index := 0 to High(Table) do
    if Table[Index].Part = Part then
      Exit(Table[Index].Name);
  Result := nil;
end;

{ Appends Text to the #0-terminated text in Destination. }
procedure AppendText(Destination: PChar; Text: PChar);
var
  Length: PtrUInt;
begin
  Length := TextLength(Destination);
  if Length + 1 < AbiTextCapacity then
    CopyText(Destination + Length, Text, AbiTextCapacity - Length);
end;

procedure DescribeProcessor(out Description: TAbiProcessorDescription);
var
  MainId: QWord;
  Implementer: Word;
  Part: Word;
  Name: PChar;
  Number: TNumberText;
begin
  ZeroMemory(@Description, SizeOf(Description));
  MainId := ReadMainId;
  Description.Identification := MainId;
  Implementer := Word((MainId shr 24) and $FF);
  Part := Word((MainId shr 4) and $FFF);

  Name := FindName(Implementers, Implementer);
  if Name <> nil then
    CopyText(@Description.Vendor[0], Name, AbiTextCapacity)
  else
  begin
    CopyText(@Description.Vendor[0], 'implementer 0x', AbiTextCapacity);
    AppendText(@Description.Vendor[0], FormatHexadecimal(Implementer, 2, Number));
  end;

  Name := nil;
  if Implementer = ImplementerArm then
    Name := FindName(ArmParts, Part);
  if Name <> nil then
    CopyText(@Description.Model[0], Name, AbiTextCapacity)
  else
  begin
    CopyText(@Description.Model[0], 'part 0x', AbiTextCapacity);
    AppendText(@Description.Model[0], FormatHexadecimal(Part, 3, Number));
  end;
  { The variant and revision: r0p3. }
  AppendText(@Description.Model[0], ' r');
  AppendText(@Description.Model[0], FormatDecimal((MainId shr 20) and $F, Number));
  AppendText(@Description.Model[0], 'p');
  AppendText(@Description.Model[0], FormatDecimal(MainId and $F, Number));
end;

function MachineArchitectureName: PChar;
begin
  Result := 'aarch64';
end;

end.
