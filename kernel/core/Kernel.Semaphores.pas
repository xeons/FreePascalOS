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
  Semaphores: a count of things available, from zero up to a limit.

  A wait takes one (and waits while there are none); a release gives
  back one or more, releasing as many waiters as it can in the order
  they came. A release that would take the count above the limit fails
  and changes nothing.

  A semaphore is an event of kind EventKindSemaphore (Kernel.Events),
  signaled while its count is above zero, so it is waited on like any
  event: alone, among others (WaitForAnyEvent) or together with others
  (WaitForAllEvents, which takes one from it only when all are
  signaled). The waiters it releases get the BoostEvent priority boost.

  Waiting is for PassiveLevel; releasing may be done at DispatchLevel
  or below (from a deferred call, for example).
}
unit Kernel.Semaphores;

{$mode objfpc}

interface

uses
  Kernel.Threads,
  Kernel.Events;

const
  MaximumSemaphoreLimit = High(LongInt);

type
  TSemaphore = record
    { Kind EventKindSemaphore; SignalCount is the count. }
    Event: TEvent;
    Limit: LongInt;
  end;
  PSemaphore = ^TSemaphore;

{ InitialCount must lie between 0 and Limit, Limit at least 1. }
procedure InitializeSemaphore(out Semaphore: TSemaphore; InitialCount, Limit: LongInt);
{ Gives back ReleaseCount (at least 1). False, changing nothing, if
  that would take the count above the limit; PreviousCount is the count
  before. }
function ReleaseSemaphore(var Semaphore: TSemaphore; ReleaseCount: LongInt;
  out PreviousCount: LongInt): Boolean;
{ Takes one, waiting at most TimeoutMilliseconds (InfiniteTimeout, or 0
  only to try); an alertable wait also ends when the thread is
  alerted. }
function WaitForSemaphore(var Semaphore: TSemaphore; TimeoutMilliseconds: QWord;
  Alertable: Boolean): TWaitResult;
function SemaphoreCount(var Semaphore: TSemaphore): LongInt;

implementation

uses
  Kernel.PriorityLevel,
  Kernel.PriorityBoosts,
  Kernel.Scheduler,
  Kernel.Panic;

procedure InitializeSemaphore(out Semaphore: TSemaphore; InitialCount, Limit: LongInt);
begin
  if (Limit < 1) or (InitialCount < 0) or (InitialCount > Limit) then
    KernelPanicWithCode(PanicSchedulerFailure, 'invalid semaphore count or limit',
      QWord(@Semaphore), QWord(InitialCount), QWord(Limit), 0);
  InitializeEvent(Semaphore.Event, EventKindSemaphore, InitialCount > 0);
  Semaphore.Event.SignalCount := InitialCount;
  Semaphore.Limit := Limit;
end;

function ReleaseSemaphore(var Semaphore: TSemaphore; ReleaseCount: LongInt;
  out PreviousCount: LongInt): Boolean;
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireDispatcherLock;
  PreviousCount := Semaphore.Event.SignalCount;
  { Written so it cannot overflow: Count <= Limit always holds. }
  Result := (ReleaseCount >= 1) and (ReleaseCount <= Semaphore.Limit - PreviousCount);
  if Result then
  begin
    Inc(Semaphore.Event.SignalCount, ReleaseCount);
    Semaphore.Event.IsSignaled := True;
    ReleaseEventWaitersLocked(Semaphore.Event, BoostEvent);
  end;
  ReleaseDispatcherLock(PreviousLevel);
end;

function WaitForSemaphore(var Semaphore: TSemaphore; TimeoutMilliseconds: QWord;
  Alertable: Boolean): TWaitResult;
begin
  Result := WaitForEventWithOptions(Semaphore.Event, TimeoutMilliseconds, Alertable);
end;

function SemaphoreCount(var Semaphore: TSemaphore): LongInt;
begin
  Result := Semaphore.Event.SignalCount;
end;

end.
