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
  The kernel stack traces of threads, for the debug shell's "trace"
  command: one thread by its id, or every thread of every process (the
  system's kernel threads first). Each gets a line naming it, then its
  trace (Debug.StackTrace): where in the kernel it waits, or a note if
  it runs on another processor.
}
unit Processes.ThreadTraces;

{$mode objfpc}

interface

const
  AllThreads = High(QWord);

{ Writes the trace of the thread with ThreadId (AllThreads: of every
  thread); False if there is no such thread. }
function WriteThreadTraces(ThreadId: QWord): Boolean;

implementation

uses
  Kernel.Threads,
  Processes.Process,
  Processes.Thread,
  Debug.StackTrace,
  Debug.Output;

type
  TTraceSearch = record
    ThreadId: QWord;
    Process: PProcess;
    Found: Boolean;
  end;
  PTraceSearch = ^TTraceSearch;

procedure TraceThread(Thread: PThread; Context: Pointer);
var
  Search: PTraceSearch;
  Block: PThreadControlBlock;
begin
  Search := PTraceSearch(Context);
  Block := @Thread^.ControlBlock;
  if (Search^.ThreadId <> AllThreads) and (Block^.ThreadId <> Search^.ThreadId) then
    Exit;
  Search^.Found := True;
  DebugBeginMessage;
  DebugWrite('thread ');
  DebugWriteDecimal(Block^.ThreadId);
  DebugWrite(' ');
  DebugWrite(@Block^.Name[0]);
  DebugWrite(' (');
  DebugWrite(ThreadStateName(Block^.State));
  DebugWrite(') of process ');
  DebugWriteDecimal(Search^.Process^.ProcessId);
  DebugWrite(' ');
  DebugWriteLine(@Search^.Process^.Name[0]);
  DebugEndMessage;
  WriteThreadStackTrace(Block, '  ');
end;

procedure TraceProcessThreads(Process: PProcess; Context: Pointer);
begin
  if Process = SystemProcess then
    Exit;
  PTraceSearch(Context)^.Process := Process;
  VisitProcessThreads(Process, @TraceThread, Context);
end;

function WriteThreadTraces(ThreadId: QWord): Boolean;
var
  Search: TTraceSearch;
begin
  Search.ThreadId := ThreadId;
  Search.Found := False;
  Search.Process := SystemProcess;
  VisitProcessThreads(SystemProcess, @TraceThread, @Search);
  LockProcessRegistryShared;
  VisitRunningProcessesLocked(@TraceProcessThreads, @Search);
  UnlockProcessRegistry;
  Result := Search.Found;
end;

end.
