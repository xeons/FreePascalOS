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
  Input events: every keyboard and pointing device as one stream of
  events (TAbiInputEvent), for the program that takes the input (a
  display server).

  The device is /dev/events. One program opens it at a time; while it is
  open, the keyboards' characters stop going to the text console (they
  come as events instead), and when it closes they go back. Drivers add
  events from any level, interrupt handlers included (AddInputEvent);
  nobody listening, they are dropped. Each device gets a source number
  (NewInputSource) the events carry. Reads return whole events, as many
  as fit and have arrived, waiting for at least one.
}
unit Io.InputEvents;

{$mode objfpc}
{$pointermath on}

interface

uses
  Abi.SystemCalls;

procedure InitializeInputEvents;
{ A number for a new keyboard or pointing device. }
function NewInputSource: Word;
{ True while a program has the input (the console does not). }
function InputIsTaken: Boolean;
{ Queues Event (its time is filled in). Any level. }
procedure AddInputEvent(var Event: TAbiInputEvent);

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Kernel.Events,
  Kernel.PriorityLevel,
  Kernel.Arch.Cpu,
  Kernel.SpinLock,
  Kernel.DeferredCalls,
  Kernel.Clock,
  Io.Manager,
  Debug.Output;

const
  RingCapacity = 256;
  OwnerOnly = $180; { rw------- }

var
  Driver: PDriverObject;
  Lock: TSpinLock;
  Ring: array[0..RingCapacity - 1] of TAbiInputEvent;
  RingStart: LongWord;
  RingCount: LongWord;
  Dropped: QWord;
  WaitingReads: TRequestQueue;
  CompleteReads: TDeferredCall;
  Taken: Boolean;
  NextSource: Int64;
  { Signaled while events wait to be read. }
  Ready: TEvent;

{ Moves whole events into Request; Lock held. }
function TakeEventsLocked(var Request: TIoRequest): QWord;
var
  Destination: PAbiInputEvent;
  Count: QWord;
begin
  Destination := PAbiInputEvent(Request.Buffer);
  Count := 0;
  while ((Count + 1) * SizeOf(TAbiInputEvent) <= Request.Length) and (RingCount > 0) do
  begin
    Destination[Count] := Ring[RingStart];
    RingStart := (RingStart + 1) mod RingCapacity;
    Dec(RingCount);
    Inc(Count);
  end;
  if RingCount = 0 then
    ResetEvent(Ready);
  Result := Count * SizeOf(TAbiInputEvent);
end;

procedure CompleteWaitingReads(Context: Pointer);
var
  Request: PIoRequest;
  WereEnabled: Boolean;
begin
  repeat
    Request := nil;
    WereEnabled := SaveAndDisableInterrupts;
    AcquireSpinLockAtCurrentLevel(Lock);
    if RingCount > 0 then
    begin
      Request := TakeQueuedRequest(WaitingReads);
      if Request <> nil then
        Request^.Information := Int64(TakeEventsLocked(Request^));
    end;
    ReleaseSpinLockAtCurrentLevel(Lock);
    RestoreInterrupts(WereEnabled);
    if Request = nil then
      Break;
    CompleteRequest(Request^, ErrorNone);
  until False;
  { Interrupt handlers add events but cannot signal (above dispatch
    level): it is done here, and reset by the reader that empties the
    ring, both under the lock, so a reset never undoes a newer signal. }
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Lock);
  if RingCount > 0 then
    SignalEvent(Ready);
  ReleaseSpinLockAtCurrentLevel(Lock);
  RestoreInterrupts(WereEnabled);
end;

procedure AddInputEvent(var Event: TAbiInputEvent);
var
  WereEnabled: Boolean;
begin
  if not Taken then
    Exit;
  Event.Time := UptimeMilliseconds;
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Lock);
  if RingCount < RingCapacity then
  begin
    Ring[(RingStart + RingCount) mod RingCapacity] := Event;
    Inc(RingCount);
  end
  else
    Inc(Dropped);
  ReleaseSpinLockAtCurrentLevel(Lock);
  RestoreInterrupts(WereEnabled);
  QueueDeferredCall(CompleteReads);
end;

function NewInputSource: Word;
begin
  Result := Word(AtomicIncrement(NextSource) - 1);
end;

function InputIsTaken: Boolean;
begin
  Result := Taken;
end;

{ --- The device ------------------------------------------------------------- }

function OpenEvents(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  WereEnabled: Boolean;
  PreviousLevel: TPriorityLevel;
begin
  if Taken then
    Exit(ErrorBusy);
  { At dispatch level, so resetting the event (which takes the
    dispatcher lock) cannot switch threads with the lock held. }
  PreviousLevel := RaisePriorityLevel(DispatchLevel);
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Lock);
  RingStart := 0;
  RingCount := 0;
  ResetEvent(Ready);
  Taken := True;
  ReleaseSpinLockAtCurrentLevel(Lock);
  RestoreInterrupts(WereEnabled);
  LowerPriorityLevel(PreviousLevel);
  Result := ErrorNone;
end;

function CloseEvents(Device: PDeviceObject; var Request: TIoRequest): LongInt;
begin
  Taken := False;
  Result := ErrorNone;
end;

function ReadEvents(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  WereEnabled: Boolean;
  PreviousLevel: TPriorityLevel;
begin
  if Request.Length < SizeOf(TAbiInputEvent) then
    Exit(ErrorInvalidArgument);
  { (At dispatch level for the same reason as in OpenEvents.) }
  PreviousLevel := RaisePriorityLevel(DispatchLevel);
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Lock);
  Request.Information := Int64(TakeEventsLocked(Request));
  ReleaseSpinLockAtCurrentLevel(Lock);
  RestoreInterrupts(WereEnabled);
  LowerPriorityLevel(PreviousLevel);
  if Request.Information > 0 then
    Exit(ErrorNone);
  if not QueueRequest(WaitingReads, Request) then
    Exit(ErrorInterrupted);
  QueueDeferredCall(CompleteReads);
  Result := StatusPending;
end;

procedure InitializeInputEvents;
var
  Dispatch: TDispatchTable;
  Device: PDeviceObject;
begin
  InitializeSpinLock(Lock);
  InitializeEvent(Ready, EventKindNotification, False);
  InitializeRequestQueue(WaitingReads);
  InitializeDeferredCall(CompleteReads, @CompleteWaitingReads, nil);
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionOpen] := @OpenEvents;
  Dispatch[IoFunctionClose] := @CloseEvents;
  Dispatch[IoFunctionRead] := @ReadEvents;
  Driver := CreateDriver('events', Dispatch);
  Device := CreateDevice(Driver, 'events', DeviceKindCharacter, OwnerOnly, 0);
  if Device <> nil then
    Device^.ReadyEvent := @Ready
  else
  begin
    DebugBeginMessage;
    DebugWriteTag('input');
    DebugWriteLine('could not create /dev/events');
    DebugEndMessage;
  end;
end;

end.
