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
  Shared locks: sleeping reader/writer locks.

  Any number of threads may hold a shared lock shared (to read what it
  protects), or one thread exclusively (to change it). Like a mutex, a
  thread that cannot have it sleeps, so it may be held across I/O, and
  it may only be used at PassiveLevel.

  Fairness:

    * Writers come first. A thread asking for the lock shared waits if
      a writer holds it or is waiting for it, so a stream of readers
      cannot keep a writer out (no writer starvation).

    * Readers are not starved either. When a writer releases the lock,
      every reader waiting at that moment gets it together, before the
      next writer; the writers then waiting get it in turn once those
      readers are done. So under contention readers and writers take
      turns.

    * Ownership is handed over: the releasing thread makes the waiters
      it wakes the holders, so nobody slips in between.

  Recursion:

    * The exclusive holder may acquire the lock again, exclusively or
      shared; each acquisition counts as another exclusive one and needs
      its own release.

    * A shared holder must not acquire the lock again in any way: shared
      again would deadlock as soon as a writer waits in between (writers
      come first), and exclusive would wait for itself. Shared holders
      are not recorded per thread, so this is not detected - it is a
      rule.

  ReleaseSharedLock releases either kind of hold.
}
unit Kernel.SharedLocks;

{$mode objfpc}

interface

uses
  Runtime.LinkedList,
  Kernel.Threads;

type
  TSharedLock = record
    { The exclusive holder and how often it acquired the lock, or nil. }
    ExclusiveOwner: PThreadControlBlock;
    ExclusiveCount: LongWord;
    { How many threads hold it shared. }
    SharedCount: LongWord;
    { Threads waiting, linked by their SchedulerLink. }
    SharedWaiters: TListEntry;
    ExclusiveWaiters: TListEntry;
    ExclusiveWaiterCount: LongWord;
  end;
  PSharedLock = ^TSharedLock;

procedure InitializeSharedLock(out Lock: TSharedLock);
procedure AcquireSharedLockShared(var Lock: TSharedLock);
procedure AcquireSharedLockExclusive(var Lock: TSharedLock);
{ The same without waiting: False if the lock could not be had now. }
function TryAcquireSharedLockShared(var Lock: TSharedLock): Boolean;
function TryAcquireSharedLockExclusive(var Lock: TSharedLock): Boolean;
{ Gives up one hold, shared or exclusive. }
procedure ReleaseSharedLock(var Lock: TSharedLock);
function SharedLockIsHeldExclusivelyByCurrentThread(var Lock: TSharedLock): Boolean;

implementation

uses
  Kernel.PriorityLevel,
  Kernel.Scheduler,
  Kernel.Panic;

procedure InitializeSharedLock(out Lock: TSharedLock);
begin
  Lock.ExclusiveOwner := nil;
  Lock.ExclusiveCount := 0;
  Lock.SharedCount := 0;
  InitializeListHead(Lock.SharedWaiters);
  InitializeListHead(Lock.ExclusiveWaiters);
  Lock.ExclusiveWaiterCount := 0;
end;

procedure CheckPassiveLevel(var Lock: TSharedLock);
begin
  if CurrentPriorityLevel <> PassiveLevel then
    KernelPanicWithCode(PanicInvalidPriorityLevel, 'shared lock acquired above passive level',
      CurrentPriorityLevel, QWord(@Lock), 0, 0);
end;

{ Whether a thread asking for it shared may have it at once. }
function SharedIsFreeLocked(var Lock: TSharedLock): Boolean;
begin
  Result := (Lock.ExclusiveOwner = nil) and (Lock.ExclusiveWaiterCount = 0);
end;

function ExclusiveIsFreeLocked(var Lock: TSharedLock): Boolean;
begin
  Result := (Lock.ExclusiveOwner = nil) and (Lock.SharedCount = 0);
end;

{ Takes a hold the caller may have now; False if it must wait. }
function TryTakeSharedLocked(var Lock: TSharedLock; Thread: PThreadControlBlock): Boolean;
begin
  Result := True;
  if Lock.ExclusiveOwner = Thread then
    Inc(Lock.ExclusiveCount)
  else if SharedIsFreeLocked(Lock) then
    Inc(Lock.SharedCount)
  else
    Result := False;
end;

function TryTakeExclusiveLocked(var Lock: TSharedLock; Thread: PThreadControlBlock): Boolean;
begin
  Result := True;
  if Lock.ExclusiveOwner = Thread then
    Inc(Lock.ExclusiveCount)
  else if ExclusiveIsFreeLocked(Lock) then
  begin
    Lock.ExclusiveOwner := Thread;
    Lock.ExclusiveCount := 1;
  end
  else
    Result := False;
end;

procedure AcquireSharedLockShared(var Lock: TSharedLock);
var
  PreviousLevel: TPriorityLevel;
  Thread: PThreadControlBlock;
begin
  CheckPassiveLevel(Lock);
  PreviousLevel := AcquireDispatcherLock;
  Thread := CurrentThread;
  if not TryTakeSharedLocked(Lock, Thread) then
  begin
    InsertAtTail(Lock.SharedWaiters, @Thread^.SchedulerLink);
    WaitCurrentThreadLocked;
    { The releasing thread counted this one among the holders. }
  end;
  ReleaseDispatcherLock(PreviousLevel);
end;

procedure AcquireSharedLockExclusive(var Lock: TSharedLock);
var
  PreviousLevel: TPriorityLevel;
  Thread: PThreadControlBlock;
begin
  CheckPassiveLevel(Lock);
  PreviousLevel := AcquireDispatcherLock;
  Thread := CurrentThread;
  if not TryTakeExclusiveLocked(Lock, Thread) then
  begin
    InsertAtTail(Lock.ExclusiveWaiters, @Thread^.SchedulerLink);
    Inc(Lock.ExclusiveWaiterCount);
    WaitCurrentThreadLocked;
    { The releasing thread made this one the owner. }
  end;
  ReleaseDispatcherLock(PreviousLevel);
end;

function TryAcquireSharedLockShared(var Lock: TSharedLock): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  CheckPassiveLevel(Lock);
  PreviousLevel := AcquireDispatcherLock;
  Result := TryTakeSharedLocked(Lock, CurrentThread);
  ReleaseDispatcherLock(PreviousLevel);
end;

function TryAcquireSharedLockExclusive(var Lock: TSharedLock): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  CheckPassiveLevel(Lock);
  PreviousLevel := AcquireDispatcherLock;
  Result := TryTakeExclusiveLocked(Lock, CurrentThread);
  ReleaseDispatcherLock(PreviousLevel);
end;

{ Makes every waiting reader a holder and wakes it; False if none
  waited. }
function HandToWaitingReadersLocked(var Lock: TSharedLock): Boolean;
var
  Entry: PListEntry;
begin
  Result := False;
  Entry := RemoveHeadEntry(Lock.SharedWaiters);
  while Entry <> nil do
  begin
    Inc(Lock.SharedCount);
    ReadyThreadLocked(ThreadFromSchedulerLink(Entry));
    Result := True;
    Entry := RemoveHeadEntry(Lock.SharedWaiters);
  end;
end;

{ Makes the first waiting writer the owner and wakes it; False if none
  waited. }
function HandToWaitingWriterLocked(var Lock: TSharedLock): Boolean;
var
  Entry: PListEntry;
  Writer: PThreadControlBlock;
begin
  Entry := RemoveHeadEntry(Lock.ExclusiveWaiters);
  if Entry = nil then
    Exit(False);
  Dec(Lock.ExclusiveWaiterCount);
  Writer := ThreadFromSchedulerLink(Entry);
  Lock.ExclusiveOwner := Writer;
  Lock.ExclusiveCount := 1;
  ReadyThreadLocked(Writer);
  Result := True;
end;

procedure ReleaseExclusiveLocked(var Lock: TSharedLock);
begin
  Dec(Lock.ExclusiveCount);
  if Lock.ExclusiveCount > 0 then
    Exit;
  Lock.ExclusiveOwner := nil;
  { Readers that waited go first, then the next writer. }
  if not HandToWaitingReadersLocked(Lock) then
    HandToWaitingWriterLocked(Lock);
end;

procedure ReleaseSharedLocked(var Lock: TSharedLock);
begin
  Dec(Lock.SharedCount);
  if Lock.SharedCount = 0 then
    HandToWaitingWriterLocked(Lock);
end;

procedure ReleaseSharedLock(var Lock: TSharedLock);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  if Lock.ExclusiveOwner = CurrentThread then
    ReleaseExclusiveLocked(Lock)
  else if (Lock.ExclusiveOwner = nil) and (Lock.SharedCount > 0) then
    ReleaseSharedLocked(Lock)
  else
  begin
    ReleaseDispatcherLock(PreviousLevel);
    KernelPanicWithCode(PanicSchedulerFailure, 'shared lock released by a thread that does not hold it',
      QWord(@Lock), QWord(Lock.ExclusiveOwner), QWord(CurrentThread), Lock.SharedCount);
  end;
  ReleaseDispatcherLock(PreviousLevel);
end;

function SharedLockIsHeldExclusivelyByCurrentThread(var Lock: TSharedLock): Boolean;
begin
  Result := Lock.ExclusiveOwner = CurrentThread;
end;

end.
