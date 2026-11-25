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
  Address space layout randomization: where the parts of a new user
  address space go.

  Without randomization (the kernel option aslr=off) every process has
  the same layout:

    0000_0000_0040_0000   program image
    0000_1000_0000_0000   run time allocations (heap chunks, thread stacks
                          and thread data, mappings), first fit upwards
    0000_7F00_0000_0000   shared libraries, one after another
    0000_7FFF_FFFF_F000   top of the main stack

  With it, each process gets its own, every part in a window of its own
  so they stay out of each other's way and each keeps room to grow:

    program image     a random page in [1 TiB, 2 TiB)           28 bits
    allocations       first fit from a random page of
                      [16 TiB, 17 TiB) upwards                  28 bits
    thread stacks     first fit from a random page of
    and thread data   [48 TiB, 64 TiB), chosen per thread       32 bits
    each library      a random page of [126 TiB, 127 TiB)       28 bits
                      (kept for every process unless aslr=process:
                      Processes.ImageLoader.PlaceLibrary)
    main stack top    a random page of the 64 GiB below
                      0000_7FFF_FFFF_F000, and the initial
                      stack pointer a random 16 bytes in a page 24+8 bits

  (bits of entropy, in pages of 4 KiB). All of it lies in the lower half
  of the 47-bit user space both processors have, below the main stack's
  guard. A range that does not fit above its random start is looked for
  from the start of its window instead, so randomization never makes
  memory run out sooner.

  Plain Pascal: the random numbers come from the caller (Kernel.Random in
  the kernel), so the host test (tools/AslrTest) checks the layouts.
}
unit Processes.AddressLayout;

{$mode objfpc}

interface

const
  LayoutPageSize = 4096;

  { The fixed layout (aslr=off). }
  FixedImageBase = QWord($0000000000400000);
  FixedAllocationBase = QWord($0000100000000000);
  FixedLibraryBase = QWord($00007F0000000000);
  FixedStackTop = QWord($00007FFFFFFFF000);

  { Run time allocations end where the randomized libraries begin. }
  AllocationAreaLimit = QWord($00007E0000000000);

  { The windows of the randomized layout. }
  RandomImageWindowStart = QWord($0000010000000000);
  RandomImageWindowPages = QWord(1) shl 28;
  RandomAllocationWindowPages = QWord(1) shl 28;
  RandomStackWindowStart = QWord($0000300000000000);
  RandomStackWindowPages = QWord(1) shl 32;
  RandomLibraryWindowStart = QWord($00007E0000000000);
  RandomLibraryWindowEnd = QWord($00007F0000000000);
  RandomStackTopPages = QWord(1) shl 24;
  InitialStackSlots = LayoutPageSize div 16;

  { The main stack's reserve, and the guard below it: nothing else may
    come closer to the stack top than this. }
  MainStackReserve = QWord(8) * 1024 * 1024;
  MainStackGuard = QWord(256) * 1024 * 1024;

type
  { A random number from 0 to Limit - 1. }
  TLayoutRandom = function(Limit: QWord): QWord;

  PAddressLayout = ^TAddressLayout;
  TAddressLayout = record
    IsRandomized: Boolean;
    { Where a position independent program's lowest page goes. }
    ImageBase: QWord;
    { Where the first fit search for run time allocations starts. }
    AllocationBase: QWord;
    { Where libraries go: each at a random page of the window
      (randomized), or one after another from LibraryWindowStart. }
    LibraryWindowStart: QWord;
    LibraryWindowEnd: QWord;
    { The main stack: its region ends at StackTop; the initial stack
      pointer lies InitialStackOffset (a multiple of 16) below it. }
    StackTop: QWord;
    InitialStackOffset: QWord;
  end;

procedure ChooseAddressLayout(Randomize: Boolean; Random: TLayoutRandom; out Layout: TAddressLayout);

{ Where to start looking for room for a library of Length bytes: a
  random page of the library window that leaves room for it (the
  window's start if it does not fit at all). }
function ChooseLibraryAddress(const Layout: TAddressLayout; Length: QWord; Random: TLayoutRandom): QWord;

{ Where to start looking for room for a thread's stack or thread data:
  a random page of the stack window, or the allocation base without
  randomization. }
function ChooseThreadMemoryAddress(const Layout: TAddressLayout; Random: TLayoutRandom): QWord;

{ The lowest address the main stack's guard reaches. }
function MainStackFloor(const Layout: TAddressLayout): QWord;

implementation

function RandomPageOffset(Pages: QWord; Random: TLayoutRandom): QWord;
begin
  Result := Random(Pages) * LayoutPageSize;
end;

procedure ChooseAddressLayout(Randomize: Boolean; Random: TLayoutRandom; out Layout: TAddressLayout);
begin
  Layout.IsRandomized := Randomize and Assigned(Random);
  if not Layout.IsRandomized then
  begin
    Layout.ImageBase := FixedImageBase;
    Layout.AllocationBase := FixedAllocationBase;
    Layout.LibraryWindowStart := FixedLibraryBase;
    Layout.StackTop := FixedStackTop;
    Layout.LibraryWindowEnd := MainStackFloor(Layout);
    Layout.InitialStackOffset := 0;
    Exit;
  end;
  Layout.ImageBase := RandomImageWindowStart + RandomPageOffset(RandomImageWindowPages, Random);
  Layout.AllocationBase := FixedAllocationBase + RandomPageOffset(RandomAllocationWindowPages, Random);
  Layout.LibraryWindowStart := RandomLibraryWindowStart;
  Layout.LibraryWindowEnd := RandomLibraryWindowEnd;
  Layout.StackTop := FixedStackTop - RandomPageOffset(RandomStackTopPages, Random);
  Layout.InitialStackOffset := Random(InitialStackSlots) * 16;
end;

function ChooseLibraryAddress(const Layout: TAddressLayout; Length: QWord; Random: TLayoutRandom): QWord;
var
  Pages: QWord;
  Span: QWord;
begin
  Result := Layout.LibraryWindowStart;
  if not Layout.IsRandomized then
    Exit;
  Span := Layout.LibraryWindowEnd - Layout.LibraryWindowStart;
  if Length >= Span then
    Exit;
  Pages := (Span - Length) div LayoutPageSize + 1;
  Result := Layout.LibraryWindowStart + RandomPageOffset(Pages, Random);
end;

function ChooseThreadMemoryAddress(const Layout: TAddressLayout; Random: TLayoutRandom): QWord;
begin
  if not Layout.IsRandomized then
    Exit(Layout.AllocationBase);
  Result := RandomStackWindowStart + RandomPageOffset(RandomStackWindowPages, Random);
end;

function MainStackFloor(const Layout: TAddressLayout): QWord;
begin
  Result := Layout.StackTop - MainStackReserve - MainStackGuard;
end;

end.
