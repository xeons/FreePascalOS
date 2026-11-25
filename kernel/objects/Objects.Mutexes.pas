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
  Mutex objects: mutex events (Kernel.MutexEvents) that programs create,
  take by waiting on their handles (CallWaitForHandles) and release
  (CallReleaseMutex). A thread of a program owns the mutex it took, may
  take it again, and abandons it by ending without releasing it.
}
unit Objects.Mutexes;

{$mode objfpc}

interface

uses
  Kernel.Events;

type
  PMutexObject = ^TMutexObject;
  TMutexObject = record
    Event: TEvent;
  end;

procedure InitializeMutexObjects;
{ A new mutex object with one reference (the caller's), owned by the
  calling thread if InitiallyOwned; nil if memory ran out. }
function CreateMutexObject(InitiallyOwned: Boolean): PMutexObject;

implementation

uses
  Abi.SystemCalls,
  Kernel.MutexEvents,
  Objects.Manager;

var
  MutexObjectType: TObjectType;

procedure DeleteMutexObject(ObjectBody: Pointer);
begin
  DiscardMutexEvent(PMutexObject(ObjectBody)^.Event);
end;

procedure InitializeMutexObjects;
begin
  RegisterObjectType(MutexObjectType, 'Mutex', SizeOf(TMutexObject), @DeleteMutexObject);
  SetObjectTypeOpenKind(MutexObjectType, HandleKindMutex);
end;

function CreateMutexObject(InitiallyOwned: Boolean): PMutexObject;
begin
  Result := PMutexObject(CreateObject(MutexObjectType, nil));
  if Result = nil then
    Exit;
  InitializeMutexEvent(Result^.Event);
  { Free and new, so this take never waits. }
  if InitiallyOwned then
    WaitForEventWithOptions(Result^.Event, 0, False);
end;

end.
