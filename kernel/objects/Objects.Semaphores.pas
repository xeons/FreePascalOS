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
  Semaphore objects: semaphores (Kernel.Semaphores) that programs
  create, release and wait on through handles (CallCreateSemaphore,
  CallReleaseSemaphore, CallWaitForHandles). A wait that a semaphore
  ends takes one from its count.
}
unit Objects.Semaphores;

{$mode objfpc}

interface

uses
  Kernel.Semaphores;

type
  PSemaphoreObject = ^TSemaphoreObject;
  TSemaphoreObject = record
    Semaphore: TSemaphore;
  end;

procedure InitializeSemaphoreObjects;
{ A new semaphore object with one reference (the caller's); nil if
  memory ran out. The caller checked the count and the limit. }
function CreateSemaphoreObject(InitialCount, Limit: LongInt): PSemaphoreObject;

implementation

uses
  Abi.SystemCalls,
  Objects.Manager;

var
  SemaphoreObjectType: TObjectType;

procedure InitializeSemaphoreObjects;
begin
  RegisterObjectType(SemaphoreObjectType, 'Semaphore', SizeOf(TSemaphoreObject), nil);
  SetObjectTypeOpenKind(SemaphoreObjectType, HandleKindSemaphore);
end;

function CreateSemaphoreObject(InitialCount, Limit: LongInt): PSemaphoreObject;
begin
  Result := PSemaphoreObject(CreateObject(SemaphoreObjectType, nil));
  if Result = nil then
    Exit;
  InitializeSemaphore(Result^.Semaphore, InitialCount, Limit);
end;

end.
