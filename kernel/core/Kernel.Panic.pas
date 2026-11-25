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
  Fatal error handling.

  When the kernel detects that its own state can no longer be trusted it
  stops the system with a panic: interrupts are masked, the reason and any
  diagnostic values are printed, and the processor halts for good.

  The panic is split into BeginKernelPanic and FinishKernelPanic so that
  architecture specific code (for example the processor exception handler)
  can print extra details such as a register dump in between.

  FinishKernelPanic writes the back trace (Debug.StackTrace): of the
  interrupted code when the exception handler gave its frame
  (SetPanicTraceStart), otherwise of the code that called
  BeginKernelPanic - the routine that panicked and its callers. Each
  processor notes its own trace start (two may fault at once, and only
  the first to panic reports), so the trace is always of the processor
  that panicked.

  FinishKernelPanic then, in this order: lets the reset policy say what
  will happen (Kernel.Watchdog: "resets in N seconds"), lets the network
  log send what it has not sent yet (Network.LogStreaming), runs the panic
  hook (leaving the emulator under test), and lets the reset policy reset
  the machine after its delay; if nothing resets it, it halts.
}
unit Kernel.Panic;

{$mode objfpc}

interface

const
  PanicGeneral = $00;
  PanicAssertionFailed = $01;
  PanicInvalidPriorityLevel = $02;
  PanicUnhandledProcessorException = $03;
  PanicInvalidBootInformation = $04;
  PanicOutOfPhysicalMemory = $05;
  PanicPageTableFailure = $06;
  PanicHeapCorruption = $07;
  PanicSchedulerFailure = $08;
  PanicObjectReferenceFailure = $09;
  PanicHardwareMissing = $0A;
  PanicInitializationFailed = $0B;

procedure KernelPanic(Reason: PChar); noreturn;

procedure KernelPanicWithCode(Code: QWord; Reason: PChar;
  Parameter1, Parameter2, Parameter3, Parameter4: QWord); noreturn;

{ Fatal if Condition is False. }
procedure KernelAssert(Condition: Boolean; Description: PChar);

procedure BeginKernelPanic(Code: QWord; Reason: PChar);
procedure FinishKernelPanic; noreturn;

{ Makes the panic's back trace start at an interrupted context (an
  exception handler passes its frame's address and frame pointer) rather
  than at BeginKernelPanic's caller. Called before BeginKernelPanic. }
procedure SetPanicTraceStart(ProgramCounter, FramePointer: QWord);

type
  TPanicHook = procedure;

{ Registers a routine that runs at the very end of a panic, after the
  message has been printed (used to leave the emulator during tests). }
procedure SetPanicHook(Hook: TPanicHook);

{ The routine that sends the log on after the message (the network log).
  It runs with interrupts disabled and the other processors stopped. }
procedure SetPanicFlushRoutine(Routine: TPanicHook);
{ The reset policy: Announce writes what will happen before the log is
  sent on, Perform resets the machine (it returns only if it does not). }
procedure SetPanicResetRoutines(Announce, Perform: TPanicHook);

function PanicIsInProgress: Boolean;

implementation

uses
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Arch.PriorityLevel,
  Kernel.PriorityLevel,
  Debug.Output,
  Debug.FramebufferConsole,
  Hal.Platform,
  Kernel.Processors,
  Debug.StackTrace;

var
  PanicCount: Int64 = 0;
  PanicHook: TPanicHook = nil;
  PanicFlushRoutine: TPanicHook = nil;
  PanicResetAnnounce: TPanicHook = nil;
  PanicResetPerform: TPanicHook = nil;
  { Indexed by processor. }
  TraceProgramCounters: array[0..MaximumProcessors - 1] of QWord;
  TraceFramePointers: array[0..MaximumProcessors - 1] of QWord;
  TraceStartIsSet: array[0..MaximumProcessors - 1] of Boolean;

function TraceSlot: LongWord;
begin
  Result := CurrentProcessorIndexOrZero;
  if Result >= MaximumProcessors then
    Result := 0;
end;

procedure SetPanicHook(Hook: TPanicHook);
begin
  PanicHook := Hook;
end;

procedure SetPanicFlushRoutine(Routine: TPanicHook);
begin
  PanicFlushRoutine := Routine;
end;

procedure SetPanicResetRoutines(Announce, Perform: TPanicHook);
begin
  PanicResetAnnounce := Announce;
  PanicResetPerform := Perform;
end;

function PanicIsInProgress: Boolean;
begin
  Result := PanicCount > 0;
end;

procedure HaltForever; noreturn;
begin
  while True do
  begin
    DisableInterrupts;
    HaltProcessor;
  end;
end;

procedure SetPanicTraceStart(ProgramCounter, FramePointer: QWord);
var
  Slot: LongWord;
begin
  if PanicIsInProgress then
    Exit;
  Slot := TraceSlot;
  TraceProgramCounters[Slot] := ProgramCounter;
  TraceFramePointers[Slot] := FramePointer;
  TraceStartIsSet[Slot] := True;
end;

{ BeginKernelPanic's caller: where it will return to and its frame. }
procedure NoteCallerForTrace(BeginFrame: QWord);
var
  Slot: LongWord;
begin
  Slot := TraceSlot;
  if TraceStartIsSet[Slot] or (BeginFrame = 0) then
    Exit;
  TraceFramePointers[Slot] := PQWord(BeginFrame)^;
  TraceProgramCounters[Slot] := PQWord(BeginFrame + 8)^;
  TraceStartIsSet[Slot] := True;
end;

procedure WritePanicTrace;
var
  Bounds: TStackTraceBounds;
  Slot: LongWord;
begin
  Slot := TraceSlot;
  if not TraceStartIsSet[Slot] then
    Exit;
  DebugWriteLine('');
  DebugWriteLine('Back trace:');
  FindStackBounds(TraceFramePointers[Slot], Bounds);
  WriteStackTrace(TraceProgramCounters[Slot], TraceFramePointers[Slot], Bounds, '  ');
end;

procedure BeginKernelPanic(Code: QWord; Reason: PChar);
var
  BeginFrame: QWord;
begin
  BeginFrame := QWord(get_frame);
  DisableInterrupts;
  ArchSetPriorityLevel(HighLevel);

  { A panic while panicking means the panic path itself is broken; do not
    risk making things worse by printing again. }
  if AtomicIncrement(PanicCount) > 1 then
    HaltForever;
  NoteCallerForTrace(BeginFrame);

  { The others may hold the output lock or keep changing what the
    message is about to describe. }
  if OnlineProcessorCount > 1 then
    HalHaltOtherProcessors;

  DebugForceUnlockForPanic;

  { A program may have had the screen: the console takes it back. }
  ResumeConsoleDrawing;
  ConsoleSetBackgroundColor(ColorDarkRed);
  ConsoleClearScreen;
  DebugSetColor(ColorWhite);

  DebugWriteLine('');
  DebugWriteLine('*** KERNEL PANIC ***');
  DebugWriteLine('');
  DebugWrite('The system has been stopped to prevent damage. Code 0x');
  DebugWriteHex(Code, 2);
  DebugWriteLine('');
  DebugWrite('Reason: ');
  DebugWriteLine(Reason);
  DebugWriteLine('');
end;

procedure FinishKernelPanic; noreturn;
begin
  WritePanicTrace;
  DebugWriteLine('');
  DebugWriteLine('System halted.');
  if Assigned(PanicResetAnnounce) then
    PanicResetAnnounce;
  if Assigned(PanicFlushRoutine) then
    PanicFlushRoutine;
  if Assigned(PanicHook) then
    PanicHook;
  if Assigned(PanicResetPerform) then
    PanicResetPerform;
  HaltForever;
end;

procedure WriteParameter(Index: Integer; Value: QWord);
begin
  DebugWrite('  Parameter ');
  DebugWriteDecimal(QWord(Index));
  DebugWrite(': ');
  DebugWriteAddress(Value);
  DebugWriteLine('');
end;

procedure KernelPanicWithCode(Code: QWord; Reason: PChar;
  Parameter1, Parameter2, Parameter3, Parameter4: QWord); noreturn;
begin
  BeginKernelPanic(Code, Reason);
  WriteParameter(1, Parameter1);
  WriteParameter(2, Parameter2);
  WriteParameter(3, Parameter3);
  WriteParameter(4, Parameter4);
  FinishKernelPanic;
end;

procedure KernelPanic(Reason: PChar); noreturn;
begin
  BeginKernelPanic(PanicGeneral, Reason);
  FinishKernelPanic;
end;

procedure KernelAssert(Condition: Boolean; Description: PChar);
begin
  if not Condition then
  begin
    BeginKernelPanic(PanicAssertionFailed, 'assertion failed');
    DebugWrite('  ');
    DebugWriteLine(Description);
    FinishKernelPanic;
  end;
end;

end.
