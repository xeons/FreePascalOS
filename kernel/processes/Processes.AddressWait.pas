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
  Waiting on an address: the kernel half of user-mode locks.

  A user-mode lock lives in an ordinary 32-bit word of the process. Taking
  and releasing it is an atomic instruction in user mode; only when it
  is contended does a thread ask the kernel to sleep "while the word
  still holds this value" (WaitOnAddress), and the releasing thread asks
  the kernel to wake sleepers on that word (WakeAddress).

  The value is compared under the same lock that wakers take, so a wake
  that comes after the user-mode check but before the thread is queued
  cannot be lost: either the waiter sees the changed value and does not
  sleep, or it is already queued when the waker looks.

  Waiters are keyed by address space and address and kept in one list;
  the number of sleeping threads is small.
}
unit Processes.AddressWait;

{$mode objfpc}

interface

uses
  Processes.AddressSpace;

{ Returns ErrorNone when woken, ErrorBusy if the value differed,
  ErrorTimedOut, ErrorInterrupted (alerted) or ErrorBadAddress. }
function WaitOnAddress(Space: PAddressSpace; Address: QWord; ExpectedValue: LongWord;
  TimeoutMilliseconds: QWord): LongInt;

{ Wakes up to Count waiters on Address; returns how many. }
function WakeAddress(Space: PAddressSpace; Address: QWord; Count: QWord): QWord;

procedure InitializeAddressWaits;

implementation

uses
  Runtime.LinkedList,
  Abi.SystemCalls,
  Kernel.SpinLock,
  Kernel.PriorityLevel,
  Kernel.Threads,
  Kernel.Events;

type
  PAddressWaiter = ^TAddressWaiter;
  TAddressWaiter = record
    Link: TListEntry;
    Space: PAddressSpace;
    Address: QWord;
    Event: TEvent;
    WasWoken: Boolean;
  end;

var
  WaitLock: TSpinLock;
  Waiters: TListEntry;

procedure InitializeAddressWaits;
begin
  InitializeSpinLock(WaitLock);
  InitializeListHead(Waiters);
end;

function WaiterFromLink(Entry: PListEntry): PAddressWaiter;
begin
  Result := PAddressWaiter(ContainingRecord(Entry, FieldOffset(PAddressWaiter(nil)^.Link)));
end;

function WaitOnAddress(Space: PAddressSpace; Address: QWord; ExpectedValue: LongWord;
  TimeoutMilliseconds: QWord): LongInt;
var
  Waiter: TAddressWaiter;
  CurrentValue: LongWord;
  PreviousLevel: TPriorityLevel;
  WaitResult: TWaitResult;
begin
  if (Address and 3) <> 0 then
    Exit(ErrorInvalidArgument);
  Waiter.Space := Space;
  Waiter.Address := Address;
  Waiter.WasWoken := False;
  InitializeEvent(Waiter.Event, EventKindNotification, False);

  PreviousLevel := AcquireSpinLock(WaitLock);
  Result := ReadFromAddressSpace(Space, Address, @CurrentValue, SizeOf(CurrentValue));
  if (Result = ErrorNone) and (CurrentValue <> ExpectedValue) then
    Result := ErrorBusy;
  if Result = ErrorNone then
    InsertAtTail(Waiters, @Waiter.Link);
  ReleaseSpinLock(WaitLock, PreviousLevel);
  if Result <> ErrorNone then
    Exit;

  WaitResult := WaitForEventWithOptions(Waiter.Event, TimeoutMilliseconds, True);

  { A waker removes the waiter itself; otherwise it is still queued. The
    waiter (with its event) lives on this stack, so it must be off the
    list before returning. }
  PreviousLevel := AcquireSpinLock(WaitLock);
  if not Waiter.WasWoken then
    RemoveListEntry(@Waiter.Link);
  ReleaseSpinLock(WaitLock, PreviousLevel);

  if Waiter.WasWoken then
    Result := ErrorNone
  else if WaitResult = WaitTimedOut then
    Result := ErrorTimedOut
  else
    Result := ErrorInterrupted;
end;

function WakeAddress(Space: PAddressSpace; Address: QWord; Count: QWord): QWord;
var
  PreviousLevel: TPriorityLevel;
  Entry: PListEntry;
  NextEntry: PListEntry;
  Waiter: PAddressWaiter;
begin
  Result := 0;
  PreviousLevel := AcquireSpinLock(WaitLock);
  Entry := Waiters.Next;
  while (Entry <> @Waiters) and (Result < Count) do
  begin
    NextEntry := Entry^.Next;
    Waiter := WaiterFromLink(Entry);
    if (Waiter^.Space = Space) and (Waiter^.Address = Address) then
    begin
      RemoveListEntry(Entry);
      Waiter^.WasWoken := True;
      SignalEvent(Waiter^.Event);
      Inc(Result);
    end;
    Entry := NextEntry;
  end;
  ReleaseSpinLock(WaitLock, PreviousLevel);
end;

end.
