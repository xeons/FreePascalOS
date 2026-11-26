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
  Event counters (eventfd): a 64-bit count that writers add to and
  readers take.

  A read takes the whole count and leaves zero, or (a semaphore counter)
  takes one; with the count at zero it waits for a writer. A write adds
  a value; one that would take the count past EventCounterMaximum waits
  for a reader to make room. A non-blocking counter fails with
  ErrorWouldBlock instead of waiting.

  Two notification events follow the count, for waits on several
  handles and for event polls: Readable while it is above zero, Writable
  while one more can be added. Each write signals Readable again and each
  read Writable, even when they were signaled already, so an edge
  triggered event poll hears of every change, as on other systems.
}
unit Objects.EventCounters;

{$mode objfpc}

interface

uses
  Kernel.Events,
  Kernel.Mutex;

type
  PEventCounter = ^TEventCounter;
  TEventCounter = record
    Lock: TMutex;
    Count: QWord;
    IsSemaphore: Boolean;
    NonBlocking: Boolean;
    Readable: TEvent;
    Writable: TEvent;
    { For writers waiting for room: reset by a writer that found too
      little (under Lock), signaled by every read. }
    RoomMade: TEvent;
  end;

procedure InitializeEventCounters;
{ A new counter with one reference (the caller's); nil if memory ran out. }
function CreateEventCounter(InitialCount: QWord; IsSemaphore, NonBlocking: Boolean): PEventCounter;

{ Takes the count (or one) into Value: ErrorNone, ErrorWouldBlock (non
  blocking and zero) or ErrorInterrupted (the wait was alerted). }
function ReadEventCounter(Counter: PEventCounter; out Value: QWord): LongInt;
{ Adds Value: ErrorNone, ErrorInvalidArgument (all ones),
  ErrorWouldBlock or ErrorInterrupted. }
function WriteEventCounter(Counter: PEventCounter; Value: QWord): LongInt;

{ What poll says of it (Poll* bits). }
function EventCounterReadiness(Counter: PEventCounter): LongWord;

implementation

uses
  Abi.SystemCalls,
  Kernel.Threads,
  Kernel.Scheduler,
  Objects.Manager;

var
  EventCounterType: TObjectType;

procedure InitializeEventCounters;
begin
  RegisterObjectType(EventCounterType, 'EventCounter', SizeOf(TEventCounter), nil);
end;

{ Readable and Writable as the count says; Lock held. }
procedure UpdateReadinessLocked(Counter: PEventCounter);
begin
  if Counter^.Count = 0 then
    ResetEvent(Counter^.Readable);
  if Counter^.Count >= EventCounterMaximum then
    ResetEvent(Counter^.Writable);
end;

function CreateEventCounter(InitialCount: QWord; IsSemaphore, NonBlocking: Boolean): PEventCounter;
begin
  Result := PEventCounter(CreateObject(EventCounterType, nil));
  if Result = nil then
    Exit;
  InitializeMutex(Result^.Lock);
  Result^.Count := InitialCount;
  Result^.IsSemaphore := IsSemaphore;
  Result^.NonBlocking := NonBlocking;
  InitializeEvent(Result^.Readable, EventKindNotification, InitialCount > 0);
  InitializeEvent(Result^.Writable, EventKindNotification, InitialCount < EventCounterMaximum);
  InitializeEvent(Result^.RoomMade, EventKindNotification, False);
end;

{ Waits for Event (alertable): ErrorNone once signaled, ErrorInterrupted. }
function WaitForChange(var Event: TEvent): LongInt;
begin
  if WaitForEventWithOptions(Event, InfiniteTimeout, True) = WaitSignaled then
    Result := ErrorNone
  else
    Result := ErrorInterrupted;
end;

function ReadEventCounter(Counter: PEventCounter; out Value: QWord): LongInt;
begin
  Value := 0;
  repeat
    AcquireMutex(Counter^.Lock);
    if Counter^.Count > 0 then
    begin
      if Counter^.IsSemaphore then
        Value := 1
      else
        Value := Counter^.Count;
      Counter^.Count := Counter^.Count - Value;
      UpdateReadinessLocked(Counter);
      SignalEvent(Counter^.Writable);
      SignalEvent(Counter^.RoomMade);
      ReleaseMutex(Counter^.Lock);
      Exit(ErrorNone);
    end;
    ReleaseMutex(Counter^.Lock);
    if Counter^.NonBlocking then
      Exit(ErrorWouldBlock);
    Result := WaitForChange(Counter^.Readable);
  until Result <> ErrorNone;
end;

function WriteEventCounter(Counter: PEventCounter; Value: QWord): LongInt;
begin
  if Value = High(QWord) then
    Exit(ErrorInvalidArgument);
  repeat
    AcquireMutex(Counter^.Lock);
    if Value <= EventCounterMaximum - Counter^.Count then
    begin
      Counter^.Count := Counter^.Count + Value;
      UpdateReadinessLocked(Counter);
      if Counter^.Count > 0 then
        SignalEvent(Counter^.Readable);
      ReleaseMutex(Counter^.Lock);
      Exit(ErrorNone);
    end;
    if not Counter^.NonBlocking then
      ResetEvent(Counter^.RoomMade);
    ReleaseMutex(Counter^.Lock);
    if Counter^.NonBlocking then
      Exit(ErrorWouldBlock);
    Result := WaitForChange(Counter^.RoomMade);
  until Result <> ErrorNone;
end;

function EventCounterReadiness(Counter: PEventCounter): LongWord;
var
  Count: QWord;
begin
  Count := Counter^.Count;
  Result := 0;
  if Count > 0 then
    Result := Result or PollReadable;
  if Count < EventCounterMaximum then
    Result := Result or PollWritable;
end;

end.
