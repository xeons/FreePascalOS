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
  A panic on purpose, to check the panic's back trace (Debug.StackTrace)
  and the symbol table (Debug.KernelSymbols): with the kernel option

    testpanic           (or testpanic=fault) a page fault, three calls
                        deep: the processor exception's trace
    testpanic=assert    a failed assertion, three calls deep: the trace
                        of the code that called the panic

  the system panics once start-up has its threads going - with the
  netlog option, once the network log has found its listener (at most
  NetworkLogWaitSeconds), so the trace reaches it as well.
  scripts/test-panic-trace.sh boots each and checks that the serial log
  (and the network log) name PanicTestInnermost, PanicTestMiddle,
  PanicTestOutermost and RunPanicTestIfAsked, in that order.
}
unit Kernel.PanicTest;

{$mode objfpc}

interface

{ Panics if the testpanic option asks for it; returns otherwise. }
procedure RunPanicTestIfAsked;

implementation

uses
  Runtime.Text,
  Kernel.Options,
  Kernel.Panic,
  Kernel.Scheduler,
  Network.LogStreaming,
  Debug.Output;

const
  OptionPanicTest = 'testpanic';
  NetworkLogWaitSeconds = 60;
  WaitStepMilliseconds = 100;

type
  TPanicKind = (PanicKindFault, PanicKindAssertion);

var
  { Not constants, so the compiler cannot see through them: a low
    address no kernel thread maps, and a count each level adds to after
    its call, so no call becomes a jump. }
  FaultAddress: QWord = 8;
  LevelsPassed: QWord = 0;

procedure PanicTestInnermost(Kind: TPanicKind);
begin
  if Kind = PanicKindAssertion then
    KernelAssert(LevelsPassed = High(QWord), 'testpanic: the assertion fails on purpose')
  else
    PQWord(FaultAddress)^ := LevelsPassed;
  Inc(LevelsPassed);
end;

procedure PanicTestMiddle(Kind: TPanicKind);
begin
  PanicTestInnermost(Kind);
  Inc(LevelsPassed);
end;

procedure PanicTestOutermost(Kind: TPanicKind);
begin
  PanicTestMiddle(Kind);
  Inc(LevelsPassed);
end;

procedure WaitForNetworkLog;
var
  Waited: QWord;
begin
  if not NetworkLogIsWanted then
    Exit;
  Waited := 0;
  while not NetworkLogHasRoute and (Waited < NetworkLogWaitSeconds * 1000) do
  begin
    SleepMilliseconds(WaitStepMilliseconds);
    Inc(Waited, WaitStepMilliseconds);
  end;
end;

procedure RunPanicTestIfAsked;
var
  Value: array[0..31] of Char;
  Kind: TPanicKind;
begin
  if KernelOptionIsSet(OptionPanicTest) then
    Kind := PanicKindFault
  else if GetKernelOptionValue(OptionPanicTest, @Value[0], SizeOf(Value)) then
  begin
    if TextIsEqual(@Value[0], 'assert') then
      Kind := PanicKindAssertion
    else
      Kind := PanicKindFault;
  end
  else
    Exit;
  WaitForNetworkLog;
  DebugBeginMessage;
  DebugWriteTag('testpanic');
  if Kind = PanicKindAssertion then
    DebugWriteLine('Failing an assertion on purpose')
  else
    DebugWriteLine('Faulting on purpose');
  DebugEndMessage;
  PanicTestOutermost(Kind);
  { Not reached. }
  KernelPanic('testpanic: the deliberate panic did not happen');
end;

end.
