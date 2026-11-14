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
