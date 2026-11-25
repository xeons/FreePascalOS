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
  Event objects: events (Kernel.Events) that programs create, set, reset
  and wait on through handles.

  A manual reset event stays signaled until reset and releases every
  waiter (a notification event); an automatic reset event releases one
  waiter and resets itself (a synchronization event).
}
unit Objects.Events;

{$mode objfpc}

interface

uses
  Kernel.Events;

type
  PEventObject = ^TEventObject;
  TEventObject = record
    Event: TEvent;
  end;

procedure InitializeEventObjects;
{ A new event object with one reference (the caller's); nil if memory
  ran out. }
function CreateEventObject(ManualReset, Signaled: Boolean): PEventObject;

implementation

uses
  Abi.SystemCalls,
  Objects.Manager;

var
  EventObjectType: TObjectType;

procedure InitializeEventObjects;
begin
  RegisterObjectType(EventObjectType, 'Event', SizeOf(TEventObject), nil);
  SetObjectTypeOpenKind(EventObjectType, HandleKindEvent);
end;

function CreateEventObject(ManualReset, Signaled: Boolean): PEventObject;
begin
  Result := PEventObject(CreateObject(EventObjectType, nil));
  if Result = nil then
    Exit;
  if ManualReset then
    InitializeEvent(Result^.Event, EventKindNotification, Signaled)
  else
    InitializeEvent(Result^.Event, EventKindSynchronization, Signaled);
end;

end.
