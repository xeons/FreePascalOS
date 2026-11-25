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
  Mutex events: mutexes that are events (kind EventKindMutex), so they
  are waited on with every other event - alone, among others or in a
  wait for all - which the kernel's own Kernel.Mutex is not. Programs
  get them as mutex objects (Objects.Mutexes).

  A mutex is owned by one thread at a time. A wait that takes it makes
  the waiting thread its owner (Kernel.Events), and its owner may take
  it again without waiting: each take is a hold, and the mutex is free
  again once every hold is released. Only the owner may release it.

  A thread that ends while it owns mutexes abandons them
  (AbandonOwnedMutexEvents): each is freed and marked abandoned, so the
  next owner learns (TakeAbandonedMark) that what the mutex protected
  may have been left half changed.

  Everything here holds the dispatcher lock, like every wait queue;
  releasing may be done at DispatchLevel or below.
}
unit Kernel.MutexEvents;

{$mode objfpc}

interface

uses
  Kernel.Threads,
  Kernel.Events;

{ A free mutex. }
procedure InitializeMutexEvent(out Event: TEvent);
{ Gives up one hold of the calling thread. False (and no change) if the
  thread does not own it; RemainingHolds is how many it still has (0:
  the mutex is free, and its first waiter, if any, owns it now). }
function ReleaseMutexEvent(var Event: TEvent; out RemainingHolds: LongInt): Boolean;
{ Frees and marks abandoned every mutex Thread still owns: called as a
  thread ends. }
procedure AbandonOwnedMutexEvents(Thread: PThreadControlBlock);
{ Before a mutex's memory goes: takes it off its owner's list. }
procedure DiscardMutexEvent(var Event: TEvent);
{ True, once, if the calling thread owns the mutex and took it after
  its previous owner abandoned it. }
function TakeAbandonedMark(var Event: TEvent): Boolean;
{ The owner (nil if free) and its holds, as they are now. }
function MutexEventOwner(var Event: TEvent): PThreadControlBlock;
function MutexEventHolds(var Event: TEvent): LongInt;

implementation

uses
  Kernel.PriorityLevel,
  Kernel.PriorityBoosts,
  Kernel.Scheduler;

procedure InitializeMutexEvent(out Event: TEvent);
begin
  InitializeEvent(Event, EventKindMutex, True);
  Event.SignalCount := 0;
end;

{ Takes Event off its owner's list of owned mutexes. }
procedure UnlinkFromOwnerLocked(Event: PEvent);
var
  Link: ^PEvent;
begin
  Link := @Event^.Owner^.OwnedMutexes;
  while (Link^ <> nil) and (Link^ <> Event) do
    Link := @Link^^.NextOwned;
  if Link^ = Event then
    Link^ := Event^.NextOwned;
  Event^.NextOwned := nil;
end;

{ Frees an owned mutex and lets its first waiter have it. }
procedure FreeMutexLocked(Event: PEvent; Abandoned: Boolean);
begin
  UnlinkFromOwnerLocked(Event);
  Event^.Owner := nil;
  Event^.SignalCount := 0;
  Event^.Abandoned := Abandoned;
  Event^.IsSignaled := True;
  ReleaseEventWaitersLocked(Event^, BoostEvent);
end;

function ReleaseMutexEvent(var Event: TEvent; out RemainingHolds: LongInt): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  Result := (Event.Owner <> nil) and (Event.Owner = CurrentThread);
  RemainingHolds := Event.SignalCount;
  if Result then
  begin
    Dec(Event.SignalCount);
    RemainingHolds := Event.SignalCount;
    if Event.SignalCount = 0 then
      FreeMutexLocked(@Event, False);
  end;
  ReleaseDispatcherLock(PreviousLevel);
end;

procedure AbandonOwnedMutexEvents(Thread: PThreadControlBlock);
var
  PreviousLevel: TPriorityLevel;
begin
  if Thread^.OwnedMutexes = nil then
    Exit;
  PreviousLevel := AcquireDispatcherLock;
  while Thread^.OwnedMutexes <> nil do
    FreeMutexLocked(PEvent(Thread^.OwnedMutexes), True);
  ReleaseDispatcherLock(PreviousLevel);
end;

procedure DiscardMutexEvent(var Event: TEvent);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  if Event.Owner <> nil then
  begin
    UnlinkFromOwnerLocked(@Event);
    Event.Owner := nil;
  end;
  ReleaseDispatcherLock(PreviousLevel);
end;

function TakeAbandonedMark(var Event: TEvent): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  Result := Event.Abandoned and (Event.Owner = CurrentThread);
  if Result then
    Event.Abandoned := False;
  ReleaseDispatcherLock(PreviousLevel);
end;

function MutexEventOwner(var Event: TEvent): PThreadControlBlock;
begin
  Result := Event.Owner;
end;

function MutexEventHolds(var Event: TEvent): LongInt;
begin
  Result := Event.SignalCount;
end;

end.
