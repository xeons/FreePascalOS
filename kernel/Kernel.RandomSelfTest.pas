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
  Self test of the kernel's random numbers (Kernel.Random) and of the
  layouts of new address spaces (Processes.AddressLayout): no repeats
  among a few hundred numbers, every value of a small range drawn and
  none outside it, filled buffers that are not zero, and two address
  spaces made one after the other with their program, allocations and
  main stack in different places (the same with aslr=off), each in its
  window.
}
unit Kernel.RandomSelfTest;

{$mode objfpc}

interface

procedure RunRandomSelfTest;

implementation

uses
  Runtime.Memory,
  Kernel.Random,
  Kernel.SelfTest,
  Processes.AddressLayout,
  Processes.AddressSpace;

const
  SampleCount = 256;
  RangeSize = 10;
  RangeDraws = 2000;

procedure TestNumbers;
var
  Samples: array[0..SampleCount - 1] of QWord;
  Index: Integer;
  Other: Integer;
  Repeated: Boolean;
  Seen: array[0..RangeSize - 1] of Boolean;
  Value: QWord;
  InRange: Boolean;
  Buffer: array[0..63] of Byte;
  AnyNonzero: Boolean;
begin
  for Index := 0 to SampleCount - 1 do
    Samples[Index] := RandomQWord;
  Repeated := False;
  for Index := 0 to SampleCount - 1 do
    for Other := Index + 1 to SampleCount - 1 do
      if Samples[Index] = Samples[Other] then
        Repeated := True;
  Check(not Repeated, 'the random numbers repeat');

  for Index := 0 to RangeSize - 1 do
    Seen[Index] := False;
  InRange := True;
  for Index := 1 to RangeDraws do
  begin
    Value := RandomBelow(RangeSize);
    if Value >= RangeSize then
      InRange := False
    else
      Seen[Value] := True;
  end;
  Check(InRange, 'RandomBelow went out of its range');
  for Index := 0 to RangeSize - 1 do
    Check(Seen[Index], 'RandomBelow never gave one of its values');

  FillMemory(@Buffer[0], SizeOf(Buffer), 0);
  FillRandom(@Buffer[0], SizeOf(Buffer));
  AnyNonzero := False;
  for Index := 0 to High(Buffer) do
    if Buffer[Index] <> 0 then
      AnyNonzero := True;
  Check(AnyNonzero, 'FillRandom left the buffer zero');
end;

procedure TestLayouts;
var
  First: PAddressSpace;
  Second: PAddressSpace;
begin
  Check(CreateAddressSpace(First) = 0, 'could not make an address space');
  Check(CreateAddressSpace(Second) = 0, 'could not make a second address space');
  if AddressSpaceRandomizationIsOn then
  begin
    Check(First^.Layout.IsRandomized and Second^.Layout.IsRandomized, 'a layout is not randomized');
    Check((First^.Layout.ImageBase <> Second^.Layout.ImageBase) and
      (First^.Layout.AllocationBase <> Second^.Layout.AllocationBase) and
      (First^.Layout.StackTop <> Second^.Layout.StackTop), 'two address spaces have the same layout');
    Check((First^.Layout.ImageBase >= RandomImageWindowStart) and
      (First^.Layout.ImageBase < FixedAllocationBase) and
      (MainStackFloor(First^.Layout) >= RandomLibraryWindowEnd), 'a layout part is outside its window');
  end
  else
    Check((First^.Layout.ImageBase = FixedImageBase) and (Second^.Layout.StackTop = FixedStackTop),
      'aslr=off did not give the fixed layout');
  DestroyAddressSpace(First);
  DestroyAddressSpace(Second);
end;

procedure RunRandomSelfTest;
begin
  TestNumbers;
  TestLayouts;
  ReportPassed('random numbers and address space layouts');
end;

end.
