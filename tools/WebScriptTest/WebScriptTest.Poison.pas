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
  Freed memory is overwritten (with $DD) before the memory manager takes
  it back, so a test that reads an object after it was freed (a wrapper
  whose native object went, an event freed under a listener's reference)
  reads garbage pointers and fails instead of passing on stale contents.
  First in the program's uses: in force from the start.
}
unit WebScriptTest.Poison;

{$mode objfpc}
{$H+}

interface

implementation

var
  Previous: TMemoryManager;

function PoisonFreeMem(P: Pointer): PtrUInt;
begin
  if P <> nil then
    FillChar(P^, Previous.MemSize(P), $DD);
  Result := Previous.FreeMem(P);
end;

function PoisonFreeMemSize(P: Pointer; Size: PtrUInt): PtrUInt;
begin
  if P <> nil then
    FillChar(P^, Previous.MemSize(P), $DD);
  Result := Previous.FreeMemSize(P, Size);
end;

procedure InstallPoison;
var
  Poisoning: TMemoryManager;
begin
  GetMemoryManager(Previous);
  Poisoning := Previous;
  Poisoning.FreeMem := @PoisonFreeMem;
  Poisoning.FreeMemSize := @PoisonFreeMemSize;
  SetMemoryManager(Poisoning);
end;

initialization
  InstallPoison;
end.
