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
  Memory from the kernel for the heap manager (heap.inc): fresh pages,
  zeroed, freed as a whole.
}

function SysOSAlloc(Size: PtrUInt): Pointer;
var
  Address: Int64;
begin
  Address := SystemCall(CallAllocateMemory, Size, 0, 0, 0, 0, 0);
  if Address <= 0 then
    SysOSAlloc := nil
  else
    SysOSAlloc := Pointer(Address);
end;

{$define HAS_SYSOSFREE}
procedure SysOSFree(P: Pointer; Size: PtrUInt);
begin
  SystemCall(CallFreeMemory, QWord(P), 0, 0, 0, 0, 0);
end;
