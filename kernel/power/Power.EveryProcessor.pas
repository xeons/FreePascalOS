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
  Running a routine once on every processor, for settings each
  processor keeps in its own registers (clock modulation): the calling
  kernel thread moves itself from processor to processor by changing
  its affinity, runs the routine on each, and gets its old affinity
  back - unless its affinity was set by someone else meanwhile (taskset
  on its process, say): each move exchanges the mask and sees what it
  replaced, so that setting is kept and put back at the end instead.
  Slow (a switch per processor) but simple, and only for the rare
  changes that need it. Passive level, from a kernel thread.
}
unit Power.EveryProcessor;

{$mode objfpc}

interface

type
  TProcessorRoutine = procedure(Context: Pointer);

procedure RunOnEveryProcessor(Routine: TProcessorRoutine; Context: Pointer);

implementation

uses
  Kernel.Threads,
  Kernel.Processors,
  Kernel.Scheduler;

{ Moves the calling thread to processor Index; False if it does not
  get there (it is not online). LastSet is the mask this unit set last;
  a different one found in its place was set by someone else, and
  becomes Wanted, the mask to leave at the end. }
function MoveToProcessor(Thread: PThreadControlBlock; Index: LongWord; var LastSet, Wanted: QWord): Boolean;
const
  MaximumYields = 1000;
var
  Yields: Integer;
  Replaced: QWord;
begin
  Replaced := ExchangeThreadAffinity(Thread, QWord(1) shl Index);
  if Replaced <> LastSet then
    Wanted := Replaced;
  LastSet := QWord(1) shl Index;
  Yields := 0;
  while (CurrentProcessor^.Index <> Index) and (Yields < MaximumYields) do
  begin
    YieldExecution;
    Inc(Yields);
  end;
  Result := CurrentProcessor^.Index = Index;
end;

procedure RunOnEveryProcessor(Routine: TProcessorRoutine; Context: Pointer);
var
  Thread: PThreadControlBlock;
  LastSet: QWord;
  Wanted: QWord;
  Index: LongWord;
  Processor: PProcessor;
begin
  Thread := CurrentThread;
  LastSet := Thread^.AffinityMask;
  Wanted := LastSet;
  Index := 0;
  while Index < ProcessorTotal do
  begin
    Processor := ProcessorByIndex(Index);
    if (Processor <> nil) and Processor^.IsOnline and MoveToProcessor(Thread, Index, LastSet, Wanted) then
      Routine(Context);
    Inc(Index);
  end;
  { Set by someone else during the last routine: theirs stays. }
  ReplaceThreadAffinity(Thread, LastSet, Wanted);
end;

end.
