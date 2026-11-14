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
  x86-64 implementation of interrupt priority levels.

  The priority level is stored directly in CR8, the task priority register.
  The local APIC holds off every interrupt whose vector's priority class
  (vector div 16) is less than or equal to CR8, so an interrupt at level L
  uses vectors L*16 .. L*16+15.
}
unit Kernel.Arch.PriorityLevel;

{$mode objfpc}

interface

function ArchGetPriorityLevel: Byte;
procedure ArchSetPriorityLevel(Level: Byte);
function ArchPriorityLevelOfVector(Vector: Byte): Byte;

implementation

uses
  Kernel.Arch.Cpu;

function ArchGetPriorityLevel: Byte;
begin
  Result := Byte(ReadTaskPriority);
end;

procedure ArchSetPriorityLevel(Level: Byte);
begin
  WriteTaskPriority(Level);
end;

function ArchPriorityLevelOfVector(Vector: Byte): Byte;
begin
  Result := Vector shr 4;
end;

end.
