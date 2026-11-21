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
  Self test of the kernel symbol table (Debug.KernelSymbols) and the
  frame walk (Debug.StackTrace), at every boot: the table names this
  unit's routines as written in the source, an address inside a routine
  gives its offset, an address outside the kernel's code gives nothing,
  and a walk from two calls deep finds the two callers, in order. The
  panic itself is tested by booting with testpanic
  (scripts/test-panic-trace.sh).
}
unit Kernel.StackTraceSelfTest;

{$mode objfpc}

interface

procedure RunStackTraceSelfTest;

implementation

uses
  Runtime.Text,
  Kernel.SelfTest,
  Debug.KernelSymbols,
  Debug.StackTrace;

const
  ThisUnit = 'Kernel.StackTraceSelfTest';

var
  { Where the walk from the inner routine found its callers. }
  FirstCaller: QWord;
  SecondCaller: QWord;
  WalkSucceeded: Boolean;
  { Keeps the calls from being the routines' last instructions. }
  CallCount: LongWord;

function NamesRoutine(Address: QWord; RoutineName: PChar): Boolean;
var
  FoundUnit: PChar;
  FoundRoutine: PChar;
  Offset: QWord;
begin
  Result := FindKernelSymbol(Address, FoundUnit, FoundRoutine, Offset) and (FoundUnit <> nil) and
    TextIsEqual(FoundUnit, ThisUnit) and TextIsEqual(FoundRoutine, RoutineName);
end;

procedure WalkFromHere;
var
  Frame: QWord;
  Bounds: TStackTraceBounds;
begin
  Frame := QWord(get_frame);
  FindStackBounds(Frame, Bounds);
  { This routine's own frame holds the return into its caller. }
  WalkSucceeded := StepToCallerFrame(Frame, Bounds, FirstCaller) and
    StepToCallerFrame(Frame, Bounds, SecondCaller);
  Inc(CallCount);
end;

procedure CallWalkFromHere;
begin
  WalkFromHere;
  Inc(CallCount);
end;

procedure TestSymbolLookup;
var
  FoundUnit: PChar;
  FoundRoutine: PChar;
  Offset: QWord;
begin
  Check(KernelSymbolsArePresent, 'the kernel carries its symbol table');
  Check(FindKernelSymbol(QWord(@CallWalkFromHere), FoundUnit, FoundRoutine, Offset),
    'a routine of the kernel is found');
  Check((FoundUnit <> nil) and TextIsEqual(FoundUnit, ThisUnit), 'the unit is named as in the source');
  Check(TextIsEqual(FoundRoutine, 'CallWalkFromHere'), 'the routine is named as in the source');
  Check(Offset = 0, 'a routine''s first instruction is at offset 0');
  Check(FindKernelSymbol(QWord(@CallWalkFromHere) + 2, FoundUnit, FoundRoutine, Offset) and (Offset = 2),
    'an address inside a routine gives its offset');
  Check(not FindKernelSymbol(QWord(@CallCount), FoundUnit, FoundRoutine, Offset),
    'data is not code');
end;

procedure TestFrameWalk;
begin
  WalkSucceeded := False;
  CallWalkFromHere;
  Check(WalkSucceeded, 'the walk follows two frames');
  Check(NamesRoutine(FirstCaller - 1, 'CallWalkFromHere'), 'the first caller is the routine that called');
  Check(NamesRoutine(SecondCaller - 1, 'TestFrameWalk'), 'the second caller is the one before');
end;

procedure RunStackTraceSelfTest;
begin
  CallCount := 0;
  TestSymbolLookup;
  TestFrameWalk;
  ReportPassed('kernel symbols and back traces');
end;

end.
