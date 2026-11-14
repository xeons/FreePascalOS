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
  Mutexes: sleeping locks with an owner.

  Unlike a spin lock, a thread that finds a mutex taken goes to sleep
  until it is released, so a mutex may be held for a long time (across
  disk I/O, for example) without wasting processor time. The owning
  thread may acquire it again recursively; it must release it as many
  times as it acquired it.

  When a mutex is released while threads are waiting, ownership passes
  directly to the first waiter, so waiters are served in arrival order.

  Mutexes may only be used at PassiveLevel.
}
unit Kernel.Mutex;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Kernel.Threads;

type
  TMutex = record
    Owner: PThreadControlBlock;
    RecursionCount: LongWord;
    Waiters: TListEntry;
  end;
  PMutex = ^TMutex;

procedure InitializeMutex(out Mutex: TMutex);
procedure AcquireMutex(var Mutex: TMutex);
procedure ReleaseMutex(var Mutex: TMutex);
function MutexIsOwnedByCurrentThread(var Mutex: TMutex): Boolean;

implementation

uses
  Kernel.PriorityLevel,
  Kernel.Scheduler,
  Kernel.Panic;

procedure InitializeMutex(out Mutex: TMutex);
begin
  Mutex.Owner := nil;
  Mutex.RecursionCount := 0;
  InitializeListHead(Mutex.Waiters);
end;

procedure AcquireMutex(var Mutex: TMutex);
var
  PreviousLevel: TPriorityLevel;
  Thread: PThreadControlBlock;
begin
  if CurrentPriorityLevel <> PassiveLevel then
    KernelPanicWithCode(PanicInvalidPriorityLevel, 'mutex acquired above passive level',
      CurrentPriorityLevel, QWord(@Mutex), 0, 0);

  PreviousLevel := AcquireDispatcherLock;
  Thread := CurrentThread;

  if Mutex.Owner = nil then
  begin
    Mutex.Owner := Thread;
    Mutex.RecursionCount := 1;
  end
  else if Mutex.Owner = Thread then
    Inc(Mutex.RecursionCount)
  else
  begin
    InsertAtTail(Mutex.Waiters, @Thread^.SchedulerLink);
    WaitCurrentThreadLocked;
    { ReleaseMutex made this thread the owner before waking it. }
  end;

  ReleaseDispatcherLock(PreviousLevel);
end;

procedure ReleaseMutex(var Mutex: TMutex);
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
  NextOwner: PThreadControlBlock;
begin
  PreviousLevel := AcquireDispatcherLock;

  if Mutex.Owner <> CurrentThread then
  begin
    ReleaseDispatcherLock(PreviousLevel);
    KernelPanicWithCode(PanicSchedulerFailure, 'mutex released by a thread that does not own it',
      QWord(@Mutex), QWord(Mutex.Owner), QWord(CurrentThread), 0);
  end;

  Dec(Mutex.RecursionCount);
  if Mutex.RecursionCount = 0 then
  begin
    Entry := RemoveHeadEntry(Mutex.Waiters);
    if Entry = nil then
      Mutex.Owner := nil
    else
    begin
      NextOwner := ThreadFromSchedulerLink(Entry);
      Mutex.Owner := NextOwner;
      Mutex.RecursionCount := 1;
      ReadyThreadLocked(NextOwner);
    end;
  end;

  ReleaseDispatcherLock(PreviousLevel);
end;

function MutexIsOwnedByCurrentThread(var Mutex: TMutex): Boolean;
begin
  Result := Mutex.Owner = CurrentThread;
end;

end.
