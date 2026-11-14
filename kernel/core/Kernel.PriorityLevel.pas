{
  Interrupt priority levels.

  Every processor runs at a priority level. While it runs at level L, only
  interrupts with a level above L are delivered. This is how the kernel
  protects data shared with interrupt handlers without turning interrupts
  off entirely, and it defines what code may do in each context:

    PassiveLevel   Normal thread execution. Threads may block and be
                   preempted.
    DispatchLevel  The scheduler's level. The current thread cannot be
                   switched away from, so code here must not block. Spin
                   locks protecting scheduler data are held at this level.
    DeviceLevel*   Hardware device interrupts.
    ClockLevel     The periodic clock interrupt.
    HighLevel      Everything is masked. Used by the panic path and the
                   debug output lock.
}
unit Kernel.PriorityLevel;

{$mode objfpc}

interface

type
  TPriorityLevel = Byte;

const
  PassiveLevel = 0;
  DispatchLevel = 2;
  DeviceLevelLowest = 3;
  DeviceLevelHighest = 12;
  ClockLevel = 13;
  InterProcessorLevel = 14;
  HighLevel = 15;

function CurrentPriorityLevel: TPriorityLevel;

{ Raises to NewLevel and returns the previous level. Raising to a lower
  level than the current one is a fatal error. }
function RaisePriorityLevel(NewLevel: TPriorityLevel): TPriorityLevel;

{ Returns to a level previously obtained from RaisePriorityLevel. }
procedure LowerPriorityLevel(PreviousLevel: TPriorityLevel);

implementation

uses
  Kernel.Arch.PriorityLevel,
  Kernel.Panic;

function CurrentPriorityLevel: TPriorityLevel;
begin
  Result := ArchGetPriorityLevel;
end;

function RaisePriorityLevel(NewLevel: TPriorityLevel): TPriorityLevel;
begin
  Result := ArchGetPriorityLevel;
  if NewLevel < Result then
    KernelPanicWithCode(PanicInvalidPriorityLevel,
      'RaisePriorityLevel called with a level below the current one',
      Result, NewLevel, 0, 0);
  ArchSetPriorityLevel(NewLevel);
end;

procedure LowerPriorityLevel(PreviousLevel: TPriorityLevel);
var
  Level: TPriorityLevel;
begin
  Level := ArchGetPriorityLevel;
  if PreviousLevel > Level then
    KernelPanicWithCode(PanicInvalidPriorityLevel,
      'LowerPriorityLevel called with a level above the current one',
      Level, PreviousLevel, 0, 0);
  ArchSetPriorityLevel(PreviousLevel);
end;

end.
