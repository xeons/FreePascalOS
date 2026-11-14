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
  Kernel thread stacks.

  Each stack lives in the kernel dynamic region with one unmapped guard
  page below it. Running off the bottom of the stack therefore causes a
  page fault (handled on the separate double fault stack) instead of
  silently corrupting whatever memory happens to be next.
}
unit Memory.KernelStacks;

{$mode objfpc}

interface

const
  DefaultKernelStackSize = 32 * 1024;

type
  TKernelStack = record
    { Lowest usable address. }
    Base: QWord;
    { One past the highest usable address; the initial stack pointer. }
    Top: QWord;
  end;

function AllocateKernelStack(SizeInBytes: QWord; out Stack: TKernelStack): Boolean;
procedure FreeKernelStack(var Stack: TKernelStack);

implementation

uses
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.VirtualRanges,
  Memory.PageMapping,
  Memory.Arch.PageTables;

const
  GuardPageCount = 1;

function AllocateKernelStack(SizeInBytes: QWord; out Stack: TKernelStack): Boolean;
var
  StackPageCount: QWord;
  RangeStart: QWord;
  FirstStackPage: QWord;
begin
  Stack.Base := 0;
  Stack.Top := 0;

  StackPageCount := PagesForBytes(SizeInBytes);
  RangeStart := AllocateVirtualRange(StackPageCount + GuardPageCount);
  if RangeStart = 0 then
    Exit(False);

  FirstStackPage := RangeStart + GuardPageCount * PageSize;
  if not MapNewPages(FirstStackPage, StackPageCount, PageUsageKernelStack, MappingWritable) then
  begin
    FreeVirtualRange(RangeStart, StackPageCount + GuardPageCount);
    Exit(False);
  end;

  Stack.Base := FirstStackPage;
  Stack.Top := FirstStackPage + StackPageCount * PageSize;
  Result := True;
end;

procedure FreeKernelStack(var Stack: TKernelStack);
var
  StackPageCount: QWord;
begin
  if Stack.Base = 0 then
    Exit;
  StackPageCount := (Stack.Top - Stack.Base) shr PageShift;
  UnmapAndFreePages(Stack.Base, StackPageCount);
  FreeVirtualRange(Stack.Base - GuardPageCount * PageSize, StackPageCount + GuardPageCount);
  Stack.Base := 0;
  Stack.Top := 0;
end;

end.
