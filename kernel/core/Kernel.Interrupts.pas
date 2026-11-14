{
  Architecture independent interrupt dispatching.

  The architecture entry code calls DispatchInterrupt for every interrupt
  and exception. Processor exceptions are passed to the architecture's
  exception handler. Everything else is a hardware or software interrupt,
  which is handled like this:

    1. Raise the priority level to the interrupt's level, which holds off
       this interrupt and everything below it.
    2. Acknowledge the interrupt controller right away; the raised level
       already prevents re-entry.
    3. Re-enable interrupts so higher priority interrupts can nest.
    4. Run the registered handler.
    5. Disable interrupts and return to the previous level.

  A handler may switch threads (the dispatch interrupt does exactly that).
  The interrupted thread then finishes steps 5 and the interrupt return
  only once it is scheduled again, which is correct because each thread
  keeps its own interrupt frame on its own stack.
}
unit Kernel.Interrupts;

{$mode objfpc}

interface

uses
  Kernel.Arch.TrapFrame;

type
  TInterruptHandler = procedure(Frame: PTrapFrame; Context: Pointer);
  { Runs as an interrupt is about to return to user mode, with interrupts
    disabled at PassiveLevel. It may end the current thread. }
  TUserModeReturnHook = procedure(Frame: PTrapFrame);

procedure SetUserModeReturnHook(Hook: TUserModeReturnHook);

{ Installs Handler for Vector. Returns False if the vector already has one. }
function RegisterInterruptHandler(Vector: Byte; Handler: TInterruptHandler;
  Context: Pointer): Boolean;

procedure UnregisterInterruptHandler(Vector: Byte);

{ Called by the architecture specific entry code. }
procedure DispatchInterrupt(Frame: PTrapFrame);

function InterruptCountForVector(Vector: Byte): QWord;

implementation

uses
  Runtime.Atomic,
  Hal.InterruptVectors,
  Hal.Platform,
  Kernel.Arch.Cpu,
  Kernel.Arch.PriorityLevel,
  Kernel.Arch.Exceptions,
  Kernel.Arch.UserMode,
  Kernel.PriorityLevel,
  Kernel.Panic,
  Debug.Output;

type
  TInterruptRegistration = record
    Handler: TInterruptHandler;
    Context: Pointer;
    Count: Int64;
  end;

var
  Registrations: array[0..255] of TInterruptRegistration;
  UserModeReturnHook: TUserModeReturnHook = nil;

procedure SetUserModeReturnHook(Hook: TUserModeReturnHook);
begin
  UserModeReturnHook := Hook;
end;

function RegisterInterruptHandler(Vector: Byte; Handler: TInterruptHandler;
  Context: Pointer): Boolean;
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  Result := Registrations[Vector].Handler = nil;
  if Result then
  begin
    Registrations[Vector].Context := Context;
    Registrations[Vector].Handler := Handler;
  end;
  RestoreInterrupts(WereEnabled);
end;

procedure UnregisterInterruptHandler(Vector: Byte);
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  Registrations[Vector].Handler := nil;
  Registrations[Vector].Context := nil;
  RestoreInterrupts(WereEnabled);
end;

function InterruptCountForVector(Vector: Byte): QWord;
begin
  Result := QWord(Registrations[Vector].Count);
end;

procedure ReportUnexpectedInterrupt(Vector: Byte);
begin
  DebugBeginMessage;
  DebugWriteTag('interrupt');
  DebugWrite('No handler for vector 0x');
  DebugWriteHex(Vector, 2);
  DebugWriteLine(', ignoring');
  DebugEndMessage;
end;

procedure DispatchHardwareInterrupt(Frame: PTrapFrame; Vector: Byte);
var
  PreviousLevel: TPriorityLevel;
  InterruptLevel: TPriorityLevel;
  Handler: TInterruptHandler;
begin
  { Spurious interrupts must not be acknowledged. }
  if IsSpuriousInterruptVector(Vector) then
    Exit;

  InterruptLevel := ArchPriorityLevelOfVector(Vector);
  PreviousLevel := ArchGetPriorityLevel;
  if InterruptLevel <= PreviousLevel then
    KernelPanicWithCode(PanicInvalidPriorityLevel,
      'interrupt delivered at or below the current priority level',
      Vector, PreviousLevel, 0, 0);

  ArchSetPriorityLevel(InterruptLevel);
  HalEndOfInterrupt;
  AtomicIncrement(Registrations[Vector].Count);

  EnableInterrupts;

  Handler := Registrations[Vector].Handler;
  if Handler <> nil then
    Handler(Frame, Registrations[Vector].Context)
  else
    ReportUnexpectedInterrupt(Vector);

  DisableInterrupts;
  ArchSetPriorityLevel(PreviousLevel);
end;

procedure DispatchInterrupt(Frame: PTrapFrame);
var
  Vector: Byte;
begin
  Vector := TrapFrameVector(Frame);
  if IsProcessorException(Vector) then
    HandleProcessorException(Frame)
  else
    DispatchHardwareInterrupt(Frame, Vector);

  if ArchFrameIsFromUserMode(Frame) and Assigned(UserModeReturnHook) then
    UserModeReturnHook(Frame);
end;

end.
