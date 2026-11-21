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
  Kernel back traces: the chain of calls that led to a point, walked
  through the frame pointers and named from the kernel symbol table
  (Debug.KernelSymbols), one line per frame:

      #0 0xFFFFFFFF80123456 Kernel.PanicTest.FaultInLevelThree+0x1C
      #1 0xFFFFFFFF80123500 Kernel.PanicTest.CallLevelThree+0x11

  The kernel is compiled to keep a frame in every routine (the Makefile's
  -OoNOSTACKFRAME). On both processors a frame is the same pair: the
  frame pointer (RBP, X29) holds the address of the caller's frame
  pointer, and the word above it the return address (x86-64: pushed by
  CALL, then PUSH RBP; AArch64: STP X29, X30 at the frame's base). The
  first line is the interrupted or current address; every later one is
  a return address, named by the call before it (the address minus one),
  since a call to a routine that does not return may be the last
  instruction of its routine.

  The walk trusts nothing it reads: a frame must lie inside the stack
  being walked (the thread's kernel stack, or a small window above the
  first frame when there is no thread yet or the frame is elsewhere,
  such as an interrupt stack) and above the frame before it, a return
  address must be in the kernel's code, and the walk stops after
  MaximumTraceDepth frames. So a corrupt stack ends the trace early
  rather than faulting inside a panic.
}
unit Debug.StackTrace;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Threads,
  Kernel.Arch.TrapFrame;

const
  MaximumTraceDepth = 32;

type
  TStackTraceBounds = record
    Low: QWord;
    High: QWord;
  end;

{ Writes the trace starting at ProgramCounter (line #0, skipped if 0)
  and walking up from FramePointer, each line after Indent. }
procedure WriteStackTrace(ProgramCounter, FramePointer: QWord;
  const Bounds: TStackTraceBounds; Indent: PChar);

{ The stack a walk starting at FramePointer may read: the running
  thread's kernel stack if the frame is on it, otherwise a window above
  the frame. }
procedure FindStackBounds(FramePointer: QWord; out Bounds: TStackTraceBounds);

{ The trace of an interrupted kernel context (an exception's frame). }
procedure WriteTrapFrameStackTrace(Frame: PTrapFrame; Indent: PChar);

{ The trace of a thread: the caller's own for the running thread, where
  the thread stopped for one that is not running, a note for one that
  runs on another processor (its stack changes under the walk). }
procedure WriteThreadStackTrace(Thread: PThreadControlBlock; Indent: PChar);

{ The trace of the caller. }
procedure WriteCurrentStackTrace(Indent: PChar);

implementation

uses
  Kernel.Arch.ContextSwitch,
  Kernel.Processors,
  Debug.KernelSymbols,
  Debug.Output;

const
  FrameRecordBytes = 16;
  FallbackWindowBytes = 32 * 1024;

procedure WriteFrameLine(Index: LongWord; Address: QWord; IsReturnAddress: Boolean; Indent: PChar);
var
  UnitName: PChar;
  RoutineName: PChar;
  Offset: QWord;
  Adjustment: QWord;
begin
  { A return address belongs to the call before it. }
  Adjustment := 0;
  if IsReturnAddress then
    Adjustment := 1;
  DebugBeginMessage;
  DebugWrite(Indent);
  DebugWrite('#');
  DebugWriteDecimal(Index);
  DebugWrite(' ');
  DebugWriteAddress(Address);
  DebugWrite(' ');
  if FindKernelSymbol(Address - Adjustment, UnitName, RoutineName, Offset) then
  begin
    if UnitName <> nil then
    begin
      DebugWrite(UnitName);
      DebugWrite('.');
    end;
    DebugWrite(RoutineName);
    DebugWrite('+0x');
    DebugWriteHex(Offset + Adjustment, 1);
  end
  else if IsKernelCodeAddress(Address) then
    DebugWrite('(no symbols)')
  else
    DebugWrite('?');
  DebugWriteLine('');
  DebugEndMessage;
end;

function FrameIsInside(FramePointer: QWord; const Bounds: TStackTraceBounds): Boolean;
begin
  Result := ((FramePointer and 7) = 0) and (FramePointer >= Bounds.Low) and
    (FramePointer <= Bounds.High - FrameRecordBytes) and (Bounds.High > FrameRecordBytes);
end;

procedure WriteStackTrace(ProgramCounter, FramePointer: QWord;
  const Bounds: TStackTraceBounds; Indent: PChar);
var
  Depth: LongWord;
  ReturnAddress: QWord;
  NextFrame: QWord;
begin
  Depth := 0;
  if ProgramCounter <> 0 then
  begin
    WriteFrameLine(Depth, ProgramCounter, False, Indent);
    Inc(Depth);
  end;
  while Depth < MaximumTraceDepth do
  begin
    if not FrameIsInside(FramePointer, Bounds) then
      Exit;
    NextFrame := PQWord(FramePointer)[0];
    ReturnAddress := PQWord(FramePointer)[1];
    { A frame whose caller has none is a thread's first routine: it was
      not called, so the word above is no return address (on AArch64 the
      switch's jump into it leaves the routine's own start there). }
    if (NextFrame = 0) or not IsKernelCodeAddress(ReturnAddress) then
      Exit;
    WriteFrameLine(Depth, ReturnAddress, True, Indent);
    Inc(Depth);
    { Callers' frames lie higher up; anything else is the end or a loop. }
    if NextFrame <= FramePointer then
      Exit;
    FramePointer := NextFrame;
  end;
  DebugBeginMessage;
  DebugWrite(Indent);
  DebugWriteLine('... (more frames)');
  DebugEndMessage;
end;

function RunningThreadOrNil: PThreadControlBlock;
begin
  Result := nil;
  if ProcessorBlocksAreReady then
    Result := CurrentProcessor^.RunningThread;
end;

procedure SetThreadBounds(Thread: PThreadControlBlock; out Bounds: TStackTraceBounds);
begin
  Bounds.Low := Thread^.StackBase;
  Bounds.High := Thread^.StackTop;
end;

procedure FindStackBounds(FramePointer: QWord; out Bounds: TStackTraceBounds);
var
  Thread: PThreadControlBlock;
begin
  Thread := RunningThreadOrNil;
  if (Thread <> nil) and (Thread^.StackBase <> 0) and
     (FramePointer >= Thread^.StackBase) and (FramePointer < Thread^.StackTop) then
  begin
    SetThreadBounds(Thread, Bounds);
    Exit;
  end;
  Bounds.Low := FramePointer;
  Bounds.High := FramePointer + FallbackWindowBytes;
  if Bounds.High < FramePointer then
    Bounds.High := High(QWord);
end;

procedure WriteTrapFrameStackTrace(Frame: PTrapFrame; Indent: PChar);
var
  Bounds: TStackTraceBounds;
begin
  FindStackBounds(TrapFrameFramePointer(Frame), Bounds);
  WriteStackTrace(TrapFrameInstructionPointer(Frame), TrapFrameFramePointer(Frame), Bounds, Indent);
end;

procedure WriteCurrentStackTrace(Indent: PChar);
var
  Frame: QWord;
  Bounds: TStackTraceBounds;
begin
  Frame := QWord(get_frame);
  FindStackBounds(Frame, Bounds);
  { From this routine's frame: the first line is the caller. }
  WriteStackTrace(0, Frame, Bounds, Indent);
end;

procedure WriteThreadStackTrace(Thread: PThreadControlBlock; Indent: PChar);
var
  ProgramCounter: QWord;
  FramePointer: QWord;
  Bounds: TStackTraceBounds;
begin
  if Thread = RunningThreadOrNil then
  begin
    WriteCurrentStackTrace(Indent);
    Exit;
  end;
  if (Thread^.State = ThreadStateRunning) or (Thread^.SavedStackPointer = 0) or (Thread^.StackBase = 0) then
  begin
    DebugBeginMessage;
    DebugWrite(Indent);
    if Thread^.State = ThreadStateRunning then
    begin
      DebugWrite('(running on processor ');
      DebugWriteDecimal(Thread^.LastProcessorIndex);
      DebugWriteLine(')');
    end
    else
      DebugWriteLine('(no saved state)');
    DebugEndMessage;
    Exit;
  end;
  SetThreadBounds(Thread, Bounds);
  if (Thread^.SavedStackPointer < Bounds.Low) or (Thread^.SavedStackPointer >= Bounds.High) then
    Exit;
  ArchSwitchFramePointers(Thread^.SavedStackPointer, ProgramCounter, FramePointer);
  WriteStackTrace(ProgramCounter, FramePointer, Bounds, Indent);
end;

end.
