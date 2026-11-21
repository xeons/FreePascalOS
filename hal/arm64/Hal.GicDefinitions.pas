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
  What both GIC versions share: the INTID ranges, the software generated
  interrupts the kernel uses and their vectors, and the vector table of
  the INTIDs up to 1019 (the LPIs of GICv3 have one of their own,
  Hal.GicV3Its).
}
unit Hal.GicDefinitions;

{$mode objfpc}

interface

const
  SoftwareInterruptDispatch = 0;
  SoftwareInterruptRequest = 1;
  SoftwareInterruptStop = 2;
  FirstPrivatePeripheralInterrupt = 16;
  FirstSharedInterrupt = 32;
  { INTIDs 1020-1023 are special (1023: nothing pending). }
  MaximumInterrupts = 1020;
  SpuriousInterruptId = 1023;

type
  TInterruptVectorTable = array[0..MaximumInterrupts - 1] of Byte;

{ Every INTID without a vector, but the kernel's three SGIs. }
procedure ResetInterruptVectorTable(out Table: TInterruptVectorTable);

implementation

uses
  Hal.InterruptVectors;

procedure ResetInterruptVectorTable(out Table: TInterruptVectorTable);
var
  Index: LongWord;
begin
  for Index := 0 to MaximumInterrupts - 1 do
    Table[Index] := SpuriousInterruptVector;
  Table[SoftwareInterruptDispatch] := DispatchInterruptVector;
  Table[SoftwareInterruptRequest] := InterProcessorInterruptVector;
  Table[SoftwareInterruptStop] := InterProcessorInterruptVector + 1;
end;

end.
