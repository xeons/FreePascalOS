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
  The thread reaper: a system thread that releases what threads that
  have exited still hold (Processes.Thread.ReapTerminatedThreads): their
  place in their process, their kernel stack, and the last reference to
  the process itself, whose deletion closes its handles and destroys its
  address space - work that may wait on mutexes and shoot down
  translations, which the idle thread must never do (it may not wait).

  An exited thread is left on the scheduler's terminated list by its
  final switch. The idle thread, whenever it runs, wakes the reaper if
  that list holds one (WakeThreadReaperIfNeeded); the reaper also looks
  once a second by itself, so a processor that never idles does not
  keep exited threads forever.
}
unit Processes.ThreadReaper;

{$mode objfpc}

interface

{ Starts the reaper (once, at PassiveLevel, when system threads can be
  created). }
procedure StartThreadReaper;
{ For the idle thread: wakes the reaper if a thread waits to be reaped.
  Never waits. }
procedure WakeThreadReaperIfNeeded;

implementation

uses
  Runtime.Atomic,
  Kernel.Events,
  Kernel.Scheduler,
  Kernel.Panic,
  Processes.Thread;

const
  ReaperPriority = 10;
  LookMilliseconds = 1000;

var
  ReaperEvent: TEvent;
  ReaperStarted: PtrUInt = 0;

procedure RunThreadReaper(Context: Pointer);
begin
  while True do
  begin
    ReapTerminatedThreads;
    WaitForEventWithOptions(ReaperEvent, LookMilliseconds, False);
  end;
end;

procedure StartThreadReaper;
begin
  InitializeEvent(ReaperEvent, EventKindSynchronization, False);
  if CreateSystemThread(@RunThreadReaper, nil, ReaperPriority, 'ThreadReaper', False) = nil then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the thread reaper', 0, 0, 0, 0);
  AtomicStore(ReaperStarted, 1);
end;

procedure WakeThreadReaperIfNeeded;
begin
  if (AtomicLoad(ReaperStarted) <> 0) and TerminatedThreadsArePending then
    SignalEvent(ReaperEvent);
end;

end.
