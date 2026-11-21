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
  AslrTest

  On the host: the kernel's random number generator core and the
  address space layouts it randomizes.

    * Kernel.ChaCha20 against the block function test vector of RFC 8439
      (section 2.3.2),
    * Processes.AddressLayout: the fixed layout of aslr=off is the old
      one; randomized layouts (many, from a deterministic generator, and
      from the extreme random numbers) keep every part in its window,
      page aligned, the windows apart from each other and below the main
      stack's guard, library places leaving room for the library, and
      the random parts actually vary.

  Prints every failed check and exits with 1 if there was one.
}
program AslrTest;

{$mode objfpc}

uses
  SysUtils,
  Kernel.ChaCha20,
  Processes.AddressLayout;

const
  LayoutRounds = 200000;
  DistinctRounds = 2000;
  LargestImage = QWord(64) * 1024 * 1024;

var
  Failures: Integer = 0;
  GeneratorState: QWord = $1E3779B97F4A7C15;
  ExtremeChoice: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    WriteLn('FAIL: ', What);
    Inc(Failures);
  end;
end;

{ --- ChaCha20 ---------------------------------------------------------- }

procedure TestChaChaVector;
const
  Expected: TChaChaBlock = (
    $E4E7F110, $15593BD1, $1FDD0F50, $C47120A3, $C7F4D1C7, $0368C033, $9AAA2204, $4E6CD4C3,
    $466482D2, $09AA9F07, $05D7C214, $A2028BD9, $D19C12B5, $B94E16DE, $E883D0CB, $4E3C50A2);
var
  Key: TChaChaKey;
  Nonce: TChaChaNonce;
  Block: TChaChaBlock;
  Index: Integer;
begin
  { Key bytes 00 01 02 ... 1f, nonce 00 00 00 09 00 00 00 4a 00 00 00 00,
    block counter 1, all as little endian words. }
  for Index := 0 to ChaChaKeyWords - 1 do
    Key[Index] := LongWord(4 * Index) or (LongWord(4 * Index + 1) shl 8) or (LongWord(4 * Index + 2) shl 16) or
      (LongWord(4 * Index + 3) shl 24);
  Nonce[0] := $09000000;
  Nonce[1] := $4A000000;
  Nonce[2] := 0;
  ChaChaBlock(Key, 1, Nonce, Block);
  for Index := 0 to ChaChaBlockWords - 1 do
    Check(Block[Index] = Expected[Index], Format('ChaCha20 RFC 8439 vector, word %d', [Index]));
end;

{ --- Layouts ----------------------------------------------------------- }

function NextRandom: QWord;
begin
  GeneratorState := GeneratorState xor (GeneratorState shl 13);
  GeneratorState := GeneratorState xor (GeneratorState shr 7);
  GeneratorState := GeneratorState xor (GeneratorState shl 17);
  Result := GeneratorState;
end;

function TestRandom(Limit: QWord): QWord;
begin
  Result := NextRandom mod Limit;
end;

{ The smallest or the largest number allowed, as ExtremeChoice says. }
function ExtremeRandom(Limit: QWord): QWord;
begin
  if ExtremeChoice = 0 then
    Result := 0
  else
    Result := Limit - 1;
end;

function IsPageAligned(Value: QWord): Boolean;
begin
  Result := (Value and (LayoutPageSize - 1)) = 0;
end;

procedure TestFixedLayout;
var
  Layout: TAddressLayout;
begin
  ChooseAddressLayout(False, @TestRandom, Layout);
  Check(not Layout.IsRandomized, 'aslr=off: not randomized');
  Check(Layout.ImageBase = $400000, 'aslr=off: program at 0x400000');
  Check(Layout.AllocationBase = $100000000000, 'aslr=off: allocations from 0x100000000000');
  Check(Layout.LibraryWindowStart = $7F0000000000, 'aslr=off: libraries from 0x7F0000000000');
  Check(Layout.StackTop = $7FFFFFFFF000, 'aslr=off: stack top 0x7FFFFFFFF000');
  Check(Layout.InitialStackOffset = 0, 'aslr=off: no initial stack offset');
  Check(Layout.LibraryWindowEnd = MainStackFloor(Layout), 'aslr=off: libraries end at the stack guard');
  Check(ChooseLibraryAddress(Layout, LayoutPageSize, @TestRandom) = Layout.LibraryWindowStart,
    'aslr=off: libraries one after another');
  Check(ChooseThreadMemoryAddress(Layout, @TestRandom) = Layout.AllocationBase,
    'aslr=off: thread stacks with the allocations');
  ChooseAddressLayout(True, nil, Layout);
  Check(not Layout.IsRandomized, 'no random source: the fixed layout');
end;

procedure CheckLayout(const Layout: TAddressLayout; const Context: string);
var
  LibraryLength: QWord;
  LibraryStart: QWord;
  ThreadStart: QWord;
begin
  Check(Layout.IsRandomized, Context + ': randomized');
  Check(IsPageAligned(Layout.ImageBase) and IsPageAligned(Layout.AllocationBase) and
    IsPageAligned(Layout.StackTop), Context + ': page aligned');
  Check((Layout.ImageBase >= RandomImageWindowStart) and
    (Layout.ImageBase + LargestImage <= FixedAllocationBase), Context + ': program in its window');
  Check((Layout.AllocationBase >= FixedAllocationBase) and
    (Layout.AllocationBase < FixedAllocationBase + RandomAllocationWindowPages * LayoutPageSize),
    Context + ': allocation base in its window');
  Check(Layout.AllocationBase < RandomStackWindowStart, Context + ': heap below the thread stacks');
  Check(RandomStackWindowStart + RandomStackWindowPages * LayoutPageSize <= AllocationAreaLimit,
    Context + ': thread stacks in the allocation area');
  Check((Layout.LibraryWindowStart >= AllocationAreaLimit) and
    (Layout.LibraryWindowEnd <= MainStackFloor(Layout)), Context + ': libraries between allocations and stack');
  Check((Layout.StackTop <= FixedStackTop) and (MainStackFloor(Layout) >= RandomLibraryWindowEnd),
    Context + ': main stack and its guard above the libraries');
  Check((Layout.InitialStackOffset mod 16 = 0) and (Layout.InitialStackOffset < LayoutPageSize),
    Context + ': initial stack offset');

  LibraryLength := (TestRandom(64 * 1024) + 1) * LayoutPageSize;
  LibraryStart := ChooseLibraryAddress(Layout, LibraryLength, @TestRandom);
  Check(IsPageAligned(LibraryStart) and (LibraryStart >= Layout.LibraryWindowStart) and
    (LibraryStart + LibraryLength <= Layout.LibraryWindowEnd), Context + ': a library fits where it is put');
  ThreadStart := ChooseThreadMemoryAddress(Layout, @TestRandom);
  Check(IsPageAligned(ThreadStart) and (ThreadStart >= RandomStackWindowStart) and
    (ThreadStart < AllocationAreaLimit), Context + ': thread memory in its window');
end;

procedure TestRandomLayouts;
var
  Layout: TAddressLayout;
  Round: Integer;
  Choice: Integer;
begin
  for Round := 1 to LayoutRounds do
  begin
    ChooseAddressLayout(True, @TestRandom, Layout);
    CheckLayout(Layout, Format('layout %d', [Round]));
    if Failures > 20 then
      Exit;
  end;
  for Choice := 0 to 1 do
  begin
    ExtremeChoice := Choice;
    ChooseAddressLayout(True, @ExtremeRandom, Layout);
    CheckLayout(Layout, Format('extreme layout %d', [ExtremeChoice]));
    Check(ChooseLibraryAddress(Layout, Layout.LibraryWindowEnd - Layout.LibraryWindowStart, @ExtremeRandom) =
      Layout.LibraryWindowStart, 'a library as large as the window goes at its start');
  end;
  Check(ChooseLibraryAddress(Layout, QWord(1) shl 46, @TestRandom) = Layout.LibraryWindowStart,
    'a library larger than the window goes at its start (and fails there)');
end;

{ Each random part takes many values: at least 99 % different in a few
  thousand layouts. }
procedure TestEntropy;
var
  Images: array of QWord;
  Allocations: array of QWord;
  Stacks: array of QWord;
  Layout: TAddressLayout;
  Round: Integer;

  function DistinctCount(var Values: array of QWord): Integer;
  var
    Index: Integer;
    Other: Integer;
    Seen: Boolean;
  begin
    Result := 0;
    for Index := 0 to High(Values) do
    begin
      Seen := False;
      for Other := 0 to Index - 1 do
        if Values[Other] = Values[Index] then
        begin
          Seen := True;
          Break;
        end;
      if not Seen then
        Inc(Result);
    end;
  end;

begin
  SetLength(Images, DistinctRounds);
  SetLength(Allocations, DistinctRounds);
  SetLength(Stacks, DistinctRounds);
  for Round := 0 to DistinctRounds - 1 do
  begin
    ChooseAddressLayout(True, @TestRandom, Layout);
    Images[Round] := Layout.ImageBase;
    Allocations[Round] := Layout.AllocationBase;
    Stacks[Round] := Layout.StackTop;
  end;
  Check(DistinctCount(Images) * 100 >= DistinctRounds * 99, 'program bases vary');
  Check(DistinctCount(Allocations) * 100 >= DistinctRounds * 99, 'allocation bases vary');
  Check(DistinctCount(Stacks) * 100 >= DistinctRounds * 99, 'stack tops vary');
end;

begin
  TestChaChaVector;
  TestFixedLayout;
  TestRandomLayouts;
  TestEntropy;
  if Failures > 0 then
  begin
    WriteLn('ASLR TEST FAILED: ', Failures, ' checks');
    Halt(1);
  end;
  WriteLn('ASLR TEST PASSED');
end.
